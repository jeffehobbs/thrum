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

    /// The substring we search for.
    let deviceName: String
    /// The full display name of whatever actually connected — "Launch Control XL"
    /// and "Launch Control" need different CC maps, and only this can tell them apart.
    private(set) var connectedName: String = ""
    private let portHint: String?
    private let onMessage: ([Message]) -> Void
    private let onConnect: (Bool) -> Void

    var isConnected: Bool { source != 0 && dest != 0 }

    init(clientName: String, deviceName: String, portHint: String? = nil,
         onConnect: @escaping (Bool) -> Void,
         onMessage: @escaping ([Message]) -> Void) {
        self.deviceName = deviceName
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
        var foundSource: MIDIEndpointRef = 0
        var foundDest: MIDIEndpointRef = 0
        for i in 0..<MIDIGetNumberOfSources() {
            let ep = MIDIGetSource(i)
            if matches(ep) { foundSource = ep; break }
        }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let ep = MIDIGetDestination(i)
            if matches(ep) { foundDest = ep; break }
        }
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
        connectedName = Self.displayName(source) ?? deviceName
        MIDIPortConnectSource(inPort, source, nil)
        onConnect(true)
        didConnect()
    }

    private static func displayName(_ ep: MIDIEndpointRef) -> String? {
        var unmanaged: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &unmanaged)
        return unmanaged?.takeRetainedValue() as String?
    }

    private func matches(_ ep: MIDIEndpointRef) -> Bool {
        guard let name = Self.displayName(ep) else { return false }
        guard name.localizedCaseInsensitiveContains(deviceName) else { return false }
        // The Launchpad X exposes both a DAW and a MIDI port pair; programmer
        // mode traffic lives on the one named "…MIDI".
        if let hint = portHint { return name.localizedCaseInsensitiveContains(hint) }
        return true
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
