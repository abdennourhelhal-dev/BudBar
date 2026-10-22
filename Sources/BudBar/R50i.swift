/// soundcore R50i (also P20i and P25i), model A3949.
/// Protocol ported from OpenSCQ30 (GPL-3.0): lib/src/devices/soundcore/a3949.rs and common/.
struct R50i: Equatable {
    /// The first four characters of the serial number.
    static let model = "3949"
    static let requestState = Packet(command: [0x01, 0x01])

    var host = 0  // the earbud talking to this Mac: 0 left, 1 right
    var bothConnected = true  // both earbuds are out and linked to each other
    var battery = [0, 0]  // left, right; 0...5, or 255 for an earbud that isn't connected
    var charging = [false, false]
    var systemBattery: Int?  // the 10%-step reading macOS gets over HFP, finer than `battery`
    var firmware = ""
    var serial = ""
    var preset = 0
    var controls: [UInt8] = []  // raw action byte for each `Control`, in that order
    var gamingMode = false
    var touchTone = false

    /// Parses the state packet (01 01).
    init?(state b: [UInt8]) {
        guard b.count >= 73 else { return nil }
        host = Int(b[0])
        bothConnected = b[1] != 0
        battery = [Int(b[2]), Int(b[3])]
        charging = [b[4] != 0, b[5] != 0]
        firmware = String(decoding: b[6..<11], as: UTF8.self)
        serial = String(decoding: b[16..<32], as: UTF8.self)
        preset = Int(b[32]) | Int(b[33]) << 8
        // 34..<44 are the band levels, followed by 11 unknown bytes.
        // Each control is an enabled flag (unused on this model) and an action byte.
        controls = (0..<6).map { b[56 + $0 * 2] }
        gamingMode = b[71] != 0
        touchTone = b[72] != 0
    }

    /// Battery percentage of one earbud, or nil when it isn't connected. The earbuds only report 0–5,
    /// so while both sit on the same level, macOS's single finer reading stands in for both.
    func batteryPercent(_ side: Int) -> Int? {
        let level = battery[side]
        guard level <= 5, bothConnected || side == host else { return nil }
        if let systemBattery, !bothConnected || battery[0] == battery[1] { return systemBattery }
        return level * 20
    }

    /// Applies a status update the earbuds send on their own.
    mutating func apply(_ packet: Packet) {
        let b = packet.body
        switch packet.command {
        case [0x01, 0x02] where b.count >= 2:
            host = Int(b[0])
            bothConnected = b[1] != 0
        case [0x01, 0x03] where b.count >= 2: battery = [Int(b[0]), Int(b[1])]
        case [0x01, 0x04] where b.count >= 2: charging = [b[0] != 0, b[1] != 0]
        case [0x01, 0x11] where b.count >= 1: gamingMode = b[0] != 0
        default: break
        }
    }

    mutating func setGamingMode(_ on: Bool) -> Packet {
        gamingMode = on
        return Packet(command: [0x01, 0x87], body: [on ? 1 : 0])
    }

    mutating func setTouchTone(_ on: Bool) -> Packet {
        touchTone = on
        return Packet(command: [0x01, 0x83], body: [on ? 1 : 0])
    }

    // MARK: Touch controls

    enum Control: Int, CaseIterable, Identifiable {
        case leftTap, rightTap, leftDoubleTap, rightDoubleTap, leftHold, rightHold

        var id: Int { rawValue }
        var side: UInt8 { UInt8(rawValue % 2) }
        var buttonID: UInt8 { [2, 0, 1][rawValue / 2] }
        var title: String { ["Tap", "Double tap", "Hold"][rawValue / 2] }
    }

    enum Action: UInt8, CaseIterable, Identifiable {
        case volumeUp = 0, volumeDown = 1, previous = 2, next = 3, assistant = 5, playPause = 6

        var id: UInt8 { rawValue }
        var title: String {
            switch self {
            case .volumeUp: "Volume up"
            case .volumeDown: "Volume down"
            case .previous: "Previous track"
            case .next: "Next track"
            case .assistant: "Voice assistant"
            case .playPause: "Play/Pause"
            }
        }
    }

    /// A control's action, or nil when it's off. The low nibble applies while both earbuds are connected,
    /// the high nibble while only one is.
    func action(_ control: Control) -> Action? {
        guard controls.indices.contains(control.rawValue) else { return nil }
        let byte = controls[control.rawValue]
        return Action(rawValue: bothConnected ? byte & 0x0f : byte >> 4)
    }

    /// The earbuds only change the action for the mode in use (one earbud or both) and ignore the other
    /// nibble, so the action goes in both and only the current mode's nibble changes here.
    mutating func set(_ control: Control, _ action: Action?) -> Packet? {
        guard controls.indices.contains(control.rawValue) else { return nil }
        let id = action?.rawValue ?? 0x0f
        let old = controls[control.rawValue]
        controls[control.rawValue] = bothConnected ? (old & 0xf0) | id : (id << 4) | (old & 0x0f)
        return Packet(command: [0x04, 0x81], body: [control.side, control.buttonID, (id << 4) | id])
    }

    // MARK: Equalizer

    struct Preset: Identifiable {
        let id: Int
        let name: String
        let bands: [Int]  // eight bands in tenths of a dB
    }

