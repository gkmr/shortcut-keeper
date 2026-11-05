// click x y: one real left click at (x, y) in screen points, then the pointer goes back where it was.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count == 3, let x = Double(a[1]), let y = Double(a[2]) else { print("usage: click x y"); exit(2) }
let back = CGEvent(source: nil)?.location ?? .zero
let p = CGPoint(x: x, y: y)
for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60000)
}
CGWarpMouseCursorPosition(back)
print("clicked \(Int(x)),\(Int(y))")
