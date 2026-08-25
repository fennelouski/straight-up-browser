//
//  ResearchLedger.swift
//  Straight Up Browser
//
//  Phase 1 of Thought Flow (docs/phase1-design.md): research workspaces and the
//  source ledger. A Workspace owns tabs; the ledger records the sources those
//  tabs were, once, globally, referenced by many workspaces.
//
//  The two rules everything else hangs off:
//    - Capture happens when a page SETTLES, never when a tab closes.
//    - Closing a tab is how a source is REJECTED, so it only writes a disposition.
//  ADR 0007 records why, because capture-on-close is the design a later session
//  will want to reintroduce.
//

import Foundation
import SwiftData

// MARK: - Vocabulary

/// What a source is, which decides how an anchor locator is composed into a URL.
nonisolated enum SourceModality: String, CaseIterable, Codable, Sendable {
    case webPage
    case video
    case pdf
    case image
    case importedFile

    /// Best guess from the URL alone. The user can correct it; nothing depends
    /// on this being right at capture time.
    static func inferred(from url: URL) -> SourceModality {
        if url.isFileURL { return .importedFile }
        let host = (url.host ?? "").lowercased()
        if host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") || host.hasSuffix("vimeo.com") {
            return .video
        }
        // arxiv.org/pdf/2401.12345 serves a PDF with no extension.
        if host.hasSuffix("arxiv.org"), url.path.hasPrefix("/pdf/") { return .pdf }
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "avif": return .image
        default: return .webPage
        }
    }
}

/// Where a workspace reference came from.
nonisolated enum SourceCaptureMethod: String, CaseIterable, Codable, Sendable {
    case settle          // the page loaded and the user stayed with it
    case manual          // deliberate one-keystroke capture, and workspace promotion
    case rejectedOnClose // never settled; the close itself created the row
    case shareSheet      // Phase 3
    case importBundle    // Phase 7
}

/// The user's verdict on a source within one workspace. Universal semantics:
/// no per-workspace setting, no per-user setting.
nonisolated enum SourceDisposition: String, CaseIterable, Codable, Sendable {
    case open       // still in the working set — written by settle
    case dismissed  // rejected — written by a user-initiated tab close, and nothing else
    case kept       // survived to the end — written by the archive sweep, and nothing else
}

/// Why a tab is closing. Required at every call site rather than defaulted:
/// `closeTab` has roughly fifteen callers and most are housekeeping, so a
/// default would silently misfile whichever one is added next.
nonisolated enum TabCloseReason: Sendable {
    /// The user rejected this source. The only value that writes `dismissed`.
    case userRejected
    /// Blank-tab cleanup, JS `window.close()`, container deletion, undoing an
    /// automatic link open. Never touches the ledger.
    case housekeeping
}

nonisolated enum WorkspaceCapturePolicy {
    /// Not "the page finished loading" — "you stayed with it". The ledger records
    /// sources that were considered, not every page that scrolled past.
    /// ponytail: tune here, nowhere else.
    static let settleDwell: Duration = .seconds(20)

    /// Archives above this are skipped; the extracted text still lands.
    /// ponytail: per-archive cap plus manual clearing in Settings, no automatic
    /// eviction. Add LRU eviction if the local archive store gets uncomfortable.
    static let maximumArchiveBytes = 25 * 1_024 * 1_024
}

// MARK: - Models

/// A named research project. Owns tabs (via `Tab.workspaceId`), documents, and
/// references into the global ledger.
///
/// There is no `isSuspended`: suspension is per-window view state on TabManager,
/// exactly as a Split is (ADR 0001). The same workspace can be open in one
/// window and not another.
@Model
final class Workspace {
    // Defaults on every attribute: SwiftData+CloudKit requires each
    // non-relationship attribute to be optional or have a default value.
    var id: UUID = UUID()
    var name: String = ""
    /// Frozen at create. Renaming a workspace must not re-file every article
    /// already sitting in the Newspaper under the old Section.
    var sectionName: String = ""
    var colorHex: String?
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    var lastActiveAt: Date = Date()
    /// Completion. Setting this runs the disposition sweep (open -> kept) and is
    /// the only thing that ever writes `kept`.
    var isArchived: Bool = false

