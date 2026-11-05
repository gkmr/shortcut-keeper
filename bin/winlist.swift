// winlist (2026-10-21): one line per on-screen window, straight from the window server (CGWindowListCopyWindowInfo,
// optionOnScreenOnly + excludeDesktopElements), front to back, in about 50 ms. Replaces System Events window listings in
// director.sh (call-window snapshot) and layout.py (--check and settle read-backs): System Events serializes accessibility
// requests and one listing took 15 to 40 s under load at the start of a call (2026-10-21). AX is still used for moves.
//   winlist             owner name TAB pid TAB window title TAB x,y,w,h TAB layer        (x,y top-left, global points)
//   winlist --bundles   the same plus TAB bundle id (layout.py matches apps by bundle id)
// Titles need Screen Recording permission for the process that runs this (macOS 10.15+). Without it the tool prints
// "winlist: no Screen Recording permission" on stderr and exits 3, so callers fall back to System Events instead of
// reading empty titles. Build: swiftc -O -o bin/winlist bin/winlist.swift
import AppKit
import CoreGraphics
import Foundation

let bundles = CommandLine.arguments.contains("--bundles")
if !CGPreflightScreenCaptureAccess() {
    FileHandle.standardError.write("winlist: no Screen Recording permission for this process, window titles unavailable\n".data(using: .utf8)!)
    exit(3)
}
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("winlist: CGWindowListCopyWindowInfo failed\n".data(using: .utf8)!); exit(2)
}
var bundleOf: [Int: String] = [:]
func bundle(_ pid: Int) -> String {
    if let b = bundleOf[pid] { return b }
    let b = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? ""
    bundleOf[pid] = b; return b
}
func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
var out = ""
for w in list {
    let owner = clean(w[kCGWindowOwnerName as String] as? String ?? "")
    let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
    let title = clean(w[kCGWindowName as String] as? String ?? "")
    let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    var x = 0, y = 0, wd = 0, ht = 0
    if let b = w[kCGWindowBounds as String] as? [String: Any] {
        x = Int(((b["X"] as? NSNumber)?.doubleValue ?? 0).rounded()); y = Int(((b["Y"] as? NSNumber)?.doubleValue ?? 0).rounded())
        wd = Int(((b["Width"] as? NSNumber)?.doubleValue ?? 0).rounded()); ht = Int(((b["Height"] as? NSNumber)?.doubleValue ?? 0).rounded())
    }
    out += "\(owner)\t\(pid)\t\(title)\t\(x),\(y),\(wd),\(ht)\t\(layer)"
    if bundles { out += "\t\(bundle(pid))" }
    out += "\n"
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
