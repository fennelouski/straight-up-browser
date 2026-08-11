import Foundation

nonisolated enum PageHandleError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

nonisolated struct PageHandle: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    let windowID: UUID
    let tabID: UUID

    init(windowID: UUID, tabID: UUID) {
        self.windowID = windowID
        self.tabID = tabID
    }

    init(parsing value: String) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let windowID = UUID(uuidString: String(parts[0])),
              let tabID = UUID(uuidString: String(parts[1])) else {
            throw PageHandleError.invalidFormat(value)
        }
        self.init(windowID: windowID, tabID: tabID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(parsing: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid PageHandle automation address"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    var description: String {
        "\(windowID.uuidString):\(tabID.uuidString)"
    }
}

nonisolated struct PageNavigationGeneration: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    func advanced() -> Self {
        Self(rawValue: rawValue &+ 1)
    }
}

nonisolated struct PageDocumentGeneration: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

nonisolated enum SemanticDOMPathComponent: Codable, Equatable, Hashable, Sendable {
    case sameOriginFrame(localID: String, origin: String?)
    case openShadowRoot(hostLocalID: String)
}

nonisolated struct SemanticFrameContext: Codable, Equatable, Hashable, Sendable {
    static let mainDocument = Self(path: [])

    var path: [SemanticDOMPathComponent]

    init(path: [SemanticDOMPathComponent]) {
        self.path = path
    }
}

nonisolated enum SemanticFrameBoundaryReason: String, Codable, Equatable, Hashable, Sendable {
    case crossOrigin
    case inaccessible
}

nonisolated struct SemanticFrameBoundary: Codable, Equatable, Hashable, Sendable {
    var parentContext: SemanticFrameContext
    var frameLocalID: String
    var sourceURL: URL?
    var reason: SemanticFrameBoundaryReason
}

nonisolated struct SemanticGeometryDigest: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        rawValue = [x, y, width, height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ":")
    }
}

nonisolated enum SemanticElementState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case visible
    case enabled
    case disabled
    case checked
    case selected
    case expanded
    case editable
    case focused
}

nonisolated enum SemanticElementIdentifier: Codable, Equatable, Hashable, Sendable {
    case local(String)
    case legacySub(Int)

    init(parsing value: String) throws {
        if value.hasPrefix("sub-") {
            guard let ordinal = Int(value.dropFirst(4)), ordinal > 0 else {
                throw SemanticReferenceResolutionError.invalidIdentifier(value)
            }
            self = .legacySub(ordinal)
        } else if !value.isEmpty {
            self = .local(value)
        } else {
            throw SemanticReferenceResolutionError.invalidIdentifier(value)
        }
    }

    var compatibilityString: String {
        switch self {
        case .local(let value): value
        case .legacySub(let ordinal): "sub-\(ordinal)"
        }
    }
}

nonisolated struct SemanticElementReference: Codable, Equatable, Hashable, Sendable {
    let page: PageHandle
    let navigationGeneration: PageNavigationGeneration
    let documentGeneration: PageDocumentGeneration
    let identifier: SemanticElementIdentifier
    let role: String
    let name: String
    let states: Set<SemanticElementState>
    let frameContext: SemanticFrameContext
    let geometryDigest: SemanticGeometryDigest

    var localID: String? {
        guard case .local(let value) = identifier else { return nil }
        return value
    }
}

nonisolated struct SemanticNodeSnapshot: Codable, Equatable, Hashable, Sendable {
    var localID: String
    var legacySubID: Int?
    var role: String
    var name: String
    var states: Set<SemanticElementState>
    var frameContext: SemanticFrameContext
    var geometryDigest: SemanticGeometryDigest
    var matchedSelectors: Set<String>
    var text: String
    var destinationURL: URL?
    var isInteractive: Bool
    /// Form-control attributes, present only for `input`/`textarea`/`select`.
    /// Consumed by autofill in Swift; deliberately absent from
    /// `renderCompatibilityText`, so this never reaches the agent's context.
    var fieldHints: AutofillFieldDescriptor?

    init(
        localID: String,
        legacySubID: Int? = nil,
        role: String,
        name: String,
        states: Set<SemanticElementState> = [],
        frameContext: SemanticFrameContext = .mainDocument,
        geometryDigest: SemanticGeometryDigest,
        matchedSelectors: Set<String> = [],
        text: String = "",
        destinationURL: URL? = nil,
        isInteractive: Bool = true,
        fieldHints: AutofillFieldDescriptor? = nil
    ) {
        self.localID = localID
        self.legacySubID = legacySubID
        self.role = role
        self.name = name
        self.states = states
        self.frameContext = frameContext
        self.geometryDigest = geometryDigest
        self.matchedSelectors = matchedSelectors
        self.text = text
        self.destinationURL = destinationURL
        self.isInteractive = isInteractive
        self.fieldHints = fieldHints
    }

    func reference(
        on page: PageHandle,
        navigationGeneration: PageNavigationGeneration,
        documentGeneration: PageDocumentGeneration,
        preferLegacyIdentifier: Bool = false
    ) -> SemanticElementReference {
        let identifier: SemanticElementIdentifier
        if preferLegacyIdentifier, let legacySubID {
            identifier = .legacySub(legacySubID)
        } else {
            identifier = .local(localID)
        }
        return SemanticElementReference(
            page: page,
            navigationGeneration: navigationGeneration,
            documentGeneration: documentGeneration,
            identifier: identifier,
            role: role,
            name: name,
            states: states,
            frameContext: frameContext,
            geometryDigest: geometryDigest
        )
    }
}

