// Key Deck v2: the user's one-screen, mouse-first shortcut deck, Webcam Mode helper and clipboard-screenshot saver.
// Caps + /   opens the deck. Every runnable tile and row has a one-key badge: press that key (no Enter) or click. Esc closes.
//            Left hand runs the tiles (number row, QWERTY row, home row = the three rows of window tiles; Z to B = meetings).
//            Right hand runs the rows (7 to =, U to ], J to ', N to /).
// Caps + W   Webcam Mode: front window to the top center ninth (under the camera) and pinned on top (Floaty). Again to undo.
//            Pins and unpins by choosing the window in Floaty's menu bar menu (no focus needed); the pin key is a fallback.
// Caps + 1 2 3  jump into Granola's ask box, BetterWispr's notes (Wispr deprecation test; was Wispr's ask box), Claude.
// Caps + 4   BetterWispr's main window forward; again puts it away (it waits behind during calls).
// Clipboard-only screenshots (hold ⌃ with ⌘⇧3 or ⌘⇧4) are written to ~/Pictures/Screenshots as well, so a
//            screenshot mover agent (optional) picks them up like every other screenshot.
// URLs: keydeck://deck, keydeck://webcam?bundle=<id>&title=<text>, keydeck://webcam-off, keydeck://pause?seconds=90, keydeck://report,
//       keydeck://chat?app=granola|betterwispr|wispr|claude (Caps 1, 2, -, 3), keydeck://swap, keydeck://layout?id=<layout id>
// Data: $SHORTCUT_KEEPER_HOME/keys.json (default ~/Projects/shortcut-keeper) (deck blocks drive the tiles, the badges and the Rectangle snap panel) and status.json.
import AppKit
import CoreAudio
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import SwiftUI

// MARK: - Data

struct DeckInfo: Decodable {
    let rect: [Double]?
    let rects: [[Double]]?
    let labels: [String]?
    let apps: [String]?     // v100: the bundle ids per slot, and their window hints (FastLayout)
    let titles: [String]?
    let behind: [Int]?      // indexes into rects of windows that wait behind others: drawn as a dashed outline on top
    let url: String?
    let short: String?
    let order: Int?
    let group: String?      // "windows" or "meetings": drawn as a tile (and mirrored in the Rectangle snap panel)
    let caps: [String]?     // keycaps to draw instead of the combo; "|text|" is plain text between caps
    let caption: String?    // tile caption instead of the keys
    let aspect: Double?     // mini screen width / height: 1.6 laptop, 2.39 ultrawide
    let badge: String?      // SF Symbol on the tile (pin for Webcam Mode)
    let run: Bool?          // false = show only
}

struct KeyEntry: Decodable, Identifiable {
    let id: String
    let section: String
    let keys: String
    let action: String
    let app: String
    let note: String?
    let combo: String?
    let sheet: Bool?
    let pending: String?
    let isNew: String?
    let deck: DeckInfo?
}

struct SectionInfo: Decodable { let id: String; let title: String }
struct KeysFile: Decodable { let sections: [SectionInfo]; let keys: [KeyEntry]; let deck_theme: String? }
struct HealthStatus: Decodable { let summary: String?; let ok: Bool?; let checked_at: String?; let counts: [String: Int]? }