    /// OpenSCQ30 common_settings_type_2 (common/modules/equalizer.rs).
    static let presets = [
        Preset(id: 0, name: "Soundcore Signature", bands: [0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(id: 1, name: "Acoustic", bands: [40, 10, 20, 20, 40, 40, 40, 20]),
        Preset(id: 2, name: "Bass Booster", bands: [40, 30, 10, 0, 0, 0, 0, 0]),
        Preset(id: 3, name: "Bass Reducer", bands: [-40, -30, -10, 0, 0, 0, 0, 0]),
        Preset(id: 4, name: "Classical", bands: [30, 30, -20, -20, 0, 20, 30, 40]),
        Preset(id: 5, name: "Podcast", bands: [-30, 20, 40, 40, 30, 20, 0, -20]),
        Preset(id: 6, name: "Dance", bands: [20, -30, -10, 10, 20, 20, 10, -30]),
        Preset(id: 7, name: "Deep", bands: [20, 10, 30, 30, 20, -20, -40, -50]),
        Preset(id: 8, name: "Electronic", bands: [30, 20, -20, 20, 10, 20, 30, 30]),
        Preset(id: 9, name: "Flat", bands: [-20, -20, -10, 0, 0, 0, -20, -20]),
        Preset(id: 10, name: "Hip-Hop", bands: [20, 30, -10, -10, 20, -10, 20, 30]),
        Preset(id: 11, name: "Jazz", bands: [20, 20, -20, -20, 0, 20, 30, 40]),
        Preset(id: 12, name: "Latin", bands: [0, 0, -20, -20, -20, 0, 30, 50]),
        Preset(id: 13, name: "Lounge", bands: [-10, 20, 40, 30, 0, -20, 20, 10]),
        Preset(id: 14, name: "Piano", bands: [0, 30, 30, 20, 40, 50, 30, 40]),
        Preset(id: 15, name: "Pop", bands: [-10, 10, 30, 30, 10, -10, -20, -30]),
        Preset(id: 16, name: "R&B", bands: [60, 20, -20, -20, 20, 30, 30, 40]),
        Preset(id: 17, name: "Rock", bands: [30, 20, -10, -10, 10, 30, 40, 50]),
        Preset(id: 18, name: "Small Speakers", bands: [40, 30, 10, 0, -20, -30, -40, -40]),
        Preset(id: 19, name: "Spoken Word", bands: [-30, -20, 10, 20, 20, 10, 0, -30]),
        Preset(id: 20, name: "Treble Booster", bands: [-20, -20, -20, -10, 10, 20, 20, 40]),
        Preset(id: 21, name: "Treble Reducer", bands: [0, 0, 0, -20, -30, -40, -40, -60]),
    ]

    /// Sends the preset's bands, then the same bands with DRC applied (common/packet/outbound/set_equalizer_with_drc.rs).
    /// Two more bands follow the eight adjustable ones and are fixed on this model.
    mutating func setPreset(_ id: Int) -> Packet? {
        guard let preset = Self.presets.first(where: { $0.id == id }) else { return nil }
        self.preset = id
        let fixed = [0, -120]
        let body = [UInt8(id & 0xff), UInt8(id >> 8)]
            + (preset.bands + fixed).map(Self.byte)
            + (Self.drc(preset.bands) + fixed).map(Self.byte)
        return Packet(command: [0x02, 0x83], body: body)
    }

    /// A band adjustment (tenths of a dB, -12.0 to +13.4) as its wire byte.
    static func byte(_ adjustment: Int) -> UInt8 {
        UInt8(min(max(adjustment, -120), 134) + 120)
    }

    /// The dynamic range compensation the Soundcore app applies before sending an EQ, ported from OpenSCQ30's
    /// VolumeAdjustments::apply_drc (common/structures/volume_adjustments.rs). Eight bands in, eight out.
    static func drc(_ bands: [Int]) -> [Int] {
        let a = bands.map { Double($0) / 10 }
        let s = 0.85, l = 0.95
        let c: [[Double]] = [
            [1.26, -0.71 * s, 0.177, -0.0494, 0.0345, -0.0197, 0.0075, -0.00217],
            [-0.71 * s, 1.73 * l, 0, 0.204, -0.068, 0.045, -0.0235, 0.0075],
            [0.177, -0.81 * s, 1.73 * l, -0.81 * s, 0.208, -0.07, 0.045, -0.0197],
            [-0.0494, 0.204, 0, 1.73 * l, -0.82 * s, 0.208, -0.068, 0.0345],
            [0.0345, -0.068, 0.208, -0.82 * s, 1.73 * l, 0, 0.204, -0.0494],
            [-0.0197, 0.045, -0.07, 0.208, -0.81 * s, 1.73 * l, -0.81 * s, 0.177],
            [0.0075, -0.0235, 0.045, -0.068, 0.204, 0, 1.83 * l, -0.71 * s],
            [-0.00217, 0.0075, -0.0197, 0.0345, -0.0494, 0.177, -0.71 * s, 1.5],
        ]
        // Bands 1 and 3 subtract a scaled band 2 instead of weighting it; bands 4 and 6 do the same with band 5.
        let lows = a[2] * 0.81 * s
        let highs = a[5] * 0.81 * s
        return (0..<8).map { i in
            var sum = 0.0
            for j in 0..<8 {
                if (i == 1 || i == 3) && j == 2 {
                    sum -= lows
                } else if (i == 4 || i == 6) && j == 5 {
                    sum -= highs
                } else {
                    sum += a[j] * c[i][j]
                }
            }
            return Int((sum / 10 * 10).rounded())
        }
    }
}
