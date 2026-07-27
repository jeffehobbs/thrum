import CoreGraphics
import Foundation

// Posts a real mouse click at a global screen point. System Events' "click at"
// routes through accessibility and never reaches SwiftUI gestures, so testing
// the pads needs an actual CGEvent.
//
//   thrumclick <x> <y> [option]

let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else {
    print("usage: thrumclick <x> <y> [option]")
    exit(1)
}
let withOption = a.count > 3 && a[3] == "option"
let p = CGPoint(x: x, y: y)
let flags: CGEventFlags = withOption ? .maskAlternate : []

let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(60_000)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
down?.flags = flags
down?.post(tap: .cghidEventTap)
usleep(50_000)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
up?.flags = flags
up?.post(tap: .cghidEventTap)
