// axwins <bundle id>: the app's windows as Accessibility sees them (title, subrole, frame). Read only.
import AppKit
import ApplicationServices
let b = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { print("not running"); exit(1) }
let el = AXUIElementCreateApplication(app.processIdentifier)
var v: CFTypeRef?
let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
guard err == .success, let ws = v as? [AXUIElement] else { print("no windows (AX error \(err.rawValue))"); exit(1) }
for w in ws {
    var t: CFTypeRef?; var s: CFTypeRef?; var p: CFTypeRef?; var z: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &s)
    AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p)
    AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &z)
    var pt = CGPoint.zero, sz = CGSize.zero
    if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
    if let z { AXValueGetValue(z as! AXValue, .cgSize, &sz) }
    print("\((t as? String) ?? "<nil>")\t\((s as? String) ?? "")\t\(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height))")
}