let home = FileManager.default.homeDirectoryForCurrentUser
// SHORTCUT_KEEPER_HOME (set it in the LaunchAgent's EnvironmentVariables) or ~/Projects/shortcut-keeper
let root = ProcessInfo.processInfo.environment["SHORTCUT_KEEPER_HOME"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Projects/shortcut-keeper")

func loadKeys() -> KeysFile {
    do {
        let d = try Data(contentsOf: root.appendingPathComponent("keys.json"))
        return try JSONDecoder().decode(KeysFile.self, from: d)
    } catch {
        log("keys.json could not be read: \(error)")
        return KeysFile(sections: [], keys: [], deck_theme: nil)
    }
}

func loadStatus() -> HealthStatus? {
    guard let d = try? Data(contentsOf: root.appendingPathComponent("status.json")) else { return nil }
    return try? JSONDecoder().decode(HealthStatus.self, from: d)
}

func log(_ s: String) {
    let url = root.appendingPathComponent(".state/keydeck.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - Keys

let keyCodes: [String: CGKeyCode] = [
    "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
    "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "Return": 36, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, ",": 43,
    "/": 44, "N": 45, "M": 46, ".": 47, "Tab": 48, "Space": 49, "`": 50, "Delete": 51, "Esc": 53,
    "Left": 123, "Right": 124, "Down": 125, "Up": 126,
]

let modGlyph: [String: String] = ["fn": "fn", "HYPER": "Caps", "capslock": "Caps", "ctrl": "⌃", "rctrl": "right ⌃", "opt": "⌥",
                                  "ropt": "right ⌥", "shift": "⇧", "rshift": "right ⇧", "cmd": "⌘", "rcmd": "right ⌘"]
let modOrder = ["fn", "HYPER", "capslock", "ctrl", "rctrl", "opt", "ropt", "shift", "rshift", "cmd", "rcmd"]
let keyGlyph: [String: String] = ["Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Return": "↩", "Delete": "⌫", "Tab": "⇥",
                                  "Esc": "esc", "Space": "Space"]

/// Keycaps for an entry, in Apple's modifier order (⌃⌥⇧⌘), drawn from the combo so the label can never drift from the real key.
func capsFor(_ k: KeyEntry) -> [String] {
    if let c = k.deck?.caps { return c }
    guard let combo = k.combo else { return [] }
    let parts = combo.split(separator: "+").map(String.init)
    guard let last = parts.last else { return [] }
    let mods = Set(parts.dropLast())
    var out = modOrder.filter { mods.contains($0) }.compactMap { modGlyph[$0] }
    out.append(keyGlyph[last] ?? modGlyph[last] ?? last.uppercased())
    return out
}

/// "⌃⌥←", "Caps W": the compact form used under tiles.
func compactKeys(_ caps: [String]) -> String {
    var s = ""
    for c in caps {
        if c.hasPrefix("|") { s += " " + c.trimmingCharacters(in: CharacterSet(charactersIn: "|")) + " "; continue }
        let glue = s.isEmpty || s.hasSuffix(" ") || "⌃⌥⇧⌘".contains(s.last!)
        s += (glue ? "" : " ") + c
    }
    return s.trimmingCharacters(in: .whitespaces)
}

/// v95: Windows tiles carry "Group · caption" (Left, Center, Right, Rows, Tilers); the group names the label row above the
/// tiles on the Windows screen (the tiles needed group labels), the caption stays under the tile.
func tileGroup(_ k: KeyEntry) -> String {
    let c = k.deck?.caption ?? ""
    guard let r = c.range(of: " · ") else { return "Calls" }
    return String(c[..<r.lowerBound])
}
func windowGroups(_ ks: [DeckItem]) -> [(String, [DeckItem])] {
    var out: [(String, [DeckItem])] = []
    for k in ks {
        let g = tileGroup(k.k)
        if let i = out.firstIndex(where: { $0.0 == g }) { out[i].1.append(k) } else { out.append((g, [k])) }
    }
    return out
}
func tileCaption(_ k: KeyEntry) -> String {
    if let c = k.deck?.caption { if let r = c.range(of: " · ") { return String(c[r.upperBound...]) }; return c }
    if k.combo != nil || k.deck?.caps != nil { return compactKeys(capsFor(k)) }
    return k.keys
}

func runnable(_ k: KeyEntry) -> Bool {
    if k.deck?.run == false { return false }
    if k.deck?.url != nil { return true }
    guard let c = k.combo, k.app != "Key Deck" else { return false }
    if ["mouse", "ring"].contains(k.section) { return false }
    let parts = c.split(separator: "+").map(String.init)
    if parts.contains(where: { ["fn", "rctrl", "ropt", "rcmd", "rshift", "capslock"].contains($0) }) { return false }
    if k.keys.lowercased().contains("hold") { return false }
    return keyCodes[parts.last ?? ""] != nil
}

func postCombo(_ combo: String) {
    var parts = combo.split(separator: "+").map(String.init)
    guard let key = parts.popLast(), let code = keyCodes[key] else { return }
    var flags: CGEventFlags = []
    if parts.contains("HYPER") { flags.formUnion([.maskControl, .maskAlternate, .maskShift, .maskCommand]) }
    if parts.contains("ctrl") { flags.insert(.maskControl) }
    if parts.contains("opt") { flags.insert(.maskAlternate) }
    if parts.contains("shift") { flags.insert(.maskShift) }
    if parts.contains("cmd") { flags.insert(.maskCommand) }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(30000)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
    if !flags.isEmpty { usleep(20000); releaseModifiers() }
}

// A synthetic key event that carries modifier flags leaves macOS believing those keys are still held until a real
// modifier key goes up. Every later synthetic event then inherits them: on Oct 27 a click became ⌘⌥-click (hid every
// app) and the KrispWatch applet opened with its "Press Run" startup screen (Control held at launch). So after each
// combo, post key-up events for the four modifiers with no flags, which resets the shared modifier state.
func releaseModifiers() {
    let src = CGEventSource(stateID: .hidSystemState)
    for k: CGKeyCode in [0x38, 0x3B, 0x3A, 0x37] {   // shift, control, option, command
        let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)
        e?.flags = []
        e?.post(tap: .cghidEventTap)
        usleep(5000)
    }
}

func openQuietly(_ s: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", s]
    try? p.run()
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

// MARK: - Window helpers (Accessibility)

func axFrame(_ w: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?; var sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
    var p = CGPoint.zero; var s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func axSetFrame(_ w: AXUIElement, _ r: CGRect) {
    var p = r.origin; var s = r.size
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
}

func focusedWindow(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        var w: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, attr as CFString, &w) == .success, let w { return (w as! AXUIElement) }
    }
    return windows(pid: pid).first
}

func windows(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var list: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success, let arr = list as? [AXUIElement] else { return [] }
    return arr
}

func title(_ w: AXUIElement) -> String {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    return (t as? String) ?? ""
}

/// The call box on the screen that holds the window, in AX (top-left origin) coordinates: the "Call" slot of the meeting
/// layout in keys.json (desk layout on a wide screen), so Webcam Mode and the layouts always agree. v15 (no gap
/// between the call window and Krisp): 656,39 880x621 on the laptop, from Claude's edge to Granola's, still
/// under the camera. Falls back to the top center ninth (the old box) when keys.json has no Call slot.
func webcamTarget(for frame: CGRect) -> CGRect {
    let mainH = NSScreen.screens.first?.frame.height ?? 0
    let center = CGPoint(x: frame.midX, y: mainH - frame.midY)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens[0]
    let vf = screen.visibleFrame
    let top = mainH - vf.maxY
    let lid = vf.width / max(vf.height, 1) > 2 ? "layout-transcripts-desk" : "layout-transcripts"
    if let d = loadKeys().keys.first(where: { $0.id == lid })?.deck, let labels = d.labels, let rects = d.rects,
       let i = labels.firstIndex(of: "Call"), i < rects.count, rects[i].count == 4 {
        let r = rects[i]
        return CGRect(x: (vf.minX + r[0] * vf.width).rounded(), y: (top + r[1] * vf.height).rounded(),
                      width: (r[2] * vf.width).rounded(), height: (r[3] * vf.height).rounded())
    }
    let w = vf.width / 3, h = vf.height / 3
    return CGRect(x: vf.minX + w, y: top, width: w, height: h)
}

// MARK: - Floaty's menu bar menu (pin and unpin a named window, whatever has the focus)

func axEl(_ e: AXUIElement, _ a: String) -> AXUIElement? {
    guard let v = axValue(e, a), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func axKids(_ e: AXUIElement) -> [AXUIElement] { (axValue(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

/// Owner (process name, as Floaty's menu shows it: "Comet", "krisp") of the normal window at frame `f`; pid nil = any app but
/// Floaty. Window names are not used: macOS gives them only to apps with Screen Recording permission, which Key Deck lacks.
func cgOwner(pid: pid_t?, frame f: CGRect) -> String? {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.first(where: { w in
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
        return owner != "Floaty" && (pid == nil || (w[kCGWindowOwnerPID as String] as? Int) == Int(pid!)) &&
            (w[kCGWindowLayer as String] as? Int) == 0 &&
            ((w[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                .map { abs($0.minX - f.minX) < 4 && abs($0.minY - f.minY) < 4 && abs($0.width - f.width) < 4 } ?? false)
    })?[kCGWindowOwnerName as String] as? String
}

/// Floaty's menu bar menu lists the open windows as "App \u{2014} window name" (long names cut with "…", the rest under "More…");
/// choosing one pins or unpins that window whatever has the keyboard focus. The Hyper+P toggle acts on the focused window, and
/// Krisp's invisible window holds the focus while Krisp records: Floaty pinned Krisp instead of the call three times
/// on 2026-10-27. An entry fits when it (without "…") starts `want`, "App \u{2014} <AX title>": a browser's AX title adds the
/// tab group to the tab title that Floaty shows. The longest fitting entry is chosen; two equally long = ambiguous (Krisp's two
/// windows are both "krisp \u{2014} Krisp"), nothing chosen. `want` nil = "Unpin/Restore All Windows".
@discardableResult func floatyMenu(choose want: String?) -> Bool {
    guard let fl = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Floaty" }),
          let bar = axEl(AXUIElementCreateApplication(fl.processIdentifier), kAXExtrasMenuBarAttribute),
          let item = axKids(bar).first else { log("floaty menu: no menu bar item"); return false }
    quickPress(item)
    // v106: polled every 20 ms until the menu shows with its entries (was a fixed 250 ms)
    var opened: AXUIElement? = nil
    for _ in 0..<30 { if let m = axKids(item).first, !axKids(m).isEmpty { opened = m; break }; usleep(20000) }
    guard let menu = opened else { log("floaty menu: it did not open"); return false }
    // v108b: Comet adds " - High memory usage - 1.0 GB" to a window's title mid-call, so Floaty's entry and
    // the window's title stopped matching and the call stayed unpinned; that part is left out on both sides
    func norm(_ s: String) -> String {
        s.replacingOccurrences(of: " - High memory usage - [0-9.]+ [KMG]B", with: "", options: .regularExpression)
    }
    // how much of `want` an entry covers (0 = it does not fit)
    func fit(_ t: String) -> Int {
        guard let want else { return t == "Unpin/Restore All Windows" ? 1 : 0 }
        let p = norm(t.hasSuffix("…") ? String(t.dropLast()) : t), w = norm(want)
        guard let r = p.range(of: " \u{2014} "), p.distance(from: r.upperBound, to: p.endIndex) >= 4 else { return 0 }   // needs a window name
        return w.hasPrefix(p) || p.hasPrefix(w) ? p.count : 0
    }
    var items = axKids(menu)
    if want != nil, let more = items.first(where: { axText($0, kAXTitleAttribute) == "More…" }) {
        quickPress(more)
        for _ in 0..<20 { if !axKids(more).flatMap({ axKids($0) }).isEmpty { break }; usleep(20000) }   // v106: was a fixed 200 ms
        items += axKids(more).flatMap { axKids($0) }
    }
    let scored = items.map { ($0, fit(axText($0, kAXTitleAttribute))) }.filter { $0.1 > 0 }
    let best = scored.map { $0.1 }.max() ?? 0
    let hits = scored.filter { $0.1 == best }.map { $0.0 }
    guard hits.count == 1 else {
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        log("floaty menu: \(hits.count) entries match \"\(want ?? "Unpin/Restore All Windows")\", nothing chosen")
        return false
    }
    quickPress(hits[0])
    usleep(60000)   // v106: the callers check the pin themselves (was 300 ms); this only lets the menu close
    return true
}

/// v106: director.sh's pin_wait and unpin_wait read this instead of the window list every 0.25 s
func pinResult(_ s: String, since t0: Date) {
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    try? "\(s) \(ms) ms\n".write(to: root.appendingPathComponent(".state/pin-result"), atomically: true, encoding: .utf8)
    log("pin request: \(s) in \(ms) ms")
}

/// v106c: presses a menu (bar) item without waiting for the app's menu to close: the press blocks until then or until the
/// messaging timeout (BetterWispr 1.5 s, Floaty 0.55 s, measured 2026-10-30), while the menu itself is open in 1 to 24 ms.
func quickPress(_ e: AXUIElement) {
    AXUIElementSetMessagingTimeout(e, 0.08)
    AXUIElementPerformAction(e, kAXPressAction as CFString)
    AXUIElementSetMessagingTimeout(e, 0)   // back to the default for reading it
}

/// Chooses an item by its exact name in a menu bar app's own menu (its menu bar extra), whatever has the focus.
@discardableResult func menuExtraChoose(bundle: String, item name: String) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
          let bar = axEl(AXUIElementCreateApplication(app.processIdentifier), kAXExtrasMenuBarAttribute),
          let extra = axKids(bar).first else { return false }
    quickPress(extra)
    var opened: AXUIElement? = nil   // v106b: polled every 20 ms (was a fixed 400 ms)
    for _ in 0..<40 { if let m = axKids(extra).first, !axKids(m).isEmpty { opened = m; break }; usleep(20000) }
    guard let menu = opened else { return false }
    if let mi = axKids(menu).first(where: { axText($0, kAXTitleAttribute) == name }) {
        quickPress(mi); return true
    }
    AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    return false
}

// MARK: - Webcam Mode (move and pin, nothing else)

/// True when `w` is the focused window of the frontmost app. Floaty's pin key (Hyper+P) toggles whatever window has focus, so
/// Webcam Mode presses it only when this holds (2026-10-27: a Phone call ended, its window closed, and "webcam off" pinned the
/// Slack window that had focus instead).
func isFront(_ w: AXUIElement, pid: pid_t) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &f) == .success,
          let f else { return false }
    return CFEqual(f, w)
}

final class Webcam {
    var window: AXUIElement?
    var pid: pid_t = 0
    var original: CGRect = .zero
    var pinned = false

    /// Brings `w` to the front and gives it focus; true when it took focus. Since macOS 14 a background app's activate() is often refused (2026-10-27: the Meet would not take focus and
    /// stayed unpinned), so the app is also made frontmost through Accessibility, and as a last resort one real click on the
    /// window's selected tab or title bar gives it the focus.
    func bringFront(_ w: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
        usleep(250000)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        usleep(250000)
        if isFront(w, pid: pid) { return true }
        clickTitleBar(w)
        usleep(350000)
        return isFront(w, pid: pid)
    }

    func toggleFront() {
        if !AXIsProcessTrusted() {
            log("webcam: Accessibility not granted, opening System Settings")
            openAccessibilitySettings()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let w = focusedWindow(pid: app.processIdentifier) else { log("webcam: no front window"); return }
        if let cur = window, CFEqual(cur, w) { off(); return }
        if window != nil { off(); usleep(300000); app.activate(); usleep(300000) }
        on(w, pid: app.processIdentifier)
    }

    /// .state/webcam.json keeps the call window in Webcam Mode (pid, title, where it was), so "webcam off" still unpins it and
    /// puts it back after Key Deck restarts mid-call (2026-10-27: after a rebuild the stop found nothing to undo and
    /// the Meet stayed pinned).
    let stateURL = root.appendingPathComponent(".state/webcam.json")

    func saveState(_ w: AXUIElement) {
        let d: [String: Any] = ["pid": Int(pid), "title": title(w), "x": original.minX, "y": original.minY, "w": original.width, "h": original.height]
        if let data = try? JSONSerialization.data(withJSONObject: d) { try? data.write(to: stateURL, options: .atomic) }
        // v93: the call strip over the pinned window (Phone or FaceTime = handset glyph)
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let phone = bid.contains("mobilephone") || bid.contains("FaceTime")
        if let f = axFrame(w) { DispatchQueue.main.async { AppDelegate.shared?.strip.show(over: f, phone: phone) } }
    }

    /// Webcam Mode from before a restart: the same app's window with the saved title, and where it was before.
    func restoreState() -> (AXUIElement, pid_t, CGRect)? {
        guard let data = try? Data(contentsOf: stateURL), let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = d["pid"] as? Int, let t = d["title"] as? String,
              let x = d["x"] as? Double, let y = d["y"] as? Double, let ww = d["w"] as? Double, let hh = d["h"] as? Double,
              NSRunningApplication(processIdentifier: pid_t(p)) != nil else { return nil }
        // the saved title, else (a browser window's title follows its tab and tab group) the app's window that Floaty pins
        let ws = windows(pid: pid_t(p))
        guard let w = ws.first(where: { title($0) == t }) ?? ws.first(where: { axFrame($0).flatMap { floatyPinWindow($0) } != nil })
        else { return nil }
        return (w, pid_t(p), CGRect(x: x, y: y, width: ww, height: hh))
    }

    func on(_ w: AXUIElement, pid: pid_t) {
        let tOn = Date()   // v106b: where the pin's time goes
        guard let f = axFrame(w) else { return }
        original = f; window = w; self.pid = pid; pinned = false
        // the same window already in Webcam Mode before a Key Deck restart: keep where it really was before
        if let s = restoreState(), s.1 == pid, CFEqual(s.0, w) { original = s.2 }
        axSetFrame(w, webcamTarget(for: f))
        usleep(100000)
        // already pinned (Key Deck restarted mid-call, or the Director started twice): pressing the toggle again would unpin it
        if pinOK(w) { pinned = true; saveState(w); log("webcam on pid \(pid) \(title(w)) (already pinned, left as is)"); return }
        // first choice: pin it by name from Floaty's menu, which needs no keyboard focus
        let before0 = floatyPins().compactMap { axFrame($0) }
        let tMenu = Date()
        if let f1 = axFrame(w), let owner = cgOwner(pid: pid, frame: f1), floatyMenu(choose: "\(owner) \u{2014} \(title(w))") {
            let tChosen = Date()
            for _ in 0..<100 { if pinOK(w) { break }; usleep(20000) }   // v106: every 20 ms (was 100 ms)
            if pinOK(w) {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)   // no clicks: a click in a browser's tab strip can switch tabs
                let tPin = Date()
                pinned = true; saveState(w)
                log("webcam on pid \(pid) \(title(w)) (pinned from Floaty's menu: move \(Int(tMenu.timeIntervalSince(tOn) * 1000)) ms, menu \(Int(tChosen.timeIntervalSince(tMenu) * 1000)) ms, Floaty \(Int(tPin.timeIntervalSince(tChosen) * 1000)) ms)")
                return
            }
            let wrong = undoNewPins(before0)
            log("webcam on pid \(pid): Floaty's menu entry for \"\(owner) \u{2014} \(title(w))\" did not pin it\(wrong.isEmpty ? "" : " (pinned \(wrong.joined(separator: ", ")), undone)"); trying the pin key")
        }
        // v108b: no title-bar click and pin key during a call (in a v108 test it clicked the Meet and Floaty pinned BetterWispr's
        // panel and Krisp instead); the Director's recheck tries Floaty's menu again a few seconds later
        if FrontPick.inCall() {
            log("webcam on pid \(pid) \(title(w)): moved under the camera, not pinned yet (no pin key during a call; the Director tries again)")
            return
        }
        guard bringFront(w, pid: pid) else {   // never let Floaty pin another app's window
            log("webcam on pid \(pid) \(title(w)): moved under the camera, not pinned (it would not take focus)")
            return
        }
        let before = floatyPins().compactMap { axFrame($0) }
        clickTitleBar(w)       // a real click takes the keyboard focus from Krisp's invisible window (seen twice on 2026-10-27)
        usleep(350000)
        postCombo("HYPER+P")   // Floaty pin on top
        usleep(700000)
        if pinOK(w) { pinned = true; saveState(w); log("webcam on pid \(pid) \(title(w))"); return }
        // Floaty pinned another window. 2026-10-27: Krisp's invisible window keeps the keyboard focus while Krisp
        // records, so Floaty pinned "Krisp" instead of the Meet. Undo that pin, click the call window's title bar (a real
        // click takes the focus back), and pin again.
        let wrong = undoNewPins(before)
        clickTitleBar(w)
        usleep(350000)
        postCombo("HYPER+P")
        usleep(700000)
        if pinOK(w) {
            pinned = true; saveState(w)
            log("webcam on pid \(pid) \(title(w)) (pinned after a click on its title bar; Floaty had pinned \(wrong.isEmpty ? "nothing" : wrong.joined(separator: ", ")))")
            return
        }
        let wrong2 = undoNewPins(before)
        log("webcam on pid \(pid) \(title(w)): moved under the camera, NOT pinned (Floaty pinned \((wrong + wrong2).joined(separator: ", ")) instead, undone)")
    }

    func pinOK(_ w: AXUIElement) -> Bool { axFrame(w).flatMap { floatyPinWindow($0) } != nil }

    /// v99: the pill's Call chip. The pinned call window forward (raise only: activating a browser brings all its windows over
    /// the layout); pinned again in place when Floaty dropped the pin. It never unpins (the strip's Call button unpinned a
    /// live call on 2026-10-30): Option-click the chip or Caps W does.
    func raiseOrRepin() {
        guard let w = window else { toggleFront(); return }
        if pinOK(w) { AXUIElementPerformAction(w, kAXRaiseAction as CFString); log("webcam: call window raised (pill)"); return }
        let keep = original
        log("webcam: \(title(w)) lost its Floaty pin; pinning it again (pill)")
        on(w, pid: pid); original = keep
        if pinned { saveState(w) }
    }

    /// Floaty's pin windows (one per pinned window).
    func floatyPins() -> [AXUIElement] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Floaty" }) else { return [] }
        return windows(pid: app.processIdentifier)
    }

    /// Unpins every pin that was not there before (by pressing its X); returns their titles (the pinned windows' titles).
    @discardableResult func undoNewPins(_ before: [CGRect]) -> [String] {
        var names: [String] = []
        for pw in floatyPins() {
            guard let r = axFrame(pw) else { continue }
            if before.contains(where: { abs($0.minX - r.minX) < 4 && abs($0.minY - r.minY) < 4 && abs($0.width - r.width) < 4 }) { continue }
            names.append("\"\(title(pw))\"")
            if pressFloatyX(pw) { continue }
            // Floaty shows its X only on hover: choose the pinned window in Floaty's menu (no keyboard focus involved; the
            // toggle key pinned Krisp's invisible window again on 2026-10-27)
            // Floaty titles its pin like the pinned window, plus " 🔊" while it plays sound
            let pinName = title(pw).replacingOccurrences(of: " 🔊", with: "")
            if let owner = cgOwner(pid: nil, frame: r), floatyMenu(choose: "\(owner) \u{2014} \(pinName)") { continue }
        }
        if !names.isEmpty { usleep(400000) }
        // still there and ambiguous in the menu (Krisp has two windows both called "Krisp"): when every pin now showing is a
        // new one, "Unpin/Restore All Windows" undoes exactly them
        let left = floatyPins().compactMap { axFrame($0) }.filter { r in
            !before.contains(where: { abs($0.minX - r.minX) < 4 && abs($0.minY - r.minY) < 4 && abs($0.width - r.width) < 4 }) }
        if !left.isEmpty && left.count == floatyPins().count { floatyMenu(choose: nil); usleep(400000) }
        return names
    }

    /// One real click that gives the window the focus without changing anything in it: on its selected tab in a browser
    /// (so a window with several tabs never switches tab), else on the empty title bar. The pointer goes back afterwards.
    func clickTitleBar(_ w: AXUIElement) {
        guard let f = axFrame(w) else { return }
        var c = CGPoint(x: f.minX + min(175, f.width / 3), y: f.minY + 12)
        var queue: [AXUIElement] = [w], seen = 0, found = false, sawTabs = false
        search: while !queue.isEmpty && seen < 4000 {
            let e = queue.removeFirst(); seen += 1
            let role = axText(e, kAXRoleAttribute)
            if role == "AXRadioButton" || role == "AXTab", let r = axFrame(e), r.minY < f.minY + 70, r.width > 20 {
                sawTabs = true
                if ((axValue(e, kAXValueAttribute) as? NSNumber)?.intValue ?? 0) == 1 { c = CGPoint(x: r.midX, y: r.midY); found = true; break search }
            }
            if role == "AXTabGroup" { sawTabs = true }
            if let kids = axValue(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        // a window with tabs whose selected tab was not found: no blind click (2026-10-27: a click at the fixed spot
        // landed on Comet's pinned Gmail tab, the Meet went to the background and popped out as picture in picture)
        var wpid: pid_t = 0; AXUIElementGetPid(w, &wpid)
        let browser = ["ai.perplexity.comet", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                       "com.microsoft.edgemac", "com.brave.Browser"].contains(NSRunningApplication(processIdentifier: wpid)?.bundleIdentifier ?? "")
        if !found && (sawTabs || browser) { log("click: no selected tab found in \"\(title(w))\", no click"); return }
        let back = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            // no modifier flags: a click that inherited ⌘⌥ from the Hyper+P combo just before it meant "hide others" and
            // hid every other app (2026-10-27)
            let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: c, mouseButton: .left)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
            usleep(50000)
        }
        CGWarpMouseCursorPosition(back)
    }

    /// Floaty draws each pin as its own window with exactly the pinned window's frame, holding two buttons: X (unpin, the
    /// left one) and its menu (2026-10-27: Slack and TextEdit tests).
    func floatyPinWindow(_ f: CGRect) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Floaty" }) else { return nil }
        return windows(pid: app.processIdentifier).first { pw in
            guard let r = axFrame(pw) else { return false }
            return abs(r.minX - f.minX) < 4 && abs(r.minY - f.minY) < 4 && abs(r.width - f.width) < 4 && abs(r.height - f.height) < 4
        }
    }

    /// Presses the X on Floaty's pin window: unpins exactly that window, whatever has focus. Floaty's Hyper+P toggle did not
    /// unpin a window pinned seconds earlier in the 2026-10-27 tests, and with the call window gone it pinned Slack instead.
    func pressFloatyX(_ pw: AXUIElement) -> Bool {
        var queue: [AXUIElement] = [pw], buttons: [AXUIElement] = [], seen = 0
        while !queue.isEmpty && seen < 200 {
            let e = queue.removeFirst(); seen += 1
            if axText(e, kAXRoleAttribute) == "AXButton" { buttons.append(e) }
            if let kids = axValue(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        guard let x = buttons.min(by: { (axFrame($0)?.minX ?? 0) < (axFrame($1)?.minX ?? 0) }) else { return false }
        return AXUIElementPerformAction(x, kAXPressAction as CFString) == .success
    }

    func off() {
        if window == nil, let s = restoreState() {   // Key Deck restarted during the call
            window = s.0; pid = s.1; original = s.2; pinned = true
            log("webcam off: picked up the call window from before Key Deck restarted")
        }
        guard let w = window else { try? FileManager.default.removeItem(at: stateURL); return }
        window = nil
        AppDelegate.shared?.strip.hide()
        defer { pinned = false; try? FileManager.default.removeItem(at: stateURL) }
        guard axFrame(w) != nil else {   // the call window closed with the call: Floaty's pin went with it
            log("webcam off pid \(pid): the call window is closed, nothing to unpin")
            return
        }
        // only a pin Floaty really shows on this window is undone; a window the user already unpinned is left alone
        if let f = axFrame(w), let pw = floatyPinWindow(f) {
            let stillPinned = { () -> Bool in axFrame(w).flatMap({ self.floatyPinWindow($0) }) != nil }
            let wait = { for _ in 0..<6 { usleep(300000); if !stillPinned() { break } } }   // up to 1.8 s
            var how = "Floaty's menu"
            // v101: Floaty's menu first: Floaty shows its X only on hover, so pressing the X first cost a 1.8 s wait on every call.
            // No toggle key here: with Krisp recording it pinned Krisp's invisible window instead (2026-10-27)
            if let owner = cgOwner(pid: pid, frame: f), floatyMenu(choose: "\(owner) \u{2014} \(title(w))") { wait() }
            if stillPinned() { how = "its X"; if pressFloatyX(pw) { wait() } }
            if stillPinned() && floatyPins().count == 1 { how = "Unpin/Restore All Windows (it was the only pin)"; floatyMenu(choose: nil); wait() }
            log(stillPinned() ? "webcam off pid \(pid): Floaty still shows the pin (its X on the window unpins)" : "webcam off pid \(pid): unpinned with \(how)")
        } else if pinned {
            log("webcam off pid \(pid): Floaty shows no pin on the call window, nothing pressed")
        }
        axSetFrame(w, original)
        log("webcam off pid \(pid)")
    }

    /// Used by the Meeting Director: put a specific app's call window in Webcam Mode.
    /// strict = only the window whose title contains `titleContains` (browsers, Slack, WhatsApp, Teams): never fall back to
    /// whatever window is in front (that pinned a non-call Comet window on 2026-10-21). Not strict = the app's own window
    /// (Phone and FaceTime only: their window is the call; director.sh checks call audio first).
    func onApp(bundle: String, titleContains: String?, strict: Bool) {
        if !AXIsProcessTrusted() { log("webcam: Accessibility not granted"); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { log("webcam: \(bundle) not running"); return }
        var target: AXUIElement? = nil
        if let t = titleContains, !t.isEmpty {
            target = windows(pid: app.processIdentifier).first(where: { title($0).localizedCaseInsensitiveContains(t) })
        }
        if target == nil && !strict { target = focusedWindow(pid: app.processIdentifier) }
        guard let w = target else { log("webcam: no call window \"\(titleContains ?? "")\" in \(bundle): nothing pinned"); return }
        if let cur = window, CFEqual(cur, w) {
            if pinOK(w) { return }
            // v91 (2026-10-29, first live call on layout v17): Floaty dropped the pin mid-call, Key Deck still had the
            // window as its Webcam Mode window and skipped the Director's three re-pins, so the Meet ended unpinned. Now the pin
            // itself is checked: pinned again in place, keeping the window's spot from before the call for the put-back.
            let keep = original
            log("webcam: \(title(w)) lost its Floaty pin; pinning it again")
            on(w, pid: app.processIdentifier)
            original = keep
            if pinned { saveState(w) }
            return
        }
        if window != nil { off() }
        // v106: no activate first (it cost 250 ms of waits): Floaty's menu pins by name without the focus, the pin-key
        // fallback in on() brings the window front itself, and activating a browser pulled all its windows over the layout
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        on(w, pid: app.processIdentifier)
    }
}

// MARK: - Clipboard screenshots also land in the screenshot folder

func fnv(_ d: Data) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for b in p { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    }
    return h
}

/// macOS puts a clipboard-only screenshot (⌃⌘⇧3 / ⌃⌘⇧4) on the pasteboard and writes no file. This notices it and writes
/// the PNG into ~/Pictures/Screenshots, where a screenshot mover agent (optional) treats it like any other.
/// It never reads the pasteboard's data unless the change looks like a screenshot, and it writes nowhere else.
final class ClipSaver {
    private var lastCount = NSPasteboard.general.changeCount
    private var lastSeen = Date.distantPast
    private var pids = [pid_t](repeating: 0, count: 8192)
    private var nameBuf = [CChar](repeating: 0, count: 256)
    private var saved: [UInt64] = []
    private var timer: Timer?
    let shots = home.appendingPathComponent("Pictures/Screenshots")
    let hashFile = root.appendingPathComponent(".state/clip-hashes")
    let watcherMark = root.appendingPathComponent(".state/last-clip")
    let signature: Set<String> = ["public.png", "Apple PNG pasteboard type", "public.tiff", "NeXT TIFF v4.0 pasteboard type"]

    func start() {
        saved = ((try? String(contentsOf: hashFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { UInt64($0) }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("clipboard screenshot saver on")
    }

    private func captureRunning() -> Bool {
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard n > 0 else { return false }
        for i in 0..<min(n, pids.count) where pids[i] > 0 {
            if proc_name(pids[i], &nameBuf, UInt32(nameBuf.count)) > 0 {
                let s = nameBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if s == "screencapture" { return true }
            }
        }
        return false
    }

    private func watcherJustCopied() -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: watcherMark.path), let m = a[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(m) < 5
    }

    private func tick() {
        if captureRunning() { lastSeen = Date() }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = Set((pb.types ?? []).map { $0.rawValue })
        guard types.contains("public.png") || types.contains("public.tiff") else { return }
        let looksLikeShot = types == signature
        let afterCapture = Date().timeIntervalSince(lastSeen) < 4
        guard looksLikeShot || afterCapture else { return }
        if watcherJustCopied() { return }          // the screenshot mover agent (optional) put a saved file on the clipboard
        guard let png = pngData(pb) else { log("clip: screenshot on the clipboard but it could not be read"); return }
        let h = fnv(png)
        if saved.contains(h) { return }
        save(png, hash: h)
    }

    private func pngData(_ pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        if let t = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: t) { return rep.representation(using: .png, properties: [:]) }
        return nil
    }

    private func save(_ png: Data, hash h: UInt64) {
        let fm = FileManager.default
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        let now = Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss"
        let a = DateFormatter(); a.locale = Locale(identifier: "en_US_POSIX"); a.dateFormat = "a"
        let stem = "Screenshot \(f.string(from: now))\u{202F}\(a.string(from: now))"
        var name = stem + ".png"
        var n = 2
        while fm.fileExists(atPath: shots.appendingPathComponent(name).path) { name = "\(stem) \(n).png"; n += 1 }
        let tmp = shots.appendingPathComponent(".keydeck-clip-\(ProcessInfo.processInfo.globallyUniqueString)")
        do {
            try png.write(to: tmp)
            try fm.moveItem(at: tmp, to: shots.appendingPathComponent(name))
            saved.append(h)
            if saved.count > 300 { saved.removeFirst(saved.count - 300) }
            try? saved.map { String($0) }.joined(separator: "\n").write(to: hashFile, atomically: true, encoding: .utf8)
            log("clip: saved a clipboard screenshot as \(name) (\(png.count / 1024) KB)")
        } catch {
            log("clip: could not save (\(error.localizedDescription))")
            try? fm.removeItem(at: tmp)
        }
    }
}

// MARK: - Caps Lock indicator

/// With Raycast's Hyper Key, a quick tap of Caps Lock is a real Caps Lock (Quick Press: Trigger). This shows an amber
/// "Caps Lock on" pill at the top of the screen (with a short Tink) while it is on, so capitals never surprise the user. Polls the modifier state
/// (no permission needed), 5 times a second.
final class CapsIndicator {
    private var panel: NSPanel?
    private var on = false
    private var timer: Timer?

    func start() {
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("caps lock indicator on")
    }

    private func tick() {
        let now = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        guard now != on else { return }
        on = now
        now ? show() : hide()
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 168, height: 34)
        let vf = screen.visibleFrame
        let frame = NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.maxY - size.height - 10).rounded(), width: size.width, height: size.height)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView:
                HStack(spacing: 7) {
                    Image(systemName: "capslock.fill").font(.system(size: 13, weight: .semibold))
                    Text("Caps Lock on").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .frame(width: size.width, height: size.height)
                .background(Capsule().fill(Color.orange))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)))
            panel = p
        }
        guard let p = panel else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()   // short cue when capitals turn on
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; p.animator().alphaValue = 1 }
    }

    private func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

