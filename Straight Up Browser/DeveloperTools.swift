#if os(macOS)
import SwiftUI
import WebKit
import Combine

enum DeveloperToolsTab: String, CaseIterable, Identifiable {
    case elements = "Elements"
    case console = "Console"
    case network = "Network"

    var id: Self { self }
}

struct DeveloperConsoleEntry: Identifiable, Equatable {
    enum Kind: String {
        case command, result, log, debug, info, warn, error

        var symbol: String {
            switch self {
            case .command: "chevron.right"
            case .result: "chevron.left"
            case .warn: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .info: "info.circle.fill"
            case .log, .debug: "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .command: .blue
            case .result: .secondary
            case .warn: .orange
            case .error: .red
            case .info: .blue
            case .log, .debug: .secondary
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let source: String?
    let timestamp: Date
}

struct DeveloperDOMRow: Identifiable, Equatable {
    let id: String
    let depth: Int
    let tag: String
    let attributes: [String: String]
    let text: String?
    let childCount: Int
}

struct DeveloperNetworkEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: String
    let type: String
    let status: String
    let size: Int
    let duration: Double
    let startTime: Double
}

@MainActor
final class DeveloperToolsModel: ObservableObject {
    @Published var selectedTab: DeveloperToolsTab = .elements
    @Published private(set) var consoleByTab: [UUID: [DeveloperConsoleEntry]] = [:]
    @Published private(set) var elements: [DeveloperDOMRow] = []
    @Published private(set) var networkEntries: [DeveloperNetworkEntry] = []
    @Published var consoleFilter = ""
    @Published var networkFilter = ""
    @Published var preserveLog = false
    @Published var isLoadingElements = false
    @Published var isLoadingNetwork = false

    private(set) var tabID: UUID?
    private weak var webView: WKWebView?

    var consoleEntries: [DeveloperConsoleEntry] {
        guard let tabID else { return [] }
        let entries = consoleByTab[tabID, default: []]
        guard !consoleFilter.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(consoleFilter)
                || ($0.source?.localizedCaseInsensitiveContains(consoleFilter) ?? false)
        }
    }

    var filteredNetworkEntries: [DeveloperNetworkEntry] {
        guard !networkFilter.isEmpty else { return networkEntries }
        return networkEntries.filter {
            $0.name.localizedCaseInsensitiveContains(networkFilter)
                || $0.url.localizedCaseInsensitiveContains(networkFilter)
                || $0.type.localizedCaseInsensitiveContains(networkFilter)
        }
    }

    func attach(to webView: WKWebView?, tabID: UUID?) {
        self.webView?.evaluateJavaScript("window.__subDevTools && window.__subDevTools.disable()")
        self.webView = webView
        self.tabID = tabID
        webView?.evaluateJavaScript("window.__subDevTools && window.__subDevTools.enable()")
        refreshSelectedSurface()
    }

    func detach() {
        removeHighlight()
        webView?.evaluateJavaScript("window.__subDevTools && window.__subDevTools.disable()")
        webView = nil
        tabID = nil
    }

    func select(_ tab: DeveloperToolsTab) {
        selectedTab = tab
        refreshSelectedSurface()
    }

    func refreshSelectedSurface() {
        switch selectedTab {
        case .elements: refreshElements()
        case .network: refreshNetwork()
        case .console: break
        }
    }

    func receiveConsoleMessage(_ note: Notification) {
        guard let tabID = note.userInfo?["tabID"] as? UUID,
              tabID == self.tabID,
              let level = note.userInfo?["level"] as? String,
              let text = note.userInfo?["message"] as? String else { return }
        let kind = DeveloperConsoleEntry.Kind(rawValue: level) ?? .log
        let source = note.userInfo?["source"] as? String
        let line = note.userInfo?["line"] as? Int ?? 0
        let timestamp = note.userInfo?["timestamp"] as? Double ?? 0
        append(
            .init(
                kind: kind,
                text: text,
                source: sourceLabel(source, line: line),
                timestamp: timestamp > 0 ? Date(timeIntervalSince1970: timestamp / 1000) : Date()
            ),
            to: tabID
        )
    }

