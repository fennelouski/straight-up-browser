#!/usr/bin/env python3
"""Require a release-specific model review; recheck public provider sources at release."""
import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.request
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parent.parent
REVIEW = ROOT / "docs/agent-model-review.json"


class MainText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_main = False
        self.skip = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "main":
            self.in_main = True
        if tag in ("script", "style"):
            self.skip += 1

    def handle_endtag(self, tag):
        if tag == "main":
            self.in_main = False
        if tag in ("script", "style"):
            self.skip = max(0, self.skip - 1)

    def handle_data(self, text):
        if self.in_main and not self.skip:
            self.parts.append(text)


def source_digest(source):
    request = urllib.request.Request(source["url"], headers={"User-Agent": "BrowserReleaseModelReview/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        text = response.read(4 * 1024 * 1024).decode("utf-8")
    if source["format"] == "openai-featured":
        text = text.split("## Featured models", 1)[1].split("## Browse", 1)[0]
    elif source["format"] == "html-main":
        parser = MainText()
        parser.feed(text)
        text = " ".join(parser.parts)
        if not text.strip():
            raise ValueError("Provider page has no readable model content")
    elif source["format"] == "openrouter-models":
        available = {model["id"] for model in json.loads(text)["data"]}
        if not set(source["requiredIDs"]).issubset(available):
            raise ValueError("A reviewed OpenRouter model is no longer available")
        text = "\n".join(sorted(source["requiredIDs"]))
    elif source["format"] != "markdown":
        raise ValueError("Unrecognized model-review source format")
    return hashlib.sha256(" ".join(text.split()).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Recheck official model and pricing sources")
    args = parser.parse_args()
    review = json.loads(REVIEW.read_text())
    project = (ROOT / "Straight Up Browser.xcodeproj/project.pbxproj").read_text()
    settings = re.findall(r"buildSettings = \{(.*?)\};", project, re.S)
    versions = {re.search(r"MARKETING_VERSION = ([^;]+);", block).group(1)
                for block in settings if "PRODUCT_NAME = Browser;" in block
                and "SDKROOT = iphoneos;" not in block}
    if versions != {review["releaseVersion"]}:
        raise ValueError("Review the current provider models and update the review for this release version")
    reviewed = dt.date.fromisoformat(review["reviewedOn"])
    age = (dt.datetime.now(dt.timezone.utc).date() - reviewed).days
    if not 0 <= age <= 7:
        raise ValueError("The provider model review must be completed within seven days of release")
    for file, expected in review["sourceFiles"].items():
        if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Model implementation changed since review: {file}")
    if args.live:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(source_digest, review["providerSources"]))
        for source, actual in zip(review["providerSources"], results):
            if source["sha256"] != actual:
                raise ValueError(f"Provider model or pricing information changed; review before releasing: {source['url']}")
    print("Agent model review passed" + (" with live provider checks." if args.live else "."))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError) as error:
        print(f"Agent model review failed: {error}", file=sys.stderr)
        sys.exit(1)
