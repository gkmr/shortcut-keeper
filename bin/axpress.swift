// axpress <bundle id> <window title> <label> [standard|panel]: presses the first button whose AX description or help is
// <label> in that app's window with that title (standard window or floating panel), straight through Accessibility.
// v109 tests: System Events' "entire contents" of BetterWispr's main window took over 90 s during a recording.
import Cocoa
import ApplicationServices
let a = CommandLine.arguments
guard a.count >= 4, let app = NSRunningApplication.runningApplications(withBundleIdentifier: a[1]).first else { print("usage: axpress <bundle> <title> <label> [standard|panel] (or app not running)"); exit(2) }
let want = a.count > 4 ? a[4] : ""
func val(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
func str(_ e: AXUIElement, _ k: String) -> String { (val(e, k) as? String) ?? "" }
let ax = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(ax, 1.0)
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if d > 12 { return nil }
    if str(e, kAXRoleAttribute) == "AXButton" && (str(e, kAXDescriptionAttribute) == a[3] || str(e, kAXHelpAttribute) == a[3]) { return e }
    for c in (val(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let x = find(c, d + 1) { return x } }
    return nil
}
for w in (val(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where str(w, kAXTitleAttribute) == a[2] {
    let std = str(w, kAXSubroleAttribute) == "AXStandardWindow"
    if want == "standard" && !std || want == "panel" && std { continue }
    if let b = find(w, 0) { let r = AXUIElementPerformAction(b, kAXPressAction as CFString); print(r == .success ? "pressed" : "press failed \(r.rawValue)"); exit(0) }
}
print("not found"); exit(1)