    func clearConsole() {
        guard let tabID else { return }
        consoleByTab[tabID] = []
    }

    func pageDidLoad(_ note: Notification) {
        guard let loadedTabID = note.userInfo?["tabID"] as? UUID,
              loadedTabID == tabID else { return }
        if !preserveLog { consoleByTab[loadedTabID] = [] }
        webView?.evaluateJavaScript("window.__subDevTools && window.__subDevTools.enable()")
        refreshSelectedSurface()
    }

    func execute(_ command: String) {
        guard let webView, let tabID else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(.init(kind: .command, text: trimmed, source: nil, timestamp: Date()), to: tabID)

        let quoted = Self.javaScriptString(trimmed)
        let script = """
        (function() {
            function display(value) {
                if (value === undefined) return 'undefined';
                if (value === null) return 'null';
                if (typeof value === 'string') return value;
                if (typeof value === 'function') return value.toString();
                if (value instanceof Error) return value.stack || value.message;
                if (value && value.outerHTML) return value.outerHTML.slice(0, 8000);
                try {
                    var seen = new WeakSet();
                    return JSON.stringify(value, function(_, item) {
                        if (typeof item === 'bigint') return String(item) + 'n';
                        if (typeof item === 'object' && item !== null) {
                            if (seen.has(item)) return '[Circular]'; seen.add(item);
                        }
                        return item;
                    }, 2);
                } catch (_) { return String(value); }
            }
            try { return {ok: true, value: display((0, eval)(\(quoted)))}; }
            catch (error) { return {ok: false, value: display(error)}; }
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self else { return }
                let dictionary = value as? [String: Any]
                let isSuccess = dictionary?["ok"] as? Bool ?? (error == nil)
                let text = dictionary?["value"] as? String
                    ?? error?.localizedDescription
                    ?? String(describing: value ?? "undefined")
                self.append(
                    .init(kind: isSuccess ? .result : .error, text: text, source: nil, timestamp: Date()),
                    to: tabID
                )
            }
        }
    }

    func refreshElements() {
        guard let webView else { elements = []; return }
        isLoadingElements = true
        let script = """
        (function() {
            var count = 0, limit = 1200;
            function selector(el) {
                if (el.id) return '#' + CSS.escape(el.id);
                var parts = [];
                while (el && el.nodeType === 1 && el !== document.documentElement) {
                    var part = el.tagName.toLowerCase();
                    if (el.parentElement) {
                        var same = Array.from(el.parentElement.children).filter(function(x) { return x.tagName === el.tagName; });
                        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
                    }
                    parts.unshift(part); el = el.parentElement;
                }
                return 'html > ' + parts.join(' > ');
            }
            function visit(node) {
                if (!node || count++ >= limit) return null;
                if (node.nodeType === 3) {
                    var text = (node.nodeValue || '').replace(/\\s+/g, ' ').trim();
                    return text ? {path: '', tag: '#text', attributes: {}, text: text.slice(0, 300), children: []} : null;
                }
                if (node.nodeType !== 1) return null;
                var attrs = {};
                Array.from(node.attributes || []).forEach(function(a) { attrs[a.name] = a.value.slice(0, 500); });
                var children = [];
                Array.from(node.childNodes || []).forEach(function(child) {
                    var item = visit(child); if (item) children.push(item);
                });
                return {path: selector(node), tag: node.tagName.toLowerCase(), attributes: attrs, text: null, children: children};
            }
            return JSON.stringify(visit(document.documentElement));
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingElements = false
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let root = try? JSONDecoder().decode(DOMNode.self, from: data) else {
                    self.elements = []
                    return
                }
                var rows: [DeveloperDOMRow] = []
                Self.flatten(root, depth: 0, ordinal: &rows)
                self.elements = rows
            }
        }
    }

