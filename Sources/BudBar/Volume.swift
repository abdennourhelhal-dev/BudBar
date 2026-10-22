import AudioToolbox
import Foundation
import IOKit.hid

/// The earbuds send one volume key press per long press and nothing when the finger lifts, so a hold
/// can't repeat. Instead, this turns each volume press from the earbuds into several quick steps.
@MainActor
final class VolumeBoost {
    var steps = 1  // volume steps per press; 1 leaves the earbuds' presses alone
    private var manager: IOHIDManager?

    /// Starts listening to the earbuds' media keys, which needs Input Monitoring permission.
    func start(product: String) {
        guard manager == nil else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Matching on the product name alone matches every HID device, so pin the transport too.
        let matching = [kIOHIDProductKey: product, kIOHIDTransportKey: "Bluetooth"]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(
            manager,
            { context, _, _, value in
                MainActor.assumeIsolated {
                    Unmanaged<VolumeBoost>.fromOpaque(context!).takeUnretainedValue().handle(value)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard steps > 1, Int(IOHIDElementGetUsagePage(element)) == kHIDPage_Consumer,
            IOHIDValueGetIntegerValue(value) == 1
        else { return }
        let direction: Float32
        switch Int(IOHIDElementGetUsage(element)) {
        case kHIDUsage_Csmr_VolumeIncrement: direction = 1
        case kHIDUsage_Csmr_VolumeDecrement: direction = -1
        default: return
        }
        // macOS already took the first step for this press.
        Task {
            for _ in 1..<steps {
                try? await Task.sleep(for: .milliseconds(90))
                Self.nudgeVolume(by: direction)
            }
        }
    }

    /// Moves the default output's volume one sixteenth, the same step as the volume keys.
    private static func nudgeVolume(by direction: Float32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
            == noErr
        else { return }
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        address.mScope = kAudioDevicePropertyScopeOutput
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return }
        volume = min(max(((volume * 16).rounded() + direction) / 16, 0), 1)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume)
    }
}
