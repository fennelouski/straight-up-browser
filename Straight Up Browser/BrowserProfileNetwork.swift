import Foundation

/// Native requests in an explicit profile have no persistent cookie/cache or
/// credential storage and cannot issue requests. Production keeps its session.
nonisolated enum BrowserProfileNetwork {
    private static let isolated = URLSession(configuration: isolatedConfiguration())

    static var session: URLSession {
        BrowserProfile.isIsolated ? isolated : URLSession.shared
    }

    static func configuration(_ requested: URLSessionConfiguration) -> URLSessionConfiguration {
        BrowserProfile.isIsolated ? isolatedConfiguration() : requested
    }

    static func isolatedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [BrowserProfileURLProtocol.self]
        return configuration
    }
}

nonisolated private final class BrowserProfileURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.noPermissionsToReadFile))
    }
    override func stopLoading() {}
}