    func highlight(_ path: String) {
        guard !path.isEmpty, let webView else { return }
        let quoted = Self.javaScriptString(path)
        webView.evaluateJavaScript("""
        (function() {
            var old = document.getElementById('__sub-devtools-highlight'); if (old) old.remove();
            var el; try { el = document.querySelector(\(quoted)); } catch (_) { return; }
            if (!el) return;
            var r = el.getBoundingClientRect(), box = document.createElement('div');
            box.id = '__sub-devtools-highlight';
            box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;' +
                'left:' + r.left + 'px;top:' + r.top + 'px;width:' + r.width + 'px;height:' + r.height + 'px;' +
                'background:rgba(70,140,255,.20);border:1px solid rgb(70,140,255);box-sizing:border-box';
            document.documentElement.appendChild(box);
        })();
        """)
    }

    func removeHighlight() {
        webView?.evaluateJavaScript("document.getElementById('__sub-devtools-highlight')?.remove()")
    }

    func refreshNetwork() {
        guard let webView else { networkEntries = []; return }
        isLoadingNetwork = true
        let script = """
        (function() {
            var rows = performance.getEntriesByType('resource').map(function(e) {
                return {
                    name: e.name.split('/').pop() || e.name,
                    url: e.name,
                    type: e.initiatorType || 'other',
                    status: e.responseStatus ? String(e.responseStatus) : '',
                    size: e.transferSize || e.encodedBodySize || 0,
                    duration: e.duration || 0,
                    startTime: e.startTime || 0
                };
            });
            rows.unshift({name: document.title || location.pathname || location.host, url: location.href,
                type: 'document', status: '', size: 0,
                duration: performance.getEntriesByType('navigation')[0]?.duration || 0, startTime: 0});
            return JSON.stringify(rows);
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingNetwork = false
                guard let json = value as? String, let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([NetworkRow].self, from: data) else {
                    self.networkEntries = []
                    return
                }
                self.networkEntries = decoded.map {
                    .init(name: $0.name, url: $0.url, type: $0.type, status: $0.status,
                          size: $0.size, duration: $0.duration, startTime: $0.startTime)
                }
            }
        }
    }

    private func append(_ entry: DeveloperConsoleEntry, to tabID: UUID) {
        var entries = consoleByTab[tabID, default: []]
        entries.append(entry)
        if entries.count > 1_000 { entries.removeFirst(entries.count - 1_000) }
        consoleByTab[tabID] = entries
    }

    private func sourceLabel(_ source: String?, line: Int) -> String? {
        guard let source, !source.isEmpty, let url = URL(string: source) else { return nil }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? source) : url.lastPathComponent
        return line > 0 ? "\(name):\(line)" : name
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func flatten(_ node: DOMNode, depth: Int, ordinal rows: inout [DeveloperDOMRow]) {
        let id = node.path.isEmpty ? "text-\(rows.count)" : node.path
        rows.append(.init(id: id, depth: depth, tag: node.tag, attributes: node.attributes,
                          text: node.text, childCount: node.children.count))
        for child in node.children { flatten(child, depth: depth + 1, ordinal: &rows) }
    }
}

private struct DOMNode: Decodable {
    let path: String
    let tag: String
    let attributes: [String: String]
    let text: String?
    let children: [DOMNode]
}

private struct NetworkRow: Decodable {
    let name: String
    let url: String
    let type: String
    let status: String
    let size: Int
    let duration: Double
    let startTime: Double
}

struct DeveloperToolsCommandModifier: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var model: DeveloperToolsModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .browserToggleDeveloperTools)) { _ in
                withAnimation(.easeInOut(duration: 0.16)) { isPresented.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserShowDeveloperConsole)) { _ in
                model.select(.console)
                withAnimation(.easeInOut(duration: 0.16)) { isPresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserDeveloperConsoleMessage)) { note in
                model.receiveConsoleMessage(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserDeveloperPageDidLoad)) { note in
                model.pageDidLoad(note)
            }
    }
}

struct DeveloperToolsView: View {
    @ObservedObject var model: DeveloperToolsModel
    let webView: WKWebView?
    let tabID: UUID?
    let onClose: () -> Void
    @State private var command = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                switch model.selectedTab {
                case .elements: elementsView
                case .console: consoleView
                case .network: networkView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.attach(to: webView, tabID: tabID) }
        .onChange(of: tabID) { _, newID in model.attach(to: webView, tabID: newID) }
        .onDisappear { model.detach() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Developer Tools")
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(DeveloperToolsTab.allCases) { tab in
                Button {
                    model.select(tab)
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: model.selectedTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) {
                            if model.selectedTab == tab { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { model.refreshSelectedSurface() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(model.selectedTab == .console)
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close Developer Tools")
        }
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var consoleView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.clearConsole() } label: { Image(systemName: "clear") }
                    .buttonStyle(.plain).help("Clear console")
                TextField("Filter", text: $model.consoleFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                Toggle("Preserve log", isOn: $model.preserveLog)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            .padding(.horizontal, 8).frame(height: 28)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.consoleEntries) { entry in
                            consoleRow(entry).id(entry.id)
                        }
                    }
                }
                .onChange(of: model.consoleEntries.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "chevron.right").foregroundStyle(.blue)
                TextField("JavaScript expression", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        let value = command
                        command = ""
                        model.execute(value)
                    }
            }
            .padding(.horizontal, 8).frame(minHeight: 30)
        }
    }

    private func consoleRow(_ entry: DeveloperConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 9)).foregroundStyle(entry.kind.color)
                .frame(width: 12)
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let source = entry.source {
                Text(source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(entry.kind == .error ? Color.red.opacity(0.08) : entry.kind == .warn ? Color.orange.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var elementsView: some View {
        Group {
            if model.isLoadingElements && model.elements.isEmpty {
                ProgressView().controlSize(.small)
            } else if model.elements.isEmpty {
                ContentUnavailableView("No document", systemImage: "chevron.left.forwardslash.chevron.right")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.elements) { row in
                            elementRow(row)
                        }
                    }
                }
                .onHover { hovering in if !hovering { model.removeHighlight() } }
            }
        }
    }

    private func elementRow(_ row: DeveloperDOMRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * 14)
            if row.childCount > 0 {
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
            if row.tag == "#text" {
                Text("\"\(row.text ?? "")\"").foregroundStyle(.secondary)
            } else {
                Text("<").foregroundStyle(.secondary)
                Text(row.tag).foregroundStyle(.blue)
                ForEach(row.attributes.keys.sorted(), id: \.self) { key in
                    Text(" \(key)").foregroundStyle(.purple)
                    Text("=\"").foregroundStyle(.secondary)
                    Text(row.attributes[key] ?? "").foregroundStyle(Color(red: 0.72, green: 0.30, blue: 0.18))
                    Text("\"").foregroundStyle(.secondary)
                }
                Text(">").foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(.vertical, 2).padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { model.highlight(row.id) }
        }
    }

    private var networkView: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                TextField("Filter", text: $model.networkFilter).textFieldStyle(.plain).font(.system(size: 11))
                Text("\(model.filteredNetworkEntries.count) requests")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 28)
            Divider()
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 58, alignment: .leading)
                Text("Type").frame(width: 72, alignment: .leading)
                Text("Size").frame(width: 72, alignment: .trailing)
                Text("Time").frame(width: 72, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 24)
            Divider()
            if model.isLoadingNetwork && model.networkEntries.isEmpty {
                Spacer(); ProgressView().controlSize(.small); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredNetworkEntries) { entry in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: icon(for: entry.type)).foregroundStyle(color(for: entry.type)).frame(width: 13)
                                    Text(entry.name).lineLimit(1).help(entry.url)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.status).frame(width: 58, alignment: .leading)
                                Text(entry.type).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
                                Text(byteLabel(entry.size)).frame(width: 72, alignment: .trailing)
                                Text(String(format: "%.0f ms", entry.duration)).frame(width: 72, alignment: .trailing)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 8).frame(height: 23)
                            .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func icon(for type: String) -> String {
        switch type { case "document": "doc"; case "script": "curlybraces"; case "img", "image": "photo"; case "css", "link": "paintbrush"; default: "circle" }
    }

    private func color(for type: String) -> Color {
        switch type { case "document": .blue; case "script": .orange; case "img", "image": .purple; case "css", "link": .green; default: .secondary }
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes <= 0 { return "—" }
        if bytes < 1_000 { return "\(bytes) B" }
        if bytes < 1_000_000 { return String(format: "%.1f kB", Double(bytes) / 1_000) }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
#endif
