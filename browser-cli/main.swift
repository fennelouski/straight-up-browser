#!/usr/bin/env swift
//
//  main.swift
//  browser-cli
//
//  Created by Nathan Fennel on 1/9/26.
//

import Foundation

// Command line interface for the Internet browser (Straight Up Browser).
// Usage: browser-cli <command> [arguments]
// Run `browser-cli docs` for the full agent-oriented guide.
//
// Talks to the app over a named pipe in the app's own Application Support
// directory (owner-only permissions - filesystem permissions are the auth).
// Every command passes a response file name inside the app's response
// directory and polls it for the JSON result. Contract: {"ok":true,...} to
// stdout with exit 0; {"error":"..."} to stderr with exit 1.

let supportDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Straight Up Browser", isDirectory: true)
let pipePath = supportDirectory.appendingPathComponent("cli.pipe").path
let responseDirectory = supportDirectory.appendingPathComponent("responses", isDirectory: true)

// MARK: - Small helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// Base64 lets payloads with spaces/newlines/quotes survive the
// one-line-per-command pipe protocol
func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

// JSON string literal (quotes included) - for embedding user input in JS
func jsonLiteral(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), encoding: .utf8)!
}

// MARK: - Transport

func openPipe() -> FileHandle? {
    // O_NONBLOCK: open() fails with ENXIO when no reader (the app) is
    // attached instead of hanging forever. A plain write(toFile:atomically:)
    // would rename() over the FIFO and destroy it - never do that.
    let fd = open(pipePath, O_WRONLY | O_NONBLOCK)
    return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
}

func launchApp() {
    // This binary ships at Internet.app/Contents/Helpers/browser-cli - walk
    // up to the bundle so we launch the exact copy we belong to. Fall back to
    // Launch Services by name for dev builds living outside a bundle.
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
    let bundle = exe
        .deletingLastPathComponent() // Helpers
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // Internet.app
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = bundle.pathExtension == "app" ? [bundle.path] : ["-a", "Internet"]
    try? process.run()
    process.waitUntilExit()
}

func sendCommand(_ command: String) {
    var handle = openPipe()
    if handle == nil {
        // App not running (or pipe missing): launch it and wait for the pipe.
        // Status goes to stderr so stdout stays clean JSON.
        FileHandle.standardError.write(Data("Browser not running - launching it...\n".utf8))
        launchApp()
        let deadline = Date().addingTimeInterval(20)
        while handle == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            handle = openPipe()
        }
    }
    guard let handle = handle else {
        fail("Error: Could not reach the browser. Open the Internet app manually and retry (first launch may be waiting on the EULA).")
    }
    // One command per line; strip any stray newlines (structured payloads are base64)
    let line = command
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    handle.write(Data((line + "\n").utf8))
    try? handle.close()
}

// Send a command and return the raw response bytes (JSON, or PNG for screenshot).
// Only the response FILENAME goes over the pipe (the full path contains
// spaces, and the app only writes inside its own response directory).
func requestResponse(_ command: String, timeout: TimeInterval = 15) -> Data {
    try? FileManager.default.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
    let responseName = "response_\(UUID().uuidString).json"
    let responseFile = responseDirectory.appendingPathComponent(responseName)

    sendCommand("\(command) --response-file \(responseName)")

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let data = try? Data(contentsOf: responseFile), !data.isEmpty {
            try? FileManager.default.removeItem(at: responseFile)
            return data
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    try? FileManager.default.removeItem(at: responseFile)
    fail("Error: Timeout waiting for response from browser.")
}

// Print a JSON response; a top-level "error" key goes to stderr with exit 1
func printResponse(_ data: Data) {
    if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], dict["error"] != nil {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        exit(1)
    }
    print(String(data: data, encoding: .utf8) ?? "")
}

// Run JavaScript in the active tab and return the parsed envelope
// ({"ok":true,"result":...}); JS exceptions and eval errors exit 1.
@discardableResult
func runJS(_ code: String, timeout: TimeInterval = 15) -> [String: Any] {
    let data = requestResponse("js \(b64(code))", timeout: timeout)
    guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail("Error: malformed response: \(String(data: data, encoding: .utf8) ?? "")")
    }
    if dict["error"] != nil {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        exit(1)
    }
    return dict
}

// MARK: - JavaScript builders (click/type/snapshot are sugar over `js`)

func clickJS(_ selector: String) -> String {
    let sel = jsonLiteral(selector)
    return """
    var el = document.querySelector(\(sel));
    if (!el) throw new Error('no element matches selector: ' + \(sel));
    el.scrollIntoView({block: 'center'});
    el.click();
    'clicked'
    """
}

