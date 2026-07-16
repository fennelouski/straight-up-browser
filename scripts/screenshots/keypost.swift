import CoreGraphics
import Foundation
// usage: keypost <keycode> [cmd,opt,shift,ctrl]
guard let kc = UInt16(CommandLine.arguments[1]) else { exit(2) }
var flags: CGEventFlags = []
if CommandLine.arguments.count > 2 {
    for m in CommandLine.arguments[2].split(separator: ",") {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
}
let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kc), keyDown: true)!
down.flags = flags
let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kc), keyDown: false)!
up.flags = flags
down.post(tap: .cghidEventTap)
usleep(40000)
up.post(tap: .cghidEventTap)
