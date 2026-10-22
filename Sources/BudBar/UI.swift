import SwiftUI

/// One of the bundled template icons (drawn with Codex) at `height` points, tinted like an SF Symbol.
/// Falls back to an SF Symbol when running outside the app bundle, e.g. with `swift run`.
@MainActor
func icon(_ name: String, height: CGFloat, fallback: String) -> Image {
    guard let source = NSImage(named: name), let image = source.copy() as? NSImage else {
        return Image(systemName: fallback)
    }
    image.size = NSSize(width: height * source.size.width / source.size.height, height: height)
    image.isTemplate = true
    return Image(nsImage: image)
}

struct MenuBarLabel: View {
    let buds: Buds

    var body: some View {
        let levels = [0, 1].compactMap { buds.state?.batteryPercent($0) }
        if let lowest = levels.min() {
            HStack(spacing: 4) {
                icon("buds", height: 16, fallback: "earbuds")
                Text("\(lowest)%")
            }
        } else {
            icon("buds", height: 16, fallback: "earbuds")
        }
    }
}

struct PanelView: View {
    let buds: Buds

    var body: some View {
        VStack(spacing: 0) {
            header.padding()
            if let state = buds.state {
                Form { settings(state) }
                    .formStyle(.grouped)
                    .frame(height: 470)
            }
            Divider()
            footer.padding(12)
        }
        .frame(width: 340)
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(buds.name).font(.headline)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let state = buds.state {
                HStack(spacing: 48) {
                    BatteryRing(state: state, side: 0)
                    BatteryRing(state: state, side: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func settings(_ state: R50i) -> some View {
        Section {
            Picker("Equalizer", selection: Binding(get: { state.preset }, set: { buds.setPreset($0) })) {
                ForEach(R50i.presets) { Text($0.name).tag($0.id) }
            }
        }
        controls("Left earbud", side: 0, state)
        controls("Right earbud", side: 1, state)
        Section {
            Picker("Volume steps per press", selection: Binding(get: { buds.volumeSteps }, set: { buds.setVolumeSteps($0) })) {
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
        } footer: {
            Text("The earbuds send a single volume press however long you hold. More steps make each press go further. Needs Input Monitoring permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Gaming mode", isOn: Binding(get: { state.gamingMode }, set: { buds.setGamingMode($0) }))
            Toggle("Touch tone", isOn: Binding(get: { state.touchTone }, set: { buds.setTouchTone($0) }))
        }
        Section {
            LabeledContent("Firmware", value: state.firmware)
            LabeledContent("Serial number", value: state.serial)
        } footer: {
            Text("macOS gets the battery from the earbuds in 10% steps. BudBar estimates the steps in between from how fast it drains.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func controls(_ title: String, side: UInt8, _ state: R50i) -> some View {
        Section {
            ForEach(R50i.Control.allCases.filter { $0.side == side }) { control in
                Picker(control.title, selection: Binding(get: { state.action(control) }, set: { buds.set(control, $0) })) {
                    Text("Off").tag(R50i.Action?.none)
                    ForEach(R50i.Action.allCases) { Text($0.title).tag(R50i.Action?.some($0)) }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if side == 1 {
                Text(state.bothConnected
                    ? "These are for wearing both earbuds. To set what one earbud does on its own, put the other in the case first."
                    : "These are for wearing one earbud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Open at login", isOn: Binding(get: { buds.opensAtLogin }, set: { buds.setOpensAtLogin($0) }))
            HStack {
                switch buds.status {
                case .notPaired: EmptyView()
                case .disconnected: Button("Connect to this Mac") { buds.connect() }
                default: Button("Disconnect") { buds.disconnect() }
                }
                Spacer()
                Button("Quit BudBar") { NSApp.terminate(nil) }
            }
        }
    }

    private var statusText: String {
        switch buds.status {
        case .notPaired: "Pair your earbuds in Bluetooth settings first"
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unsupported(let model): "Model A\(model) isn't supported yet"
        }
    }
}

/// One earbud's battery as a ring around its icon, like the AirPods battery view.
struct BatteryRing: View {
    let state: R50i
    let side: Int
    var size: CGFloat = 52

    var body: some View {
        let percent = state.batteryPercent(side)
        let charging = state.charging[side]
        let color: Color = (percent ?? 0) <= 20 && !charging ? .red : .green
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: size / 14)
                Circle()
                    .trim(from: 0, to: Double(percent ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: size / 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                icon(side == 0 ? "bud-left" : "bud-right", height: size * 0.5,
                     fallback: side == 0 ? "earbud.left" : "earbud.right")
                    .font(.system(size: size * 0.4))
            }
            .frame(width: size, height: size)
            HStack(spacing: 2) {
                if charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                Text(percent.map { "\($0)%" } ?? "–").monospacedDigit()
            }
            .font(.callout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side == 0 ? "Left earbud" : "Right earbud")
        .accessibilityValue(
            percent.map { "\($0) percent\(charging ? ", charging" : "")" } ?? "Not connected")
    }
}

/// The AirPods-style card that fades in near the bottom of the screen when the earbuds connect.
@MainActor
final class ConnectPopup {
    private var panel: NSPanel?

    func show(name: String, state: R50i) {
        panel?.close()
        let card = NSHostingView(rootView: PopupCard(name: name, state: state))
        let size = card.fittingSize
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.maskImage = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
            return true
        }
        card.frame = background.bounds
        background.addSubview(card)

        let panel = NSPanel(
            contentRect: background.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.contentView = background
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 80))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        Task {
            try? await Task.sleep(for: .seconds(4))
            guard self.panel === panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            panel.close()
        }
    }
}

struct PopupCard: View {
    let name: String
    let state: R50i

    var body: some View {
        VStack(spacing: 18) {
            Text(name).font(.title3.weight(.semibold))
            HStack(spacing: 48) {
                BatteryRing(state: state, side: 0, size: 72)
                BatteryRing(state: state, side: 1, size: 72)
            }
            Text("Connected").font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 320)
    }
}
