import CoreAudio
import Foundation

// MARK: - CONTRACT (InputDeviceObserver)
//
// GUARANTEES
// - Reads default input device id and `DeviceIsRunningSomewhere` without opening AVAudioEngine.
// - Optional listener fires when default input device id changes.
//
// DOES NOT
// - Start capture or identify which application owns the device.

/// Core Audio helpers for default input device and IO activity.
public enum InputDeviceObserver {
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    public static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanaged) == noErr,
              let cf = unmanaged?.takeRetainedValue() else {
            return "device \(deviceID)"
        }
        return cf as String
    }

    /// True when some client has active IO on this device (device-level, not per-app).
    public static func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    public static func isDefaultInputBusy() -> Bool {
        guard let id = defaultInputDeviceID() else { return false }
        return isRunningSomewhere(id)
    }

    /// Registers a callback on the main dispatch queue when default input changes. Returns remove function.
    public static func addDefaultInputChangeHandler(
        _ handler: @escaping @Sendable () -> Void
    ) -> () -> Void {
        let box = ListenerBox(handler: handler)
        let context = Unmanaged.passRetained(box).toOpaque()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputListenerProc,
            context
        )

        guard status == noErr else {
            Unmanaged<ListenerBox>.fromOpaque(context).release()
            return {}
        }

        return {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                defaultInputListenerProc,
                context
            )
            Unmanaged<ListenerBox>.fromOpaque(context).release()
        }
    }
}

private final class ListenerBox: @unchecked Sendable {
    let handler: () -> Void
    init(handler: @escaping @Sendable () -> Void) { self.handler = handler }
}

private let defaultInputListenerProc: AudioObjectPropertyListenerProc = { _, _, _, context in
    guard let context else { return noErr }
    let box = Unmanaged<ListenerBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.handler() }
    return noErr
}