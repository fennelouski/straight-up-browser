import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

nonisolated struct FileMetadata: Sendable {
    let exists: Bool
    let sizeText: String?
    let typeText: String?
    let created: Date?
    let accessed: Date?
    #if os(macOS)
    let icon: CGImage?
    #endif
}

// One worker per window serializes visible-row reads without blocking MainActor.
actor FileMetadataLoader {
    func exists(_ url: URL) throws -> Bool {
        try Task.checkCancellation()
        assert(!Thread.isMainThread)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func load(_ url: URL) throws -> FileMetadata {
        let exists = try exists(url)
        let values = exists ? try? url.resourceValues(forKeys: [
            .totalFileSizeKey, .fileSizeKey, .contentTypeKey,
            .creationDateKey, .contentAccessDateKey,
        ]) : nil
        let size = values?.totalFileSize ?? values?.fileSize
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        #if os(macOS)
        // NSWorkspace permits icon(forFile:) on any thread. Only the immutable
        // bitmap crosses to the UI; never share or mutate its cached NSImage.
        var rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
            .cgImage(forProposedRect: &rect, context: nil, hints: nil)
        try Task.checkCancellation()
        return FileMetadata(exists: exists, sizeText: sizeText,
                            typeText: values?.contentType?.localizedDescription,
                            created: values?.creationDate, accessed: values?.contentAccessDate,
                            icon: icon)
        #else
        try Task.checkCancellation()
        return FileMetadata(exists: exists, sizeText: sizeText,
                            typeText: values?.contentType?.localizedDescription,
                            created: values?.creationDate, accessed: values?.contentAccessDate)
        #endif
    }
}