// MARK: - Meeting chats: Caps 1, 2, 3 jump into the ask boxes

/// During calls the user queries Granola and Wispr (their own LLM chats over their transcripts) and Claude (Krisp
/// over MCP). Caps 1 / 2 / 3 bring that app's window forward and put the cursor in its ask box, ready to type.
/// Granola and Wispr show "Ask anything"; Claude's message box is the editable field nearest the bottom of its window.
/// No app documents a shortcut for this, so it uses Accessibility (Electron apps build their tree on request:
/// AXManualAccessibility). They work any time, not only on calls. Log lines start with "chat:".
struct ChatTarget { let name: String; let bundle: String; let window: String?; let hints: [String] }
let chatTargets: [String: ChatTarget] = [
    "granola": ChatTarget(name: "Granola", bundle: "com.granola.app", window: nil, hints: ["ask anything", "ask granola"]),
    "wispr": ChatTarget(name: "Wispr", bundle: "com.electron.wispr-flow", window: "Meeting Recorder", hints: ["ask anything", "ask wispr"]),
    // Caps 2 since 2026-10-27 (Wispr deprecation test): BetterWispr's notes ("My thoughts") in its floating notes panel,
    // else its dashboard. BetterWispr has no LLM ask box; keydeck://chat?app=wispr still reaches Wispr.
    "betterwispr": ChatTarget(name: "BetterWispr", bundle: "org.betterwispr.app", window: "Notetaker", hints: ["my thoughts"]),
    "claude": ChatTarget(name: "Claude", bundle: "com.anthropic.claudefordesktop", window: nil, hints: ["reply to claude", "how can i help", "write your prompt", "talk to claude"]),
]

func axValue(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axText(_ e: AXUIElement, _ a: String) -> String { (axValue(e, a) as? String) ?? "" }

final class ChatJump {
    func go(_ key: String) {
        guard let t = chatTargets[key] else { log("chat: unknown target \(key)"); return }
        guard AXIsProcessTrusted() else { log("chat: Accessibility not granted"); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundle).first else {
            reopen(t); log("chat: \(t.name) was not running, opened it"); return
        }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.focusBox(t, app.processIdentifier, attempt: 1) }
    }

    private func reopen(_ t: ChatTarget) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The window with the ask box: the named one (Wispr's Meeting Recorder), else the app's largest standard window.
    private func window(_ t: ChatTarget, _ pid: pid_t) -> AXUIElement? {
        let all = windows(pid: pid)
        if t.name == "BetterWispr" {   // its floating notes panel while it takes notes, else its dashboard window
            let named = all.filter { title($0) == "Notetaker" }
            return named.first(where: { axText($0, kAXSubroleAttribute) != "AXStandardWindow" }) ?? named.first
        }
        if let h = t.window, let w = all.first(where: { title($0).localizedCaseInsensitiveContains(h) }) { return w }
        let std = all.filter { axText($0, kAXSubroleAttribute) == "AXStandardWindow" }
        // no dialog fallback: Wispr with only its "Status" panel open gets reopened instead, which brings back its main window
        return std.max(by: { (axFrame($0)?.width ?? 0) * (axFrame($0)?.height ?? 0) < (axFrame($1)?.width ?? 0) * (axFrame($1)?.height ?? 0) })
    }

    /// Editable fields (with any label they carry) and "markers": any element whose text says a hint, such as Granola's
    /// "Ask anything" placeholder drawn as static text on top of an unlabeled text area.
    private func scan(_ win: AXUIElement, _ hints: [String]) -> (fields: [(el: AXUIElement, label: String, frame: CGRect)], markers: [CGRect]) {
        var fields: [(el: AXUIElement, label: String, frame: CGRect)] = []
        var markers: [CGRect] = []
        var queue: [AXUIElement] = [win]
        var seen = 0
        while !queue.isEmpty && seen < 8000 {
            let e = queue.removeFirst(); seen += 1
            let role = axText(e, kAXRoleAttribute)
            let label = [axText(e, "AXPlaceholderValue"), axText(e, kAXDescriptionAttribute), axText(e, kAXTitleAttribute),
                         axText(e, kAXHelpAttribute)].filter { !$0.isEmpty }.joined(separator: " | ")
            if role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" {
                if let f = axFrame(e), f.width > 40, f.height > 8 { fields.append((e, label, f)) }
            } else {
                let text = (label + " " + axText(e, kAXValueAttribute)).lowercased()
                if hints.contains(where: { text.contains($0) }), let f = axFrame(e), f.width > 0 { markers.append(f) }
            }
            if let kids = axValue(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return (fields, markers)
    }

    private func focusBox(_ t: ChatTarget, _ pid: pid_t, attempt: Int) {
        guard let win = window(t, pid) else {
            if attempt == 1 {
                // BetterWispr runs from the menu bar: its dashboard opens from its menu ("Open Dashboard")
                if t.name == "BetterWispr" { _ = menuExtraChoose(bundle: t.bundle, item: "Open Dashboard") } else { reopen(t) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.focusBox(t, pid, attempt: 2) }; return
            }
            log("chat: \(t.name) has no window"); return
        }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        if t.name == "BetterWispr" {   // its notes editor ("My thoughts", an AXTextArea) shows only under the "My thoughts" tab button
            var queue: [AXUIElement] = [win], seen = 0
            while !queue.isEmpty && seen < 4000 {
                let e = queue.removeFirst(); seen += 1
                let role = axText(e, kAXRoleAttribute)
                if role == "AXButton" || role == "AXRadioButton",
                   axText(e, kAXTitleAttribute) == "My thoughts" || axText(e, kAXDescriptionAttribute) == "My thoughts" {
                    AXUIElementPerformAction(e, kAXPressAction as CFString); usleep(350000); break
                }
                if let kids = axValue(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
            }
        }
        let (fs, marks) = scan(win, t.hints)
        var pick: (el: AXUIElement?, label: String, frame: CGRect)? = nil
        if let f = t.hints.lazy.compactMap({ h in fs.first(where: { $0.label.lowercased().contains(h) }) }).first {
            pick = (el: f.el, label: f.label, frame: f.frame)
        } else if t.name == "BetterWispr" {   // fallback: the largest editable field that is not the meeting title or a search box
            let notes = fs.filter { !$0.label.lowercased().contains("title") && !$0.label.lowercased().contains("search") && $0.frame.height > 40 }
            if let f = notes.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                pick = (el: f.el, label: "notes editor", frame: f.frame)
            }
        } else if let m = marks.first {   // the field under or nearest the "Ask anything" text; no field = click the text itself
            let c = CGPoint(x: m.midX, y: m.midY)
            if let n = fs.min(by: { dist($0.frame, c) < dist($1.frame, c) }), dist(n.frame, c) < 80 {
                pick = (el: n.el, label: "near the ask text", frame: n.frame)
            } else {
                pick = (el: nil, label: "ask text", frame: m)
            }
        } else if t.name == "Claude" {   // Claude's box: the widest editable field lowest in the window
            if let f = fs.filter({ $0.frame.width > 250 }).max(by: { $0.frame.maxY < $1.frame.maxY }) { pick = (el: f.el, label: "bottom field", frame: f.frame) }
        }
        guard let p = pick else {
            if attempt < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.focusBox(t, pid, attempt: attempt + 1) }; return }
            log("chat: \(t.name) window \"\(title(win))\" forward, no ask box found (\(fs.count) fields)")
            return
        }
        if let el = p.el { AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let focused = p.el.flatMap { axValue($0, kAXFocusedAttribute) as? Bool } ?? false
            if !focused {   // web views often need a real click to place the cursor; the pointer goes back afterwards
                let back = CGEvent(source: nil)?.location ?? .zero
                let c = CGPoint(x: p.frame.minX + min(24, p.frame.width / 2), y: p.frame.midY)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {   // no modifier flags (Caps keys are ⌘⌥⌃⇧: ⌘⌥-click hides other apps)
                    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: c, mouseButton: .left)
                    e?.flags = []
                    e?.post(tap: .cghidEventTap)
                }
                CGWarpMouseCursorPosition(back)
            }
            log("chat: \(t.name) ask box \(focused ? "focused" : "clicked") (\(p.label.isEmpty ? "unlabeled field" : p.label))")
        }
    }

    private func dist(_ r: CGRect, _ c: CGPoint) -> CGFloat {
        let dx = max(r.minX - c.x, 0, c.x - r.maxX), dy = max(r.minY - c.y, 0, c.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Krisp next to your work (Caps + 5, and hover)

/// Krisp should be usable in parallel, with an easy window switch and hover. Krisp keeps its
/// slot (bottom row, layout v17) and a big browser window often covers most of it. Two ways in; nothing is moved or resized:
///   Caps + 5 (keydeck://krisp): Krisp's main window to the front; pressed again while Krisp is in front, back to the app you
///     were in. Log "krisp:".
///   Hover: rest the pointer for half a second on a visible part of Krisp's window and Krisp comes forward. Only where Krisp
///     is the window you actually see under the pointer (never through another window, a pinned call or a floating panel),
///     never while a mouse button is down, at most once a second. keydeck://hover?on=0 turns it off (.state/hover-off), on=1 on.
final class KrispPeek {
    let bundle = "ai.krisp.krispMac"
    var prev: NSRunningApplication?
    var monitor: Any?
    var pending: DispatchWorkItem?
    var lastRaise = Date.distantPast
    let offURL = root.appendingPathComponent(".state/hover-off")

    func mainWindow(_ app: NSRunningApplication) -> AXUIElement? {
        let area = { (w: AXUIElement) -> CGFloat in let f = axFrame(w) ?? .zero; return f.width * f.height }
        let std = windows(pid: app.processIdentifier).filter {
            axText($0, kAXSubroleAttribute) == "AXStandardWindow" && !title($0).contains("Widget") && !title($0).contains("Notification")
        }
        return std.max(by: { area($0) < area($1) })
    }

    func toggle() {
        guard AXIsProcessTrusted() else { log("krisp: Accessibility not granted"); return }
        guard let k = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { log("krisp: Krisp is not running"); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == k.processIdentifier, let p = prev, !p.isTerminated {
            front(p); log("krisp: back to \(p.localizedName ?? "the previous app") (Caps 5)"); return
        }
        raise(k, why: "Caps 5")
    }

    func raise(_ app: NSRunningApplication, why: String) {
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != app.processIdentifier { prev = f }
        guard let w = mainWindow(app) else { log("krisp: Krisp has no main window"); return }
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        front(app)
        lastRaise = Date()
        log("krisp: Krisp to the front (\(why))")
    }

    /// macOS ignores activate() from a background app (Key Deck is one), so set the app's AXFrontmost too
    func front(_ app: NSRunningApplication) {
        // an Apple Event "activate" is what works on macOS 27 (activate() and AXFrontmost are ignored for a background caller)
        if let id = app.bundleIdentifier {
            var err: NSDictionary?
            NSAppleScript(source: "tell application id \"\(id)\" to activate")?.executeAndReturnError(&err)
            if let e = err { log("krisp: activate \(id) failed: \(e)") } else { return }
        }
        app.activate()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    func startHover() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.moved() }
        log("krisp: hover to raise \(FileManager.default.fileExists(atPath: offURL.path) ? "off" : "on")")
    }

    func setHover(_ on: Bool) {
        if on { try? FileManager.default.removeItem(at: offURL) } else { FileManager.default.createFile(atPath: offURL.path, contents: Data()) }
        log("krisp: hover to raise \(on ? "on" : "off")")
    }

    func moved() {
        pending?.cancel()
        let at = NSEvent.mouseLocation
        let item = DispatchWorkItem { [weak self] in self?.check(at) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    func check(_ at: NSPoint) {
        let now = NSEvent.mouseLocation
        guard abs(now.x - at.x) < 6, abs(now.y - at.y) < 6, NSEvent.pressedMouseButtons == 0 else { return }
        guard !FileManager.default.fileExists(atPath: offURL.path), Date().timeIntervalSince(lastRaise) > 1.0 else { return }
        guard !FrontPick.inCall() else { return }   // v107: during calls Krisp comes forward only when the user picks it
        guard let k = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != k.processIdentifier else { return }
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: now.x, y: mainH - now.y)
        // v90 (2026-10-29): ask Accessibility which app a click at this point would reach (what bin/wins --at does). The window
        // list cannot tell: the Dock and Notification Center keep full-screen see-through windows above everything, and
        // ChatGPT a 1138x2549 overlay at layer 3. A menu, a pinned call or a floating panel under the pointer answers with
        // its own app, so Krisp stays put there.
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.5)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let hit = el else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid == k.processIdentifier else { return }
        if let kw = mainWindow(k), let f = axFrame(kw), f.contains(p) { raise(k, why: "hover") }
    }
}

// MARK: - BetterWispr window (Caps + 4)

/// During calls BetterWispr's main window (its full notes and history, 760 pt minimum) waits behind its notes panel and
/// Wispr, so no visible window overlaps another. Caps + 4 brings it forward; pressed again while it
/// is in front, it puts it away (minimized; the next call's layout or Caps + 4 brings it back). keydeck://swap. Log "swap:".
final class TranscriptSwap {
    func go() {
        guard AXIsProcessTrusted() else { log("swap: Accessibility not granted"); return }
        guard let bw = NSRunningApplication.runningApplications(withBundleIdentifier: "org.betterwispr.app").first else {
            log("swap: BetterWispr is not running"); return
        }
        let area = { (w: AXUIElement) -> CGFloat in let f = axFrame(w) ?? .zero; return f.width * f.height }
        let std = windows(pid: bw.processIdentifier).filter { axText($0, kAXSubroleAttribute) == "AXStandardWindow" }
        guard let win = std.max(by: { area($0) < area($1) }) else { log("swap: BetterWispr has no main window"); return }
        let minimized = (axValue(win, kAXMinimizedAttribute) as? Bool) ?? false
        // in front = its window is the frontmost normal window over its own frame (nothing but floating panels above it)
        var inFront = false
        if !minimized, let f = axFrame(win) {
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
                guard let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                      r.intersects(f.insetBy(dx: 4, dy: 4)), r.width > 60, r.height > 60 else { continue }
                inFront = (w[kCGWindowOwnerPID as String] as? Int) == Int(bw.processIdentifier)
                break
            }
        }
        if inFront {
            // v109: Granola back on top (BetterWispr's notes wait behind it in the same slot); minimized only without Granola
            if let g = NSRunningApplication.runningApplications(withBundleIdentifier: "com.granola.app").first,
               let gw = windows(pid: g.processIdentifier).filter({ axText($0, kAXSubroleAttribute) == "AXStandardWindow" }).max(by: { area($0) < area($1) }) {
                AXUIElementPerformAction(gw, kAXRaiseAction as CFString); g.activate(); Guard.bwPicked = false
                log("swap: Granola back on top (BetterWispr's notes wait behind it)")
            } else {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                log("swap: BetterWispr's main window put away (minimized)")
            }
        } else {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            bw.activate(); Guard.bwPicked = true
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            log("swap: BetterWispr's main window to the front")
        }
    }
}

// MARK: - Secure input notice

/// Raycast's Hyper key (Caps Lock held) goes dead while any app holds macOS secure input: a password field, 1Password,
/// Terminal's Secure Keyboard Entry, an app that forgot to release it. Karabiner-Elements gets around this with a driver;
/// This setup uses Raycast instead (2026-10-21 comparison), so Key Deck says when it happens instead of failing silently:
/// after 15 s of secure input held by an app that is NOT in front (typing a password in the front app is normal), a grey
/// pill names the app. Read only: it never changes secure input. Log lines "secure input held by ..." in keydeck.log.
final class SecureInputWatch {
    private var panel: NSPanel?
    private var since: Date?
    private var shown: pid_t = 0
    private var timer: Timer?

    func start() {
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("secure input watch on")
    }

    /// PID of the app holding secure input, -1 when it is on but the holder is unknown, 0 when off.
    static func holder() -> pid_t {
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any], let n = d["kCGSSessionSecureInputPID"] as? NSNumber, n.int32Value > 0 {
            return n.int32Value
        }
        return IsSecureEventInputEnabled() ? -1 : 0
    }

    static func name(_ pid: pid_t) -> String {
        if pid <= 0 { return "an app" }
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }

    private func tick() {
        let pid = Self.holder()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let who = pid == 0 ? "" : Self.name(pid)
        if pid == 0 || pid == front || who == "loginwindow" {
            since = nil
            if shown != 0 { hide(); log("secure input released"); shown = 0 }
            return
        }
        if since == nil { since = Date() }
        guard let s = since, Date().timeIntervalSince(s) >= 15, shown != pid else { return }
        shown = pid
        log("secure input held by \(who) (pid \(pid)) for 15 s: Caps keys paused")
        show(who)
    }

    private func show(_ who: String) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 430, height: 34)
        let vf = screen.visibleFrame
        let frame = NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.maxY - size.height - 54).rounded(), width: size.width, height: size.height)
        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            return p
        }()
        panel = p
        p.contentView = NSHostingView(rootView:
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
                Text("Caps keys paused: \(who) holds secure input").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(width: size.width, height: size.height)
            .background(Capsule().fill(Color(white: 0.28)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)))
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; p.animator().alphaValue = 1 }
    }

    private func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

// MARK: - Deck model: tiles, rows and one-key badges

struct DeckItem: Identifiable { let k: KeyEntry; let hint: String?; var id: String { k.id } }

struct SectionSpec { let id: String; let title: String; let symbol: String; let tint: Color; let trailing: String? }

let col2: [SectionSpec] = [
    SectionSpec(id: "lookup", title: "Look up", symbol: "magnifyingglass", tint: .teal, trailing: nil),
    SectionSpec(id: "launch", title: "Launch, paste, AI", symbol: "sparkles", tint: .indigo, trailing: nil),
    SectionSpec(id: "screenshots", title: "Screenshots", symbol: "camera.viewfinder", tint: .orange, trailing: "Every one: saved and on the clipboard"),
    SectionSpec(id: "keyboard", title: "Keyboard", symbol: "keyboard", tint: .gray, trailing: nil),
]
let col3: [SectionSpec] = [
    SectionSpec(id: "dictation", title: "Dictation and notes", symbol: "waveform", tint: .pink, trailing: nil),
    SectionSpec(id: "windows", title: "More window moves", symbol: "macwindow", tint: .blue, trailing: nil),
    SectionSpec(id: "other", title: "Other apps", symbol: "square.grid.2x2", tint: .gray, trailing: nil),
]

// Left hand: the three keyboard rows mirror the three rows of window tiles; the bottom row runs the meeting tiles.
let tileHints = ["1", "2", "3", "4", "5", "6", "Q", "W", "E", "R", "T", "Y", "A", "S", "D", "F", "G", "H"]
let meetingHints = ["Z", "X", "C", "V", "B"]
// Right hand: rows, top to bottom, middle column then right column.
let rowHints = ["7", "8", "9", "0", "-", "=", "U", "I", "O", "P", "[", "]", "J", "K", "L", ";", "'", "N", "M", ",", ".", "/"]

final class DeckModel {
    let windows: [DeckItem]
    let meetings: [DeckItem]
    let rows: [String: [DeckItem]]
    let byHint: [String: KeyEntry]
    let gestures: [KeyEntry]
    let ring: [KeyEntry]

