import AVFoundation

// Reports the current output route and the HRTF target Thrum will pick for it.
//
//   swiftc -O -o /tmp/thrumroute Shared/AudioRoute.swift Tools/route/main.swift && /tmp/thrumroute
//
// Worth having as a tool rather than a print statement because the mapping is
// the whole point of AudioRoute and it is only checkable by changing the output
// in Control Centre and running it again. Measured this way: built-in speakers
// 'bltn' → builtInSpeakers(2), an AirPlay speaker 'airp' → externalSpeakers(3).
// Before this existed the environment node was pinned to headphones(1) for all
// of them.

func label(_ t: AVAudioEnvironmentOutputType) -> String {
    switch t {
    case .auto:            return "auto(0)"
    case .headphones:      return "headphones(1)"
    case .builtInSpeakers: return "builtInSpeakers(2)"
    case .externalSpeakers: return "externalSpeakers(3)"
    @unknown default:      return "?(\(t.rawValue))"
    }
}

MainActor.assumeIsolated {
    let route = AudioRoute()
    print("Route:    \"\(route.name)\"")
    print("Kind:     \(route.kind)")
    print("HRTF:     \(label(route.environmentOutputType))")
    print("Is room:  \(route.isRoom)")
    print("Latency:  \(route.latencyWarning ?? "—")")
}