func typeJS(_ selector: String, _ text: String) -> String {
    let sel = jsonLiteral(selector)
    let value = jsonLiteral(text)
    // Native value setter + input/change events so framework-managed inputs
    // (React etc.) see the change
    return """
    var el = document.querySelector(\(sel));
    if (!el) throw new Error('no element matches selector: ' + \(sel));
    el.focus();
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, \(value));
    } else {
        el.value = \(value);
    }
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
    'typed'
    """
}

// ponytail: main document only - no shadow DOM or iframes. Agents fall back
// to `js` for those.
let snapshotJS = #"""
var lines = [];
lines.push('URL: ' + location.href);
lines.push('TITLE: ' + document.title);
var els = Array.from(document.querySelectorAll(
    'a[href],button,input,select,textarea,[role=button],[role=link],[role=textbox],[role=checkbox],[role=combobox],[onclick],[contenteditable=true]'
)).filter(function(el) {
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
});
function cssPath(el) {
    if (el.id) return '#' + CSS.escape(el.id);
    var path = [];
    var node = el;
    while (node && node !== document.body && node.nodeType === 1) {
        if (node.id) { path.unshift('#' + CSS.escape(node.id)); break; }
        var i = 1, sib = node;
        while ((sib = sib.previousElementSibling)) { if (sib.tagName === node.tagName) i++; }
        path.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + i + ')');
        node = node.parentElement;
    }
    if (path.length === 0 || path[0][0] !== '#') path.unshift('body');
    return path.join('>');
}
function label(el) {
    var n = el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.alt || el.title || '';
    n = String(n).replace(/\s+/g, ' ').trim();
    return n.length > 80 ? n.slice(0, 80) + '…' : n;
}
var max = 150;
lines.push('');
lines.push('INTERACTIVE (' + els.length + (els.length > max ? ', showing first ' + max : '') + '):');
els.slice(0, max).forEach(function(el) {
    var tag = el.tagName.toLowerCase();
    var d = tag;
    if (tag === 'input') d += '[' + (el.type || 'text') + ']';
    d += ' "' + label(el) + '" ' + cssPath(el);
    if (tag === 'a' && el.href) d += ' -> ' + el.href;
    if (el.type === 'checkbox' || el.type === 'radio') d += ' checked=' + el.checked;
    else if (tag === 'input' || tag === 'textarea' || tag === 'select') {
        var v = String(el.value);
        d += ' value="' + (v.length > 40 ? v.slice(0, 40) + '…' : v) + '"';
    }
    if (el.disabled) d += ' disabled';
    lines.push('  ' + d);
});
lines.push('');
lines.push('TEXT:');
var t = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').trim();
lines.push(t.length > 6000 ? t.slice(0, 6000) + '\n…[truncated, use `get` for full text]' : t);
lines.join('\n')
"""#

// MARK: - Help & docs

func printUsage() {
    print("""
    Internet browser CLI (Straight Up Browser)

    Usage: browser-cli <command> [arguments]

    Every command prints JSON to stdout ({"ok":true,...}) and exits 0 on
    success; errors print {"error":"..."} to stderr and exit 1. The browser
    is launched automatically if it isn't running. All commands act on the
    ACTIVE tab - use `switch` first to target another tab.

    Navigation:
      open [--new] <url>       Open URL in the active tab (--new: in a new tab)
      search <query>           Web-search the query in the active tab
      back | forward | reload  History navigation / reload
      wait [seconds]           Block until the page finishes loading (default 15)

    Tabs:
      new                      Create a new tab
      close                    Close the active tab
      tabs                     List open tabs as JSON (1-based "index")
      switch <index>           Make tab <index> active

    Reading the page:
      snapshot                 Compact text outline: URL, title, interactive
                               elements with CSS selectors, page text
      screenshot [path]        Save a PNG of the page (default ./screenshot.png)
      get [url|current]        Full page JSON (html, text, links, images, meta)

    Interacting:
      js <code>                Run JavaScript; prints {"ok":true,"result":...}
      click <selector>         Click the element (JavaScript click)
      click --real <selector>  Real mouse click (enable in Settings > Security)
      type <selector> <text>   Set an input's value (fires input/change events)

    Human handoff:
      notify <message>         Bounce the Dock, focus the window, show message
      focus                    Bring the browser window to the front

    Docs:
      help                     This overview
      docs                     Full guide for AI agents (schemas, patterns)

    Examples:
      browser-cli open https://example.com && browser-cli wait
      browser-cli snapshot
      browser-cli click '#more-info' && browser-cli wait
      browser-cli type 'input[name=q]' hello world
      browser-cli js 'document.title'
      browser-cli notify "Please solve the captcha in the browser window"

    Install on PATH (tool ships inside the app bundle):
      sudo ln -sf "/Applications/Internet.app/Contents/Helpers/browser-cli" /usr/local/bin/browser-cli
    """)
}

let agentDocs = #"""
# browser-cli — driving the Internet browser from the terminal

