import CoreMIDI
import Foundation

// Listens on the Launchpad X MIDI port and decodes every message the way
// Thrum's LaunchpadController does, so the programmer-mode geometry can be
// checked against real hardware. Multiple CoreMIDI clients can share a source,
// so this runs alongside Thrum without stealing input.
//
//   midimon [seconds]

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 30 : 30

func endpointName(_ ep: MIDIEndpointRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? ""
}

/// Thrum's interpretation of a programmer-mode grid note.
func describe(_ note: Int) -> String {
    let row = note / 10, col = note % 10
    guard (1...8).contains(col) else { return "note \(note) — off-grid (col \(col))" }
    switch row {
    case 5...8:
        let pad = (row - 5) * 8 + (col - 1)
        let octave = row - 5
        return "TONE pad \(pad)  register +\(octave), degree \(col - 1)"
    case 4: return "TIMBRE \(col) of 8"
    case 3: return "TEMPERAMENT \(col) of 8"
    case 2:
        let names = ["SITAR", "SWELL", "BLOOM", "AIR", "DRIFT", "WIDE", "SAT", "LET GO"]
        return "MODIFIER \(names[col - 1])"
    case 1: return "MODE \(col) of the current bank"
    default: return "note \(note) — off-grid (row \(row))"
    }
}

func describeCC(_ cc: Int) -> String {
    let top = [91: "KEY ◀", 92: "KEY ▶", 93: "OCT ◀", 94: "OCT ▶",
               95: "MODE BANK", 96: "TIMBRE", 97: "TEMPERAMENT", 98: "PANIC"]
    if let t = top[cc] { return "TOP ROW \(t)" }
    let ladder = [89, 79, 69, 59, 49, 39, 29, 19]
    if let step = ladder.firstIndex(of: cc) {
        return "LEVEL LADDER step \(step) → output \(Int(Double(7 - step) / 7.0 * 100))%"
    }
    if cc == 99 { return "LOGO" }
    return "CC \(cc) — unmapped"
}

var client = MIDIClientRef()
var port = MIDIPortRef()
var seenNotes = Set<Int>()
var seenCCs = Set<Int>()
var aftertouchCount = 0
let lock = NSLock()

MIDIClientCreateWithBlock("ThrumMon" as CFString, &client, nil)
MIDIInputPortCreateWithBlock(client, "ThrumMonIn" as CFString, &port) { list, _ in
    var packet = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let length = Int(packet.length)
        withUnsafeBytes(of: packet.data) { raw in
            var i = 0
            while i + 2 < min(length, raw.count) {
                let status = raw[i] & 0xF0
                let d1 = Int(raw[i + 1]), d2 = Int(raw[i + 2])
                lock.lock()
                switch status {
                case 0x90 where d2 > 0:
                    seenNotes.insert(d1)
                    print("  DOWN  \(describe(d1))   vel \(d2)")
                case 0x80, 0x90:
                    print("  UP    \(describe(d1))")
                case 0xA0:
                    aftertouchCount += 1
                    if aftertouchCount % 12 == 1 {
                        print("  PRESS \(describe(d1))   \(Int(Double(d2) / 127.0 * 100))%")
                    }
                case 0xB0:
                    if d2 > 0 { seenCCs.insert(d1); print("  DOWN  \(describeCC(d1))") }
                default:
                    if raw[i] >= 0xF0 { i = length }
                }
                lock.unlock()
                if status >= 0x80 && status < 0xF0 { i += 3 } else { i += 1 }
            }
        }
        packet = MIDIPacketNext(&packet).pointee
    }
}

var found = false
for i in 0..<MIDIGetNumberOfSources() {
    let ep = MIDIGetSource(i)
    let n = endpointName(ep)
    if n.localizedCaseInsensitiveContains("Launchpad X") && n.localizedCaseInsensitiveContains("MIDI") {
        MIDIPortConnectSource(port, ep, nil)
        print("listening on \"\(n)\" for \(Int(seconds))s — press some pads\n")
        found = true
        break
    }
}
guard found else {
    print("no Launchpad X MIDI port found")
    exit(1)
}

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: deadline)
}

lock.lock()
print("\n--- summary ---")
print("distinct grid notes seen: \(seenNotes.count)  \(seenNotes.sorted())")
print("distinct CCs seen:        \(seenCCs.count)  \(seenCCs.sorted())")
print("aftertouch messages:      \(aftertouchCount)")
let regions = Dictionary(grouping: seenNotes) { note -> String in
    switch note / 10 {
    case 5...8: return "tone block"
    case 4: return "timbre row"
    case 3: return "temperament row"
    case 2: return "modifier row"
    case 1: return "mode row"
    default: return "off-grid"
    }
}
for (k, v) in regions.sorted(by: { $0.key < $1.key }) {
    print("  \(k): \(v.count) pad(s)")
}
lock.unlock()
