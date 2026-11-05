// micusers: which processes are using a microphone right now (macOS 14.2+ Core Audio process objects).
// Prints one line per process: pid|bundle id|process name|in|out   (in = recording from a mic, out = playing audio)
//   micusers         only processes with mic input running
//   micusers --all   every process Core Audio knows, with both flags
// Used by director.sh so a Phone, FaceTime or Google Voice window only counts as a call when call audio is live.
// Needs no permission: it reads Core Audio's process list, never the audio itself.
import CoreAudio
import Darwin
import Foundation

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s); var v: UInt32 = 0; var n = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr ? v : 0
}

let all = CommandLine.arguments.contains("--all")
var a = addr(kAudioHardwarePropertyProcessObjectList)
var size: UInt32 = 0
let sys = AudioObjectID(kAudioObjectSystemObject)
guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { FileHandle.standardError.write("micusers: no process list\n".data(using: .utf8)!); exit(2) }
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { exit(2) }
for id in ids {
    let inp = u32(id, kAudioProcessPropertyIsRunningInput), out = u32(id, kAudioProcessPropertyIsRunningOutput)
    if !all && inp == 0 { continue }
    var pa = addr(kAudioProcessPropertyPID); var pid: pid_t = 0; var pn = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(id, &pa, 0, nil, &pn, &pid)
    var ba = addr(kAudioProcessPropertyBundleID); var ref: Unmanaged<CFString>? = nil; var bn = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var bundle = ""
    if AudioObjectGetPropertyData(id, &ba, 0, nil, &bn, &ref) == noErr, let r = ref { bundle = r.takeRetainedValue() as String }
    var buf = [CChar](repeating: 0, count: 256)
    let name = proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "?"
    print("\(pid)|\(bundle)|\(name)|\(inp)|\(out)")
}
