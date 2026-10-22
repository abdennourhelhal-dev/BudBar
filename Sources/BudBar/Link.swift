import Foundation
@preconcurrency import IOBluetooth

/// One Soundcore protocol packet: a two-byte command and its body.
struct Packet: Equatable {
    var command: [UInt8]
    var body: [UInt8] = []
}

/// Soundcore wire framing, ported from OpenSCQ30 (lib/src/devices/soundcore/common/packet.rs):
/// direction prefix, command, little-endian total length, body, then a one-byte additive checksum.
enum Framing {
    static let outbound: [UInt8] = [0x08, 0xee, 0x00, 0x00, 0x00]
    static let inbound: [UInt8] = [0x09, 0xff, 0x00, 0x00, 0x01]
    static let headerSize = 9
    static let maxLength = 1024

    static func encode(_ packet: Packet) -> [UInt8] {
        let length = headerSize + packet.body.count + 1
        var bytes = outbound + packet.command + [UInt8(length & 0xff), UInt8(length >> 8)] + packet.body
        bytes.append(checksum(bytes))
        return bytes
    }

    /// Removes every complete inbound packet from the front of `buffer`, leaving a trailing partial one.
    /// Bytes that can't start a packet, and packets with a bad checksum, are dropped.
    static func decode(_ buffer: inout [UInt8]) -> [Packet] {
        var packets: [Packet] = []
        while buffer.count >= headerSize {
            let length = Int(buffer[7]) | Int(buffer[8]) << 8
            guard buffer.starts(with: inbound), (headerSize + 1...maxLength).contains(length) else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }
            let frame = Array(buffer.prefix(length))
            buffer.removeFirst(length)
            if checksum(frame.dropLast()) == frame.last {
                packets.append(Packet(command: Array(frame[5..<7]), body: Array(frame[headerSize..<length - 1])))
            }
        }
        return packets
    }

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0, &+)
    }
}

/// Watches for Soundcore earbuds connecting to this Mac and talks to them over their vendor RFCOMM channel.
@MainActor
final class Link: NSObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    var onDevice: (IOBluetoothDevice) -> Void = { _ in }
    var onPacket: (Packet) -> Void = { _ in }
    var onClose: () -> Void = {}

    private var channel: IOBluetoothRFCOMMChannel?
    private var buffer: [UInt8] = []
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?

    /// The paired Soundcore earbuds, preferring ones that are connected right now.
    static func pairedDevice() -> IOBluetoothDevice? {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter(isSoundcore)
        return devices.first { $0.isConnected() } ?? devices.first
    }

    static func isSoundcore(_ device: IOBluetoothDevice) -> Bool {
        device.name?.lowercased().hasPrefix("soundcore") == true
    }

    func start() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    func open(_ device: IOBluetoothDevice) -> Bool {
        if channel != nil { return true }
        guard let id = Self.channelID(device) else { return false }
        var newChannel: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelSync(&newChannel, withChannelID: id, delegate: self) == kIOReturnSuccess
        else { return false }
        channel = newChannel
        disconnectNotification = device.register(
            forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        return true
    }

    func send(_ packet: Packet) {
        var bytes = Framing.encode(packet)
        _ = channel?.writeSync(&bytes, length: UInt16(bytes.count))
    }

    func close() {
        disconnectNotification?.unregister()
        disconnectNotification = nil
        _ = channel?.close()
        channel = nil
        buffer.removeAll()
    }

    /// Brings the earbuds over to this Mac; the connect notification fires once they're here.
    func connect(_ device: IOBluetoothDevice) {
        device.openConnection(self)
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {}

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if Self.isSoundcore(device) { onDevice(device) }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        close()
        onClose()
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int
    ) {
        buffer += UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        Framing.decode(&buffer).forEach(onPacket)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        close()
        onClose()
    }

    /// Soundcore's vendor service is 0cf12d31-fac3-4553-bd80-d6832e7xxxxx; older models use Serial Port instead.
    /// (OpenSCQ30 lib/src/devices/soundcore.rs)
    private static func channelID(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let vendor: [UInt8] = [0x0c, 0xf1, 0x2d, 0x31, 0xfa, 0xc3, 0x45, 0x53, 0xbd, 0x80, 0xd6, 0x83, 0x2e]
        let serialPort: [UInt8] = [0, 0, 0x11, 0x01, 0, 0, 0x10, 0, 0x80, 0, 0, 0x80, 0x5f, 0x9b, 0x34, 0xfb]
        let records = device.services as? [IOBluetoothSDPServiceRecord] ?? []
        let isVendor = { (uuid: [UInt8]) in uuid.starts(with: vendor) && uuid[13] & 0xf0 == 0x70 }
        let record = records.first { serviceClasses($0).contains(where: isVendor) }
            ?? records.first { serviceClasses($0).contains(serialPort) }
        var id: BluetoothRFCOMMChannelID = 0
        guard record?.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return nil }
        return id
    }

    /// The record's service class UUIDs as 16-byte values. Some earbuds put a bare UUID here instead of a list.
    private static func serviceClasses(_ record: IOBluetoothSDPServiceRecord) -> [[UInt8]] {
        let attribute = BluetoothSDPServiceAttributeID(kBluetoothSDPAttributeIdentifierServiceClassIDList.rawValue)
        guard let element = record.getAttributeDataElement(attribute) else { return [] }
        let elements = element.getUUIDValue() != nil
            ? [element] : element.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
        return elements.compactMap { $0.getUUIDValue()?.getWithLength(16).map { [UInt8]($0 as Data) } }
    }
}