    init(_ data: KeysFile) {
        var bh: [String: KeyEntry] = [:]
        func tiles(_ g: String) -> [KeyEntry] {
            data.keys.filter { $0.deck?.group == g }.sorted { ($0.deck?.order ?? 999) < ($1.deck?.order ?? 999) }
        }
        func assign(_ ks: [KeyEntry], _ hints: [String]) -> [DeckItem] {
            var out: [DeckItem] = []
            for (i, k) in ks.enumerated() {
                let h: String? = i < hints.count ? hints[i] : nil
                if let h { bh[h] = k }
                out.append(DeckItem(k: k, hint: h))
            }
            return out
        }
        windows = assign(tiles("windows"), tileHints)
        meetings = assign(tiles("meetings"), meetingHints)
        var left = rowHints
        var r: [String: [DeckItem]] = [:]
        for spec in col2 + col3 {
            let ks = data.keys.filter { $0.section == spec.id && $0.sheet != false && $0.deck?.group == nil }
            var items: [DeckItem] = []
            for k in ks {
                var h: String? = nil
                if runnable(k), !left.isEmpty { h = left.removeFirst(); bh[h!] = k }
                items.append(DeckItem(k: k, hint: h))
            }
            r[spec.id] = items
        }
        rows = r
        byHint = bh
        gestures = data.keys.filter { $0.section == "mouse" }
        ring = data.keys.filter { $0.section == "ring" }
    }

    func hint(for k: KeyEntry) -> String? { byHint.first(where: { $0.value.id == k.id })?.key }

    /// .state/deck-hints.json: {"hints": {entry id: badge key}} so Raycast's keys search shows the same badges.
    func writeHints() {
        var h: [String: String] = [:]
        for (key, k) in byHint { h[k.id] = key }
        let obj: [String: Any] = ["generated": ISO8601DateFormatter().string(from: Date()), "hints": h]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: root.appendingPathComponent(".state/deck-hints.json"), options: .atomic)
        }
    }
}

final class DeckState: ObservableObject {
    @Published var pressed: String? = nil
    @Published var shown = false
}

// MARK: - Views

final class HoverModel: ObservableObject { @Published var on = false }

/// The press-me badge. Accent tint so it reads as "action", never confused with the grey shortcut keycaps.
struct HintBadge: View {
    let text: String?
    let hot: Bool
    var body: some View {
        Text(text ?? "")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(hot ? Color.white : Color.accentColor)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hot ? Color.accentColor : Color.accentColor.opacity(0.15)))
            .opacity(text == nil ? 0 : 1)
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
}

struct KeyCapsView: View {
    let caps: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, c in
                if c.count >= 2 && c.hasPrefix("|") && c.hasSuffix("|") {
                    Text(String(c.dropFirst().dropLast())).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 1)
                } else {
                    KeyCap(text: c)
                }
            }
        }
    }
}

/// State layers (Material 3): hover +8%, pressed +12%, 150 ms, accent outline on focus.
struct DeckPress: ButtonStyle {
    let hover: Bool
    let forced: Bool
    let radius: CGFloat
    let base: Double
    let outline: Bool
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || forced
        let fill = base + (hover ? 0.08 : 0) + (down ? 0.12 : 0)
        let edge = (hover || down) ? Color.accentColor.opacity(0.6) : Color.primary.opacity(outline ? 0.08 : 0)
        return configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(edge, lineWidth: 1))
            .scaleEffect(down && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            .animation(.easeOut(duration: 0.1), value: down)
    }
}

let appPalette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo]

struct MiniScreen: View {
    let rects: [[Double]]
    let labels: [String]
    var behind: [Int] = []
    let badge: String?
    let notch: Bool
    let hot: Bool
    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            let bar = max(3, H * 0.08)
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.05)
                Color.primary.opacity(0.09).frame(height: bar)
                if notch {
                    Capsule().fill(Color.primary.opacity(0.35)).frame(width: W * 0.12, height: bar * 0.6).offset(x: W * 0.44, y: 0)
                }
                ForEach(Array(rects.enumerated()).filter { !behind.contains($0.offset) }, id: \.offset) { i, r in
                    let x = W * r[0], y = bar + (H - bar) * r[1], w = W * r[2], h = (H - bar) * r[3]
                    let tint = labels.isEmpty ? Color.accentColor : appPalette[i % appPalette.count]
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(tint.opacity(hot ? 0.95 : 0.78))
                        .overlay(
                            Text(i < labels.count && w >= 28 ? labels[i] : "")
                                .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 2))
                        .frame(width: max(3, w - 2), height: max(3, h - 2))
                        .offset(x: x + 1, y: y + 1)
                }
                // a window that waits behind others (BetterWispr behind Krisp on the laptop): dashed outline, Caps 4 swaps
                ForEach(Array(rects.enumerated()).filter { behind.contains($0.offset) }, id: \.offset) { _, r in
                    let x = W * r[0], y = bar + (H - bar) * r[1], w = W * r[2], h = (H - bar) * r[3]
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                        .frame(width: max(3, w - 4), height: max(3, h - 4))
                        .offset(x: x + 2, y: y + 2)
                }
                if let b = badge, let r = rects.first {
                    Image(systemName: b).font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(Color.primary.opacity(0.75)))
                        .offset(x: W * (r[0] + r[2]) - 13, y: bar + (H - bar) * r[1] + 2)
                }
            }
            .frame(width: W, height: H, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        }
    }
}

struct TileView: View {
    let item: DeckItem
    let width: CGFloat
    let height: CGFloat
    let mini: CGSize
    let run: (KeyEntry) -> Void
    @ObservedObject var state: DeckState
    @ObservedObject var hv = HoverModel()
    var body: some View {
        let k = item.k
        let rects = k.deck?.rects ?? (k.deck?.rect.map { [$0] } ?? [])
        let aspect = CGFloat(k.deck?.aspect ?? 1.6)
        let mw = min(mini.width, mini.height * aspect)
        let forced = item.hint != nil && state.pressed == item.hint
        Button(action: { run(k) }) {
            VStack(spacing: 6) {
                MiniScreen(rects: rects, labels: k.deck?.labels ?? [], behind: k.deck?.behind ?? [], badge: k.deck?.badge, notch: aspect < 2, hot: hv.on || forced)
                    .frame(width: mw, height: mw / aspect)
                    .frame(width: mini.width, height: mini.height)
                HStack(spacing: 5) {
                    HintBadge(text: item.hint, hot: hv.on || forced)
                    Text(k.deck?.short ?? k.action)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(tileCaption(k))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(8)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeckPress(hover: hv.on, forced: forced, radius: 10, base: 0.035, outline: true))
        .onHover { hv.on = $0 }
        .help(k.action + (item.hint.map { "   Press \($0)" } ?? ""))
    }
}

struct RowView: View {
    let item: DeckItem
    let run: (KeyEntry) -> Void
    @ObservedObject var state: DeckState
    @ObservedObject var hv = HoverModel()
    var body: some View {
        let k = item.k
        let can = runnable(k)
        let forced = item.hint != nil && state.pressed == item.hint
        let showCaps = k.deck?.caps != nil || k.combo != nil
        let line = HStack(spacing: 8) {
            HintBadge(text: can ? item.hint : nil, hot: can && (hv.on || forced))
            Text(k.deck?.short ?? k.action)
                .font(.system(size: 13)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
            if k.isNew != nil {
                Text("New").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
            if k.pending != nil {
                Text("To set").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.orange.opacity(0.14)))
            }
            Spacer(minLength: 8)
            if showCaps { KeyCapsView(caps: capsFor(k)) }
            else { Text(k.keys).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .contentShape(Rectangle())
        Group {
            if can {
                Button(action: { run(k) }) { line }
                    .buttonStyle(DeckPress(hover: hv.on, forced: forced, radius: 6, base: 0, outline: false))
                    .onHover { hv.on = $0 }
            } else {
                line
            }
        }
        .help(k.action + (k.note.map { ". " + $0 } ?? ""))
    }
}

/// v96 (the gestures needed instructions on the Caps / screen too):
/// two or three plain lines under a section header.
struct HowTo: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { l in
                Text(l).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 664, alignment: .leading)
        .padding(.bottom, 2)
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String
    let tint: Color
    let trailing: String?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let t = trailing { Text(t).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .frame(height: 16)
    }
}

struct RowsBlock: View {
    let spec: SectionSpec
    let items: [DeckItem]
    let run: (KeyEntry) -> Void
    @ObservedObject var state: DeckState
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: spec.title, symbol: spec.symbol, tint: spec.tint, trailing: spec.trailing)
                .padding(.horizontal, 6).padding(.bottom, 4)
            ForEach(items) { RowView(item: $0, run: run, state: state) }
        }
    }
}

struct MouseBlock: View {
    let gestures: [KeyEntry]
    let ring: [KeyEntry]
    func label(_ k: KeyEntry?) -> String { k.map { $0.deck?.short ?? $0.action } ?? "" }
    func g(_ dir: String) -> KeyEntry? { gestures.first { $0.keys.lowercased().hasSuffix(dir) } }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold the gesture button and move").font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    HStack(spacing: 6) { blank; card("arrow.up", label(g("up"))); blank }
                    HStack(spacing: 6) {
                        card("arrow.left", label(g("left")))
                        card("smallcircle.filled.circle", label(g("click")), center: true)
                        card("arrow.right", label(g("right")))
                    }
                    HStack(spacing: 6) { blank; card("arrow.down", label(g("down"))); blank }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Click it for the Actions Ring").font(.system(size: 11)).foregroundStyle(.secondary)
                ZStack {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).frame(width: 108, height: 108)
                    Image(systemName: "computermouse").font(.system(size: 18)).foregroundStyle(.tertiary)
                    ForEach(Array(ring.enumerated()), id: \.offset) { i, k in
                        let order = ["top", "top right", "right", "bottom right", "bottom", "bottom left", "left", "top left"]
                        let idx = Double(order.firstIndex(of: k.keys.lowercased()) ?? i)
                        let a = (idx * 45.0 - 90.0) * Double.pi / 180
                        Text(label(k)).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                            .offset(x: cos(a) * 116, y: sin(a) * 66)
                    }
                }
                .frame(width: 320, height: 160)
            }
        }
    }
    var blank: some View { Color.clear.frame(width: 88, height: 40) }
    func card(_ sym: String, _ text: String, center: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: sym).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 88, height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(center ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct StatusPill: View {
    let status: HealthStatus?
    let open: () -> Void
    @ObservedObject var hv = HoverModel()
    var level: Int {
        guard let s = status else { return 1 }
        let c = s.counts ?? [:]
        if s.ok == false || (c["high"] ?? 0) + (c["medium"] ?? 0) > 0 { return 2 }
        if (c["todo"] ?? 0) + (c["low"] ?? 0) > 0 { return 1 }
        return 0
    }
    var tint: Color { [Color.green, Color.orange, Color.red][level] }
    var checked: String {
        guard let t = status?.checked_at else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let d = f.date(from: String(t.prefix(19))) else { return "" }
        let o = DateFormatter(); o.locale = Locale(identifier: "en_US_POSIX")
        o.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "MMM d, h:mm a"
        return "checked " + o.string(from: d)
    }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(status?.summary ?? "No health check yet").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                Text(checked).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(tint.opacity(hv.on ? 0.22 : 0.13)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hv.on = $0 }
        .help("Open the latest Shortcut Keeper report")
    }
}

struct FooterHint: View {
    let caps: [String]
    let text: String
    var badge = false
    var body: some View {
        HStack(spacing: 6) {
            if badge { HintBadge(text: caps.first, hot: false) } else { KeyCapsView(caps: caps) }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct Hairline: View { var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) } }

struct DeckView: View {
    let model: DeckModel
    let status: HealthStatus?
    let run: (KeyEntry) -> Void
    let openReport: () -> Void
    @ObservedObject var state: DeckState
    var fixedHeight: Bool = true
    static let designWidth: CGFloat = 1680
    static let minHeight: CGFloat = 960
    /// The deck's height follows its content (new rows once pushed the footer below 960 pt).
    /// measure() sets it before each show and each render.
    static var height: CGFloat = 960

    @MainActor static func measure(_ model: DeckModel, _ status: HealthStatus?) -> CGFloat {
        let probe = NSHostingView(rootView: DeckView(model: model, status: status, run: { _ in }, openReport: {}, state: DeckState(), fixedHeight: false))
        height = max(minHeight, (probe.fittingSize.height + 8).rounded(.up))
        return height
    }
    static let pad: CGFloat = 24
    static let col1: CGFloat = 664
    static let gap: CGFloat = 32
    static var colW: CGFloat { (designWidth - 2 * pad - col1 - 2 * gap) / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Hairline()
            HStack(alignment: .top, spacing: DeckView.gap) {
                column1.frame(width: DeckView.col1, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(col2, id: \.id) { RowsBlock(spec: $0, items: model.rows[$0.id] ?? [], run: run, state: state) }
                }
                .frame(width: DeckView.colW, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(col3, id: \.id) { RowsBlock(spec: $0, items: model.rows[$0.id] ?? [], run: run, state: state) }
                }
                .frame(width: DeckView.colW, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            Hairline()
            footer
        }
        .padding(DeckView.pad)
        .frame(width: DeckView.designWidth, height: fixedHeight ? DeckView.height : nil, alignment: .topLeading)
        .scaleEffect(state.shown || reduceMotion ? 1 : 0.985)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { state.shown = true } }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("My Keys").font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                Text("Press a badge key or click.   Caps = hold Caps Lock (⌃⌥⇧⌘).   Microsoft keyboard: Win = ⌥, Alt = ⌘.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(status: status, open: openReport)
        }
    }

    var column1: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Windows", symbol: "rectangle.split.3x1", tint: .blue, trailing: "Same tiles, same order in the snap panel")
                ForEach(windowGroups(model.windows), id: \.0) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.0.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                            ForEach(g.1) {
                                TileView(item: $0, width: 104, height: 104, mini: CGSize(width: 76, height: 48), run: run, state: state)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Meetings", symbol: "video", tint: .green, trailing: "Automatic on calls: it finds and moves the apps")
                HowTo(lines: [
                    "Automatic: a call app on the mic plus a call window = this layout, the call pinned under the camera, BetterWispr and Wispr started. Hang up and everything goes back in about 10 s.",
                    "By hand: click a tile. Caps W pins or unpins the front window. While a call is pinned, a small pill sits on the seam under it: red dot = recording, orange ring = moved (a click puts it back). Drag it anywhere; Call never unpins (Option-click or Caps W does).",
                    "Wispr peeks out on the right between Krisp and BetterWispr's corner panel: click it for Wispr, click Krisp to put it back. Start a notetaker yourself and the layout follows too."])
                HStack(spacing: 8) {
                    ForEach(model.meetings) {
                        TileView(item: $0, width: 126, height: 116, mini: CGSize(width: 100, height: 60), run: run, state: state)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Mouse", symbol: "computermouse", tint: .purple, trailing: "MX Master gesture button")
                HowTo(lines: [
                    "Gestures: press and hold the thumb rest (the wide button under your thumb), move the mouse a little, let go. Up = webcam spot, left = left ⅔, right = right ⅓, down = this screen.",
                    "Actions Ring: click the thumb rest (no move), the ring appears under the pointer; move to a slice and release. Jerky gestures? Use the ring, it needs no movement before the click."])
                MouseBlock(gestures: model.gestures, ring: model.ring)
            }
        }
    }

    var footer: some View {
        HStack(spacing: 20) {
            FooterHint(caps: ["3"], text: "Press a badge key to run it, no Enter", badge: true)
            FooterHint(caps: ["esc"], text: "Close")
            FooterHint(caps: ["Caps", "/"], text: "Open or close")
            FooterHint(caps: ["⌘", "Space"], text: "Raycast: keys opens this screen, search keys finds one")
            Spacer()
            Text("Drag a window: the snap panel shows the same Windows tiles")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(height: 22)
    }
}

struct VisualBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ScaledDeck: View {
    let deck: DeckView
    let scale: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        deck.scaleEffect(scale, anchor: .topLeading)
            .frame(width: DeckView.designWidth * scale, height: DeckView.height * scale, alignment: .topLeading)
            .background(ZStack { VisualBackground(); Color(nsColor: .windowBackgroundColor).opacity(0.55) }.clipShape(shape))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }
}

final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScrimPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ScrimView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - App


// MARK: - Call strip (v93): one click per window while a call is on

/// One click per meeting window, labelled by what it acts on. A thin bar of six buttons
/// over the top edge of the pinned call window (its title bar, dead space during a call): Call (unpins and puts the window
/// back; pins the front window when nothing is pinned; video or handset glyph), Claude, Granola, BW (BetterWispr's notes;
/// option-click its main window), Krisp (forward, again back), Wispr. Each does what the matching Caps key does. A
/// non-activating panel at status-bar level: it never takes keyboard focus. Shown when Webcam Mode pins, hidden when it unpins.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }      // a borderless panel cannot become key by default: its buttons never got the click (v97)
    override var canBecomeMain: Bool { false }
}

/// The layout slot for a label (Claude, Granola, Krisp, Wispr, BetterWispr notes) on the main screen, in AX coordinates;
/// the desk layout on a screen wider than 2:1 (same rule as webcamTarget).
func slotFrame(_ label: String) -> CGRect? {
    guard let screen = NSScreen.screens.first else { return nil }
    let vf = screen.visibleFrame; let mainH = screen.frame.height; let top = mainH - vf.maxY
    let lid = vf.width / max(vf.height, 1) > 2 ? "layout-transcripts-desk" : "layout-transcripts"
    guard let d = loadKeys().keys.first(where: { $0.id == lid })?.deck, let labels = d.labels, let rects = d.rects,
          let i = labels.firstIndex(of: label), i < rects.count, rects[i].count == 4 else { return nil }
    let r = rects[i]
    return CGRect(x: (vf.minX + r[0] * vf.width).rounded(), y: (top + r[1] * vf.height).rounded(), width: (r[2] * vf.width).rounded(), height: (r[3] * vf.height).rounded())
}

// MARK: - Wispr's notetaker, stopped natively (v103)

