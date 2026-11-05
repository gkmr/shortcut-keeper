// mousedo: synthetic mouse for on-screen tests (AX coordinates, top-left origin); the pointer goes back afterwards.
//   mousedo drag x1 y1 x2 y2     press at (x1,y1), move in steps, release at (x2,y2)
//   mousedo click x y [n]        n = 1 (default) or 2 (double-click)
import Foundation
import CoreGraphics
let a = CommandLine.arguments
func post(_ t: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: t, mouseCursorPosition: p, mouseButton: .left)
    e?.flags = []; e?.setIntegerValueField(.mouseEventClickState, value: clicks); e?.post(tap: .cghidEventTap); usleep(40000)
}
let back = CGEvent(source: nil)?.location ?? .zero
if a.count >= 6, a[1] == "drag", let x1 = Double(a[2]), let y1 = Double(a[3]), let x2 = Double(a[4]), let y2 = Double(a[5]) {
    let p1 = CGPoint(x: x1, y: y1), p2 = CGPoint(x: x2, y: y2)
    CGWarpMouseCursorPosition(p1); usleep(80000)
    post(.leftMouseDown, p1)
    for i in 1...12 { let t = Double(i) / 12; post(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)) }
    post(.leftMouseUp, p2)
} else if a.count >= 4, a[1] == "click", let x = Double(a[2]), let y = Double(a[3]) {
    let n = a.count > 4 ? Int64(a[4]) ?? 1 : 1, p = CGPoint(x: x, y: y)
    CGWarpMouseCursorPosition(p); usleep(80000)
    for c in 1...n { post(.leftMouseDown, p, clicks: c); post(.leftMouseUp, p, clicks: c) }
} else { print("usage: mousedo drag x1 y1 x2 y2 | click x y [n]"); exit(2) }
usleep(150000); CGWarpMouseCursorPosition(back)