    init(name: String, orderIndex: Int = 0, colorHex: String? = nil) {
        id = UUID()
        self.name = name
        sectionName = name
        self.colorHex = colorHex
        self.orderIndex = orderIndex
        createdAt = Date()
        lastActiveAt = Date()
    }
}

/// The join between a workspace and a source: when it entered this project, how,
/// what the user decided about it, and what led them to it.
@Model
final class WorkspaceSourceRef {
    var id: UUID = UUID()
    var workspaceId: UUID = UUID()
    /// NewspaperArticle.id — a Source is a Saved Article (ADR 0007).
    var sourceId: UUID = UUID()
    /// Denormalized so seen-before surfacing, which runs on every navigation,
    /// is one indexed fetch rather than a join walk.
    var sourceKey: String = ""
    var addedAt: Date = Date()
    var updatedAt: Date = Date()
    var methodRaw: String = SourceCaptureMethod.settle.rawValue
    var dispositionRaw: String = SourceDisposition.open.rawValue
    /// Which source led here — set when this tab was spawned from another
    /// workspace tab. Phase 1 records it and reads it nowhere; Phase 4's graph
    /// renders the fan-to-common-ancestor pattern from it.
    var openedFromSourceId: UUID?
    var note: String = ""

    init(
        workspaceId: UUID,
        sourceId: UUID,
        sourceKey: String,
        method: SourceCaptureMethod,
        disposition: SourceDisposition = .open,
        openedFromSourceId: UUID? = nil
    ) {
        id = UUID()
        self.workspaceId = workspaceId
        self.sourceId = sourceId
        self.sourceKey = sourceKey
        methodRaw = method.rawValue
        dispositionRaw = disposition.rawValue
        self.openedFromSourceId = openedFromSourceId
        addedAt = Date()
        updatedAt = Date()
    }

    var method: SourceCaptureMethod {
        get { SourceCaptureMethod(rawValue: methodRaw) ?? .settle }
        set { methodRaw = newValue.rawValue }
    }

    var disposition: SourceDisposition {
        get { SourceDisposition(rawValue: dispositionRaw) ?? .open }
        set { dispositionRaw = newValue.rawValue }
    }
}

/// A precise location inside a source. One `locator` column serves every
/// modality; `AnchorLocator` composes it into a URL and back.
@Model
final class LedgerAnchor {
    var id: UUID = UUID()
    var sourceId: UUID = UUID()
    var sourceKey: String = ""
    var modalityRaw: String = SourceModality.webPage.rawValue
    var locator: String = ""
    /// The resilience copy. An anchor with no quote cannot survive its locator
    /// breaking, which is the whole point of storing one.
    var quote: String = ""
    var label: String = ""
    var createdAt: Date = Date()

    init(
        sourceId: UUID,
        sourceKey: String,
        modality: SourceModality,
        locator: String,
        quote: String,
        label: String = ""
    ) {
        id = UUID()
        self.sourceId = sourceId
        self.sourceKey = sourceKey
        modalityRaw = modality.rawValue
        self.locator = locator
        self.quote = quote
        self.label = label
        createdAt = Date()
    }

    var modality: SourceModality {
        get { SourceModality(rawValue: modalityRaw) ?? .webPage }
        set { modalityRaw = newValue.rawValue }
    }
}

/// A named assertion, promoted from a text range when the user wants dedup
/// across projects. Phase 1 creates none of these; the table exists because
/// `LedgerEdge.claimId` references it.
@Model
final class LedgerClaim {
    var id: UUID = UUID()
    var text: String = ""
    /// Lowercased, whitespace-collapsed. The dedup key across projects.
    var normalizedText: String = ""
    var createdAt: Date = Date()

