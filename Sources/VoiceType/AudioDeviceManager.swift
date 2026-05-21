import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transportType: UInt32

    var menuTitle: String {
        if transportType == kAudioDeviceTransportTypeBuiltIn {
            return "\(name) (Built-in)"
        }
        if transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return "\(name) (Bluetooth)"
        }
        return name
    }
}

enum AudioDeviceManager {
    static func inputDevices() -> [AudioInputDevice] {
        allDevices()
            .filter { hasInputStreams($0) }
            .compactMap { deviceID in
                guard let name = stringProperty(deviceID, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal),
                      let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) else {
                    return nil
                }
                return AudioInputDevice(
                    id: deviceID,
                    uid: uid,
                    name: name,
                    transportType: uint32Property(deviceID, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
                )
            }
            .sorted { left, right in
                if left.transportType == kAudioDeviceTransportTypeBuiltIn && right.transportType != kAudioDeviceTransportTypeBuiltIn {
                    return true
                }
                if right.transportType == kAudioDeviceTransportTypeBuiltIn && left.transportType != kAudioDeviceTransportTypeBuiltIn {
                    return false
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    static func device(for uid: String) -> AudioInputDevice? {
        guard !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= MemoryLayout<AudioStreamID>.size
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func uint32Property(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
