import Foundation

/// Fills in the 1% steps between macOS's 10% battery readings. The earbuds report 0–9 over HFP, so a reading
/// drops right as the battery crosses a boundary (90 → 80 at about 89.5%). From there it keeps falling at the
/// rate measured between the last two drops, but never leaves the step macOS reports. Until it has seen a
/// drop it knows no more than macOS, so it shows the same number.
struct BatteryEstimate {
    var drain: Double  // percent per second
    private var reading: Int?
    private var droppedAt: Date?

    /// The default drain is the R50i's 10 hours of playback per charge.
    init(drain: Double = 10.0 / 3600) {
        self.drain = drain
    }

    mutating func update(_ newReading: Int, at now: Date = .now) -> Int {
        if let reading, newReading < reading {
            if let droppedAt {
                // Keep a measured rate within what earbuds plausibly do: 2–60% an hour.
                let measured = Double(reading - newReading) / now.timeIntervalSince(droppedAt)
                drain = min(max(measured, 2.0 / 3600), 60.0 / 3600)
            }
            droppedAt = now
        } else if let reading, newReading > reading {
            droppedAt = nil  // charged in between, so the last drop says nothing about now
        }
        reading = newReading
        guard let droppedAt else { return newReading }
        let estimate = Double(newReading) + 9.5 - drain * now.timeIntervalSince(droppedAt)
        return Int(min(max(estimate, Double(newReading)), Double(newReading + 9)).rounded())
    }
}