/// Three calls on 2026-10-30: bin/wisprnote.js (JXA through System Events) timed out after 15 to 25 s every
/// time, because System Events queues behind Krisp's long Accessibility reads, and Wispr kept recording into the next call.
/// This walks the Meeting Recorder straight through Accessibility from Key Deck (milliseconds), presses "Stop listening",
/// then closes the recorder (the note stays in Wispr). keydeck://wispr?do=stop|close|state; the result goes to
/// .state/wispr-result for director.sh, which falls back to bin/wisprnote.js when Key Deck does not answer within 4 s.
enum WisprNote {
    static let queue = DispatchQueue(label: "keydeck.wispr", qos: .userInitiated)
    static func recorder() -> (AXUIElement, AXUIElement?)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow").first else { return nil }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let w = windows(pid: app.processIdentifier).first(where: { title($0) == "Meeting Recorder" }) else { return nil }
        var q: [AXUIElement] = [w], seen = 0
        while !q.isEmpty && seen < 8000 {
            let e = q.removeFirst(); seen += 1
            if axText(e, kAXRoleAttribute) == "AXButton" && axText(e, kAXDescriptionAttribute) == "Stop listening" { return (w, e) }
            if let k = axValue(e, kAXChildrenAttribute) as? [AXUIElement] { q.append(contentsOf: k) }
        }
        return (w, nil)
    }
    static func close(_ w: AXUIElement) -> Bool {
        guard let c = axValue(w, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(c as! AXUIElement, kAXPressAction as CFString) == .success
    }
    static func run(_ act: String) {
        queue.async {
            let t0 = Date(); var r = "none"
            if let (w, stop) = recorder() {
                switch act {
                case "state": r = stop != nil ? "recording" : "idle"
                case "close": r = stop != nil ? "recording" : (close(w) ? "closed" : "idle")
                default:
                    if let s = stop { AXUIElementPerformAction(s, kAXPressAction as CFString); r = "stopped"; usleep(800000) } else { r = "idle" }
                    if close(w) { r += "+closed" }
                }
            }
            try? r.write(to: root.appendingPathComponent(".state/wispr-result"), atomically: true, encoding: .utf8)
            log("wispr: \(act) -> \(r) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }
}

// MARK: - Live snapshot (v105): who is on the mic and the call apps' window titles, kept current by Core Audio events

/// Goal: as close to zero latency as possible. Measured during a Slack huddle: bin/micusers took 1.5 to
/// 3 s a run (73 audio process objects, 6 to 9 ms a query to a busy coreaudiod) and director.sh's System Events title read 1.2 s,
/// and the watcher paid for both on every check. Key Deck now keeps the mic list itself: one scan at launch, then Core Audio
/// tells it when a process appears or starts or stops audio (listeners on the process list and on every process object), so most
/// changes reach .state/live-snap.txt as soon as Core Audio reports them. The processes on the mic are re-read every 0.5 s (a call
/// that ends shows within 0.5 s) and every process every 4 s (a third of today's Core Audio queries, for anything an event
/// missed, such as an app that was already playing sound and then opens the mic). The call apps' window titles are read every
/// 0.5 s (about 80 ms; each app is
/// capped at 0.25 s so a hung app cannot stall it). File: "<epoch s>", then "MIC|pid|bundle|name|in|out" lines like bin/micusers,
/// then "SCREEN|w|h" per display, then "Process|window title" lines like director.sh's snap(). director.sh and watch.sh use it while it is under 2 s old and
/// fall back to their own reads otherwise (no file is written while Core Audio's process list cannot be read).
enum LiveSnap {
    struct Proc { let pid: pid_t; let bundle: String; let name: String; var inp: UInt32; var out: UInt32 }
    static let queue = DispatchQueue(label: "keydeck.livesnap", qos: .userInitiated)
    static var timer: DispatchSourceTimer?
    static var procs: [AudioObjectID: Proc] = [:]   // every audio process object, with its running flags (touched on `queue` only)
    static var watched = Set<AudioObjectID>()
    static var known = false                         // the process list was readable on the last scan
    static var titleLines: [String] = []
    static var screenLines: [String] = []
    static var ticks = 0
    static var events = 0
    static let sys = AudioObjectID(kAudioObjectSystemObject)
    static let callApps: Set<String> = ["zoom.us", "Comet", "Google Chrome", "Safari", "Arc", "MSTeams", "Microsoft Teams", "Webex",
                                        "Slack", "WhatsApp", "FaceTime", "Phone"]
    static let url = root.appendingPathComponent(".state/live-snap.txt")
    static func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
        var a = addr(s); var v: UInt32 = 0; var n = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr ? v : 0
    }
    static func ids() -> [AudioObjectID]? {
        var a = addr(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return nil }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &list) == noErr else { return nil }
        return list
    }
    /// bin/micusers' fields for one process object
    static func info(_ id: AudioObjectID) -> Proc {
        var pa = addr(kAudioProcessPropertyPID); var pid: pid_t = 0; var pn = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &pa, 0, nil, &pn, &pid)
        var ba = addr(kAudioProcessPropertyBundleID); var ref: Unmanaged<CFString>? = nil; var bn = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bundle = ""
        if AudioObjectGetPropertyData(id, &ba, 0, nil, &bn, &ref) == noErr, let r = ref { bundle = r.takeRetainedValue() as String }
        var buf = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "?"
        return Proc(pid: pid, bundle: bundle, name: name, inp: u32(id, kAudioProcessPropertyIsRunningInput),
                    out: u32(id, kAudioProcessPropertyIsRunningOutput))
    }
    /// Core Audio calls back (on `queue`) when this process starts or stops recording or playing
    static func watch(_ id: AudioObjectID) {
        guard !watched.contains(id) else { return }
        watched.insert(id)
        // measured: IsRunning ('pir?') events arrive, IsRunningInput/Output events did not; all three are listened to
        for sel in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
            var a = addr(sel)
            AudioObjectAddPropertyListenerBlock(id, &a, queue) { _, _ in
                guard procs[id] != nil else { return }
                events += 1
                procs[id]?.inp = u32(id, kAudioProcessPropertyIsRunningInput)
                procs[id]?.out = u32(id, kAudioProcessPropertyIsRunningOutput)
                write()
            }
        }
    }
    /// new processes get a listener and their fields, gone ones are dropped; full = also re-read every process's flags
    static func scan(full: Bool) {
        guard let list = ids() else { known = false; return }
        known = true
        let now = Set(list)
        for id in Array(procs.keys) where !now.contains(id) { procs[id] = nil }
        for id in list {
            if var p = procs[id] {
                if full { p.inp = u32(id, kAudioProcessPropertyIsRunningInput); p.out = u32(id, kAudioProcessPropertyIsRunningOutput); procs[id] = p }
            } else { watch(id); procs[id] = info(id) }   // listener first: a change during the read is not lost
        }
        write()
    }
    /// director.sh snap(), in process: "Process|window title" for every window of a running call app (process = executable name)
    static func titles() -> [String] {
        var out: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let n = app.executableURL?.lastPathComponent, callApps.contains(n) else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(ax, 0.25)
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &list) == .success, let ws = list as? [AXUIElement] else { continue }
            for w in ws { out.append("\(n)|\(title(w))") }
        }
        return out
    }
    /// director.sh place(), in process: "SCREEN|w|h" per active display in points (system_profiler took 1.4 s)
    static func screens() -> [String] {
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetActiveDisplayList(n, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map { let b = CGDisplayBounds($0); return "SCREEN|\(Int(b.width))|\(Int(b.height))" }
    }
    static func write() {
        guard known else { return }   // mic list unknown: no update, the scripts fall back to their own reads
        let mics = procs.values.filter { $0.inp != 0 }.sorted { $0.pid < $1.pid }
            .map { "MIC|\($0.pid)|\($0.bundle)|\($0.name)|\($0.inp)|\($0.out)\n" }.joined()
        let s = "\(Int(Date().timeIntervalSince1970))\n" + mics + screenLines.map { $0 + "\n" }.joined() + titleLines.map { $0 + "\n" }.joined()
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
    static func start() {
        queue.async {
            let t0 = Date()
            var a = addr(kAudioHardwarePropertyProcessObjectList)
            let ok = AudioObjectAddPropertyListenerBlock(sys, &a, queue) { _, _ in events += 1; scan(full: false) } == noErr
            titleLines = titles(); screenLines = screens()
            scan(full: true)
            log("live snapshot on (v105): \(procs.count) audio processes watched, process list events \(ok ? "on" : "off (rescans only)"), "
                + "first scan \(Int(Date().timeIntervalSince(t0) * 1000)) ms; mic users re-read every 0.5 s, everyone every 4 s, call window titles every 0.5 s")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(50))
            t.setEventHandler {
                ticks += 1
                titleLines = titles(); screenLines = screens()
                if ticks % 8 == 0 { scan(full: true); return }   // every 4 s every process: a missed event cannot last
                for (id, p) in procs where p.inp != 0 {          // every 0.5 s the ones on the mic: a call that ends shows at once
                    procs[id]?.inp = u32(id, kAudioProcessPropertyIsRunningInput); procs[id]?.out = u32(id, kAudioProcessPropertyIsRunningOutput)
                }
                write()
            }
            t.resume(); timer = t
        }
    }
}

// MARK: - v107 (2026-10-30, every step end to end in one action): Caps T, the ring's sixths, your pick

/// A small note by the pointer for 1.6 s (what Caps T copied, where a ring slice put a window). Never takes the focus.
enum Toast {
    static var panel: NSPanel?
    static func show(_ text: String) {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .white
            label.sizeToFit()
            let size = NSSize(width: label.frame.width + 24, height: label.frame.height + 14)
            let m = NSEvent.mouseLocation
            let p = NSPanel(contentRect: NSRect(x: m.x + 16, y: m.y - size.height - 16, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true; p.hasShadow = true
            let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            v.material = .hudWindow; v.state = .active; v.wantsLayer = true; v.layer?.cornerRadius = 8; v.layer?.masksToBounds = true
            label.frame.origin = NSPoint(x: 12, y: (size.height - label.frame.height) / 2)
            v.addSubview(label); p.contentView = v
            p.orderFrontRegardless(); panel = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if panel === p { p.orderOut(nil); panel = nil } }
        }
    }
}

/// Caps T: the live call's transcript on the clipboard, ready for ⌘V in Claude. From the notetaker in front if one is, else
/// Wispr Flow, else the freshest. Measured 2026-10-30: Krisp, Wispr Flow and BetterWispr write their live
/// transcripts to files during the call (read in about 1 ms); Wispr's and BetterWispr's tell Me from Them, Krisp's live file
/// has no speakers (its transcript.md gets "Speaker 1, 2" after the call). Granola encrypts its own copy, so with Granola in
/// front its window's Copy transcript button is pressed instead. Log "transcript:".
enum Transcript {
    struct Line { let t: Date; let who: String; let text: String }
    struct Source { let app: String; let bundle: String; let title: String; let lines: [Line]; let fresh: Date }
    static let fm = FileManager.default
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let tf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"; return f }()

    static func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? 0 }

    /// the newest file in a folder (`inner` maps each subfolder to its file; nil = the folder's own files)
    static func newestFile(_ rel: String, _ inner: ((URL) -> URL)?) -> URL? {
        guard let subs = try? fm.contentsOfDirectory(at: home.appendingPathComponent(rel), includingPropertiesForKeys: nil) else { return nil }
        let files = (inner.map { f in subs.map(f) } ?? subs.filter { $0.pathExtension == "json" }).filter { fm.fileExists(atPath: $0.path) }
        return files.max { mtime($0) < mtime($1) }
    }

    static func wispr() -> Source? {
        let dir = home.appendingPathComponent("Library/Application Support/Wispr Flow/meetings")
        guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let files = subs.map { $0.appendingPathComponent("live.ndjson") }.filter { fm.fileExists(atPath: $0.path) }
        guard let f = files.max(by: { mtime($0) < mtime($1) }), let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        var lines: [Line] = []
        for l in s.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
                  let text = o["text"] as? String, !text.isEmpty, let sp = o["speaker"] as? [String: Any] else { continue }
            let name = (sp["name"] as? String) ?? ""
            lines.append(Line(t: Date(timeIntervalSince1970: num(o["startEpochMs"]) / 1000),
                              who: !name.isEmpty ? name : ((sp["source"] as? String) == "mic" ? "Me" : "Them"), text: text))
        }
        return Source(app: "Wispr Flow", bundle: "com.electron.wispr-flow", title: "", lines: lines.sorted { $0.t < $1.t }, fresh: mtime(f))
    }

    static func betterwispr() -> Source? {
        let dir = home.appendingPathComponent("Library/Application Support/BetterWispr/Meetings")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { mtime($0) > mtime($1) }).prefix(4) {
            guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let m = j["meeting"] as? [String: Any], let segs = m["segments"] as? [[String: Any]], !segs.isEmpty else { continue }
            let created = Date(timeIntervalSinceReferenceDate: num(m["createdAt"]))
            let lines = segs.compactMap { s -> Line? in
                guard let t = s["text"] as? String, !t.isEmpty else { return nil }
                return Line(t: created.addingTimeInterval(num(s["start"])), who: (s["speaker"] as? String) == "me" ? "Me" : "Them", text: t)
            }
            return Source(app: "BetterWispr", bundle: "org.betterwispr.app", title: (m["title"] as? String) ?? "", lines: lines, fresh: mtime(f))
        }
        return nil
    }

    static func krisp() -> Source? {
        let dir = home.appendingPathComponent("Meetings/Krisp/Krisp Meetings")
        guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var best: (URL, Date)? = nil
        for s in subs { for n in ["live_transcript.md", "transcript.md"] {
            let f = s.appendingPathComponent(n)
            if fm.fileExists(atPath: f.path) { let m = mtime(f); if best == nil || m > best!.1 { best = (f, m) } }
        } }
        guard let bb = best else { return nil }
        let f0 = bb.0, fresh = bb.1
        let folder = f0.deletingLastPathComponent()
        let fin = folder.appendingPathComponent("transcript.md")
        let file = fm.fileExists(atPath: fin.path) ? fin : f0   // after the call: the final file, with speakers
        guard let txt = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let name = folder.lastPathComponent   // "Comet meeting - October 30, 2026 5-07-12 PM"
        var title = name, start = fresh
        if let r = name.range(of: " - ", options: .backwards) {
            title = String(name[..<r.lowerBound])
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "MMMM d, yyyy h-mm-ss a"
            if let d = df.date(from: String(name[r.upperBound...])) { start = d }
        }
        let re = try! NSRegularExpression(pattern: "^\\*\\*(?:(.+?) \\| )?(\\d{1,2}):(\\d{2}):(\\d{2})\\*\\*$")
        var lines: [Line] = [], cur: (Date, String)? = nil, buf: [String] = []
        func flush() { if let c = cur, !buf.isEmpty { lines.append(Line(t: c.0, who: c.1, text: buf.joined(separator: " "))) }; buf = [] }
        for raw in txt.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) {
                flush()
                func g(_ i: Int) -> String { Range(m.range(at: i), in: l).map { String(l[$0]) } ?? "" }
                let secs = (Double(g(2)) ?? 0) * 3600 + (Double(g(3)) ?? 0) * 60 + (Double(g(4)) ?? 0)
                cur = (start.addingTimeInterval(secs), g(1))
            } else if cur != nil, !l.isEmpty { buf.append(l) }
        }
        flush()
        return Source(app: "Krisp", bundle: "ai.krisp.krispMac", title: title, lines: lines, fresh: fresh)
    }

    /// Granola keeps its transcript encrypted on disk: press its window's Copy transcript button and take the clipboard
    static func granola() -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.granola.app").first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var seen = 0
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            seen += 1
            if d > 45 || seen > 6000 { return nil }
            var role: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXButton" {
                for a in ["AXTitle", "AXDescription", "AXHelp"] {
                    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v)
                    if let s = v as? String, s.lowercased().contains("copy transcript") { return e }
                }
            }
            var kids: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
            for c in (kids as? [AXUIElement]) ?? [] { if let f = find(c, d + 1) { return f } }
            return nil
        }
        for w in windows(pid: app.processIdentifier) {
            guard let b = find(w, 0) else { continue }
            let pb = NSPasteboard.general, n0 = pb.changeCount
            quickPress(b)
            for _ in 0..<40 { if pb.changeCount != n0 { return pb.string(forType: .string) }; usleep(20000) }
            return nil
        }
        return nil
    }

    static func render(_ s: Source, title: String) -> String {
        var out: [String] = [], cur: Line? = nil
        func put(_ l: Line) { out.append("\(tf.string(from: l.t)) \(l.who.isEmpty ? "" : l.who + ": ")\(l.text)") }
        for l in s.lines {
            if let c = cur, !c.who.isEmpty, c.who == l.who { cur = Line(t: c.t, who: c.who, text: c.text + " " + l.text) }
            else { if let c = cur { put(c) }; cur = l }
        }
        if let c = cur { put(c) }
        let tz = TimeZone.current.abbreviation() ?? ""
        let span = s.lines.isEmpty ? "" : " · \(tf.string(from: s.lines.first!.t)) to \(tf.string(from: s.lines.last!.t)) \(tz)"
        return "\(title.isEmpty ? "Call" : title) · live transcript from \(s.app)\(span)\n\n" + out.joined(separator: "\n") + "\n"
    }

    static func copy() {
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            // the live call (director.state: kind|app|what|start|window title), if there is one
            var callTitle = "", callStart: Date? = nil
            if let st = try? String(contentsOf: root.appendingPathComponent(".state/director.state"), encoding: .utf8) {
                let p = st.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
                if p.count >= 5 { callTitle = p[4].replacingOccurrences(of: " - Comet", with: ""); callStart = Date(timeIntervalSince1970: Double(p[3]) ?? 0) }
            }
            var app = "", text = "", note = ""
            if front == "com.granola.app" {
                if let g = granola(), !g.isEmpty { app = "Granola"; text = "\(callTitle.isEmpty ? "Call" : callTitle) · live transcript from Granola\n\n" + g }
                else { note = " (Granola's transcript panel is not open)" }
            }
            if text.isEmpty {
                // v107b: only the chosen file is parsed (all three took 75 ms; the freshness check is a file date)
                let now = Date()
                func ok(_ d: Date) -> Bool { now.timeIntervalSince(d) < 6 * 3600 && (callStart.map { d >= $0.addingTimeInterval(-120) } ?? true) }
                typealias Cand = (app: String, bundle: String, fresh: Date, load: () -> Source?)
                var c: [Cand] = []
                if let u = newestFile("Library/Application Support/Wispr Flow/meetings", { $0.appendingPathComponent("live.ndjson") }) { c.append(("Wispr Flow", "com.electron.wispr-flow", mtime(u), { wispr() })) }
                if let u = newestFile("Library/Application Support/BetterWispr/Meetings", nil) { c.append(("BetterWispr", "org.betterwispr.app", mtime(u), { betterwispr() })) }
                if let u = newestFile("Meetings/Krisp/Krisp Meetings", { $0.appendingPathComponent("live_transcript.md") }) { c.append(("Krisp", "ai.krisp.krispMac", mtime(u), { krisp() })) }
                c = c.filter { ok($0.fresh) }
                let top = c.map { $0.fresh }.max() ?? .distantPast
                func rank(_ x: Cand) -> Int { x.bundle == front ? 0 : ((x.app == "Wispr Flow" && x.fresh >= top.addingTimeInterval(-20)) ? 1 : 2) }
                c.sort { rank($0) != rank($1) ? rank($0) < rank($1) : $0.fresh > $1.fresh }
                var pick: Source? = nil
                for x in c { if let s = x.load(), !s.lines.isEmpty { pick = s; break } }
                guard let p = pick else {
                    log("transcript: nothing to copy (no live transcript file from Wispr Flow, BetterWispr or Krisp)\(note)")
                    Toast.show("No live transcript yet"); return
                }
                app = p.app
                text = render(p, title: !callTitle.isEmpty ? callTitle : p.title)
            }
            let n = text.components(separatedBy: "\n").count - 3
            DispatchQueue.main.async {
                let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                log("transcript: copied \(max(n, 0)) lines from \(app) in \(ms) ms (front app \(front.isEmpty ? "none" : front))\(note)")
                Toast.show("Transcript copied from \(app): \(max(n, 0)) lines\(note.isEmpty ? "" : ", Granola panel closed")")
            }
        }
    }
}