This guide is written for AI agents. It is complete: everything you need to
control the browser is here, no repo access required.

## What this is

`browser-cli` remote-controls **Internet** (a real macOS WebKit browser with a
visible window). You automate it; a human can see the same window and take
over at any time - that's the point. Pages behave exactly as they do for a
person: real cookies, real sessions, real rendering.

## Contract

- Every command prints JSON to **stdout** and exits **0** on success.
- Failures print `{"error":"..."}` (or `Error: ...`) to **stderr** and exit **1**.
  Always check the exit code.
- If the browser isn't running, any command launches it automatically and
  waits (up to ~30s). First-ever launch shows a EULA the human must accept.
- Commands act on the **active tab**. To work in another tab, `switch` to it
  first. There is no parallel-tab control.
- Acks (`{"ok":true}`) mean "accepted", not "page finished loading" - follow
  any navigation with `wait`.

## Setup (once)

    sudo ln -sf "/Applications/Internet.app/Contents/Helpers/browser-cli" /usr/local/bin/browser-cli

## Command reference

### Navigation
| Command | Output |
|---|---|
| `open [--new] <url>` | `{"ok":true}` - loads URL in active tab; `--new` opens a new tab |
| `search <query>` | `{"ok":true}` - web search in the active tab |
| `back` / `forward` / `reload` | `{"ok":true}` |
| `wait [seconds]` | Blocks until the page load completes, then `{"ok":true,"url":"...","title":"..."}`. Default/max wait 15s unless you pass more. `{"error":"timeout waiting for page load"}` on timeout. |

### Tabs
| Command | Output |
|---|---|
| `new` | `{"ok":true}` - new tab becomes active |
| `close` | `{"ok":true}` - closes active tab |
| `tabs` | `{"tabs":[{"index":1,"title":"...","url":"...","active":true},...]}` |
| `switch <index>` | `{"ok":true}` - index is 1-based, from `tabs` |

### Reading the page (active tab)
| Command | Output |
|---|---|
| `snapshot` | Plain text, cheap to read. `URL:`/`TITLE:` lines, then `INTERACTIVE (n):` - one line per visible link/button/input with a **CSS selector you can pass to `click`/`type`** - then `TEXT:` (page text, capped at 6000 chars). Start here; it's the cheapest way to see a page. |
| `screenshot [path]` | Saves a PNG (default `./screenshot.png`), prints `{"ok":true,"path":"..."}`. Use when you need to *look* at the page (layout, captcha, images). |
| `get [url\|current]` | Full JSON: `{url,title,html,text,links[],images[],metaTags[]}`. Huge - prefer `snapshot`. With a URL argument (scheme required) it loads that page **offscreen** without touching your tabs. |

### Interacting (active tab)
| Command | Output |
|---|---|
| `js <code>` | Evaluates JavaScript; last expression is the result: `{"ok":true,"result":...}`. Exceptions come back as `{"error":"..."}`, exit 1. This is the escape hatch for anything the sugar commands can't do (shadow DOM, iframes, scrolling, waiting on elements). |
| `click <selector>` | `document.querySelector(sel).click()` after scrolling it into view. `{"ok":true}` or selector-not-found error. |
| `click --real <selector>` | Posts a **genuine mouse event** at the element's screen position (counts as a user gesture - popups, players, some login buttons). Disabled by default; on error, ask the human to enable **Settings > Security > CLI Automation**. Brings the window to front first. |
| `type <selector> <text>` | Focuses the element and sets its value via the native setter, then fires `input` and `change` (framework-managed inputs update correctly). For key-by-key entry, use `js`. |

### Human handoff
| Command | Output |
|---|---|
| `notify <message>` | Bounces the Dock icon, brings the window to the front, and shows your message in an alert on the browser window. `{"ok":true}`. |
| `focus` | Brings the browser window to the front. `{"ok":true}`. |

## The agent loop

    browser-cli open --new https://example.com
    browser-cli wait
    browser-cli snapshot                    # see the page + selectors
    browser-cli click 'a#more-info'
    browser-cli wait
    browser-cli snapshot                    # observe the result

Repeat observe → act → wait → observe. Take a `screenshot` when text isn't
enough to judge the page.

## Human handoff (captcha, 2FA, logins)

