import Foundation

// A dependency-free Model Context Protocol stdio server.  Keeping it in the
// shipped helper means every MCP client talks to the same capability-gated
// browser bridge as the CLI; there is no debug port or second daemon to run.

private let mcpProtocolVersion = "2025-06-18"

var browserMCPTools: [[String: Any]] {
    (try? AgentToolCatalog.canonical.mcpTools(profile: .browserOSMCP)) ?? []
}
private func mcpNormaliseArguments(_ arguments: [String: Any]) -> [String: Any] {
    let aliases = [
        "page_id": "pageId", "window_id": "windowId", "element_id": "elementId",
        "target_element_id": "targetElementId", "target_selector": "targetSelector",
        "full_page": "fullPage", "prompt_text": "promptText", "group_id": "groupId",
        "page_ids": "pageIds",
    ]
    var result = arguments
    for (old, new) in aliases where result[new] == nil { result[new] = result[old] }
    return result
}

private func mcpAppRequest(
    _ tool: String,
    arguments: [String: Any],
    timeout: TimeInterval = 30
) -> [String: Any] {
    let request: [String: Any] = ["tool": tool, "arguments": mcpNormaliseArguments(arguments)]
    guard let data = try? JSONSerialization.data(withJSONObject: request) else {
        return ["error": "could not encode browser request"]
    }
    do {
        let response = try requestResponseThrowing("agent \(data.base64EncodedString())", timeout: timeout)
        return ((try? JSONSerialization.jsonObject(with: response)) as? [String: Any])
            ?? ["error": "browser returned a malformed response"]
    } catch {
        return ["error": error.localizedDescription]
    }
}

private func mcpJSONString(_ value: Any) -> String {
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return String(describing: value) }
    return String(data: data, encoding: .utf8) ?? String(describing: value)
}

private func mcpSelector(from arguments: [String: Any], prefix: String = "") -> String? {
    let elementKey = prefix.isEmpty ? "elementId" : "\(prefix)ElementId"
    let selectorKey = prefix.isEmpty ? "selector" : "\(prefix)Selector"
    if let selector = arguments[selectorKey] as? String, !selector.isEmpty { return selector }
    if let elementId = arguments[elementKey] as? String, !elementId.isEmpty {
        return "[data-sub-agent-id=\(jsonLiteral(elementId))]"
    }
    return nil
}