/// The Actions Ring as a map of the 3 x 2 meeting grid (sixths, the same rule for left and right and for top and
/// bottom): the slice's direction is where the window
/// goes. Corners = the corner sixths, up and down = the middle sixths (the call above, Claude below), left and right = the side
/// thirds at full height. Caps + keypad digit, laid out like the ring (7 8 9 / 4 6 / 1 2 3). Acts on the window under the
/// pointer (no click needed first), else the front window; on the screen under the pointer. Log "ring:".
enum Ring {
    static let names: [Int: (String, String)] = [7: ("↖", "Top left sixth"), 8: ("↑", "Top middle sixth"), 9: ("↗", "Top right sixth"),
                                                 4: ("←", "Left third"), 6: ("→", "Right third"),
                                                 1: ("↙", "Bottom left sixth"), 2: ("↓", "Bottom middle sixth"), 3: ("↘", "Bottom right sixth")]
    /// `v` = the visible frame in AX coordinates (top-left origin); same cuts as the meeting layouts (laptop 685 | 1371, y 621)
    static func rect(_ d: Int, _ v: CGRect) -> CGRect {
        let x1 = v.minX + (v.width / 3).rounded(), x2 = v.minX + (2 * v.width / 3).rounded(), ym = v.minY + (v.height / 2).rounded(.down)
        let cols = [(v.minX, x1), (x1, x2), (x2, v.maxX)], rows = [(v.minY, ym), (ym, v.maxY)]
        func cell(_ c: Int, _ r: (CGFloat, CGFloat)) -> CGRect { CGRect(x: cols[c].0, y: r.0, width: cols[c].1 - cols[c].0, height: r.1 - r.0) }
        switch d {
        case 7: return cell(0, rows[0]); case 8: return cell(1, rows[0]); case 9: return cell(2, rows[0])
        case 1: return cell(0, rows[1]); case 2: return cell(1, rows[1]); case 3: return cell(2, rows[1])
        case 4: return cell(0, (v.minY, v.maxY)); default: return cell(2, (v.minY, v.maxY))
        }
    }
    static func windowUnderPointer(_ p: CGPoint) -> (AXUIElement, pid_t)? {
        let sys = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(sys, 0.3)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, var e = el else { return nil }
        var pid: pid_t = 0; AXUIElementGetPid(e, &pid)
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        if pid == getpid() || bid == "com.apple.dock" || bid == "com.apple.controlcenter" { return nil }
        for _ in 0..<40 {
            var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
            if (r as? String) == "AXWindow" { return (e, pid) }
            var w: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &w) == .success, let w { return ((w as! AXUIElement), pid) }
            var par: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &par) == .success, let par else { break }
            e = par as! AXUIElement
        }
        return nil
    }
    static func move(_ d: Int) {
        guard let nm = names[d] else { return }
        let arrow = nm.0, name = nm.1
        let t0 = Date()
        let m = NSEvent.mouseLocation, mainH = NSScreen.screens.first?.frame.height ?? 0
        guard let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { return }
        let vf = scr.visibleFrame, v = CGRect(x: vf.minX, y: mainH - vf.maxY, width: vf.width, height: vf.height)
        var target = windowUnderPointer(CGPoint(x: m.x, y: mainH - m.y)), how = "under the pointer"
        if target == nil, let a = NSWorkspace.shared.frontmostApplication, let w = focusedWindow(pid: a.processIdentifier) { target = (w, a.processIdentifier); how = "in front" }
        guard let tg = target else { log("ring: \(arrow) \(name): no window to move"); Toast.show("\(arrow) No window to move"); return }
        let w = tg.0, pid = tg.1
        let r = rect(d, v)
        axSetFrame(w, r)
        // v107b: the moved window comes forward, so it never lands hidden behind the window already there (4 PM test: a
        // Finder window sent to the bottom middle went under Claude, and the next flick moved Claude)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        let got = axFrame(w) ?? .zero
        log("ring: \(arrow) \(name): \(appName) (\(how)) to \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)), now \(Int(got.minX)),\(Int(got.minY)) \(Int(got.width))x\(Int(got.height)) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        Toast.show("\(arrow) \(name): \(appName)")
    }
}

/// Krisp vs Wispr (the two apps fought each other for focus; sometimes the user wants one, sometimes the
/// other): you pick, it stays. A click, Caps 5 / Caps 6 or a pill chip that brings one of them
/// forward is remembered in .state/front-pick, and every later raise of the meeting windows keeps that one on top (Krisp by
/// default; the Director clears the pick when a call starts). During calls Key Deck no longer raises Krisp on hover, and every
/// time Krisp or Wispr comes forward is logged with its cause ("front:"), so a fight from elsewhere shows in the log.
enum FrontPick {
    static let url = root.appendingPathComponent(".state/front-pick")
    static func get() -> String { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static func set(_ k: String, why: String) {
        guard get() != k else { return }
        try? k.write(to: url, atomically: true, encoding: .utf8)
        log("front: \(k == "krisp" ? "Krisp" : "Wispr") picked (\(why)); the meeting layouts keep it on top")
    }
    static func inCall() -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".state/director.state").path) }
    static var lastOther: NSRunningApplication? = nil, handedBack = Date.distantPast   // v109b: the app the user was in before Krisp or Wispr
    static var bwHandedBack = Date.distantPast   // v109d
    static func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let b = a.bundleIdentifier else { return }
            let k = b == "ai.krisp.krispMac" ? "krisp" : (b == "com.electron.wispr-flow" ? "wispr" : "")
            if b == "org.betterwispr.app" || b == "com.granola.app" {   // v109c: a click on either one is the user's pick of the two
                let c = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
                var el: AXUIElement?; var pid: pid_t = 0; let pt = Guard.pointerAX(); let sys = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(sys, 0.2)
                if c < 0.8, AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &el) == .success, let e = el {
                    AXUIElementGetPid(e, &pid)
                    let nv = b == "org.betterwispr.app"
                    if pid == a.processIdentifier, inCall(), nv != Guard.bwPicked {
                        Guard.bwPicked = nv
                        log("front: \(nv ? "BetterWispr's notes" : "Granola") picked (your click)")
                    }
                }
            }
            if b == "org.betterwispr.app" {   // v109d: BetterWispr made itself the active app, not the user's pick: focus back
                if inCall(), !Guard.bwPicked, let o = lastOther, !o.isTerminated, Date().timeIntervalSince(bwHandedBack) > 3 {
                    bwHandedBack = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        AXUIElementSetAttributeValue(AXUIElementCreateApplication(o.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                        log("front: BetterWispr took the focus by itself; focus back to \(o.localizedName ?? "?") (its notes wait behind Granola; the BW chip or Caps 2 brings them forward)")
                    }
                }
                return
            }
            guard !k.isEmpty else { if b != Bundle.main.bundleIdentifier { lastOther = a }; return }
            // v108: a click counts only when it landed on that app's window (in a v108 test Wispr brought itself
            // forward just as the user clicked Join in Meet); Caps 5 / Caps 6 and the pill set the pick themselves (FrontPick.set)
            let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            var overIt = false
            let sys = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(sys, 0.2)
            var el: AXUIElement?; let pt = Guard.pointerAX()
            if AXUIElementCopyElementAtPosition(sys, Float(pt.x), Float(pt.y), &el) == .success, let e = el {
                var pid: pid_t = 0; AXUIElementGetPid(e, &pid); overIt = pid == a.processIdentifier
            }
            let cause = (click < 0.8 && overIt) ? "your click" : "the app itself"
            if inCall() { log("front: \(k == "krisp" ? "Krisp" : "Wispr") came forward (\(cause))") }
            // v109b: Wispr brings itself forward when its recorder opens and keeps the focus (the user's keys went to it, and while it
            // was the active app Krisp could not be raised over it): not the user's pick, so the focus goes back to the app before it
            let pick = get().isEmpty ? "krisp" : get()
            if inCall(), cause == "the app itself", pick != k, let o = lastOther, !o.isTerminated, Date().timeIntervalSince(handedBack) > 10 {
                handedBack = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    AXUIElementSetAttributeValue(AXUIElementCreateApplication(o.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    log("front: \(k == "krisp" ? "Krisp" : "Wispr") took the focus by itself; focus back to \(o.localizedName ?? "?") (\(pick == "krisp" ? "Krisp" : "Wispr") stays on top; Caps 5 / Caps 6 or a click picks)")
                }
            }
            if cause != "the app itself" && get() != k {
                try? k.write(to: url, atomically: true, encoding: .utf8)
                log("front: \(k == "krisp" ? "Krisp" : "Wispr") picked (\(cause)); the meeting layouts keep it on top")
            }
        }
        log("front pick on (Krisp or Wispr stays where you put it; hover-raise off during calls)")
    }
}

// MARK: - Window guard (v108): during a call the meeting windows stay where the layout put them

/// v108: windows did not stay in their slots during a call. Seen on screen and in the logs:
/// Krisp had grown itself to 1358x622 over Wispr and BetterWispr (layout.log), Wispr's hub window had opened over Claude,
/// BetterWispr took its notes in its main window behind Granola, the call window was 624 wide instead of 686, and Wispr sat
/// over Krisp after Wispr brought itself forward when its recorder opened (logged as "your click" because the user had just clicked
/// Join). The layout only pulled windows back in the first 30 s, then once a minute for Krisp and Wispr. Now, every second of
/// a call: a meeting window that moved or resized itself goes back to its slot; a window the user drags stays where it is put (a
/// click on its pill chip puts it back and guarding resumes); Wispr's hub is minimized; BetterWispr's notes come out of its
/// main window ("Open beside your call") into the small panel; the one of Krisp and Wispr the user picked stays on top. Log "guard:".
enum Guard {
    static let queue = DispatchQueue(label: "keydeck.guard", qos: .utility)
    static var timer: DispatchSourceTimer?
    static var call = "", userMoved = Set<String>(), last: [String: CGRect] = [:], backoff: [String: Date] = [:]
    static var hubDone = false, bwOpened = false, raisedAt = Date.distantPast, raises: [Date] = [], zBackoff = Date.distantPast
    static var bwPicked = false, gRaisedAt = Date.distantPast, gRaises: [Date] = [], gBackoff = Date.distantPast   // v109c
    static let watched = ["Claude", "Granola", "Krisp", "Wispr", "BetterWispr"]   // v109: BetterWispr's main window (behind Granola), no panel

    static func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: .seconds(1), leeway: .milliseconds(200))
        t.setEventHandler { tick() }
        t.resume(); timer = t
        log("guard on (during calls the meeting windows go back to their slots; a window you drag stays put)")
    }
    static func pointerAX() -> CGPoint {
        let m = NSEvent.mouseLocation, mainH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: mainH - m.y)
    }
    /// The user is moving it: a mouse press or drag in the last 2 s with the pointer on the window (where it was or is now)
    static func byHand(_ before: CGRect?, _ now: CGRect) -> Bool {
        let a = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let b = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged)
        guard min(a, b) < 2 else { return false }
        let p = pointerAX()
        return now.insetBy(dx: -12, dy: -12).contains(p) || (before?.insetBy(dx: -12, dy: -12).contains(p) ?? false)
    }
    static func tick() {
        guard let st = try? String(contentsOf: root.appendingPathComponent(".state/director.state"), encoding: .utf8) else {
            if !call.isEmpty { call = "" }; return
        }
        let p = st.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard p.count >= 4 else { return }
        if p[3] != call { call = p[3]; userMoved = []; last = [:]; backoff = [:]; hubDone = false; bwOpened = false; bwPicked = false }
        let base = (p[1].contains("mobilephone") || p[1].contains("FaceTime")) ? "layout-call" : "layout-transcripts"
        let desk = NSScreen.screens.contains { $0.frame.width / max($0.frame.height, 1) > 2 }
        guard let sl = FastLayout.slots(base + (desk ? "-desk" : "")) else { return }
        let slots = sl.slots
        var frames: [String: (AXUIElement, CGRect)] = [:]
        for s in slots where watched.contains(s.label) {
            guard let w = FastLayout.pick(s), let f = axFrame(w) else { continue }
            frames[s.label] = (w, f)
            defer { last[s.label] = f }
            if FastLayout.near(f, s.r) { userMoved.remove(s.label); continue }   // in its slot (again): guarded again
            if userMoved.contains(s.label) { continue }
            if byHand(last[s.label], f) {
                userMoved.insert(s.label)
                log("guard: \(s.label) moved by you, left where you put it (its pill chip puts it back)"); continue
            }
            if let b = backoff[s.label], Date() < b { continue }
            FastLayout.move(w, s)
            usleep(80000)
            let g = axFrame(w) ?? f
            if FastLayout.near(g, s.r) {
                frames[s.label] = (w, g)
                log("guard: \(s.label) back in its slot (it had gone to \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))")
            } else {
                backoff[s.label] = Date().addingTimeInterval(60)
                log("guard: \(s.label) will not go back (\(Int(g.width))x\(Int(g.height)), its own minimum while a side panel is open?); again in 60 s")
            }
        }
        callWindow()
        wisprHub()
        betterWisprToMain()
        bwPill(slots, desk: desk)
        // v109c: BetterWispr's main window (its live notes) waits behind Granola unless the user brought it forward (BW chip, Caps 2,
        // a click on it); BetterWispr brings it out in front by itself when its panel hands the note over
        if !bwPicked, let g = frames["Granola"], let b = frames["BetterWispr"], g.1.intersects(b.1),
           Date().timeIntervalSince(gRaisedAt) > 2, Date() > gBackoff, !above(g.1, b.1, "Granola", "BetterWispr") {
            gRaises = gRaises.filter { Date().timeIntervalSince($0) < 20 } + [Date()]
            if gRaises.count > 4 {
                gRaises = []; gBackoff = Date().addingTimeInterval(60)
                log("guard: BetterWispr keeps coming out over Granola; not raised again for 60 s, so the two do not flicker")
            } else {
                AXUIElementPerformAction(g.0, kAXRaiseAction as CFString); gRaisedAt = Date()
                log("guard: Granola back in front of BetterWispr's notes (the BW chip or Caps 2 brings them forward)")
            }
        }
        // the one of Krisp and Wispr the user picked (Krisp by default) on top of the other, when they overlap
        if let k = frames["Krisp"], let w = frames["Wispr"], k.1.intersects(w.1), Date().timeIntervalSince(raisedAt) > 2, Date() > zBackoff {
            let wantWispr = FrontPick.get() == "wispr"
            let top = wantWispr ? w : k, under = wantWispr ? k : w
            if !above(top.1, under.1, wantWispr ? "Wispr Flow" : "krisp", wantWispr ? "krisp" : "Wispr Flow") {
                // v109b: 4 raises in 20 s that did not stick = the other one keeps coming forward: stop for 60 s (no flicker)
                raises = raises.filter { Date().timeIntervalSince($0) < 20 } + [Date()]
                if raises.count > 4 {
                    raises = []; zBackoff = Date().addingTimeInterval(60)
                    log("guard: \(wantWispr ? "Krisp" : "Wispr") keeps coming forward over \(wantWispr ? "Wispr" : "Krisp"); not raised again for 60 s, so the two do not flicker")
                    return
                }
                AXUIElementPerformAction(top.0, kAXRaiseAction as CFString); raisedAt = Date()
                log("guard: \(wantWispr ? "Wispr" : "Krisp") back on top (\(wantWispr ? "your pick" : "the default; Caps 6 or a click on Wispr picks Wispr"))")
            }
        }
    }
    /// front-to-back window order: is the window of `topOwner` at `a` in front of the window of `underOwner` at `b`?
    static func above(_ a: CGRect, _ b: CGRect, _ topOwner: String, _ underOwner: String) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        func idx(_ owner: String, _ r: CGRect) -> Int? {
            list.firstIndex { e in
                guard (e[kCGWindowOwnerName as String] as? String) == owner, (e[kCGWindowLayer as String] as? Int) == 0,
                      let bd = e[kCGWindowBounds as String] as? [String: Any], let br = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return false }
                return abs(br.minX - r.minX) < 4 && abs(br.minY - r.minY) < 4 && abs(br.width - r.width) < 4
            }
        }
        guard let i = idx(topOwner, a), let j = idx(underOwner, b) else { return true }
        return i < j
    }
    /// the pinned call window keeps the call box under the camera (Floaty's pin follows the window)
    static func callWindow() {
        var w: AXUIElement? = nil, pinned = false
        DispatchQueue.main.sync { w = AppDelegate.shared?.webcam.window; pinned = AppDelegate.shared?.webcam.pinned ?? false }
        guard let win = w, pinned, let f = axFrame(win) else { return }
        let target = webcamTarget(for: f)
        defer { last["Call"] = axFrame(win) ?? f }
        if FastLayout.near(f, target) { userMoved.remove("Call"); return }
        if userMoved.contains("Call") { return }
        if byHand(last["Call"], f) { userMoved.insert("Call"); log("guard: the call window moved by you, left where you put it"); return }
        if let b = backoff["Call"], Date() < b { return }
        axSetFrame(win, target); usleep(80000)
        if let g = axFrame(win), FastLayout.near(g, target) {
            log("guard: the call window back under the camera (it had become \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))")
        } else { backoff["Call"] = Date().addingTimeInterval(60) }
    }
    /// Wispr's hub (its big main window) opens itself over Claude when Wispr starts recording: minimized for the call
    static func wisprHub() {
        guard !hubDone, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow").first else { return }
        for w in windows(pid: app.processIdentifier) {
            let t = title(w)
            guard t != "Meeting Recorder", t != "Status", axText(w, kAXSubroleAttribute) == "AXStandardWindow",
                  let f = axFrame(w), f.width >= 900 else { continue }
            var mn: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mn)
            if (mn as? Bool) == true { continue }
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            hubDone = true
            log("guard: Wispr's main window minimized for the call (it had opened over the meeting windows; Wispr's recorder stays)")
        }
    }
    /// v109 (no always-on-top window over Granola: it makes Granola hard to use): BetterWispr's
    /// floating notes panel floats over everything, so during calls its note goes into BetterWispr's main window (the panel's
    /// expand button), a normal window that waits behind Granola in the same slot. The BW chip or Caps 2 brings it forward.
    static var bwTried = Date.distantPast
    static func betterWisprToMain() {
        guard Date().timeIntervalSince(bwTried) > 5,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.betterwispr.app").first else { return }
        for w in windows(pid: app.processIdentifier) where title(w) == "Notetaker" && axText(w, kAXSubroleAttribute) != "AXStandardWindow" {
            guard let pf = axFrame(w), pf.width > 100 else { continue }
            bwTried = Date()
            // the expand button "Open in BetterWispr" (v109b, measured: AX description and help "Open in BetterWispr",
            // 42x28 at 399,3 of the 440-wide panel); else by its place at the panel's top right
            func find(_ e: AXUIElement, _ d: Int, _ byLabel: Bool) -> AXUIElement? {
                if d > 7 { return nil }
                if axText(e, kAXRoleAttribute) == "AXButton" {
                    if byLabel {
                        if axText(e, kAXDescriptionAttribute) == "Open in BetterWispr" || axText(e, kAXHelpAttribute) == "Open in BetterWispr" { return e }
                    } else if let f = axFrame(e), f.width >= 28, f.width <= 60, f.height >= 18, f.height <= 40, f.minY - pf.minY < 16,
                              pf.maxX - f.maxX < 60, f.minX - pf.minX > 100 { return e }
                }
                for c in axKids(e) { if let x = find(c, d + 1, byLabel) { return x } }
                return nil
            }
            guard let b = find(w, 0, true) ?? find(w, 0, false) else { log("guard: BetterWispr's panel is open but its expand button was not found"); return }
            quickPress(b)
            log("guard: BetterWispr's notes moved from its floating panel into its main window, behind Granola (BW chip or Caps 2 brings it forward)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { FastLayout.run(Guard.layoutId(), raiseOnly: false) }
            return
        }
    }
    /// v109: BetterWispr's recording pill (an untitled 440x240 see-through window, the pill at its bottom centre) at the bottom of
    /// the right edge, centred in the strip where Wispr's recorder peeks out from behind Krisp: off Granola and off Krisp's content.
    /// The window may run past the screen's right edge (measured in v109: BetterWispr leaves it there).
    static func bwPill(_ slots: [FastLayout.Slot], desk: Bool) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.betterwispr.app").first,
              let kr = slots.first(where: { $0.label == "Krisp" })?.r, let v = FastLayout.visible(desk: desk) else { return }
        let target = CGRect(x: ((kr.maxX + v.maxX) / 2 - 220).rounded(), y: v.maxY - 262, width: 440, height: 240)
        for w in windows(pid: app.processIdentifier) where title(w).isEmpty {
            guard let f = axFrame(w), abs(f.width - 440) < 3, abs(f.height - 240) < 3 else { continue }
            if abs(f.minX - target.minX) > 3 || abs(f.minY - target.minY) > 3 {
                var p = target.origin
                if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
                log("guard: BetterWispr's pill to the bottom of the right edge (\(Int(target.minX)),\(Int(target.minY)))")
            }
        }
    }
    static func layoutId() -> String {
        let st = (try? String(contentsOf: root.appendingPathComponent(".state/director.state"), encoding: .utf8)) ?? ""
        let base = (st.contains("mobilephone") || st.contains("FaceTime")) ? "layout-call" : "layout-transcripts"
        return base + (NSScreen.screens.contains { $0.frame.width / max($0.frame.height, 1) > 2 } ? "-desk" : "")
    }
}

