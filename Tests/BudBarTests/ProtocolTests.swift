import Foundation
import Testing
@testable import BudBar

func hex(_ string: String) -> [UInt8] {
    string.split(separator: " ").map { UInt8($0, radix: 16)! }
}

/// A state packet captured from a real R50i (firmware 19.43), with its serial number replaced.
let capturedState = hex("""
    09 ff 00 00 01 01 01 62 00 01 01 05 05 00 00 31 39 2e 34 33 31 39 2e 34 33 33 39 34 39 30 31 32 33 34 35 36 37 \
    38 39 41 42 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0e 01 ff 01 ff 01 65 01 66 01 32 \
    01 33 ff ff ff 32 00 01 ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 43
    """)

/// State body from OpenSCQ30's r50i_matches_soundcore_app test (lib/src/devices/soundcore/a3949.rs).
let openSCQ30State: [UInt8] = [
    0, 1, 3, 3, 0, 0, 49, 57, 46, 52, 51, 49, 57, 46, 52, 51, 51, 57, 52, 57, 51, 70, 50, 52, 57, 69, 50, 68, 66,
    54, 70, 52, 0, 0, 120, 120, 120, 120, 120, 120, 120, 120, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 14, 1, 246, 1,
    246, 1, 98, 1, 99, 1, 51, 1, 51, 255, 255, 255, 49, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255,
]

@Test func encodesStateRequest() {
    #expect(Framing.encode(R50i.requestState) == hex("08 ee 00 00 00 01 01 0a 00 02"))
}

@Test func decodesPacketsSplitAcrossReads() throws {
    var buffer = Array(capturedState[..<20])
    #expect(Framing.decode(&buffer).isEmpty)
    buffer += capturedState[20...] + [0x09, 0xff]
    let packets = Framing.decode(&buffer)
    #expect(packets.map(\.command) == [[0x01, 0x01]])
    #expect(buffer == [0x09, 0xff])
}

@Test func dropsGarbageAndBadChecksums() {
    var buffer = [0x42] + capturedState
    buffer[buffer.count - 1] ^= 0xff
    #expect(Framing.decode(&buffer).isEmpty)
    #expect(buffer.isEmpty)
}

@Test func parsesCapturedState() throws {
    var buffer = capturedState
    let state = try #require(R50i(state: Framing.decode(&buffer)[0].body))
    #expect(state.battery == [5, 5])
    #expect(state.charging == [false, false])
    #expect(state.batteryPercent(0) == 100)
    #expect(state.firmware == "19.43")
    #expect(state.serial == "39490123456789AB")
    #expect(state.preset == 0)
    #expect(state.action(.leftTap) == nil)
    #expect(state.action(.rightTap) == nil)
    #expect(state.action(.leftDoubleTap) == .assistant)
    #expect(state.action(.rightDoubleTap) == .playPause)
    #expect(state.action(.leftHold) == .previous)
    #expect(state.action(.rightHold) == .next)
    #expect(!state.gamingMode)
    #expect(state.touchTone)
}

@Test func parsesOpenSCQ30Sample() throws {
    let state = try #require(R50i(state: openSCQ30State))
    #expect(state.serial == "39493F249E2DB6F4")
    #expect(state.battery == [3, 3])
    #expect(R50i.Control.allCases.map(state.action) == [.playPause, .playPause, .previous, .next, .next, .next])
    #expect(!state.touchTone)
}

@Test func setsPianoLikeTheSoundcoreApp() throws {
    var state = try #require(R50i(state: openSCQ30State))
    let packet = state.setPreset(14)
    #expect(packet == Packet(command: [0x02, 0x83], body: [
        14, 0, 120, 150, 150, 140, 160, 170, 150, 160, 120, 0, 119, 123, 122, 120, 123, 124, 120, 125, 120, 0,
    ]))
    #expect(state.preset == 14)
}

/// Expected values from OpenSCQ30's it_matches_expected_drc_values, in tenths of a dB.
@Test func appliesDRC() {
    #expect(R50i.drc([-60, 60, 23, 120, 22, -120, -4, 16]) == [-11, 14, -8, 16, 3, -18, 6, 1])
    #expect(R50i.drc(Array(repeating: 120, count: 8)) == [10, 6, 7, 7, 7, 7, 7, 13])
    #expect(R50i.drc(Array(repeating: -120, count: 8)) == [-10, -6, -7, -7, -7, -7, -7, -13])
    #expect(R50i.drc(Array(repeating: 0, count: 8)) == Array(repeating: 0, count: 8))
}

@Test func setsTouchControlsForTheModeInUse() throws {
    var buffer = capturedState
    var state = try #require(R50i(state: Framing.decode(&buffer)[0].body))
    #expect(state.set(.leftTap, .playPause) == Packet(command: [0x04, 0x81], body: [0, 2, 0x66]))
    #expect(state.action(.leftTap) == .playPause)
    #expect(state.set(.rightHold, nil) == Packet(command: [0x04, 0x81], body: [1, 1, 0xff]))
    #expect(state.action(.rightHold) == nil)
    state.bothConnected = false
    #expect(state.action(.leftTap) == nil)  // one-earbud mode keeps its own action
    _ = state.set(.leftTap, .next)
    #expect(state.action(.leftTap) == .next)
    state.bothConnected = true
    #expect(state.action(.leftTap) == .playPause)
}

@Test func prefersMacOSBatteryWhileBothEarbudsAgree() throws {
    var state = try #require(R50i(state: openSCQ30State))
    #expect([state.batteryPercent(0), state.batteryPercent(1)] == [60, 60])
    state.systemBattery = 50
    #expect([state.batteryPercent(0), state.batteryPercent(1)] == [50, 50])
    state.apply(Packet(command: [0x01, 0x03], body: [5, 3]))
    #expect([state.batteryPercent(0), state.batteryPercent(1)] == [100, 60])
    state.apply(Packet(command: [0x01, 0x03], body: [255, 3]))
    #expect(state.batteryPercent(0) == nil)
}

@Test func estimatesBatteryBetweenMacOSSteps() {
    var estimate = BatteryEstimate()
    let start = Date(timeIntervalSince1970: 0)
    #expect(estimate.update(90, at: start) == 90)  // no drop seen yet: nothing more to say than macOS
    #expect(estimate.update(80, at: start + 60) == 89)  // it just crossed 90
    #expect(estimate.update(80, at: start + 60 + 1980) == 84)  // 33 min at 10%/h
    #expect(estimate.update(70, at: start + 3060) == 79)  // the next drop came after 50 min
    #expect(abs(estimate.drain * 3600 - 12) < 0.001)  // so it drains 12%/h
    #expect(estimate.update(70, at: start + 3060 + 1050) == 76)
    #expect(estimate.update(70, at: start + 3060 + 36000) == 70)  // never below what macOS says
    #expect(estimate.update(90, at: start + 50000) == 90)  // charged since: back to the macOS reading
}

@Test func appliesPushedUpdates() throws {
    var state = try #require(R50i(state: openSCQ30State))
    state.apply(Packet(command: [0x01, 0x03], body: [4, 1]))
    state.apply(Packet(command: [0x01, 0x04], body: [0, 1]))
    state.apply(Packet(command: [0x01, 0x02], body: [1, 0]))
    #expect(state.battery == [4, 1])
    #expect(state.charging == [false, true])
    #expect(state.batteryPercent(0) == nil)
    #expect(state.batteryPercent(1) == 20)
}
