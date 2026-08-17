// audiodev: list / add / remove a CoreAudio aggregate input device, so a
// plug/unplug of a microphone can be reproduced without touching hardware.
//
//   audiodev list
//   audiodev add <source-device-uid>      creates "Chalant Test Aggregate" wrapping the source, makes it default input
//   audiodev remove <restore-default-uid> destroys the aggregate, restores the default input
//   audiodev rates <uid> | rate <uid> <hz>  read / set a device's nominal sample rate
//   audiodev default <uid>                make a device the system default input
import CoreAudio
import Foundation

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func deviceIDs() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func stringProp(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return "" }
    return v.takeRetainedValue() as String
}

func inputChannels(_ id: AudioDeviceID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultInput() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice)
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return id
}

func setDefaultInput(_ id: AudioDeviceID) -> Bool {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice)
    var value = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
}

func find(uid: String) -> AudioDeviceID? {
    deviceIDs().first { stringProp($0, kAudioDevicePropertyDeviceUID) == uid }
}

let aggregateUID = "com.cj.chalant.test.aggregate"
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "list"

switch cmd {
case "list":
    let def = defaultInput()
    for id in deviceIDs() {
        let ch = inputChannels(id)
        guard ch > 0 else { continue }
        let mark = id == def ? "*" : " "
        print("\(mark) id=\(id) in=\(ch) name=\"\(stringProp(id, kAudioObjectPropertyName))\" uid=\(stringProp(id, kAudioDevicePropertyDeviceUID))")
    }
case "add":
    guard args.count > 2 else { print("usage: audiodev add <source-uid>"); exit(2) }
    let source = args[2]
    guard find(uid: source) != nil else { print("no device with uid \(source)"); exit(1) }
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Chalant Test Aggregate",
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: source]],
        kAudioAggregateDeviceMainSubDeviceKey: source,
        kAudioAggregateDeviceIsPrivateKey: 0,
    ]
    var aggID: AudioDeviceID = 0
    let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
    guard status == noErr else { print("create failed: \(status)"); exit(1) }
    print("created aggregate id=\(aggID) uid=\(aggregateUID)")
    Thread.sleep(forTimeInterval: 0.5)
    print("set default input: \(setDefaultInput(aggID))")
case "remove":
    guard let aggID = find(uid: aggregateUID) else { print("no aggregate present"); exit(0) }
    if args.count > 2, let restore = find(uid: args[2]) {
        print("restore default input to \(args[2]): \(setDefaultInput(restore))")
        Thread.sleep(forTimeInterval: 0.3)
    }
    let status = AudioHardwareDestroyAggregateDevice(aggID)
    print("destroy aggregate: \(status == noErr ? "ok" : "failed \(status)")")
case "rates":
    guard args.count > 2, let id = find(uid: args[2]) else { print("usage: audiodev rates <uid>"); exit(2) }
    var a = addr(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges)
    var cur = addr(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var rsize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &cur, 0, nil, &rsize, &rate)
    print("current \(rate) Hz; available: \(ranges.map { "\($0.mMinimum)-\($0.mMaximum)" }.joined(separator: ", "))")
case "rate":
    guard args.count > 3, let id = find(uid: args[2]), let hz = Float64(args[3]) else { print("usage: audiodev rate <uid> <hz>"); exit(2) }
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var value = hz
    let st = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    print("set nominal sample rate of \(args[2]) to \(hz): \(st == noErr ? "ok" : "failed \(st)")")
case "default":
    guard args.count > 2, let id = find(uid: args[2]) else { print("usage: audiodev default <uid>"); exit(2) }
    print("set default input to \(args[2]): \(setDefaultInput(id))")
default:
    print("usage: audiodev list | add <uid> | remove [restore-uid] | rates <uid> | rate <uid> <hz> | default <uid>")
}
