import Foundation
import CoreMIDI
import AppKit

/// Shared CoreMIDI plumbing for Thrum's control surfaces: find a device by
/// name, keep the connection alive across hot-plugs, send bytes, and parse
/// incoming note/CC/aftertouch into a simple callback.
class MIDISurface {
    struct Message {
        enum Kind { case noteOn, noteOff, aftertouch, control }
        let kind: Kind
        let data1: Int
        let data2: Int
    }

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private(set) var source: MIDIEndpointRef = 0
    private(set) var dest: MIDIEndpointRef = 0

    /// The substrings we search for. A device family needs several: Novation
    /// names the Launch Control XL 3's ports "LCXL3 1 MIDI Out", nothing like
    /// the "Launch Control XL" its older siblings report.
    let deviceNames: [String]
    /// The full display name of whatever actually connected — the generations
    /// need different CC maps, and only this can tell them apart.
    private(set) var connectedName: String = ""
    private let portHint: String?
    private let onMessage: ([Message]) -> Void
    private let onConnect: (Bool) -> Void

    var isConnected: Bool { source != 0 && dest != 0 }

    init(clientName: String, deviceNames: [String], portHint: String? = nil,
         onConnect: @escaping (Bool) -> Void,
         onMessage: @escaping ([Message]) -> Void) {
        self.deviceNames = deviceNames
        self.portHint = portHint
        self.onMessage = onMessage
        self.onConnect = onConnect

        MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.scan() }
            }
        }
        MIDIInputPortCreateWithBlock(client, "\(clientName)In" as CFString, &inPort) { [weak self] packetList, _ in
            self?.parse(packetList)
        }
        MIDIOutputPortCreate(client, "\(clientName)Out" as CFString, &outPort)
        scan()
    }

    /// Called whenever a device appears. Subclasses set the device up here.
    func didConnect() {}
    /// Called just before we drop a device (or at teardown).
    func willDisconnect() {}

    func scan() {
        let foundSource = pick((0..<MIDIGetNumberOfSources()).map(MIDIGetSource))
        let foundDest = pick((0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination))
        guard foundSource != source || foundDest != dest else { return }
        if source != 0 {
            willDisconnect()
            MIDIPortDisconnectSource(inPort, source)
        }
        source = foundSource
        dest = foundDest
        guard source != 0, dest != 0 else {
            connectedName = ""
            onConnect(false)
            return
        }
        connectedName = Self.displayName(source) ?? deviceNames[0]
        MIDIPortConnectSource(inPort, source, nil)
        onConnect(true)
        didConnect()
    }

    private static func displayName(_ ep: MIDIEndpointRef) -> String? {
        var unmanaged: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &unmanaged)
        return unmanaged?.takeRetainedValue() as String?
    }

    /// The best endpoint of the ones attached, or 0 for none of them.
    ///
    /// The port hint is a preference, not a requirement: the Launchpad X and the
    /// Launch Control XL 3 both expose a DAW pair alongside the MIDI pair we
    /// want, but the older Launch Controls expose one unsuffixed pair, and
    /// insisting on the hint would leave those unfindable.
    private func pick(_ endpoints: [MIDIEndpointRef]) -> MIDIEndpointRef {
        var fallback: MIDIEndpointRef = 0
        for ep in endpoints {
            guard let name = Self.displayName(ep) else { continue }
            guard deviceNames.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { continue }
            guard let hint = portHint else { return ep }
            if name.localizedCaseInsensitiveContains(hint) { return ep }
            if fallback == 0 { fallback = ep }
        }
        return fallback
    }

    func send(_ bytes: [UInt8]) {
        guard dest != 0, bytes.count < 250 else { return }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
        MIDISend(outPort, dest, &list)
    }

    private func parse(_ packetList: UnsafePointer<MIDIPacketList>) {
        var messages: [Message] = []
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let length = Int(packet.length)
            withUnsafeBytes(of: packet.data) { raw in
                var i = 0
                while i + 2 < min(length, raw.count) {
                    let status = raw[i] & 0xF0
                    let d1 = Int(raw[i + 1])
                    let d2 = Int(raw[i + 2])
                    switch status {
                    case 0x90:
                        messages.append(Message(kind: d2 > 0 ? .noteOn : .noteOff, data1: d1, data2: d2))
                        i += 3
                    case 0x80:
                        messages.append(Message(kind: .noteOff, data1: d1, data2: d2))
                        i += 3
                    case 0xA0:
                        messages.append(Message(kind: .aftertouch, data1: d1, data2: d2))
                        i += 3
                    case 0xB0:
                        messages.append(Message(kind: .control, data1: d1, data2: d2))
                        i += 3
                    default:
                        if raw[i] >= 0xF0 { i = length } else { i += 1 }
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onMessage(messages) }
    }

    /// 0–127 RGB triple from a hue/brightness pair, matching the Launchpad's range.
    static func rgb(hue: Double, brightness: Double, saturation: Double = 0.85) -> (UInt8, UInt8, UInt8) {
        let b = min(max(brightness, 0), 1)
        let c = NSColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1.0)),
                        saturation: CGFloat(saturation), brightness: CGFloat(b), alpha: 1)
        return (UInt8(max(0, min(127, c.redComponent * 127))),
                UInt8(max(0, min(127, c.greenComponent * 127))),
                UInt8(max(0, min(127, c.blueComponent * 127))))
    }
}