// MARK: - Native layout (v100): the meeting windows in place in a fraction of a second

/// Goal: very low latency. layout.py moves windows through System Events
/// (AppleScript): its first pass on a test call took 15 s, sharing System Events with the pin and the notetakers.
/// This places the same slots (keys.json deck apps / rects / titles / labels) straight through Accessibility from Key Deck:
/// layout.py's window picking rules (exact:, only:, panel:, panel:=, else the main or largest standard window), size then
/// position twice, kept on screen unless the slot itself peeks past the right edge (Krisp's widget), raised in list order
/// (later on top; the "behind" slots are not raised). Runs on its own serial queue, never on the main thread.
///   keydeck://place?id=<layout id>            move and raise
///   keydeck://place?id=<layout id>&raise=1    raise only (after the pin: activating the browser brings all its windows forward)
/// director.sh still runs layout.py after it, in the background: it checks, logs, pulls back drift and places late windows.
enum FastLayout {
    struct Slot { let idx: Int; let bundles: [String]; let hint: String; let label: String; let r: CGRect; let rx: CGFloat; let bm: CGFloat }
    static let queue = DispatchQueue(label: "keydeck.place", qos: .userInteractive)

    static func ratio(_ s: NSScreen) -> CGFloat { s.frame.width / max(s.frame.height, 1) }
    /// the visible frame in AX coordinates (top-left origin) of the screen layout.py would pick
    static func visible(desk: Bool) -> CGRect? {
        let ss = NSScreen.screens; guard let primary = ss.first else { return nil }
        let builtIn = ss.first(where: { $0.localizedName.lowercased().contains("built") }) ?? primary
        let s = desk ? (ss.max(by: { ratio($0) < ratio($1) }) ?? builtIn) : builtIn
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: primary.frame.height - v.maxY, width: v.width, height: v.height)
    }
    static func slots(_ id: String) -> (slots: [Slot], behind: [Int], lid: String)? {
        var lid = id
        if lid.contains("desk") && !NSScreen.screens.contains(where: { ratio($0) > 2 }) { lid = lid.replacingOccurrences(of: "-desk", with: "") }
        guard let d = loadKeys().keys.first(where: { $0.id == lid })?.deck, let apps = d.apps, let rects = d.rects,
              let v = visible(desk: lid.contains("desk")) else { return nil }
        let titles = d.titles ?? [], labels = d.labels ?? []
        var out: [Slot] = []
        for (i, b) in apps.enumerated() where i < rects.count && rects[i].count == 4 && !b.hasPrefix("picture:") {
            let r = rects[i]
            out.append(Slot(idx: i, bundles: b.components(separatedBy: "|"), hint: i < titles.count ? titles[i] : "", label: i < labels.count ? labels[i] : b,
                            r: CGRect(x: (v.minX + r[0] * v.width).rounded(), y: (v.minY + r[1] * v.height).rounded(),
                                      width: (r[2] * v.width).rounded(), height: (r[3] * v.height).rounded()),
                            rx: v.maxX, bm: v.maxY))
        }
        return (out, d.behind ?? [], lid)
    }
    /// layout.py's pick(): the app's window for this slot, nil when the app is closed or has no such window
    static func pick(_ s: Slot) -> AXUIElement? {
        var hint = s.hint, panelOnly = false, nameOnly = false, exact = false, untitled = false
        if hint.hasPrefix("exact:") { exact = true; hint = String(hint.dropFirst(6)) }
        else if hint.hasPrefix("panel:") { panelOnly = true; hint = String(hint.dropFirst(6)); if hint == "=" { untitled = true; hint = "" } }
        else if hint.hasPrefix("only:") { nameOnly = true; hint = String(hint.dropFirst(5)) }
        for b in s.bundles {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { continue }
            var best: AXUIElement?, bestScore = -1.0
            for w in windows(pid: app.processIdentifier) {
                let std = axText(w, kAXSubroleAttribute) == "AXStandardWindow", nm = title(w)
                let named = !hint.isEmpty && nm.contains(hint)
                let use = panelOnly ? (!std && (untitled ? nm.isEmpty : named)) : (std && (!nameOnly || named) && (!exact || nm == hint))
                guard use, let f = axFrame(w) else { continue }
                var sc = Double(f.width * f.height)
                if (axValue(w, kAXMainAttribute) as? Bool) == true { sc += 50_000_000 }
                if named { sc += 100_000_000 }
                if sc > bestScore { bestScore = sc; best = w }
            }
            return best
        }
        return nil
    }
    static func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2 }
    static func move(_ w: AXUIElement, _ s: Slot) {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        axSetFrame(w, s.r)
        guard let f = axFrame(w) else { return }
        var nx = f.minX, ny = f.minY
        if s.r.maxX <= s.rx + 1 && nx + f.width > s.rx { nx = s.rx - f.width }   // a peeking slot may run past the right edge
        if ny + f.height > s.bm { ny = s.bm - f.height }
        if nx != f.minX || ny != f.minY {
            var p = CGPoint(x: nx, y: ny)
            if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        }
    }
    static func run(_ id: String, raiseOnly: Bool) {
        queue.async {
            let t0 = Date()
            guard let (ss, behind, lid) = slots(id) else { log("place: \(id): no slots in keys.json"); return }
            var picks: [(Slot, AXUIElement)] = [], missing: [String] = []
            for s in ss { if let w = pick(s) { picks.append((s, w)) } else { missing.append(s.label) } }
            var redo = 0
            if !raiseOnly {
                for (s, w) in picks { move(w, s) }
                usleep(60000)   // apps that resize a moment later get a second pass
                for (s, w) in picks where !(axFrame(w).map { near($0, s.r) } ?? true) { move(w, s); redo += 1 }
            }
            var order = picks.filter { !behind.contains($0.0.idx) }
            // v107: Wispr picked last (a click, Caps 6 or the pill) stays over Krisp; Krisp is on top by default
            if FrontPick.get() == "wispr", let wi = order.firstIndex(where: { $0.0.label == "Wispr" }) { order.append(order.remove(at: wi)) }
            for (_, w) in order { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("place: \(lid) \(raiseOnly ? "raised" : "placed") \(picks.count) windows in \(ms) ms\(redo > 0 ? " (\(redo) needed a second pass)" : "")\(missing.isEmpty ? "" : "; not open: \(missing.joined(separator: ", "))")")
        }
    }
}

// MARK: - Call pill (v99): small, readable, draggable status for the meeting apps

/// The status colours should be small, readable, calm and draggable anywhere on screen. The v93 to v98 strip (654 x 48 pt, six coloured two-line buttons over the call's title bar) is now a
/// 26 pt pill: one neutral line, colour only where something needs the user (a red dot while an app records, an orange ring when a
/// window drifted out of its slot, dimmed when closed). Grab it anywhere and drop it anywhere: dropped on the call window it
/// rides along with the call, elsewhere it stays put; remembered per screen in .state/strip.json; double-click the grip =
/// back to the seam between the call and Claude (centred on the camera line). Fades to 55% five seconds after the pointer
/// leaves. Right-click: Mini (glyphs only), Back to the seam. Clicks: an app forward (put back in its slot first when it
/// moved); Call = the call forward, pinned again when Floaty dropped the pin, never unpinned (the old Call button unpinned a
/// live call): Option-click Call or Caps W unpins. Option-click BW = BetterWispr's main window.
final class PillChip: NSView {
    weak var strip: CallStrip?
    var key = "", glyph = "", name = "", hint = ""   // hint: the chip's shortcut, small and faint (v107)
    var dot: NSColor?
    var ring = false, dim = false, isGrip = false
    private var downAt = NSPoint.zero, startOrigin = NSPoint.zero, dragged = false
    var text: NSAttributedString {
        let s = isGrip ? "⋮⋮" : ((strip?.mini ?? false) ? glyph : glyph + " " + name)
        let col = isGrip ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 1, alpha: dim ? 0.42 : 0.96)
        let a = NSMutableAttributedString(string: s, attributes: [.foregroundColor: col, .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)])
        if !hint.isEmpty {
            a.append(NSAttributedString(string: " " + hint, attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.36),
                                                                         .font: NSFont.systemFont(ofSize: 9, weight: .regular)]))
        }
        return a
    }
    func width() -> CGFloat { (isGrip ? 4 : 6) + (dot != nil ? 10 : 0) + ceil(text.size().width) + (isGrip ? 2 : 6) }
    override func draw(_ r: NSRect) {
        if ring {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3.5), xRadius: 9, yRadius: 9)
            NSColor.systemOrange.setStroke(); p.lineWidth = 1.5; p.stroke()
        }
        var x: CGFloat = isGrip ? 4 : 6
        if let d = dot { d.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3.5, width: 7, height: 7)).fill(); x += 10 }
        let t = text; t.draw(at: NSPoint(x: x, y: ((bounds.height - t.size().height) / 2).rounded()))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        downAt = NSEvent.mouseLocation; startOrigin = window?.frame.origin ?? .zero; dragged = false
        if isGrip && e.clickCount == 2 { strip?.resetPosition() }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation, dx = p.x - downAt.x, dy = p.y - downAt.y
        if !dragged && hypot(dx, dy) < 4 { return }
        dragged = true; strip?.dragging = true; window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }
    override func mouseUp(with e: NSEvent) { strip?.dragging = false; if dragged { strip?.dropped() } else if !isGrip { strip?.tap(key, option: e.modifierFlags.contains(.option)) } }
    override func rightMouseDown(with e: NSEvent) { strip?.showMenu(e, in: self) }
}

final class PillBack: NSView {
    weak var strip: CallStrip?
    var area: NSTrackingArea?
    private var downAt = NSPoint.zero, startOrigin = NSPoint.zero, dragged = false
    override func draw(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(red: 0.105, green: 0.12, blue: 0.14, alpha: 0.94).setFill(); p.fill()
        NSColor(white: 1, alpha: 0.16).setStroke(); p.lineWidth = 1; p.stroke()
    }
    override func updateTrackingAreas() {
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
        super.updateTrackingAreas()
    }
    override func mouseEntered(with e: NSEvent) { strip?.wake() }
    override func mouseExited(with e: NSEvent) { strip?.fadeSoon() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { downAt = NSEvent.mouseLocation; startOrigin = window?.frame.origin ?? .zero; dragged = false }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation, dx = p.x - downAt.x, dy = p.y - downAt.y
        if !dragged && hypot(dx, dy) < 4 { return }
        dragged = true; strip?.dragging = true; window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }
    override func mouseUp(with e: NSEvent) { strip?.dragging = false; if dragged { strip?.dropped() } }
    override func rightMouseDown(with e: NSEvent) { strip?.showMenu(e, in: self) }
}

/// v100: every layout slot on the main screen in one keys.json read (the pill's refresh asked for five, one read each)
func slotFrames() -> [String: CGRect] {
    guard let screen = NSScreen.screens.first else { return [:] }
    let vf = screen.visibleFrame; let top = screen.frame.height - vf.maxY
    let lid = vf.width / max(vf.height, 1) > 2 ? "layout-transcripts-desk" : "layout-transcripts"
    guard let d = loadKeys().keys.first(where: { $0.id == lid })?.deck, let labels = d.labels, let rects = d.rects else { return [:] }
    var out: [String: CGRect] = [:]
    for (l, r) in zip(labels, rects) where r.count == 4 {
        out[l] = CGRect(x: (vf.minX + r[0] * vf.width).rounded(), y: (top + r[1] * vf.height).rounded(), width: (r[2] * vf.width).rounded(), height: (r[3] * vf.height).rounded())
    }
    return out
}

final class CallStrip: NSObject {
    var panel: NSPanel?
    var back: PillBack?
    var chips: [String: PillChip] = [:]
    var timer: Timer?
    var fadeTimer: Timer?
    var phone = false
    var mini = false
    var callFrame = CGRect.zero   // the pinned call window, AX coordinates
    var dragging = false          // v101: no repositioning while the user drags the pill
    let order = ["grip", "call", "claude", "granola", "bw", "krisp", "wispr", "transcript"]   // v107: one-click transcript (Caps T)
    let posURL = root.appendingPathComponent(".state/strip.json")
    static let H: CGFloat = 26
    static let slotOf = ["claude": "Claude", "granola": "Granola", "bw": "BetterWispr", "krisp": "Krisp", "wispr": "Wispr"]   // v109: BW = its main window