private let mcpSnapshotScript = #"""
(function(enhanced) {
  var selector = 'a[href],button,input,select,textarea,[role=button],[role=link],[role=textbox],[role=checkbox],[role=combobox],[onclick],[contenteditable=true]';
  var elements = Array.from(document.querySelectorAll(selector)).filter(function(el) {
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  });
  elements.forEach(function(el, i) { el.setAttribute('data-sub-agent-id', 'sub-' + (i + 1)); });
  function label(el) {
    return String(el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.alt || el.title || '')
      .replace(/\s+/g, ' ').trim().slice(0, 180);
  }
  var lines = ['URL: ' + location.href, 'TITLE: ' + document.title, '', 'INTERACTIVE (' + elements.length + '):'];
  elements.slice(0, 300).forEach(function(el, i) {
    var r = el.getBoundingClientRect(), tag = el.tagName.toLowerCase();
    var line = '[sub-' + (i + 1) + '] ' + (el.getAttribute('role') || tag) + ' "' + label(el) + '"';
    if (tag === 'a') line += ' -> ' + el.href;
    if ('checked' in el) line += ' checked=' + !!el.checked;
    if ('disabled' in el) line += ' disabled=' + !!el.disabled;
    if (enhanced) line += ' rect=(' + Math.round(r.x) + ',' + Math.round(r.y) + ',' + Math.round(r.width) + ',' + Math.round(r.height) + ')';
    lines.push(line);
  });
  lines.push('', 'TEXT:');
  var text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').trim();
  lines.push(text.slice(0, enhanced ? 20000 : 8000));
  if (text.length > (enhanced ? 20000 : 8000)) lines.push('…[truncated]');
  return lines.join('\n');
})(__ENHANCED__)
"""#

private let mcpMarkdownScript = #"""
(function() {
  var root = document.querySelector('main,article,[role=main]') || document.body;
  if (!root) return '';
  function clean(s) { return String(s || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim(); }
  var out = [];
  Array.from(root.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,table,a[href]')).forEach(function(el) {
    if (el.closest('nav,header,footer,aside') && !el.matches('a[href]')) return;
    var t = clean(el.innerText || el.textContent); if (!t) return;
    if (/^H[1-6]$/.test(el.tagName)) out.push('#'.repeat(Number(el.tagName[1])) + ' ' + t);
    else if (el.tagName === 'LI') out.push('- ' + t);
    else if (el.tagName === 'BLOCKQUOTE') out.push('> ' + t.replace(/\n/g, '\n> '));
    else if (el.tagName === 'PRE') out.push('```\n' + t + '\n```');
    else if (el.tagName === 'A' && !el.closest('p,li,h1,h2,h3,h4,h5,h6')) out.push('[' + t + '](' + el.href + ')');
    else out.push(t);
  });
  return out.join('\n\n').slice(0, 100000);
})()
"""#

private func mcpEvaluate(_ script: String, arguments: [String: Any]) -> [String: Any] {
    var request = mcpNormaliseArguments(arguments)
    request["script"] = script
    return mcpAppRequest("evaluate_script", arguments: request)
}

private func mcpElementScript(
    _ arguments: [String: Any],
    body: (String) -> String
) -> [String: Any] {
    let normalized = mcpNormaliseArguments(arguments)
    guard let selector = mcpSelector(from: normalized) else {
        return ["error": "supply selector or elementId from take_snapshot"]
    }
    let literal = jsonLiteral(selector)
    let script = "var el=document.querySelector(\(literal));if(!el)throw new Error('element not found');" + body("el")
    return mcpEvaluate(script, arguments: normalized)
}

private func mcpWriteBase64Result(_ response: [String: Any], path: String) -> [String: Any] {
    guard response["error"] == nil,
          let encoded = response["data"] as? String,
          let data = Data(base64Encoded: encoded) else { return response }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    do {
        try data.write(to: url, options: .atomic)
        return ["ok": true, "path": url.path, "bytes": data.count, "mimeType": response["mimeType"] ?? "application/octet-stream"]
    } catch {
        return ["error": "could not write \(url.path): \(error.localizedDescription)"]
    }
}

private func mcpCallBrowserTool(_ name: String, rawArguments: [String: Any]) -> [String: Any] {
    let arguments = mcpNormaliseArguments(rawArguments)
    let direct = Set([
        "get_active_page", "list_pages", "navigate_page", "new_page", "new_hidden_page",
        "show_page", "move_page", "close_page", "take_screenshot", "evaluate_script",
        "list_windows", "create_window", "create_hidden_window", "close_window", "activate_window",
        "list_tab_groups", "group_tabs", "update_tab_group", "ungroup_tabs", "close_tab_group",
        "get_bookmarks", "create_bookmark", "remove_bookmark", "update_bookmark", "move_bookmark",
        "search_bookmarks", "search_history", "get_recent_history", "delete_history_url",
        "delete_history_range", "handle_dialog",
    ])
    if direct.contains(name) { return mcpAppRequest(name, arguments: arguments) }

    switch name {
    case "take_snapshot":
        return mcpEvaluate(mcpSnapshotScript.replacingOccurrences(of: "__ENHANCED__", with: "false"), arguments: arguments)
    case "take_enhanced_snapshot":
        return mcpEvaluate(mcpSnapshotScript.replacingOccurrences(of: "__ENHANCED__", with: "true"), arguments: arguments)
    case "get_page_content":
        return mcpEvaluate(mcpMarkdownScript, arguments: arguments)
    case "get_page_links":
        return mcpEvaluate(#"Array.from(new Map(Array.from(document.querySelectorAll('a[href]')).map(a=>[a.href,{text:String(a.innerText||a.getAttribute('aria-label')||'').trim(),url:a.href}])).values())"#, arguments: arguments)
    case "get_dom":
        let selector = arguments["selector"] as? String
        let expression = selector.map { "document.querySelector(\(jsonLiteral($0)))?.outerHTML||null" }
            ?? "document.documentElement.outerHTML"
        return mcpEvaluate(expression, arguments: arguments)
    case "search_dom":
        let query = arguments["query"] as? String ?? ""
        let mode = arguments["mode"] as? String ?? "text"
        let limit = max(1, min(arguments["limit"] as? Int ?? 50, 500))
        let script = #"""
        (function(q,mode,limit){
          var nodes=[];
          if(mode==='css') nodes=Array.from(document.querySelectorAll(q));
          else if(mode==='xpath') { var x=document.evaluate(q,document,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null); for(var i=0;i<x.snapshotLength;i++)nodes.push(x.snapshotItem(i)); }
          else nodes=Array.from(document.querySelectorAll('body *')).filter(function(n){return n.children.length===0&&String(n.textContent||'').toLowerCase().includes(q.toLowerCase());});
          return nodes.slice(0,limit).map(function(n){var r=n.getBoundingClientRect();return{tag:n.tagName?.toLowerCase()||'',text:String(n.innerText||n.textContent||'').trim().slice(0,500),html:n.outerHTML?.slice(0,2000)||'',rect:{x:r.x,y:r.y,width:r.width,height:r.height}}});
        })(__QUERY__,__MODE__,__LIMIT__)
        """#
            .replacingOccurrences(of: "__QUERY__", with: jsonLiteral(query))
            .replacingOccurrences(of: "__MODE__", with: jsonLiteral(mode))
            .replacingOccurrences(of: "__LIMIT__", with: String(limit))
        return mcpEvaluate(script, arguments: arguments)
    case "click", "download_file":
        return mcpElementScript(arguments) { "\($0).scrollIntoView({block:'center'});\($0).click();'clicked'" }
    case "click_at":
        let x = arguments["x"] as? Double ?? 0, y = arguments["y"] as? Double ?? 0
        return mcpEvaluate("var el=document.elementFromPoint(\(x),\(y));if(!el)throw new Error('no element at point');el.click();({tag:el.tagName,x:\(x),y:\(y)})", arguments: arguments)
    case "hover":
        return mcpElementScript(arguments) { "\($0).scrollIntoView({block:'center'});['mouseover','mouseenter','mousemove'].forEach(t=>\($0).dispatchEvent(new MouseEvent(t,{bubbles:true})));'hovered'" }
    case "focus":
        return mcpElementScript(arguments) { "\($0).scrollIntoView({block:'center'});\($0).focus();'focused'" }
    case "fill", "clear":
        let value = name == "clear" ? "" : arguments["value"] as? String ?? ""
        return mcpElementScript(arguments) { el in
            "\(el).focus();var p=\(el).tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;var d=Object.getOwnPropertyDescriptor(p,'value');if(d&&d.set)d.set.call(\(el),\(jsonLiteral(value)));else \(el).value=\(jsonLiteral(value));\(el).dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:\(jsonLiteral(value))}));\(el).dispatchEvent(new Event('change',{bubbles:true}));'filled'"
        }
    case "check", "uncheck":
        let checked = name == "check" ? "true" : "false"
        return mcpElementScript(arguments) { "\($0).checked=\(checked);\($0).dispatchEvent(new Event('input',{bubbles:true}));\($0).dispatchEvent(new Event('change',{bubbles:true}));({checked:\($0).checked})" }
    case "select_option":
        let values = arguments["values"] as? [String] ?? []
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
        return mcpElementScript(arguments) { el in
            "var vals=\(encoded);Array.from(\(el).options).forEach(o=>o.selected=vals.includes(o.value)||vals.includes(o.text));\(el).dispatchEvent(new Event('input',{bubbles:true}));\(el).dispatchEvent(new Event('change',{bubbles:true}));Array.from(\(el).selectedOptions).map(o=>o.value)"
        }
    case "press_key":
        let combo = arguments["key"] as? String ?? ""
        let parts = combo.split(separator: "+").map(String.init)
        let key = parts.last ?? combo
        let lowered = Set(parts.dropLast().map { $0.lowercased() })
        let target = "document.activeElement||document.body"
        let options = "{key:\(jsonLiteral(key)),code:\(jsonLiteral(key)),bubbles:true,cancelable:true,metaKey:\(lowered.contains("meta") || lowered.contains("cmd")),ctrlKey:\(lowered.contains("ctrl") || lowered.contains("control")),altKey:\(lowered.contains("alt") || lowered.contains("option")),shiftKey:\(lowered.contains("shift"))}"
        return mcpEvaluate("var el=\(target),o=\(options);el.dispatchEvent(new KeyboardEvent('keydown',o));el.dispatchEvent(new KeyboardEvent('keyup',o));'pressed'", arguments: arguments)
    case "drag":
        let source = mcpSelector(from: arguments)
        let target = mcpSelector(from: arguments, prefix: "target")
        guard let source else { return ["error": "drag requires selector or elementId"] }
        let targetExpression: String
        if let target { targetExpression = "document.querySelector(\(jsonLiteral(target)))" }
        else {
            let x = arguments["x"] as? Double ?? 0, y = arguments["y"] as? Double ?? 0
            targetExpression = "document.elementFromPoint(\(x),\(y))"
        }
        let script = "var s=document.querySelector(\(jsonLiteral(source))),t=\(targetExpression);if(!s||!t)throw new Error('drag endpoint not found');var d=new DataTransfer();s.dispatchEvent(new DragEvent('dragstart',{bubbles:true,dataTransfer:d}));t.dispatchEvent(new DragEvent('dragenter',{bubbles:true,dataTransfer:d}));t.dispatchEvent(new DragEvent('dragover',{bubbles:true,dataTransfer:d}));t.dispatchEvent(new DragEvent('drop',{bubbles:true,dataTransfer:d}));s.dispatchEvent(new DragEvent('dragend',{bubbles:true,dataTransfer:d}));'dragged'"
        return mcpEvaluate(script, arguments: arguments)
    case "scroll":
        let direction = arguments["direction"] as? String ?? "down"
        let amount = arguments["amount"] as? Double ?? 600
        let delta = direction == "up" || direction == "left" ? -amount : amount
        let dx = direction == "left" || direction == "right" ? delta : 0
        let dy = direction == "up" || direction == "down" ? delta : 0
        if let selector = mcpSelector(from: arguments) {
            return mcpEvaluate("var el=document.querySelector(\(jsonLiteral(selector)));if(!el)throw new Error('element not found');el.scrollBy({left:\(dx),top:\(dy),behavior:'instant'});({left:el.scrollLeft,top:el.scrollTop})", arguments: arguments)
        }
        return mcpEvaluate("window.scrollBy({left:\(dx),top:\(dy),behavior:'instant'});({x:scrollX,y:scrollY})", arguments: arguments)
    case "upload_file":
        guard let selector = mcpSelector(from: arguments),
              let paths = arguments["paths"] as? [String], !paths.isEmpty else {
            return ["error": "upload_file requires paths and selector or elementId"]
        }
        var fileObjects: [[String: String]] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let data = try? Data(contentsOf: url), data.count <= 5_000_000 else {
                return ["error": "could not read \(url.path), or file exceeds the 5 MB automation limit"]
            }
            fileObjects.append(["name": url.lastPathComponent, "data": data.base64EncodedString()])
        }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: fileObjects), encoding: .utf8)!
        let script = "var el=document.querySelector(\(jsonLiteral(selector)));if(!el)throw new Error('file input not found');var dt=new DataTransfer(),items=\(encoded);items.forEach(i=>{var b=atob(i.data),a=new Uint8Array(b.length);for(var n=0;n<b.length;n++)a[n]=b.charCodeAt(n);dt.items.add(new File([a],i.name));});el.files=dt.files;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));Array.from(el.files).map(f=>({name:f.name,size:f.size}))"
        return mcpEvaluate(script, arguments: arguments)
    case "save_pdf":
        guard let path = arguments["path"] as? String else { return ["error": "save_pdf requires path"] }
        return mcpWriteBase64Result(mcpAppRequest("save_pdf", arguments: arguments, timeout: 60), path: path)
    case "save_screenshot":
        guard let path = arguments["path"] as? String else { return ["error": "save_screenshot requires path"] }
        return mcpWriteBase64Result(mcpAppRequest("take_screenshot", arguments: arguments, timeout: 60), path: path)
    default:
        return ["error": "unknown browser tool: \(name)"]
    }
}

private final class MCPAuditLog {
    let sessionId = UUID().uuidString
    private var fileURL: URL?
    private var framesDirectory: URL?
    private var frameIndex = 0

    init() {
        let directory = supportDirectory.appendingPathComponent("agent-audit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            fileURL = directory.appendingPathComponent("\(sessionId).jsonl")
            let frames = directory.appendingPathComponent(sessionId, isDirectory: true)
            try FileManager.default.createDirectory(
                at: frames,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            framesDirectory = frames
            FileManager.default.createFile(atPath: fileURL!.path, contents: nil)
            append(["event": "session_started", "sessionId": sessionId])
        } catch {
            fileURL = nil
            framesDirectory = nil
        }
    }

    func append(_ fields: [String: Any]) {
        guard let fileURL else { return }
        var event = fields
        event["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(event),
              var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(UInt8(ascii: "\n"))
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    /// Agent sessions are replayable locally without recording the user's
    /// whole screen: after a browser-changing tool, save the addressed page as
    /// a still frame and link it from the JSONL action timeline.
    func captureFrame(after tool: String, arguments: [String: Any]) {
        guard let framesDirectory else { return }
        let excluded = Set([
            "get_active_page", "list_pages", "list_windows", "take_snapshot",
            "take_enhanced_snapshot", "get_page_content", "get_page_links", "get_dom",
            "search_dom", "take_screenshot", "evaluate_script", "get_bookmarks",
            "search_bookmarks", "search_history", "get_recent_history", "list_tab_groups",
            "save_pdf", "save_screenshot",
        ])
        guard !excluded.contains(tool) else { return }
        var screenshotArguments: [String: Any] = [:]
        if !["close_page", "close_window", "create_window", "create_hidden_window"].contains(tool),
           let pageId = arguments["pageId"] ?? arguments["page_id"] {
            screenshotArguments["pageId"] = pageId
        }
        let response = mcpAppRequest("take_screenshot", arguments: screenshotArguments, timeout: 60)
        guard response["error"] == nil,
              let encoded = response["data"] as? String,
              let data = Data(base64Encoded: encoded) else { return }
        frameIndex += 1
        let frame = framesDirectory.appendingPathComponent(String(format: "%04d.png", frameIndex))
        do {
            try data.write(to: frame, options: .atomic)
            append([
                "event": "frame_captured",
                "tool": tool,
                "frame": frame.path,
                "index": frameIndex,
            ])
        } catch {
            append(["event": "frame_failed", "tool": tool, "error": error.localizedDescription])
        }
    }
}

private func mcpResponseContent(_ result: [String: Any]) -> [String: Any] {
    if let encoded = result["data"] as? String,
       let mimeType = result["mimeType"] as? String,
       mimeType.hasPrefix("image/") {
        var metadata = result
        metadata.removeValue(forKey: "data")
        return [
            "content": [
                ["type": "image", "data": encoded, "mimeType": mimeType],
                ["type": "text", "text": mcpJSONString(metadata)],
            ],
        ]
    }
    let isError = result["error"] != nil
    return [
        "content": [["type": "text", "text": mcpJSONString(result)]],
        "isError": isError,
    ]
}

private func mcpSend(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
}

private func mcpError(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

func runMCPServer() -> Never {
    let audit = MCPAuditLog()
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = message["method"] as? String else { continue }
        let id = message["id"]
        if id == nil { continue } // notifications never receive a response

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let clientInfo = params?["clientInfo"] as? [String: Any] ?? [:]
            audit.append(["event": "client_initialized", "client": clientInfo])
            mcpSend([
                "jsonrpc": "2.0",
                "id": id!,
                "result": [
                    "protocolVersion": mcpProtocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "straight-up-browser", "version": "1.0.0"],
                    "instructions": "Controls the user's real WebKit browser. Start with list_pages or take_snapshot. Background pages have stable IDs; do not act on a personal page unless the user asked you to.",
                ],
            ])
        case "ping":
            mcpSend(["jsonrpc": "2.0", "id": id!, "result": [:]])
        case "tools/list":
            mcpSend(["jsonrpc": "2.0", "id": id!, "result": ["tools": browserMCPTools]])
        case "tools/call":
            guard let params = message["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                mcpSend(mcpError(id: id!, code: -32602, message: "tools/call requires a tool name"))
                continue
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let started = Date()
            audit.append(["event": "tool_started", "tool": name, "arguments": arguments])
            let result = mcpCallBrowserTool(name, rawArguments: arguments)
            var auditResult = result
            if let encoded = auditResult["data"] as? String {
                auditResult["data"] = "<\(encoded.count) base64 characters>"
            }
            audit.append([
                "event": "tool_finished",
                "tool": name,
                "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                "result": auditResult,
            ])
            if result["error"] == nil { audit.captureFrame(after: name, arguments: arguments) }
            mcpSend(["jsonrpc": "2.0", "id": id!, "result": mcpResponseContent(result)])
        default:
            mcpSend(mcpError(id: id!, code: -32601, message: "Method not found: \(method)"))
        }
    }
    audit.append(["event": "session_ended"])
    exit(0)
}
