import SwiftUI
import Vision
import CoreImage
import ImageIO

/// Immutable, bounded decoded images may cross the image worker boundary.
nonisolated final class NewspaperCoverBitmap: @unchecked Sendable {
    let original: CGImage
    let subject: CGImage?
    init(original: CGImage, subject: CGImage?) { self.original = original; self.subject = subject }
}

/// Photos stay in a small memory cache. Ephemeral, credential-free requests;
/// optional subject isolation runs in Vision on this device, never an AI API.
actor NewspaperCoverImageWorker {
    static let shared = NewspaperCoverImageWorker()
    private let cache = NSCache<NSString, NewspaperCoverBitmap>()
    private let session: URLSession
    private var pending: [String: Task<NewspaperCoverBitmap?, Never>] = [:]
    init() {
        cache.countLimit = 12
        cache.totalCostLimit = 48 * 1024 * 1024
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: NewspaperImageRequestPolicy(), delegateQueue: nil)
    }
    func load(_ url: URL, cutout: Bool) async -> NewspaperCoverBitmap? {
        guard NewspaperImageRequestPolicy.permits(url) else { return nil }
        let cutout = cutout && !ProcessInfo.processInfo.isLowPowerModeEnabled
        let key = url.absoluteString + (cutout ? "-subject" : "-photo")
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = pending[key] { return await task.value }
        while pending.count >= 3 {
            if let task = pending.values.first { _ = await task.value }
            guard !Task.isCancelled else { return nil }
        }
        // Recheck after yielding to an existing worker.
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = pending[key] { return await task.value }
        let task = Task {
            let result = await self.fetch(url, cutout: cutout)
            self.pending[key] = nil
            if let result { self.cache.setObject(result, forKey: key as NSString, cost: result.original.bytesPerRow * result.original.height * (result.subject == nil ? 1 : 2)) }
            return result
        }
        pending[key] = task
        return await task.value
    }
    private func fetch(_ url: URL, cutout: Bool) async -> NewspaperCoverBitmap? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.mimeType?.hasPrefix("image/") == true,
                  response.expectedContentLength <= 8 * 1024 * 1024 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 8 * 1024 * 1024 || Task.isCancelled { return nil }
                data.append(byte)
            }
            guard !Task.isCancelled else { return nil }
            let decoded = await Task.detached(priority: .utility) { Self.decode(data, cutout: cutout) }.value
            return decoded
        } catch { return nil }
    }
    nonisolated static func decode(_ data: Data, cutout: Bool) -> NewspaperCoverBitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { return nil }
        var subject: CGImage?
        if cutout {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            if (try? handler.perform([request])) != nil, let observation = request.results?.first,
               !observation.allInstances.isEmpty,
               let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false) {
                let result = CIImage(cvPixelBuffer: buffer)
                subject = CIContext().createCGImage(result, from: result.extent)
            }
        }
        return NewspaperCoverBitmap(original: image, subject: subject)
    }
}

nonisolated private final class NewspaperImageRequestPolicy: NSObject, URLSessionTaskDelegate {
    nonisolated static func permits(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host.contains("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.contains(":"),
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.permits) == true ? request : nil)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

struct NewspaperCoverPhoto: View {
    let url: URL
    let cutout: Bool
    var layer: Layer = .photo
    enum Layer { case photo, subject }
    @State private var bitmap: NewspaperCoverBitmap?
    var body: some View {
        Group {
            if let bitmap {
                if layer == .photo {
                    Image(decorative: bitmap.original, scale: 1).resizable().scaledToFill()
                } else if let subject = bitmap.subject {
                    Image(decorative: subject, scale: 1).resizable().scaledToFill()
                }
            }
        }
        .transition(BrowserMotion.panel)
        .newspaperMotion(bitmap != nil)
        .task(id: "\(url)-\(cutout)") {
            bitmap = nil
            let result = await NewspaperCoverImageWorker.shared.load(url, cutout: cutout)
            guard !Task.isCancelled else { return }
            bitmap = result
        }
    }
}
