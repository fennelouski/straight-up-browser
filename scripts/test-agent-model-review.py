import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("model_review", Path(__file__).with_name("check-agent-model-review.py"))
reviewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reviewer)


class ReviewGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Straight Up Browser.xcodeproj").mkdir()
        (self.root / "Straight Up Browser.xcodeproj/project.pbxproj").write_text(
            'buildSettings = { PRODUCT_NAME = Browser; MARKETING_VERSION = 2.9.17; };\n'
            'buildSettings = { PRODUCT_NAME = Browser; MARKETING_VERSION = 2.0.0; SDKROOT = iphoneos; };')
        (self.root / "catalog.swift").write_text("reviewed models")
        self.review = {
            "releaseVersion": "2.9.17",
            "reviewedOn": dt.datetime.now(dt.timezone.utc).date().isoformat(),
            "sourceFiles": {"catalog.swift": hashlib.sha256(b"reviewed models").hexdigest()},
            "providerSources": [{"url": "https://provider.invalid/models", "sha256": "reviewed"}],
        }
        self.path = self.root / "review.json"

    def run_gate(self, live=False):
        self.path.write_text(json.dumps(self.review))
        with patch.object(reviewer, "ROOT", self.root), patch.object(reviewer, "REVIEW", self.path), \
             patch.object(sys, "argv", ["review"] + (["--live"] if live else [])), \
             contextlib.redirect_stdout(io.StringIO()):
            reviewer.main()

    def test_matching_mac_review_passes_independent_ios_version(self):
        self.run_gate()

    def test_previous_release_review_is_rejected(self):
        self.review["releaseVersion"] = "2.9.16"
        with self.assertRaises(ValueError):
            self.run_gate()

    def test_stale_and_future_reviews_are_rejected(self):
        today = dt.datetime.now(dt.timezone.utc).date()
        for delta in [-8, 1]:
            self.review["reviewedOn"] = (today + dt.timedelta(days=delta)).isoformat()
            with self.assertRaises(ValueError):
                self.run_gate()

    def test_unreviewed_implementation_is_rejected(self):
        (self.root / "catalog.swift").write_text("changed models")
        with self.assertRaises(ValueError):
            self.run_gate()

    def test_provider_drift_and_network_failure_stop_live_release(self):
        with patch.object(reviewer, "source_digest", return_value="changed"):
            with self.assertRaises(ValueError):
                self.run_gate(live=True)
        with patch.object(reviewer, "source_digest", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                self.run_gate(live=True)

    def test_matching_live_sources_pass(self):
        with patch.object(reviewer, "source_digest", return_value="reviewed"):
            self.run_gate(live=True)


if __name__ == "__main__":
    unittest.main()
