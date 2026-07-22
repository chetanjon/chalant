import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's output volume, for media sources that have no per-app
/// volume script (a browser playing YouTube Music). 0...100.
enum SystemVolume {
    static func level() -> Double? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Double(volume) * 100
    }

    static func set(_ percent: Double) {
        guard let device = defaultOutputDevice() else { return }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var volume = Float32(max(0, min(100, percent)) / 100)
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume)
    }

    /// One attachable input: everything the voice session needs to
    /// pick, pin, and name an ear.
    struct InputDevice: Equatable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let transport: UInt32
        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// The Mac's own microphone. The headphone jack also claims
        /// the built-in transport (seen live: a dead "External
        /// Microphone" that is really BuiltInHeadphoneInputDevice),
        /// so transport alone cannot identify the real mic; the
        /// stable UID is the truth and the name check is the net.
        var isBuiltInMic: Bool {
            uid == "BuiltInMicrophoneDevice"
                || (isBuiltIn
                    && !uid.localizedCaseInsensitiveContains("headphone")
                    && !name.localizedCaseInsensitiveContains("external"))
        }
        /// The built-in codec's line-in jack: exactly the dead ear
        /// this round routes around, so it always queues last.
        var isJack: Bool { isBuiltIn && !isBuiltInMic }
    }

    /// Every device currently offering input streams. The lid-closed
    /// MacBook drops its own mic from this list, which is exactly the
    /// situation the voice session needs to see coming.
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        var devices: [InputDevice] = []
        for id in ids {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                id, &streamsAddress, 0, nil, &streamsSize
            ) == noErr, streamsSize > 0 else { continue }
            // A device announcing its own death is not an ear. Missing
            // property means alive; many devices never publish it.
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(id, &aliveAddress) {
                var alive: UInt32 = 1
                var aliveSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(
                    id, &aliveAddress, 0, nil, &aliveSize, &alive
                ) == noErr, alive == 0 { continue }
            }
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(
                id, &transportAddress, 0, nil, &transportSize, &transport
            ) != noErr { transport = 0 }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            // The HAL mints private aggregates as capture plumbing
            // (CADefaultDeviceAggregate-…); they are not ears anyone
            // chose and only confuse the picker and the queue.
            if uid.hasPrefix("CADefaultDeviceAggregate") { continue }
            devices.append(InputDevice(
                id: id,
                uid: uid,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Input \(id)",
                transport: transport
            ))
        }
        return devices
    }

    /// The system's default input device, if one is set at all.
    static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// The default input device's name, for the voice diagnostics: a
    /// monitor claiming the mic role explains "no speech detected"
    /// faster than any other fact.
    static func inputDeviceName() -> String? {
        guard let deviceID = defaultInputDevice() else { return nil }
        return stringProperty(deviceID, kAudioObjectPropertyName)
    }

    /// The Mac's own microphone, for the voice session's rescue path:
    /// when the default input is a dead external jack, the built-in
    /// mic is the one that actually hears the user. Nil with the lid
    /// closed, when the hardware retires it.
    static func builtInInputDevice() -> AudioObjectID? {
        inputDevices().first(where: { $0.isBuiltInMic })?.id
    }

    /// Input gain of a capture device, 0...1, nil when unsupported.
    static func inputVolume(of device: AudioObjectID) -> Float32? {
        var address = inputVolumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &volume
        ) == noErr else { return nil }
        return volume
    }

    static func setInputVolume(of device: AudioObjectID, to volume: Float32) {
        var address = inputVolumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var value = min(1, max(0, volume))
        AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &value
        )
    }

    private static func inputVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func stringProperty(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        ) == noErr else { return nil }
        return value as String
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
