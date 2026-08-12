import Foundation

/// Loads a checked-in fixture from the test bundle.
///
/// Fixtures used to be read out of the source tree via `#filePath`. That fails
/// badly rather than loudly: when the checkout lives under `~/Documents`, the
/// sandboxed test host needs TCC consent to read it, blocks on a prompt it can
/// never display, and the test dies at the timeout as "Time limit was exceeded"
/// with nothing pointing at the real cause. It bit four tests here and looks
/// exactly like a hung test — the same trap `scripts/verify.sh` already
/// documents for derived data.
///
/// The synchronized test folder copies these files into the bundle already, so
/// reading them from there needs no consent, no path arithmetic, and works
/// wherever the repo happens to live.
///
/// Deliberately no `#filePath` fallback: falling back would silently restore
/// the hang on exactly the machines the bundle lookup is meant to protect.
enum TestFixture {
    /// Anchors `Bundle(for:)` to the test bundle. Tests are swift-testing
    /// structs, so there's no XCTestCase class to point at.
    private final class BundleToken {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext) else {
            throw Failure.missingFromBundle(name)
        }
        return try Data(contentsOf: url)
    }

    enum Failure: Error, CustomStringConvertible {
        case missingFromBundle(String)

        var description: String {
            switch self {
            case .missingFromBundle(let name):
                return """
                    Fixture "\(name)" is not in the test bundle. Files under \
                    Straight Up BrowserTests/Fixtures/ are copied in \
                    automatically by the synchronized folder group — check the \
                    name and extension rather than reading it from the source \
                    tree, which hangs under TCC.
                    """
            }
        }
    }
}
