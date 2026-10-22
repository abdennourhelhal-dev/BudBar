import ServiceManagement
import SwiftUI
@preconcurrency import IOBluetooth

@main
struct BudBarApp: App {
    @State private var buds = Buds()

    var body: some Scene {
        MenuBarExtra {
            PanelView(buds: buds)
        } label: {
            MenuBarLabel(buds: buds)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The earbuds this app manages and their latest known settings.
@MainActor @Observable
final class Buds {
    enum Status: Equatable {
        case notPaired, disconnected, connecting, connected
        case unsupported(model: String)
    }

    private(set) var status = Status.notPaired
    private(set) var name = "Earbuds"
    private(set) var state: R50i?
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var volumeSteps = max(UserDefaults.standard.integer(forKey: "volumeSteps"), 1)

    @ObservationIgnored private var device: IOBluetoothDevice?
    @ObservationIgnored private let link = Link()
    @ObservationIgnored private let popup = ConnectPopup()
    @ObservationIgnored private let volumeBoost = VolumeBoost()
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var batteryEstimate = BatteryEstimate(
        drain: UserDefaults.standard.object(forKey: "batteryDrain") as? Double ?? 10.0 / 3600)

    init() {
        link.onDevice = { [unowned self] in attach($0) }
        link.onPacket = { [unowned self] in handle($0) }
        link.onClose = { [unowned self] in
            state = nil
            status = .disconnected
            batteryEstimate = BatteryEstimate(drain: batteryEstimate.drain)  // they may charge before coming back
        }
        link.start()
        if let device = Link.pairedDevice() {
            self.device = device
            name = device.name ?? name
            if device.isConnected() { attach(device) } else { status = .disconnected }
        }
        updateVolumeBoost()
    }

    func setPreset(_ id: Int) { change { $0.setPreset(id) } }
    func set(_ control: R50i.Control, _ action: R50i.Action?) { change { $0.set(control, action) } }
    func setGamingMode(_ on: Bool) { change { $0.setGamingMode(on) } }
    func setTouchTone(_ on: Bool) { change { $0.setTouchTone(on) } }

    /// Pulls the earbuds over to this Mac, or retries the data channel if they're already here.
    func connect() {
        guard let device = device ?? Link.pairedDevice() else { return }
        if device.isConnected() { attach(device) } else { link.connect(device) }
    }

    func disconnect() {
        device?.closeConnection()
    }

    func setOpensAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setVolumeSteps(_ steps: Int) {
        volumeSteps = steps
        UserDefaults.standard.set(steps, forKey: "volumeSteps")
        updateVolumeBoost()
    }

    private func updateVolumeBoost() {
        volumeBoost.steps = volumeSteps
        if volumeSteps > 1, device != nil { volumeBoost.start(product: name) }
    }

    private func change(_ update: (inout R50i) -> Packet?) {
        guard var state, let packet = update(&state) else { return }
        self.state = state
        link.send(packet)
    }

    private func attach(_ device: IOBluetoothDevice) {
        guard status != .connecting, status != .connected else { return }
        self.device = device
        name = device.name ?? name
        status = .connecting
        updateVolumeBoost()
        // The earbuds bring up their audio profiles first and refuse the data channel until they're done.
        Task {
            for delay in [1, 2, 4] {
                try? await Task.sleep(for: .seconds(delay))
                guard status == .connecting, device.isConnected() else { break }
                if link.open(device) {
                    // Right after another app lets go of the channel, the first request can go unanswered.
                    link.send(R50i.requestState)
                    try? await Task.sleep(for: .seconds(3))
                    if status == .connecting { link.send(R50i.requestState) }
                    return
                }
            }
            if status == .connecting { status = .disconnected }
        }
    }

    private func handle(_ packet: Packet) {
        guard packet.command == R50i.requestState.command else {
            state?.apply(packet)
            return
        }
        guard var new = R50i(state: packet.body) else { return }
        guard new.serial.hasPrefix(R50i.model) else {
            status = .unsupported(model: String(new.serial.prefix(4)))
            return
        }
        if let reading = device.flatMap(Self.systemBattery) {
            new.systemBattery = batteryEstimate.update(reading)
            UserDefaults.standard.set(batteryEstimate.drain, forKey: "batteryDrain")
        }
        if state == nil {
            popup.show(name: name, state: new)
            poll()
        }
        state = new
        status = .connected
    }

    /// Refreshes the state every minute: the earbuds never pushed a battery change while we watched.
    private func poll() {
        polling?.cancel()
        polling = Task {
            while (try? await Task.sleep(for: .seconds(60))) != nil, status == .connected {
                link.send(R50i.requestState)
            }
        }
    }

    /// The battery macOS reads from the earbuds over HFP, in 10% steps. It's private IOBluetooth API,
    /// so check it exists before asking; 0 means macOS has no reading.
    private static func systemBattery(_ device: IOBluetoothDevice) -> Int? {
        guard device.responds(to: Selector(("batteryPercentSingle"))),
            let percent = device.value(forKey: "batteryPercentSingle") as? Int, percent > 0
        else { return nil }
        return percent
    }
}
