// wins: every on-screen window front to back, as the window server sees it (z-order, layer, alpha, owner, title, frame).
//   wins            windows of the meeting apps (Claude, the call apps, Granola, Wispr, Krisp, BetterWispr, Key Deck, Floaty)
//   wins --all      every on-screen window
//   wins --at x,y   which app a click at that point reaches (needs Accessibility for the caller; "error -25211" = not allowed)
// Layer 0 = normal window; above 0 = floats over normal windows (panels, widgets, overlays). Frames in points, y from the top.
// Read-only, needs no permission for frames (titles need Screen Recording; without it they print empty).
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let args = CommandLine.arguments
// wins --at x,y [x,y ...]: which app gets a click at each point (Accessibility hit test; needs Accessibility for the caller)
if let i = args.firstIndex(of: "--at") {
    do {
        let sys = AXUIElementCreateSystemWide()
        for p in args[(i + 1)...] {
            let xy = p.split(separator: ",").compactMap { Float($0) }
            guard xy.count == 2 else { continue }
            var el: AXUIElement?
            let err = AXUIElementCopyElementAtPosition(sys, xy[0], xy[1], &el)
            var pid: pid_t = 0
            if let el { AXUIElementGetPid(el, &pid) }
            var buf = [CChar](repeating: 0, count: 256)
            let name = pid > 0 && proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "-"
            print("\(p)\t\(err == .success ? name : "error \(err.rawValue)")")
        }
    }
    exit(0)
}
let all = args.contains("--all")
let pat = try! NSRegularExpression(pattern: "krisp|granola|wispr|claude|phone|facetime|slack|comet|zoom|teams|webex|whatsapp|floaty|key deck|rectangle", options: .caseInsensitive)
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var z = 0
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    if layer > 100 && !all { continue }   // menu bar, Dock, system overlays
    z += 1
    if !all && pat.firstMatch(in: owner, range: NSRange(owner.startIndex..., in: owner)) == nil { continue }
    let name = w[kCGWindowName as String] as? String ?? ""
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    var f = "?"
    if let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) {
        f = "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
    }
    print("z\(z)\tL\(layer)\ta\(String(format: "%.2f", alpha))\t\(owner)\t\(name)\t\(f)\tid\(id)")
}
