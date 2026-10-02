import CoreAudio
import Foundation

/// A microphone the Mac can record from.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

/// Lists microphones and picks the one to record from.
/// Bluetooth headphones switch to a low-quality "headset" mode when their microphone is used, and the first
/// moments often arrive silent, which makes Whisper invent phrases. So by default Macky records with the Mac's
/// own microphone when headphones are connected, and the headphones keep playing in full quality.
enum AudioInputDevices {
    /// Stored in settings: empty = automatic (avoid Bluetooth microphones), "system" = whatever macOS uses, else a device UID.
    static let automaticPreference = ""
    static let systemPreference = "system"

    static func all() -> [AudioInputDevice] {
        deviceIdentifiers().compactMap { deviceID in
            guard hasInput(deviceID), let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else { return nil }
            let transport = transportType(deviceID)
            return AudioInputDevice(
                id: deviceID,
                uid: uid,
                name: stringProperty(deviceID, kAudioObjectPropertyName) ?? uid,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            )
        }
    }

    static func systemDefault() -> AudioInputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return all().first { $0.id == deviceID }
    }

    /// Makes `deviceID` the system microphone. Returns false if macOS refused.
    @discardableResult
    static func setSystemDefault(_ deviceID: AudioDeviceID) -> Bool {
        var deviceID = deviceID
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
    }

    /// The microphone to record from, or nil to leave macOS's choice.
    static func resolve(preference: String) -> AudioInputDevice? {
        let devices = all()
        if preference == systemPreference { return nil }
        if !preference.isEmpty, let chosen = devices.first(where: { $0.uid == preference }) { return chosen }
        // Automatic (or the chosen microphone is gone): avoid a Bluetooth microphone when the Mac has its own.
        guard let current = systemDefault(), current.isBluetooth else { return nil }
        return devices.first(where: \.isBuiltIn)
    }

    // MARK: Core Audio

    private static func deviceIdentifiers() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &identifiers) == noErr else { return [] }
        return identifiers
    }

    private static func hasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