nonisolated enum SemanticPageJavaScriptError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidDocumentToken(String)
    case invalidFramePath
}

/// Tracks a monotonic navigation generation from the document token created by
/// the isolated-world document-start script. Same-document history changes keep
/// the generation; every new WebKit document receives a new UUID and advances it.
nonisolated struct SemanticPageGenerationTracker: Sendable {
    private var documents: [PageHandle: (token: UUID, generation: PageNavigationGeneration)] = [:]

    mutating func generation(
        for page: PageHandle,
        documentToken: UUID
    ) -> PageNavigationGeneration {
        if let current = documents[page], current.token == documentToken {
            return current.generation
        }
        let next = documents[page]?.generation.advanced()
            ?? PageNavigationGeneration(rawValue: 1)
        documents[page] = (documentToken, next)
        return next
    }

    mutating func remove(_ page: PageHandle) {
        documents.removeValue(forKey: page)
    }
}

/// One isolated-world semantic runtime is installed at document start. It owns
/// the actual per-document token and stable WeakMap identities. Pages cannot
/// forge or rewrite these values because agent scripts execute in the same
/// isolated content world, not the hostile page world.
nonisolated enum SemanticPageJavaScript {
    static let runtimeKey = "__straightUpSemanticRuntimeV2"

    static let bootstrap = #"""
    (() => {
      'use strict';
      const runtimeKey = '__straightUpSemanticRuntimeV2';
      const existing = window[runtimeKey];
      if (existing && existing.ownerDocument === document) return;

      const uuid = () => {
        if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
          return globalThis.crypto.randomUUID();
        }
        const bytes = new Uint8Array(16);
        globalThis.crypto.getRandomValues(bytes);
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;
        const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
        return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
      };
      const state = {
        ownerDocument: document,
        documentToken: uuid(),
        nextLocalID: 0,
        nextLegacyID: 0,
        snapshotSerial: 0,
        identityByElement: new WeakMap(),
        recordsByLocalID: new Map(),
        waits: new Map()
      };

      const bounded = (value, limit) => String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit);
      const pathKey = path => JSON.stringify(path || []);
      const identityFor = (element, path) => {
        let identity = state.identityByElement.get(element);
        if (!identity) {
          identity = {
            localID: `semantic-${state.documentToken}-${++state.nextLocalID}`,
            legacySubID: null,
            exposed: false,
            reference: typeof WeakRef === 'function' ? new WeakRef(element) : element,
            path: path || []
          };
          state.identityByElement.set(element, identity);
          state.recordsByLocalID.set(identity.localID, identity);
        }
        identity.path = path || [];
        identity.snapshotSerial = state.snapshotSerial;
        return identity;
      };
      const dereference = identity => {
        if (!identity) return null;
        return typeof identity.reference?.deref === 'function'
          ? identity.reference.deref()
          : identity.reference;
      };
      const roleFor = element => bounded(
        element.getAttribute('role') || element.tagName?.toLowerCase() || '',
        80
      );
      const nameFor = element => bounded(
        element.getAttribute('aria-label') ||
        element.getAttribute('alt') ||
        element.getAttribute('title') ||
        element.getAttribute('placeholder') ||
        element.innerText || element.textContent || '',
        180
      );
      const geometryFor = element => {
        const rect = element.getBoundingClientRect();
        let x = rect.x;
        let y = rect.y;
        let view = element.ownerDocument?.defaultView;
        // Convert frame-local viewport coordinates into top-document page
        // coordinates. Child scrolling is already reflected in `rect`; only
        // the top-level scroll offset is added after walking frame bounds.
        while (view && view !== window) {
          let frame = null;
          try { frame = view.frameElement; } catch (_) { frame = null; }
          if (!frame) break;
          const frameRect = frame.getBoundingClientRect();
          x += frameRect.x + (frame.clientLeft || 0);
          y += frameRect.y + (frame.clientTop || 0);
          view = frame.ownerDocument?.defaultView;
        }
        x += view?.scrollX || 0;
        y += view?.scrollY || 0;
        return [x, y, rect.width, rect.height].map(value => Math.round(value)).join(':');
      };
      const statesFor = element => {
        const states = [];
        const rect = element.getBoundingClientRect();
        const style = element.ownerDocument?.defaultView?.getComputedStyle(element);
        if (!element.hidden && rect.width > 0 && rect.height > 0 &&
            style?.display !== 'none' && style?.visibility !== 'hidden') states.push('visible');
        if (('disabled' in element && element.disabled) || element.getAttribute('aria-disabled') === 'true') {
          states.push('disabled');
        } else {
          states.push('enabled');
        }
        if (('checked' in element && element.checked) || element.getAttribute('aria-checked') === 'true') states.push('checked');
        if (('selected' in element && element.selected) || element.getAttribute('aria-selected') === 'true') states.push('selected');
        if (element.getAttribute('aria-expanded') === 'true') states.push('expanded');
        if (element.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(element.tagName || '')) states.push('editable');
        if (element.ownerDocument?.activeElement === element) states.push('focused');
        return states;
      };
      const isInteractive = element => {
        const tag = element.tagName || '';
        const role = element.getAttribute('role') || '';
        return /^(A|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY)$/.test(tag) ||
          /^(button|link|textbox|checkbox|radio|combobox|menuitem|option|switch|tab)$/.test(role) ||
          element.isContentEditable || element.hasAttribute('onclick') || element.tabIndex >= 0;
      };
      const safeOrigin = (raw, base) => {
        try { return new URL(raw || '', base).origin; } catch (_) { return null; }
      };
      // Everything autofill needs to work out what a form control is asking for.
      // Collected here; every decision about it is made in Swift, where the rules
      // are type-checked and tested (see AutofillFieldClassifier).
      //
      // `element.labels` covers both <label for=…> and a wrapping <label> in one
      // property, which is why the accessible-name fallback above doesn't need to
      // learn about labels.
      const FILLABLE_TAGS = /^(INPUT|TEXTAREA|SELECT)$/;
      const fieldHints = element => {
        let labelText = '';
        try {
          labelText = Array.from(element.labels || [], node => node.textContent || '').join(' ');
        } catch (_) { labelText = ''; }
        return {
          tag: bounded(element.tagName, 16).toLowerCase(),
          type: bounded(element.getAttribute('type'), 32).toLowerCase(),
          autocomplete: bounded(element.getAttribute('autocomplete'), 120),
          name: bounded(element.getAttribute('name'), 120),
          elementID: bounded(element.getAttribute('id'), 120),
          placeholder: bounded(element.getAttribute('placeholder'), 120),
          label: bounded(labelText, 180),
          ariaLabel: bounded(element.getAttribute('aria-label'), 120),
          isVisible: statesFor(element).includes('visible'),
          isEditable: !element.disabled && !element.readOnly,
          isEmpty: !String(element.value || '').trim()
        };
      };
      const descriptor = (element, path, selectors) => {
        const identity = identityFor(element, path);
        const matchedSelectors = [];
        for (const selector of selectors) {
          try { if (element.matches(selector)) matchedSelectors.push(selector); }
          catch (_) { return { invalidSelector: selector }; }
        }
        const interactive = isInteractive(element);
        if (interactive || matchedSelectors.length > 0) identity.exposed = true;
        if (identity.exposed && identity.legacySubID === null) {
          identity.legacySubID = ++state.nextLegacyID;
        }
        if (!identity.exposed) {
          return {localID: identity.localID, includeInSnapshot: false};
        }
        let destinationURL = null;
        if (element.tagName === 'A' && element.href) destinationURL = bounded(element.href, 2048);
        return {
          localID: identity.localID,
          legacySubID: identity.legacySubID,
          role: roleFor(element),
          name: nameFor(element),
          states: statesFor(element),
          frameContext: path,
          geometryDigest: geometryFor(element),
          matchedSelectors,
          text: bounded(element.innerText || element.textContent || '', 512),
          destinationURL,
          isInteractive: interactive,
          // Gated on the tag so only real form controls pay the extra attribute
          // reads — scan() runs this up to 4096 times, before every agent effect.
          // Deliberately NOT rendered into the agent's snapshot text.
          fieldHints: FILLABLE_TAGS.test(element.tagName || '') ? fieldHints(element) : null,
          includeInSnapshot: identity.exposed
        };
      };
      const scan = options => {
        options = options || {};
        const maxNodes = Math.max(1, Math.min(Number(options.maximumNodes) || 4096, 4096));
        const maxRoots = Math.max(1, Math.min(Number(options.maximumRoots) || 128, 128));
        const maxDepth = Math.max(1, Math.min(Number(options.maximumDepth) || 16, 32));
        const maxText = Math.max(1, Math.min(Number(options.maximumText) || 65536, 65536));
        const selectors = Array.isArray(options.selectors) ? options.selectors.slice(0, 16) : [];
        const nodes = [];
        const inaccessibleFrameBoundaries = [];
        const roots = [];
        const queue = [{root: document, path: [], depth: 0}];
        let visibleText = '';
        let visitedNodes = 0;
        state.snapshotSerial += 1;

        while (queue.length && visitedNodes < maxNodes && roots.length < maxRoots) {
          const current = queue.shift();
          const root = current.root;
          const ownerDocument = root?.nodeType === Node.DOCUMENT_NODE ? root : root?.ownerDocument;
          if (!root || !ownerDocument) continue;
          roots.push(root);
          const textSource = root.nodeType === Node.DOCUMENT_NODE
            ? root.body?.innerText
            : root.textContent;
          if (textSource && visibleText.length < maxText) {
            visibleText += `${visibleText ? ' ' : ''}${String(textSource).slice(0, maxText - visibleText.length)}`;
          }

          const walker = ownerDocument.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
          let element = walker.nextNode();
          while (element && visitedNodes < maxNodes) {
            visitedNodes += 1;
            const item = descriptor(element, current.path, selectors);
            if (item.invalidSelector) {
              return {error: 'invalid selector', selector: item.invalidSelector};
            }
            if (item.includeInSnapshot) nodes.push(item);

            if (element.shadowRoot && current.depth < maxDepth && queue.length + roots.length < maxRoots) {
              queue.push({
                root: element.shadowRoot,
                path: current.path.concat([{kind: 'openShadowRoot', hostLocalID: item.localID}]),
                depth: current.depth + 1
              });
            }
            if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
              let frameDocument = null;
              try {
                const candidate = element.contentDocument;
                if (candidate) {
                  // Force a same-origin read now; some WebKit versions expose a
                  // non-null cross-origin document proxy that throws only later.
                  void candidate.location.href;
                  void candidate.documentElement;
                  frameDocument = candidate;
                }
              } catch (_) { frameDocument = null; }
              if (frameDocument && current.depth < maxDepth && queue.length + roots.length < maxRoots) {
                let origin = null;
                try { origin = frameDocument.location.origin; } catch (_) { origin = null; }
                queue.push({
                  root: frameDocument,
                  path: current.path.concat([{
                    kind: 'sameOriginFrame',
                    localID: item.localID,
                    origin: bounded(origin, 512) || null
                  }]),
                  depth: current.depth + 1
                });
              } else {
                const sourceOrigin = safeOrigin(element.getAttribute('src'), ownerDocument.baseURI);
                const opaqueSandbox = element.hasAttribute('sandbox') &&
                  !String(element.getAttribute('sandbox') || '')
                    .split(/\s+/)
                    .includes('allow-same-origin');
                let reason = 'inaccessible';
                try {
                  reason = opaqueSandbox ||
                    (sourceOrigin && sourceOrigin !== ownerDocument.location.origin)
                    ? 'crossOrigin' : 'inaccessible';
                } catch (_) { reason = 'crossOrigin'; }
                inaccessibleFrameBoundaries.push({
                  parentContext: current.path,
                  frameLocalID: item.localID,
                  sourceURL: opaqueSandbox ? null : sourceOrigin,
                  reason
                });
              }
            }
            element = walker.nextNode();
          }
        }

        return {
          documentToken: state.documentToken,
          url: String(location.href || ''),
          title: bounded(document.title, 512),
          nodes,
          inaccessibleFrameBoundaries,
          visibleText: bounded(visibleText, maxText),
          limits: {maximumNodes: maxNodes, maximumRoots: maxRoots, maximumDepth: maxDepth, maximumText: maxText}
        };
      };
      const resolve = expected => {
        if (!expected || expected.documentToken !== state.documentToken) {
          throw new Error('semantic reference belongs to another document');
        }
        const identity = state.recordsByLocalID.get(expected.localID);
        const element = dereference(identity);
        if (!identity || !element || !element.isConnected) throw new Error('semantic element is stale');
        const current = descriptor(element, identity.path, []);
        if (current.localID !== expected.localID || current.role !== expected.role ||
            current.name !== expected.name || current.geometryDigest !== expected.geometryDigest ||
            pathKey(current.frameContext) !== pathKey(expected.frameContext)) {
          throw new Error('semantic element was replaced or substituted');
        }
        return element;
      };
      const setValue = (element, value) => {
        element.focus();
        const view = element.ownerDocument?.defaultView || window;
        const prototype = element.tagName === 'TEXTAREA'
          ? view.HTMLTextAreaElement?.prototype
          : element.tagName === 'INPUT' ? view.HTMLInputElement?.prototype : null;
        const setter = prototype && Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
        if (setter) setter.call(element, value); else if (element.isContentEditable) element.textContent = value; else element.value = value;
        const InputEventType = view.InputEvent || InputEvent;
        const EventType = view.Event || Event;
        element.dispatchEvent(new InputEventType('input', {bubbles: true, inputType: 'insertText', data: value}));
        element.dispatchEvent(new EventType('change', {bubbles: true}));
      };
      const effect = request => {
        // Refresh every identity and fingerprint immediately before the effect.
        const refreshed = scan({maximumNodes: 4096, maximumRoots: 128, maximumDepth: 32});
        if (refreshed.error) throw new Error(refreshed.error);
        const element = request.reference ? resolve(request.reference) : null;
        switch (request.action) {
        case 'click': case 'download_file':
          element.scrollIntoView({block: 'center'}); element.click(); return 'clicked';
        case 'hover':
          element.scrollIntoView({block: 'center'});
          {
            const MouseEventType = element.ownerDocument?.defaultView?.MouseEvent || MouseEvent;
            for (const type of ['mouseover', 'mouseenter', 'mousemove']) element.dispatchEvent(new MouseEventType(type, {bubbles: true}));
          }
          return 'hovered';
        case 'focus': element.scrollIntoView({block: 'center'}); element.focus(); return 'focused';
        case 'fill': setValue(element, String(request.value || '')); return 'filled';
        case 'clear': setValue(element, ''); return 'cleared';
        case 'check': case 'uncheck':
          element.checked = request.action === 'check';
          {
            const EventType = element.ownerDocument?.defaultView?.Event || Event;
            element.dispatchEvent(new EventType('input', {bubbles: true}));
            element.dispatchEvent(new EventType('change', {bubbles: true}));
          }
          return {checked: !!element.checked};
        case 'select_option': {
          const values = Array.isArray(request.values) ? request.values.map(String) : [];
          for (const option of Array.from(element.options || [])) option.selected = values.includes(option.value) || values.includes(option.text);
          const EventType = element.ownerDocument?.defaultView?.Event || Event;
          element.dispatchEvent(new EventType('input', {bubbles: true}));
          element.dispatchEvent(new EventType('change', {bubbles: true}));
          return Array.from(element.selectedOptions || []).map(option => option.value);
        }
        case 'scroll': {
          const target = element || window;
          target.scrollBy({left: Number(request.x) || 0, top: Number(request.y) || 0, behavior: 'instant'});
          return element ? {left: element.scrollLeft, top: element.scrollTop} : {x: scrollX, y: scrollY};
        }
        case 'drag': {
          const target = request.targetReference
            ? resolve(request.targetReference)
            : document.elementFromPoint(Number(request.x) || 0, Number(request.y) || 0);
          if (!target) throw new Error('drag endpoint not found');
          const sourceView = element.ownerDocument?.defaultView || window;
          const targetView = target.ownerDocument?.defaultView || window;
          const transfer = new (sourceView.DataTransfer || DataTransfer)();
          const sourceDragEvent = sourceView.DragEvent || DragEvent;
          const targetDragEvent = targetView.DragEvent || DragEvent;
          element.dispatchEvent(new sourceDragEvent('dragstart', {bubbles: true, dataTransfer: transfer}));
          target.dispatchEvent(new targetDragEvent('dragenter', {bubbles: true, dataTransfer: transfer}));
          target.dispatchEvent(new targetDragEvent('dragover', {bubbles: true, dataTransfer: transfer}));
          target.dispatchEvent(new targetDragEvent('drop', {bubbles: true, dataTransfer: transfer}));
          element.dispatchEvent(new sourceDragEvent('dragend', {bubbles: true, dataTransfer: transfer}));
          return 'dragged';
        }
        case 'upload_file': {
          const view = element.ownerDocument?.defaultView || window;
          const transfer = new (view.DataTransfer || DataTransfer)();
          const FileType = view.File || File;
          for (const item of Array.isArray(request.files) ? request.files : []) {
            const binary = atob(item.data);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
            transfer.items.add(new FileType([bytes], item.name));
          }
          element.files = transfer.files;
          const EventType = element.ownerDocument?.defaultView?.Event || Event;
          element.dispatchEvent(new EventType('input', {bubbles: true}));
          element.dispatchEvent(new EventType('change', {bubbles: true}));
          return Array.from(element.files).map(file => ({name: file.name, size: file.size}));
        }
        default: throw new Error('unsupported semantic effect');
        }
      };
      const wait = request => new Promise(resolveWait => {
        const token = String(request.token || '');
        const timeout = Math.max(1, Math.min(Number(request.timeoutMilliseconds) || 15000, 60000));
        let disposed = false;
        let timer = null;
        let reportTimer = null;
        const observer = new MutationObserver(schedule);
        const observedRoots = new Set();
        const listeners = [];
        const cleanup = () => {
          if (disposed) return;
          disposed = true;
          if (timer !== null) clearTimeout(timer);
          if (reportTimer !== null) clearTimeout(reportTimer);
          observer.disconnect();
          for (const item of listeners) {
            try { item.root.removeEventListener(item.name, schedule, true); } catch (_) {}
          }
          state.waits.delete(token);
        };
        const finish = result => { cleanup(); resolveWait(result); };
        const observeRoots = () => {
          const roots = [];
          const queue = [document];
          const seen = new Set();
          while (queue.length && roots.length < 128) {
            const root = queue.shift();
            const ownerDocument = root?.nodeType === Node.DOCUMENT_NODE ? root : root?.ownerDocument;
            if (!root || !ownerDocument || seen.has(root)) continue;
            seen.add(root);
            roots.push(root);
            const walker = ownerDocument.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
            let element = walker.nextNode();
            while (element && queue.length + roots.length < 128) {
              if (element.shadowRoot) queue.push(element.shadowRoot);
              if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
                try {
                  const frameDocument = element.contentDocument;
                  if (frameDocument) {
                    void frameDocument.location.href;
                    queue.push(frameDocument);
                  }
                } catch (_) {}
              }
              element = walker.nextNode();
            }
          }
          for (const root of roots) {
            if (observedRoots.has(root)) continue;
            observedRoots.add(root);
            try { observer.observe(root, {subtree: true, childList: true, attributes: true, characterData: true}); } catch (_) {}
            for (const name of ['input', 'change', 'focus', 'blur', 'load']) {
              try { root.addEventListener(name, schedule, true); listeners.push({root, name}); } catch (_) {}
            }
          }
        };
        const check = () => {
          reportTimer = null;
          if (disposed) return;
          observeRoots();
          const snapshot = scan({selectors: request.selector ? [request.selector] : []});
          if (snapshot.error) return finish({status: 'error', error: snapshot.error});
          let matched = false;
          if (request.condition === 'selector') {
            matched = snapshot.nodes.some(node => node.matchedSelectors.includes(request.selector));
          } else if (request.condition === 'text') {
            matched = snapshot.visibleText.includes(String(request.value || ''));
          } else if (request.condition === 'elementState') {
            const node = snapshot.nodes.find(item => item.localID === request.localID);
            if (!node) return finish({status: 'matched', snapshot});
            matched = node.states.includes(request.state) === !!request.isPresent;
          }
          if (matched) finish({status: 'matched', snapshot});
        };
        function schedule() {
          if (disposed || reportTimer !== null) return;
          reportTimer = setTimeout(check, 32);
        }
        state.waits.set(token, () => finish({status: 'cancelled'}));
        observeRoots();
        timer = setTimeout(() => finish({status: 'timeout'}), timeout);
        check();
      });
      // ---- Autofill -------------------------------------------------------
      // Writes every assignment in ONE pass: a single scan (which refreshes all
      // identities), then resolve + setValue per field. Looping effect() instead
      // would re-scan up to 4096 nodes for each of them.
      const autofillApply = request => {
        const assignments = Array.isArray(request && request.assignments) ? request.assignments : [];
        if (!assignments.length) return {filled: 0, failed: []};
        const refreshed = scan({maximumNodes: 4096, maximumRoots: 128, maximumDepth: 32});
        if (refreshed.error) throw new Error(refreshed.error);
        const restoreTo = document.activeElement;
        const failed = [];
        let filled = 0;
        // setValue() focuses each element it writes, which would re-fire focusin
        // and reopen the suggestion list on every field we touch.
        state.autofillSuppressed = true;
        try {
          for (const assignment of assignments) {
            try {
              const element = resolve(assignment.reference);
              if (element.type === 'password') continue;   // belt and braces
              setValue(element, String(assignment.value == null ? '' : assignment.value));
              filled += 1;
            } catch (error) {
              failed.push({localID: assignment.reference && assignment.reference.localID,
                           error: String(error && error.message || error)});
            }
          }
        } finally {
          state.autofillSuppressed = false;
          try { if (restoreTo && restoreTo.focus) restoreTo.focus(); } catch (_) {}
        }
        return {filled, failed};
      };

      const postAutofill = payload => {
        try { window.webkit.messageHandlers.straightUpSemantic.postMessage(payload); } catch (_) {}
      };
      let autofillDetach = null;
      const dismissAutofill = () => {
        if (autofillDetach) { autofillDetach(); autofillDetach = null; }
        postAutofill({type: 'autofillFieldDismissed'});
      };
      document.addEventListener('focusin', event => {
        if (state.autofillSuppressed) return;
        const element = event.target;
        if (!element || !/^(INPUT|TEXTAREA)$/.test(element.tagName || '')) return;
        const type = String(element.type || '').toLowerCase();
        if (type === 'password' || type === 'hidden') return;
        // Register the identity now so the localID we report can be resolved later.
        const identity = identityFor(element, []);
        // One frame of slack: focusing a field near the fold scrolls it into view,
        // and a rect read before that settles points at where the field WAS.
        requestAnimationFrame(() => {
          if (document.activeElement !== element || state.autofillSuppressed) return;
          const rect = element.getBoundingClientRect();
          postAutofill({
            type: 'autofillFieldFocused',
            documentToken: state.documentToken,
            localID: identity.localID,
            role: roleFor(element),
            name: nameFor(element),
            geometryDigest: geometryFor(element),
            frameContext: [],
            hints: fieldHints(element),
            // CSS viewport pixels. Swift converts; see AutofillGeometry.
            rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
          });
        });
        // Attached only while a text field is focused, so no page pays for these
        // unless the user is actually in a form.
        const onScroll = () => dismissAutofill();
        window.addEventListener('scroll', onScroll, {capture: true, passive: true, once: true});
        window.addEventListener('resize', onScroll, {once: true});
        autofillDetach = () => {
          window.removeEventListener('scroll', onScroll, {capture: true});
          window.removeEventListener('resize', onScroll);
        };
      }, true);
      document.addEventListener('focusout', () => {
        if (state.autofillSuppressed) return;
        dismissAutofill();
      }, true);

      state.snapshot = scan;
      state.effect = effect;
      state.wait = wait;
      state.autofillApply = autofillApply;
      state.autofillSuppressed = false;
      state.cancelWait = token => state.waits.get(String(token || ''))?.();
      Object.defineProperty(window, runtimeKey, {
        value: state,
        configurable: true,
        enumerable: false
      });
    })();
    """#

    static let snapshot = #"""
    const runtime = window.__straightUpSemanticRuntimeV2;
    if (!runtime || runtime.ownerDocument !== document) throw new Error('semantic runtime is unavailable');
    return runtime.snapshot({
      selectors: typeof selectors !== 'undefined' && Array.isArray(selectors) ? selectors : [],
      maximumNodes: typeof maximumNodes !== 'undefined' ? maximumNodes : 4096,
      maximumRoots: typeof maximumRoots !== 'undefined' ? maximumRoots : 128,
      maximumDepth: typeof maximumDepth !== 'undefined' ? maximumDepth : 32,
      maximumText: typeof maximumText !== 'undefined' ? maximumText : 65536
    });
    """#

    static let effect = #"""
    const runtime = window.__straightUpSemanticRuntimeV2;
    if (!runtime || runtime.ownerDocument !== document) throw new Error('semantic runtime is unavailable');
    return runtime.effect(request);
    """#

    static let wait = #"""
    const runtime = window.__straightUpSemanticRuntimeV2;
    if (!runtime || runtime.ownerDocument !== document) throw new Error('semantic runtime is unavailable');
    return await runtime.wait(request);
    """#

    static let cancelWait = #"""
    const runtime = window.__straightUpSemanticRuntimeV2;
    if (runtime && runtime.ownerDocument === document) runtime.cancelWait(token);
    return true;
    """#

    /// Message-handler name for the isolated world. It cannot share `"sub"`:
    /// that handler is registered with `add(_:name:)`, which is page-world only,
    /// so `window.webkit.messageHandlers.sub` doesn't exist here. Sharing a name
    /// across worlds would also erase the trust boundary — `WKScriptMessage`
    /// can't report which world it came from, so a page could forge these.
    static let messageHandlerName = "straightUpSemantic"

    static let autofillApply = #"""
    const runtime = window.__straightUpSemanticRuntimeV2;
    if (!runtime || runtime.ownerDocument !== document) throw new Error('semantic runtime is unavailable');
    return runtime.autofillApply(request);
    """#
}

nonisolated struct SemanticPageSnapshot: Codable, Equatable, Sendable {
    var page: PageHandle
    var navigationGeneration: PageNavigationGeneration
    var documentGeneration: PageDocumentGeneration
    var nodes: [SemanticNodeSnapshot]
    var inaccessibleFrameBoundaries: [SemanticFrameBoundary]
    var visibleText: String

    init(
        page: PageHandle,
        navigationGeneration: PageNavigationGeneration,
        documentGeneration: PageDocumentGeneration,
        nodes: [SemanticNodeSnapshot],
        inaccessibleFrameBoundaries: [SemanticFrameBoundary] = [],
        visibleText: String = ""
    ) {
        self.page = page
        self.navigationGeneration = navigationGeneration
        self.documentGeneration = documentGeneration
        self.nodes = nodes
        self.inaccessibleFrameBoundaries = inaccessibleFrameBoundaries
        self.visibleText = visibleText
    }
}

nonisolated struct SemanticPageJavaScriptSnapshot: Equatable, Sendable {
    let snapshot: SemanticPageSnapshot
    let url: URL?
    let title: String

    static func decode(
        _ value: Any,
        page: PageHandle,
        generationTracker: inout SemanticPageGenerationTracker
    ) throws -> Self {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw SemanticPageJavaScriptError.invalidPayload
        }
        if payload.error != nil {
            throw SemanticPageJavaScriptError.invalidPayload
        }
        guard let token = UUID(uuidString: payload.documentToken) else {
            throw SemanticPageJavaScriptError.invalidDocumentToken(payload.documentToken)
        }
        let navigationGeneration = generationTracker.generation(
            for: page,
            documentToken: token
        )
        let nodes = try payload.nodes.map { node in
            SemanticNodeSnapshot(
                localID: node.localID,
                legacySubID: node.legacySubID,
                role: node.role,
                name: node.name,
                states: Set(node.states.compactMap(SemanticElementState.init(rawValue:))),
                frameContext: SemanticFrameContext(path: try decode(path: node.frameContext)),
                geometryDigest: SemanticGeometryDigest(rawValue: node.geometryDigest),
                matchedSelectors: Set(node.matchedSelectors),
                text: node.text,
                destinationURL: node.destinationURL.flatMap(URL.init(string:)),
                isInteractive: node.isInteractive,
                fieldHints: node.fieldHints
            )
        }
        let boundaries = try payload.inaccessibleFrameBoundaries.map { boundary in
            guard let reason = SemanticFrameBoundaryReason(rawValue: boundary.reason) else {
                throw SemanticPageJavaScriptError.invalidFramePath
            }
            return SemanticFrameBoundary(
                parentContext: SemanticFrameContext(path: try decode(path: boundary.parentContext)),
                frameLocalID: boundary.frameLocalID,
                sourceURL: boundary.sourceURL.flatMap(URL.init(string:)),
                reason: reason
            )
        }
        return Self(
            snapshot: SemanticPageSnapshot(
                page: page,
                navigationGeneration: navigationGeneration,
                documentGeneration: PageDocumentGeneration(rawValue: token),
                nodes: nodes,
                inaccessibleFrameBoundaries: boundaries,
                visibleText: payload.visibleText
            ),
            url: URL(string: payload.url),
            title: payload.title
        )
    }

    static func effectReference(
        for node: SemanticNodeSnapshot,
        in snapshot: SemanticPageSnapshot
    ) -> [String: Any] {
        [
            "documentToken": snapshot.documentGeneration.rawValue.uuidString.lowercased(),
            "localID": node.localID,
            "role": node.role,
            "name": node.name,
            "geometryDigest": node.geometryDigest.rawValue,
            "frameContext": encode(path: node.frameContext.path),
        ]
    }

    static func renderCompatibilityText(
        _ value: Self,
        enhanced: Bool
    ) -> String {
        let interactive = value.snapshot.nodes.filter(\.isInteractive)
        var lines = [
            "URL: \(value.url?.absoluteString ?? "")",
            "TITLE: \(value.title)",
            "",
            "INTERACTIVE (\(interactive.count)):",
        ]
        for node in interactive.prefix(300) {
            let identifier = node.legacySubID.map { "sub-\($0)" } ?? node.localID
            var line = "[\(identifier)] \(node.role) \"\(node.name)\""
            if let destinationURL = node.destinationURL {
                line += " -> \(destinationURL.absoluteString)"
            }
            if node.states.contains(.checked) { line += " checked=true" }
            if node.states.contains(.disabled) { line += " disabled=true" }
            if enhanced {
                line += " rect=(\(node.geometryDigest.rawValue.replacingOccurrences(of: ":", with: ",")))"
                if !node.frameContext.path.isEmpty { line += " frame=\(node.frameContext.path.count)" }
            }
            lines.append(line)
        }
        if !value.snapshot.inaccessibleFrameBoundaries.isEmpty {
            lines.append("")
            lines.append("FRAME BOUNDARIES (\(value.snapshot.inaccessibleFrameBoundaries.count)):")
            for boundary in value.snapshot.inaccessibleFrameBoundaries.prefix(64) {
                lines.append(
                    "[\(boundary.frameLocalID)] \(boundary.reason.rawValue) \(boundary.sourceURL?.absoluteString ?? "origin unavailable")"
                )
            }
        }
        lines.append("")
        lines.append("TEXT:")
        let maximumText = enhanced ? 20_000 : 8_000
        let text = String(value.snapshot.visibleText.prefix(maximumText))
        lines.append(text)
        if value.snapshot.visibleText.count > maximumText { lines.append("…[truncated]") }
        return lines.joined(separator: "\n")
    }

    private struct Payload: Decodable {
        let documentToken: String
        let url: String
        let title: String
        let nodes: [Node]
        let inaccessibleFrameBoundaries: [Boundary]
        let visibleText: String
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case documentToken, url, title, nodes, inaccessibleFrameBoundaries, visibleText, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            documentToken = try container.decodeIfPresent(String.self, forKey: .documentToken) ?? ""
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
            inaccessibleFrameBoundaries = try container.decodeIfPresent(
                [Boundary].self,
                forKey: .inaccessibleFrameBoundaries
            ) ?? []
            visibleText = try container.decodeIfPresent(String.self, forKey: .visibleText) ?? ""
            error = try container.decodeIfPresent(String.self, forKey: .error)
        }
    }

    private struct Node: Decodable {
        let localID: String
        let legacySubID: Int?
        let role: String
        let name: String
        let states: [String]
        let frameContext: [Path]
        let geometryDigest: String
        let matchedSelectors: [String]
        let text: String
        let destinationURL: String?
        let isInteractive: Bool
        /// Absent for everything that isn't a form control.
        let fieldHints: AutofillFieldDescriptor?
    }

    private struct Boundary: Decodable {
        let parentContext: [Path]
        let frameLocalID: String
        let sourceURL: String?
        let reason: String
    }

    private struct Path: Codable {
        let kind: String
        let localID: String?
        let origin: String?
        let hostLocalID: String?
    }

    private static func decode(path: [Path]) throws -> [SemanticDOMPathComponent] {
        try path.map { item in
            switch item.kind {
            case "sameOriginFrame":
                guard let localID = item.localID else {
                    throw SemanticPageJavaScriptError.invalidFramePath
                }
                return .sameOriginFrame(localID: localID, origin: item.origin)
            case "openShadowRoot":
                guard let hostLocalID = item.hostLocalID else {
                    throw SemanticPageJavaScriptError.invalidFramePath
                }
                return .openShadowRoot(hostLocalID: hostLocalID)
            default:
                throw SemanticPageJavaScriptError.invalidFramePath
            }
        }
    }

    private static func encode(path: [SemanticDOMPathComponent]) -> [[String: Any]] {
        path.map { item in
            switch item {
            case .sameOriginFrame(let localID, let origin):
                return [
                    "kind": "sameOriginFrame",
                    "localID": localID,
                    "origin": origin ?? NSNull(),
                ]
            case .openShadowRoot(let hostLocalID):
                return [
                    "kind": "openShadowRoot",
                    "hostLocalID": hostLocalID,
                ]
            }
        }
    }
}

nonisolated enum SemanticReferenceResolutionError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case pageChanged(expected: PageHandle, actual: PageHandle)
    case navigationChanged(
        expected: PageNavigationGeneration,
        actual: PageNavigationGeneration
    )
    case documentChanged(
        expected: PageDocumentGeneration,
        actual: PageDocumentGeneration
    )
    case missing(SemanticElementIdentifier)
    case substituted(SemanticElementIdentifier)
    case ambiguous(identifier: SemanticElementIdentifier, matches: Int)
}

nonisolated enum SemanticElementResolver {
    static func resolve(
        _ reference: SemanticElementReference,
        in snapshot: SemanticPageSnapshot
    ) throws -> SemanticNodeSnapshot {
        guard reference.page == snapshot.page else {
            throw SemanticReferenceResolutionError.pageChanged(
                expected: reference.page,
                actual: snapshot.page
            )
        }
        guard reference.navigationGeneration == snapshot.navigationGeneration else {
            throw SemanticReferenceResolutionError.navigationChanged(
                expected: reference.navigationGeneration,
                actual: snapshot.navigationGeneration
            )
        }
        guard reference.documentGeneration == snapshot.documentGeneration else {
            throw SemanticReferenceResolutionError.documentChanged(
                expected: reference.documentGeneration,
                actual: snapshot.documentGeneration
            )
        }

        let identifierMatches = snapshot.nodes.filter { node in
            switch reference.identifier {
            case .local(let localID): node.localID == localID
            case .legacySub(let ordinal): node.legacySubID == ordinal
            }
        }
        guard !identifierMatches.isEmpty else {
            throw SemanticReferenceResolutionError.missing(reference.identifier)
        }
        let matches = identifierMatches.filter {
            $0.frameContext == reference.frameContext
        }
        guard !matches.isEmpty else {
            throw SemanticReferenceResolutionError.substituted(reference.identifier)
        }
        guard matches.count == 1, let node = matches.first else {
            throw SemanticReferenceResolutionError.ambiguous(
                identifier: reference.identifier,
                matches: matches.count
            )
        }
        guard node.role == reference.role,
              node.name == reference.name,
              node.geometryDigest == reference.geometryDigest else {
            throw SemanticReferenceResolutionError.substituted(reference.identifier)
        }
        return node
    }
}
