import Foundation
import AVFoundation
import Combine
import CoreAudio

/// What Thrum's sound is currently coming out of, and therefore how the spatial
/// field should be rendered.
///
/// This exists for one reason: `AVAudioEnvironmentNode.outputType` was hardcoded
/// to `.headphones`, so the HRTF stage rendered binaural no matter what it was
/// playing into. Binaural meant for headphones, played over a speaker in a room,
/// comes out hollow and phasey — it spent its effort cancelling ear-to-ear
/// crosstalk that never happens. Every use of Spatial mode over the laptop
/// speakers, an interface feeding a PA, or an AirPlay speaker was wrong.
///
/// Note this deliberately does *not* select the output device. macOS already has
/// a good picker for that in Control Centre, and for AirPlay it is the only one
/// that works: an AirPlay endpoint is not a CoreAudio device until the system has
/// routed to it — measured on macOS 26, five endpoints listed in Control Centre
/// and zero of them present in CoreAudio — and the one public API that speaks
/// AirPlay, `AVRoutePickerView`, routes an `AVPlayer` and cannot carry an
/// `AVAudioEngine`. So: let the system route, and read the result.
@MainActor
public final class AudioRoute: ObservableObject {
    public enum Kind: Equatable {
        case builtInSpeakers
        case headphones
        case airPlay
        case bluetooth
        case external
        case unknown
    }

    @Published public private(set) var name: String = ""
    @Published public private(set) var kind: Kind = .unknown

    /// Set by the host; re-reads the route and pushes the result onto the
    /// environment node.
    public var onChange: (() -> Void)?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init() {
        refresh()
        watch()
    }

    /// How the HRTF stage should render into this route.
    ///
    /// Bluetooth counts as headphones because on this desk it is nearly always
    /// AirPods; a Bluetooth *speaker* is indistinguishable to CoreAudio and wants
    /// the manual override. `.auto` is deliberately unused — on macOS it treats
    /// any wired output as headphones, which is precisely backwards for an
    /// interface feeding a PA.
    public var environmentOutputType: AVAudioEnvironmentOutputType {
        switch kind {
        case .headphones, .bluetooth: return .headphones
        case .builtInSpeakers:        return .builtInSpeakers
        case .airPlay, .external:     return .externalSpeakers
        case .unknown:                return .headphones
        }
    }

    /// True when the route is a room rather than a pair of ears — which is when
    /// head tracking stops meaning anything.
    public var isRoom: Bool {
        switch kind {
        case .builtInSpeakers, .airPlay, .external: return true
        case .headphones, .bluetooth, .unknown:     return false
        }
    }

    /// Non-nil when the route adds enough delay to change how Thrum can be
    /// played, rather than merely how it sounds.
    ///
    /// AirPlay buffers a few hundred milliseconds to about two seconds and it
    /// cannot be clawed back — you cannot pre-delay the rest of an ensemble.
    /// Pulse still holds together internally, since every lane offset comes from
    /// the one clock, but the whole drone lands late against anyone playing in
    /// the room, and the Launchpad lights a pad while the note is still in flight.
    /// Fine for ambient and for Flow running unattended; not fine for playing along.
    public var latencyWarning: String? {
        switch kind {
        case .airPlay:
            return "AirPlay buffers up to ~2 s and it can't be compensated. Fine for ambient and Flow; Pulse and tap tempo won't line up with anyone playing in the room."
        case .bluetooth:
            return "Bluetooth adds ~150–250 ms. Tolerable for drones, noticeable under Pulse."
        default:
            return nil
        }
    }

    // MARK: Reading it

    public func refresh() {
        let id = Self.defaultOutputID()
        let newName = Self.string(id, kAudioObjectPropertyName) ?? ""
        let newKind = Self.kind(of: id, name: newName)
        guard newKind != kind || newName != name else { return }
        name = newName
        kind = newKind
        onChange?()
    }

    /// There is no "headphones" transport type. Wired headphones appear as a
    /// separate `BuiltIn` device named something like "External Headphones",
    /// which is why this leans on the name for that one case.
    private static func kind(of id: AudioDeviceID, name: String) -> Kind {
        guard id != 0 else { return .unknown }
        let looksLikeHeadphones = name.localizedCaseInsensitiveContains("headphone")
        switch number(id, kAudioDevicePropertyTransportType) ?? 0 {
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn:
            return looksLikeHeadphones ? .headphones : .builtInSpeakers
        default:
            return looksLikeHeadphones ? .headphones : .external
        }
    }

    private static func defaultOutputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        guard id != 0 else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func number(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: Watching it

    private func watch() {
        // The default-output property covers the cases that matter: on a modern
        // Mac, plugging headphones in or waking an AirPlay speaker moves the
        // default to a *different* device rather than changing this one. The
        // device-list listener is there for the route appearing and disappearing.
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    public func shutdown() {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }
}
