// bwtitle "<title>"  sets the title of BetterWispr's current meeting note: the "Meeting title" field in its floating notes
// panel. Used by director.sh so BetterWispr's note carries the calendar meeting's name (from Krisp, which reads all of the user's
// calendars). bwtitle --read prints the current title. Accessibility only; no keystrokes, no focus change.
import Cocoa
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: bwtitle <title> | --read"); exit(2) }
let want = args[1]
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.betterwispr.app").first else {
    print("BetterWispr not running"); exit(1)
}
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
for w in wins where (attr(w, kAXTitleAttribute) as? String) == "Notetaker" && (attr(w, kAXSubroleAttribute) as? String) != "AXStandardWindow" {
    var queue = [w], seen = 0
    while !queue.isEmpty && seen < 3000 {
        let e = queue.removeFirst(); seen += 1
        if (attr(e, kAXRoleAttribute) as? String) == "AXTextField", (attr(e, kAXDescriptionAttribute) as? String) == "Meeting title" {
            let cur = (attr(e, kAXValueAttribute) as? String) ?? ""
            if want == "--read" { print(cur); exit(0) }
            if cur == want { print("already titled \"\(cur)\""); exit(0) }
            let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, want as CFString)
            AXUIElementPerformAction(e, kAXConfirmAction as CFString)
            usleep(300000)
            let now = (attr(e, kAXValueAttribute) as? String) ?? ""
            print("title \(now == want ? "set" : "NOT set (\(r.rawValue))"): was \"\(cur)\", now \"\(now)\"")
            exit(now == want ? 0 : 1)
        }
        queue += (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
print("no BetterWispr notes panel with a title field")
exit(1)
