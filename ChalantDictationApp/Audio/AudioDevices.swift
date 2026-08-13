import AudioToolbox
import ChalantDictationCore
import CoreAudio
import Foundation

/// The CoreAudio half of choosing a microphone: enumerate what is attached,
/// and bind the engine to one on purpose rather than inheriting whatever the
/// system default happens to be.
///
/// `InputChoice` decides WHICH, and is pure and tested. This only fetches the
/// facts it decides on and carries the `AudioDeviceID` those decisions need.
enum AudioDevices {

    /// One attachable input, with the CoreAudio id kept alongside the pure
    /// description the chooser works in.
    struct Attached {
        let id: AudioDeviceID
        let device: InputChoice.Device
    }

    static func all() -> [Attached] {
        let defaultID = defaultInput()
        return ids().compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            let uid = uid(id)
            let name = name(id)
            // CoreAudio manufactures a private aggregate for THIS process
            // while it holds the default device open (seen live as
            // "CADefaultDeviceAggregate-86980-0"). It is our own reflection:
            // offering it as an alternative ear made the app hop to itself,
            // and it appears and disappears with every engine restart, which
            // is enough on its own to make a device-change watcher loop.
            guard !uid.hasPrefix("CADefaultDeviceAggregate"),
                  !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            // The jack reports the BUILT-IN transport, so transport cannot
            // identify the real microphone. The UID is the truth and the name
            // is the net (parent project, measured).
            let isJack =
                uid.localizedCaseInsensitiveContains("headphone")
                || name.localizedCaseInsensitiveContains("external microphone")
            return Attached(
                id: id,
                device: InputChoice.Device(
                    uid: uid,
                    name: name,
                    isBuiltInMic: uid == "BuiltInMicrophoneDevice",
                    isJack: isJack,
                    isSystemDefault: id == defaultID))
        }
    }

    /// Point the engine's input at one specific device. Must happen before the
    /// tap is installed, which is why `AudioEngine.startWarm` does it first.
    static func bind(_ unit: AudioUnit, to id: AudioDeviceID) -> Bool {
        var deviceID = id
        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    // MARK: - Property reads

    private static func ids() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func defaultInput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return "" }
        return value as String
    }

    private static func uid(_ id: AudioDeviceID) -> String {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func name(_ id: AudioDeviceID) -> String {
        stringProperty(id, kAudioObjectPropertyName)
    }
}
