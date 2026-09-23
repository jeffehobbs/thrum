import CoreMIDI
import Foundation

// Lists every CoreMIDI source and destination with its display name, so the
// controller's name-matching can be checked against what's actually attached.

func name(_ ep: MIDIEndpointRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "<unnamed>"
}

print("sources (\(MIDIGetNumberOfSources())):")
for i in 0..<MIDIGetNumberOfSources() {
    print("  [\(i)] \(name(MIDIGetSource(i)))")
}
print("destinations (\(MIDIGetNumberOfDestinations())):")
for i in 0..<MIDIGetNumberOfDestinations() {
    print("  [\(i)] \(name(MIDIGetDestination(i)))")
}

// What Thrum's matchers would pick. Mirrors MIDISurface.pick(_:), including
// the port hint being a preference rather than a requirement.
func pick(_ endpoints: [MIDIEndpointRef], _ needles: [String], _ hint: String?) -> String {
    var fallback: String?
    for ep in endpoints {
        let n = name(ep)
        guard needles.contains(where: { n.localizedCaseInsensitiveContains($0) }) else { continue }
        guard let hint else { return n }
        if n.localizedCaseInsensitiveContains(hint) { return n }
        if fallback == nil { fallback = n }
    }
    return fallback ?? "none"
}

let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
for (label, needles, hint) in [("Launchpad", ["Launchpad X", "LPX"], "MIDI"),
                              ("LaunchControl", ["Launch Control", "LCXL", "Launchpad Control XL"], "MIDI")] {
    print("\(label): in=\(pick(sources, needles, hint))  out=\(pick(destinations, needles, hint))")
}