    init(text: String) {
        id = UUID()
        self.text = text
        normalizedText = Self.normalize(text)
        createdAt = Date()
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A link between a text range in a document and an anchor in a source. The
/// graph view, the audit view, and "unsupported claims" are all renderings of
/// this one table.
@Model
final class LedgerEdge {
    var id: UUID = UUID()
    var documentId: UUID = UUID()
    var anchorId: UUID = UUID()
    /// nil = a plain text range, which is the default. Non-nil = a promoted claim.
    var claimId: UUID?
    /// Offsets are the fast path; this is the truth. A file edited in an external
    /// app invalidates every offset in it, and re-finding by quote is what makes
    /// that survivable.
    var rangeQuote: String = ""
    var rangeStart: Int = 0
    var rangeLength: Int = 0
    var createdAt: Date = Date()

    init(
        documentId: UUID,
        anchorId: UUID,
        rangeQuote: String,
        rangeStart: Int = 0,
        rangeLength: Int = 0,
        claimId: UUID? = nil
    ) {
        id = UUID()
        self.documentId = documentId
        self.anchorId = anchorId
        self.rangeQuote = rangeQuote
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.claimId = claimId
        createdAt = Date()
    }
}

/// A Markdown file belonging to a workspace. Phase 1 stores the reference only —
/// no editor, no file creation, no reading or writing of contents.
///
/// Paths are relative to the app's own iCloud Drive container rather than
/// security-scoped bookmarks, which are device-specific and would not survive
/// sync to the iPad.
@Model
final class WorkspaceDocument {
    var id: UUID = UUID()
    var workspaceId: UUID = UUID()
    var displayName: String = ""
    var relativePath: String = ""
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    var lastOpenedAt: Date?

    init(workspaceId: UUID, displayName: String, relativePath: String, orderIndex: Int = 0) {
        id = UUID()
        self.workspaceId = workspaceId
        self.displayName = displayName
        self.relativePath = relativePath
        self.orderIndex = orderIndex
        createdAt = Date()
    }
}

/// A video's caption track, fetched once and searchable on every device.
/// Phase 2 (docs/phase2-design.md §7–8): YouTube captions only, no ASR.
///
/// Synced deliberately, unlike LedgerArchive: a transcript is extracted text,
/// and extracted text syncs. ~100–300KB per hour of video via externalStorage
/// (a CKAsset), comfortably inside CloudKit limits.
@Model
final class SourceTranscript {
    var id: UUID = UUID()
    var sourceId: UUID = UUID()
    /// Uniqueness by fetch-then-insert on this key; a re-fetch replaces segments.
    var sourceKey: String = ""
    /// BCP-47 language of the chosen caption track.
    var languageCode: String = ""
    /// YouTube ASR ("auto-generated") vs author-provided captions.
    var isAutoGenerated: Bool = true
    var fetchedAt: Date = Date()
    /// JSON-encoded [TranscriptSegment]: start/duration seconds + text.
    @Attribute(.externalStorage) var segmentsData: Data?

    init(sourceId: UUID, sourceKey: String, languageCode: String, isAutoGenerated: Bool, segmentsData: Data?) {
        id = UUID()
        self.sourceId = sourceId
        self.sourceKey = sourceKey
        self.languageCode = languageCode
        self.isAutoGenerated = isAutoGenerated
        self.segmentsData = segmentsData
        fetchedAt = Date()
    }

    var segments: [TranscriptSegment] {
        guard let segmentsData else { return [] }
        return (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
    }
}

/// One caption line. `s` = start seconds, `d` = duration seconds, `t` = text —
/// short keys because thousands of these are JSON-encoded per video.
nonisolated struct TranscriptSegment: Codable, Equatable, Sendable {
    var s: Double
    var d: Double
    var t: String

    var startSeconds: Int { Int(s) }
    var endSeconds: Int { Int((s + d).rounded(.up)) }
}

/// A page snapshot taken at capture time, so an anchor survives the page 404ing
/// or the text fragment no longer matching.
///
/// LOCAL ONLY — deliberately absent from `TabSync.cloudBackedModels`. Archives
/// run to tens of MB; syncing them would wreck the CloudKit quota. It lives in
/// the container's second, non-CloudKit ModelConfiguration, which is also why
/// every cross-entity link in this file is a UUID rather than a SwiftData
/// relationship: a synced model cannot relate to one in another configuration.
@Model
final class LedgerArchive {
    var id: UUID = UUID()
    var sourceId: UUID = UUID()
    var sourceKey: String = ""
    var capturedAt: Date = Date()
    var byteCount: Int = 0
    @Attribute(.externalStorage) var webArchiveData: Data?

    init(sourceId: UUID, sourceKey: String, webArchiveData: Data?) {
        id = UUID()
        self.sourceId = sourceId
        self.sourceKey = sourceKey
        self.webArchiveData = webArchiveData
        byteCount = webArchiveData?.count ?? 0
        capturedAt = Date()
    }
}