    var mainH: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    func screenKey() -> String {
        guard let s = NSScreen.screens.first else { return "laptop" }
        return s.visibleFrame.width / max(s.visibleFrame.height, 1) > 2 ? "desk" : "laptop"
    }
    func loadPos() -> [String: Any] { ((try? Data(contentsOf: posURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
    func savePos(_ d: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: d) { try? data.write(to: posURL, options: .atomic) } }
    var parked: Bool { ((loadPos()[screenKey()] as? [String: Any])?["mode"] as? String) == "screen" }
    /// where the pill goes (Cocoa origin): the spot the user left it on this screen (on the call: relative to the call window), else
    /// the seam between the call and Claude, centred on the call (= the camera line)
    func origin(_ size: NSSize) -> NSPoint {
        let seam = NSPoint(x: (callFrame.midX - size.width / 2).rounded(), y: (mainH - callFrame.maxY - size.height / 2).rounded())
        guard let p = loadPos()[screenKey()] as? [String: Any], let x = p["x"] as? Double, let y = p["y"] as? Double else { return seam }
        if (p["mode"] as? String) == "call" { return NSPoint(x: callFrame.minX + x, y: mainH - (callFrame.minY + y) - size.height) }
        return NSPoint(x: x, y: y)
    }
    func dropped() {
        guard let p = panel else { return }
        let f = p.frame, top = mainH - f.maxY
        var d = loadPos()
        if callFrame.insetBy(dx: -40, dy: -40).contains(CGPoint(x: f.midX, y: mainH - f.midY)) {
            d[screenKey()] = ["mode": "call", "x": Double(f.minX - callFrame.minX), "y": Double(top - callFrame.minY)]
            log("strip: dropped on the call window at \(Int(f.minX)),\(Int(top)) (rides along with the call)")
        } else {
            d[screenKey()] = ["mode": "screen", "x": Double(f.minX), "y": Double(f.minY)]
            log("strip: dropped at \(Int(f.minX)),\(Int(top)) (stays there on the \(screenKey()))")
        }
        savePos(d)
    }
    func resetPosition() {
        var d = loadPos(); d.removeValue(forKey: screenKey()); savePos(d)
        if let p = panel { p.setFrameOrigin(origin(p.frame.size)) }
        log("strip: back to the seam")
    }
    func wake() { fadeTimer?.invalidate(); panel?.animator().alphaValue = 1 }
    func fadeSoon() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.panel?.animator().alphaValue = 0.55 }
    }
    @objc func toggleMini() { mini.toggle(); relayout(); log("strip: \(mini ? "mini" : "names shown")") }
    @objc func menuReset() { resetPosition() }
    func showMenu(_ e: NSEvent, in v: NSView) {
        let m = NSMenu()
        let a = NSMenuItem(title: mini ? "Show names" : "Mini (glyphs only)", action: #selector(toggleMini), keyEquivalent: ""); a.target = self; m.addItem(a)
        let b = NSMenuItem(title: "Back to the seam", action: #selector(menuReset), keyEquivalent: ""); b.target = self; m.addItem(b)
        NSMenu.popUpContextMenu(m, with: e, for: v)
    }

    func makeView() -> PillBack {
        let v = PillBack(frame: NSRect(x: 0, y: 0, width: 300, height: CallStrip.H)); v.strip = self
        chips = [:]
        let names: [String: (String, String)] = ["grip": ("", ""), "call": ("📌", phone ? "Phone" : "Call"), "claude": ("✳️", "Claude"),
                                                 "granola": ("🥣", "Granola"), "bw": ("📝", "BW"), "krisp": ("🎙", "Krisp"), "wispr": ("🌊", "Wispr"),
                                                 "transcript": ("📋", "Transcript")]
        for k in order {
            let c = PillChip(frame: .zero); c.strip = self; c.key = k; c.isGrip = (k == "grip")
            c.glyph = names[k]?.0 ?? ""; c.name = names[k]?.1 ?? ""
            if c.isGrip { c.toolTip = "Drag to move (anywhere on the pill works too) · double-click: back to the seam · right-click: Mini" }
            if k == "transcript" {   // v107: a one-click transcript button in the pill, its shortcut shown quietly
                c.hint = "⇪T"
                c.toolTip = "Click or Caps T: copy the live transcript (the notetaker in front, else Wispr Flow, else the freshest), then ⌘V in Claude"
            }
            if ["granola", "bw", "krisp", "wispr"].contains(k) { c.dot = NSColor(white: 0.55, alpha: 1) }   // v101: width stable from the start
            v.addSubview(c); chips[k] = c
        }
        back = v
        return v
    }
    /// sizes each chip to its text and the pill to its chips (the left edge stays put)
    func relayout() {
        guard let v = back else { return }
        var x: CGFloat = 4
        for k in order {
            guard let c = chips[k] else { continue }
            let w = c.width(); c.frame = NSRect(x: x, y: 0, width: w, height: CallStrip.H); c.needsDisplay = true; x += w
        }
        let size = NSSize(width: x + 4, height: CallStrip.H)
        v.frame = NSRect(origin: .zero, size: size); v.needsDisplay = true
        if let p = panel, p.frame.size != size { p.setContentSize(size) }
    }

    func show(over frame: CGRect, phone: Bool) {
        hide(); self.phone = phone; callFrame = frame
        let p = StripPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: CallStrip.H), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.hidesOnDeactivate = false
        p.contentView = makeView(); panel = p
        relayout(); refresh()   // v101: sized now (the status reads come back a moment later, off the main thread)
        p.setFrameOrigin(origin(p.frame.size))
        p.alphaValue = 1; p.orderFrontRegardless(); fadeSoon()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        log("strip: shown over the call window (pill \(Int(p.frame.width))x\(Int(p.frame.height)) at \(Int(p.frame.minX)),\(Int(mainH - p.frame.maxY)))")
    }

    func hide() {
        timer?.invalidate(); timer = nil; fadeTimer?.invalidate(); fadeTimer = nil
        if panel != nil { log("strip: hidden") }
        panel?.orderOut(nil); panel = nil; back = nil; chips = [:]
    }

    // MARK: status (every 2 s): who records, who sits in its slot
    func micUsers() -> String {
        let t = Process(); t.executableURL = root.appendingPathComponent("bin/micusers"); let o = Pipe(); t.standardOutput = o; t.standardError = nil
        do { try t.run() } catch { return "" }
        let d = o.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
    func krispRecording() -> Bool {   // Krisp's live transcript (.md under ~/Meetings/Krisp) written in the last 45 s
        let dir = home.appendingPathComponent("Meetings/Krisp")
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return false }
        var newest = Date.distantPast
        for case let u as URL in e where u.pathExtension == "md" {
            if let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > newest { newest = m }
        }
        return Date().timeIntervalSince(newest) < 45
    }
    func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 24 && abs(a.minY - b.minY) < 24 && abs(a.width - b.width) < 24 && abs(a.height - b.height) < 24 }
    /// "in slot" when a window of the app with the given title rule sits in its layout slot, "moved" when it sits elsewhere, "closed" when there is none
    func placed(bundle: String, slot: CGRect?, want: (String) -> Bool) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first, let s = slot else { return "closed" }
        let ws = windows(pid: app.processIdentifier).filter { want(title($0)) }
        if ws.isEmpty { return "closed" }
        return ws.contains(where: { axFrame($0).map { near($0, s) } ?? false }) ? "in slot" : "moved"
    }
    /// v100: the status reads (the mic list, five apps' windows, the pin) run off the main thread once a second, so the pill,
    /// the Caps keys and the Krisp hover never wait on them; the chips change on the main thread when the reads come back.
    var refreshing = false
    func refresh() {
        guard panel != nil, !refreshing else { return }
        refreshing = true
        let wc = AppDelegate.shared.webcam, w = wc.window
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let mics = self.micUsers(), slots = slotFrames()
            let pinned = w.map { wc.pinOK($0) } ?? false
            let cf = w.flatMap { axFrame($0) }
            let st: [String: String] = [
                "claude": self.placed(bundle: "com.anthropic.claudefordesktop", slot: slots["Claude"], want: { _ in true }),
                "granola": self.placed(bundle: "com.granola.app", slot: slots["Granola"], want: { $0 == "Granola" || $0.isEmpty }),
                "bw": self.placed(bundle: "org.betterwispr.app", slot: slots["BetterWispr"], want: { $0.contains("Notetaker") }),
                "krisp": self.placed(bundle: "ai.krisp.krispMac", slot: slots["Krisp"], want: { $0 == "Krisp" }),
                "wispr": self.placed(bundle: "com.electron.wispr-flow", slot: slots["Wispr"], want: { $0.contains("Meeting Recorder") })]
            let rec: [String: Bool] = ["granola": mics.contains("com.granola.app"), "bw": mics.contains("org.betterwispr.app"),
                                       "krisp": self.krispRecording(), "wispr": mics.contains("wispr-flow")]
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(pinned: pinned, hasWindow: w != nil, frame: cf, place: st, rec: rec)
            }
        }
    }
    func apply(pinned: Bool, hasWindow: Bool, frame cf: CGRect?, place st: [String: String], rec: [String: Bool]) {
        guard let p = panel else { return }
        // rides along with the call window when it moves (unless the user parked the pill elsewhere on this screen)
        var moved = false
        if let f = cf, abs(f.minX - callFrame.minX) > 2 || abs(f.minY - callFrame.minY) > 2 || abs(f.width - callFrame.width) > 2 || abs(f.height - callFrame.height) > 2 {
            callFrame = f; moved = true
        }
        let w0 = p.frame.width
        var lines: [String] = []
        if let c = chips["call"] {
            c.glyph = pinned ? "📌" : "⚠️"; c.dot = nil; c.ring = false; c.dim = !hasWindow
            let s = pinned ? "pinned under the camera" : (hasWindow ? "not pinned" : "nothing pinned")
            c.toolTip = "\(c.name): \(s)\nClick: the call forward, pinned again if the pin dropped · Option-click or Caps W: unpin"
            lines.append("\(c.glyph) \(c.name): \(s)")
        }
        let clicks = ["claude": "Click: Claude forward, cursor in its message box (Caps 3)",
                      "granola": "Click: Granola forward, cursor in its ask box (Caps 1)",
                      "bw": "Click: BetterWispr's notes forward (they wait behind Granola); again: Granola back on top (Caps 2)",
                      "krisp": "Click: Krisp forward; again: back where you were (Caps 5)",
                      "wispr": "Click: Wispr's recorder forward, cursor in its ask box (Caps 6)"]
        for k in ["claude", "granola", "bw", "krisp", "wispr"] {
            guard let c = chips[k], let place = st[k] else { continue }
            let r = rec[k]
            c.dot = r.map { $0 ? NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1) : NSColor(white: 0.55, alpha: 1) }
            c.ring = place == "moved"; c.dim = place == "closed"
            let s = (r.map { $0 ? "recording · " : "idle · " } ?? "") + (place == "moved" ? "moved (a click puts it back)" : place)
            c.toolTip = "\(c.name): \(s)\n\(clicks[k] ?? "")"
            lines.append("\(c.glyph) \(c.name): \(s)")
        }
        back?.toolTip = lines.joined(separator: "\n")
        relayout()
        if !dragging && !parked && (moved || abs(p.frame.width - w0) > 0.5) { p.setFrameOrigin(origin(p.frame.size)) }   // stays centred, rides with the call
    }

    var lastTap = ("", Date.distantPast)
    func tap(_ k: String, option: Bool) {
        // one click = one action: a test saw a click delivered twice (Krisp's chip toggles, twice = no change)
        if lastTap.0 == k && Date().timeIntervalSince(lastTap.1) < 0.6 { return }
        lastTap = (k, Date())
        log("strip: \(k == "bw" ? "BW" : k.capitalized) clicked\(option ? " (option)" : "")")
        let wc = AppDelegate.shared.webcam
        if k == "call" {
            if option { wc.off() } else if wc.window != nil { wc.raiseOrRepin() } else { wc.toggleFront() }
            return
        }
        if k == "transcript" { Transcript.copy(); return }   // v107: one click, same as Caps T
        let act: () -> Void = {
            switch k {
            case "claude": AppDelegate.shared.chat.go("claude")
            case "granola": AppDelegate.shared.chat.go("granola")
            case "bw": AppDelegate.shared.swap.go()   // v109: BetterWispr's notes window forward / Granola back on top
            case "krisp": FrontPick.set("krisp", why: "the pill"); AppDelegate.shared.krisp.toggle()
            case "wispr": FrontPick.set("wispr", why: "the pill"); AppDelegate.shared.chat.go("wispr")
            default: break
            }
        }
        guard let c = chips[k], c.ring, let slot = CallStrip.slotOf[k] else { act(); return }
        // drifted out of its slot: back first (layout.py moves only that window), then the usual click
        let lid = (phone ? "layout-call" : "layout-transcripts") + (screenKey() == "desk" ? "-desk" : "")
        DispatchQueue.global().async {
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            t.arguments = [root.appendingPathComponent("layout.py").path, lid, "--only", slot, "--quiet"]
            try? t.run(); t.waitUntilExit()
            DispatchQueue.main.async { log("strip: \(slot) put back in its slot"); act() }
        }
    }
}

/// `KeyDeck --render-pill <out.png>` draws the call pill offscreen with sample states (Call pinned, Granola, BW and Krisp
/// recording, Krisp moved, Wispr idle) for design review; `--render-pill <out.png> mini` the glyph-only form.
@MainActor func renderPill(to path: String, mini: Bool) {
    let s = CallStrip(); s.mini = mini
    let v = s.makeView()
    let red = NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1), grey = NSColor(white: 0.55, alpha: 1)
    for (k, rec) in [("granola", true), ("bw", true), ("krisp", true), ("wispr", false)] { s.chips[k]?.dot = rec ? red : grey }
    s.chips["krisp"]?.ring = true
    s.relayout()
    let scale: CGFloat = 2, pad: CGFloat = 10
    let host = NSView(frame: NSRect(x: 0, y: 0, width: v.frame.width + 2 * pad, height: v.frame.height + 2 * pad))
    v.setFrameOrigin(NSPoint(x: pad, y: pad)); host.addSubview(v)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.frame.width * scale), pixelsHigh: Int(host.frame.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { print("render failed"); return }
    rep.size = host.frame.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1).setFill(); host.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("rendered \(path): pill \(Int(v.frame.width))x\(Int(v.frame.height)) pt")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    let strip = CallStrip()
    var panel: DeckPanel?
    var scrim: ScrimPanel?
    let webcam = Webcam()
    let clip = ClipSaver()
    let caps = CapsIndicator()
    let secure = SecureInputWatch()
    let chat = ChatJump()
    let swap = TranscriptSwap()
    let krisp = KrispPeek()
    let state = DeckState()
    var model: DeckModel?
    var globalClick: Any?
    var localKey: Any?
    var hotRefs: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("launch v2, accessibility trusted: \(AXIsProcessTrustedWithOptions(opts))")
        registerHotKeys()
        clip.start()
        caps.start()
        secure.start()
        krisp.startHover()
        LiveSnap.start()   // v105
        FrontPick.start()  // v107
        Guard.start()      // v108
        DeckModel(loadKeys()).writeHints()
    }

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { AppDelegate.shared.hotKey(id) }
            return noErr
        }, 1, &spec, nil, nil)
        registerKeysOnly()
    }

    func pauseHotKeys(seconds: Double) {
        for r in hotRefs { if let r { UnregisterEventHotKey(r) } }
        hotRefs.removeAll()
        log("hotkeys paused for \(Int(seconds))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.registerKeysOnly() }
    }

    func registerKeysOnly() {
        let hyper = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let keys: [(UInt32, Int, String)] = [(1, kVK_ANSI_Slash, "Caps+/"), (2, kVK_ANSI_W, "Caps+W"),
                                             (3, kVK_ANSI_1, "Caps+1"), (4, kVK_ANSI_2, "Caps+2"), (5, kVK_ANSI_3, "Caps+3"),
                                             (6, kVK_ANSI_4, "Caps+4"), (7, kVK_ANSI_5, "Caps+5"),
                                             (8, kVK_ANSI_6, "Caps+6"), (9, kVK_ANSI_T, "Caps+T"),   // v107: Caps T transcript
                                             // v107: the ring's grid, laid out like the keypad (7 8 9 / 4 6 / 1 2 3)
                                             (17, kVK_ANSI_Keypad7, "Caps+Keypad7"), (18, kVK_ANSI_Keypad8, "Caps+Keypad8"),
                                             (19, kVK_ANSI_Keypad9, "Caps+Keypad9"), (14, kVK_ANSI_Keypad4, "Caps+Keypad4"),
                                             (16, kVK_ANSI_Keypad6, "Caps+Keypad6"), (11, kVK_ANSI_Keypad1, "Caps+Keypad1"),
                                             (12, kVK_ANSI_Keypad2, "Caps+Keypad2"), (13, kVK_ANSI_Keypad3, "Caps+Keypad3")]
        for (id, code, label) in keys {
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(code), hyper, EventHotKeyID(signature: OSType(0x4B44454B), id: id), GetApplicationEventTarget(), 0, &ref)
            hotRefs.append(ref)
            log("hotkey \(label) register status \(err)")
        }
    }

    func hotKey(_ id: UInt32) {
        if id == 1 { toggleDeck() }
        if id == 2 { hideDeck { self.webcam.toggleFront() } }
        if let target = [UInt32(3): "granola", 5: "claude"][id] { hideDeck { self.chat.go(target) } }
        if id == 4 { hideDeck { self.swap.go() } }   // v109: Caps 2 = BetterWispr's notes window forward / Granola back (no floating panel)
        if id == 6 { hideDeck { self.swap.go() } }
        if id == 7 { FrontPick.set("krisp", why: "Caps 5"); hideDeck { self.krisp.toggle() } }
        if id == 8 { FrontPick.set("wispr", why: "Caps 6"); hideDeck { self.chat.go("wispr") } }   // v91: Caps 6 = Wispr's ask box (Meeting Recorder)
        if id == 9 { Transcript.copy() }                       // v107: Caps T, the live transcript on the clipboard
        if (11...19).contains(id) { Ring.move(Int(id) - 10) }  // v107: Caps + keypad, the ring's sixths and thirds
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
            var q: [String: String] = [:]
            for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
            switch u.host ?? "" {
            case "deck": toggleDeck()
            case "chat": hideDeck { self.chat.go(q["app"] ?? "") }
            case "swap": hideDeck { self.swap.go() }
            case "krisp": hideDeck { self.krisp.toggle() }
            case "hover": krisp.setHover(q["on"] != "0")
            case "webcam":
                if let b = q["bundle"], !b.isEmpty {
                    let t0 = Date()   // v106: .state/pin-result the moment the request is done
                    webcam.onApp(bundle: b, titleContains: q["title"], strict: q["strict"] != "0")
                    pinResult((webcam.window.map { webcam.pinOK($0) } ?? false) ? "pinned" : "not pinned", since: t0)
                } else { webcam.toggleFront() }
            case "menu":   // v106b: a menu bar app's item by its exact name (BetterWispr's notetaker); .state/menu-result for director.sh
                let t0 = Date(), item = q["item"] ?? "", b = q["bundle"] ?? ""
                let ok = !b.isEmpty && !item.isEmpty && menuExtraChoose(bundle: b, item: item)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                try? "\(ok ? "chose \(item)" : "not chosen") \(ms) ms\n".write(to: root.appendingPathComponent(".state/menu-result"), atomically: true, encoding: .utf8)
                log("menu: \(b) \"\(item)\" \(ok ? "chosen" : "not in its menu") in \(ms) ms")
            case "webcam-off":
                let t0 = Date(), w = webcam.window
                webcam.off()
                pinResult((w.map { webcam.pinOK($0) } ?? false) ? "still pinned" : "unpinned", since: t0)
            case "pause": pauseHotKeys(seconds: Double(q["seconds"] ?? "90") ?? 90)
            case "report": openReport()
            case "layout": runLayout(id: q["id"])
            case "wispr": WisprNote.run(q["do"] ?? "state")
            case "place": if let id = q["id"], !id.isEmpty { FastLayout.run(id, raiseOnly: q["raise"] == "1") }
            default: log("unknown url \(u)")
            }
        }
    }

    func toggleDeck() { if panel?.isVisible == true { hideDeck() } else { showDeck() } }

    func showDeck() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let data = loadKeys()
        let m = DeckModel(data)
        let status = loadStatus()
        let deckH = MainActor.assumeIsolated { DeckView.measure(m, status) }   // showDeck always runs on the main thread
        let scale = min(1.0, (vf.width - 32) / DeckView.designWidth, (vf.height - 32) / deckH)
        let w = (DeckView.designWidth * scale).rounded(), h = (deckH * scale).rounded()
        let frame = NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2).rounded(), width: w, height: h)
        m.writeHints()
        model = m
        state.pressed = nil
        state.shown = false
        let deck = DeckView(model: m, status: loadStatus(), run: { [weak self] k in self?.run(k) },
                            openReport: { [weak self] in self?.openReport() }, state: state)
        let appearance: NSAppearance? = data.deck_theme == "light" ? NSAppearance(named: .aqua)
            : data.deck_theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        if panel == nil {
            let p = DeckPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = p
        }
        if scrim == nil {
            let s = ScrimPanel(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            s.level = .statusBar
            s.isOpaque = false
            s.hasShadow = false
            s.hidesOnDeactivate = false
            s.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let v = ScrimView()
            v.onClick = { [weak self] in self?.hideDeck() }
            s.contentView = v
            scrim = s
        }
        guard let p = panel, let s = scrim else { return }
        p.appearance = appearance
        s.appearance = appearance
        let dark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        s.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.34 : 0.22)
        s.setFrame(screen.frame, display: false)
        p.contentView = NSHostingView(rootView: ScaledDeck(deck: deck, scale: scale))
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        s.alphaValue = 0
        s.orderFrontRegardless()
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.08 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            s.animator().alphaValue = 1
        }
        if globalClick == nil {
            globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hideDeck() }
        }
        if localKey == nil {
            localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                if e.keyCode == 53 { self.hideDeck(); return nil }
                if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return nil }   // Caps still held
                if let ch = e.charactersIgnoringModifiers?.uppercased(), let k = self.model?.byHint[ch] { self.run(k) }
                return nil
            }
        }
        log("deck shown at scale \(String(format: "%.2f", scale)), \(m.byHint.count) badge keys")
    }

    func hideDeck(then done: (() -> Void)? = nil) {
        if let g = globalClick { NSEvent.removeMonitor(g); globalClick = nil }
        if let l = localKey { NSEvent.removeMonitor(l); localKey = nil }
        guard let p = panel, p.isVisible else { done?(); return }
        let s = scrim
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.06 : 0.12
            p.animator().alphaValue = 0
            s?.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            s?.orderOut(nil)
            done?()
        })
    }

    /// Meeting layouts: layout.py moves each app window with System Events (it needs Key Deck's Accessibility permission).
    func runLayout(id: String?) {
        guard let id, !id.isEmpty else { return }
        if !AXIsProcessTrusted() {
            log("layout \(id): needs Accessibility, opening System Settings")
            openAccessibilitySettings()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [root.appendingPathComponent("layout.py").path, id, "--quiet", "--settle", "9"]
        try? p.run()
        log("layout \(id) started")
    }

    func openReport() {
        hideDeck {
            let dir = root.appendingPathComponent("reports")
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
            NSWorkspace.shared.open(files.last.map { dir.appendingPathComponent($0) } ?? root.appendingPathComponent("keys.md"))
        }
    }

    func run(_ k: KeyEntry) {
        state.pressed = model?.hint(for: k)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.hideDeck {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.perform(k) }
            }
        }
    }

    func perform(_ k: KeyEntry) {
        if let u = k.deck?.url {
            if u.hasPrefix("keydeck://webcam") { webcam.toggleFront() }
            else if u.hasPrefix("keydeck://pause") { pauseHotKeys(seconds: 90) }
            else if u.hasPrefix("keydeck://report") { openReport() }
            else if u.hasPrefix("keydeck://layout") { runLayout(id: URLComponents(string: u)?.queryItems?.first(where: { $0.name == "id" })?.value) }
            else { openQuietly(u) }
            log("ran \(k.id) via \(u)")
        } else if let c = k.combo {
            if !AXIsProcessTrusted() {
                log("ran \(k.id): sending keys needs Accessibility, opening System Settings")
                openAccessibilitySettings()
                return
            }
            postCombo(c)
            log("ran \(k.id) via keys \(c)")
        }
    }
}

/// `KeyDeck --render <out.png> [dark|light] [hint]` draws the deck offscreen (no window, no hotkeys, no permissions) for design review.
@MainActor func renderPreview(to path: String, dark: Bool, pressed: String?) {
    let m = DeckModel(loadKeys())
    m.writeHints()
    let st = DeckState(); st.shown = true; st.pressed = pressed
    _ = DeckView.measure(m, loadStatus())
    let deck = DeckView(model: m, status: loadStatus(), run: { _ in }, openReport: {}, state: st)
    let view = deck
        .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.97, green: 0.97, blue: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("rendered \(path) with \(m.windows.count) window tiles, \(m.meetings.count) meeting tiles, \(m.byHint.count) badge keys")
}

@main
struct KeyDeckMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-pill"), i + 1 < args.count {
            _ = NSApplication.shared
            renderPill(to: args[i + 1], mini: args.count > i + 2 && args[i + 2] == "mini")
            return
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            _ = NSApplication.shared
            renderPreview(to: args[i + 1], dark: args.count > i + 2 && args[i + 2] == "dark", pressed: args.count > i + 3 ? args[i + 3] : nil)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
