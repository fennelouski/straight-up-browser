import CoreGraphics
import Foundation
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Browser"
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var best = (id: 0, area: 0)
for w in list {
    guard let o = w[kCGWindowOwnerName as String] as? String, o == owner,
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let area = Int((b["Width"] ?? 0) * (b["Height"] ?? 0))
    if area > best.area { best = (id, area) }
}
print(best.id)
