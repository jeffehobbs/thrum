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

// What Thrum's matchers would pick.
for (label, needle, hint) in [("Launchpad", "Launchpad X", "MIDI"),
                              ("LaunchControl", "Launch Control", nil)] {
    var src = "none", dst = "none"
    for i in 0..<MIDIGetNumberOfSources() {
        let n = name(MIDIGetSource(i))
        guard n.localizedCaseInsensitiveContains(needle) else { continue }
        if let h = hint, !n.localizedCaseInsensitiveContains(h) { continue }
        src = n; break
    }
    for i in 0..<MIDIGetNumberOfDestinations() {
        let n = name(MIDIGetDestination(i))
        guard n.localizedCaseInsensitiveContains(needle) else { continue }
        if let h = hint, !n.localizedCaseInsensitiveContains(h) { continue }
        dst = n; break
    }
    print("\(label): in=\(src)  out=\(dst)")
}