When you hit something only a human can do:

1. `browser-cli notify "Please solve the captcha in the browser, then leave the window open"`
2. Poll for completion every few seconds, e.g.:
       browser-cli js 'document.querySelector(".g-recaptcha") === null'
   or check `browser-cli wait` / `snapshot` for the post-captcha page.
3. When the check passes, continue the loop. The human does not need to tell
   you anything - observe the page state.

## Troubleshooting

- **`{"error":"Browser window not ready (first-run EULA screen?)"}`** - a
  human must accept the EULA in the app window once.
- **Timeout with no response** - the app may have been quit mid-command;
  re-run the command (it relaunches the browser).
- **`no element matches selector`** - re-run `snapshot`; the page changed.
- **Selectors from `snapshot`** are `#id` when available, else a
  `tag:nth-of-type` path. They're valid `document.querySelector` input.
- **Real clicks don't land** - the human may need to grant macOS
  Accessibility permission to the Internet app (System Settings >
  Privacy & Security > Accessibility), and the window must be frontmost.
- **State lives in the app** - cookies/sessions persist across commands like
  a normal browser. You're sharing the human's browser: be a good guest.
"""#

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    printUsage()
    exit(1)
}

switch arguments[1].lowercased() {
case "help", "--help", "-h":
    printUsage()

case "docs":
    print(agentDocs)

case "open":
    var rest = Array(arguments.dropFirst(2))
    var newFlag = ""
    if let index = rest.firstIndex(of: "--new") {
        rest.remove(at: index)
        newFlag = " --new"
    }
    guard let url = rest.first else { fail("Usage: browser-cli open [--new] <url>") }
    printResponse(requestResponse("open\(newFlag) \(url)"))

case "search":
    guard arguments.count > 2 else { fail("Usage: browser-cli search <query>") }
    printResponse(requestResponse("search " + arguments[2...].joined(separator: " ")))

case "new", "close", "back", "forward", "reload", "tabs", "focus":
    printResponse(requestResponse(arguments[1].lowercased()))

case "switch":
    guard arguments.count > 2, Int(arguments[2]) != nil else {
        fail("Usage: browser-cli switch <index>   (1-based, see `browser-cli tabs`)")
    }
    printResponse(requestResponse("switch \(arguments[2])"))

case "wait":
    let seconds = arguments.count > 2 ? (Double(arguments[2]) ?? 15) : 15
    printResponse(requestResponse("wait \(seconds)", timeout: seconds + 5))

case "get":
    let target = arguments.count > 2 ? arguments[2] : "current"
    printResponse(requestResponse("get \(target)", timeout: 20))

case "js":
    guard arguments.count > 2 else { fail("Usage: browser-cli js <code>") }
    printResponse(requestResponse("js " + b64(arguments[2...].joined(separator: " "))))

case "click":
    var rest = Array(arguments.dropFirst(2))
    var real = false
    if let index = rest.firstIndex(of: "--real") {
        rest.remove(at: index)
        real = true
    }
    guard !rest.isEmpty else { fail("Usage: browser-cli click [--real] <css-selector>") }
    let selector = rest.joined(separator: " ")
    if real {
        printResponse(requestResponse("realclick " + b64(selector)))
    } else {
        runJS(clickJS(selector))
        print("{\"ok\":true}")
    }

case "type":
    let rest = Array(arguments.dropFirst(2))
    guard rest.count >= 2 else { fail("Usage: browser-cli type <css-selector> <text...>") }
    runJS(typeJS(rest[0], rest[1...].joined(separator: " ")))
    print("{\"ok\":true}")

case "snapshot":
    let envelope = runJS(snapshotJS)
    print(envelope["result"] as? String ?? "")

case "screenshot":
    let target = arguments.count > 2 ? arguments[2] : "screenshot.png"
    let data = requestResponse("screenshot", timeout: 30)
    // The app writes the PNG bytes straight into the response file; anything
    // that isn't a PNG is a JSON error
    if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {
        let url = URL(fileURLWithPath: target)
        do {
            try data.write(to: url)
            print("{\"ok\":true,\"path\":\(jsonLiteral(url.path))}")
        } catch {
            fail("Error: could not write \(target): \(error.localizedDescription)")
        }
    } else {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        exit(1)
    }

case "notify":
    guard arguments.count > 2 else { fail("Usage: browser-cli notify <message>") }
    printResponse(requestResponse("notify " + arguments[2...].joined(separator: " ")))

default:
    FileHandle.standardError.write(Data("Error: unknown command '\(arguments[1])'\n\n".utf8))
    printUsage()
    exit(1)
}
