// optionhold <seconds>: synthesize a left-Option hold (keycode 58, flagsChanged,
// NX_DEVICELALTKEYMASK 0x20) on the HID event tap, the way the dictation probe
// harness in Dictation/MANUAL-TEST-LOG.md drives the app.
import CoreGraphics
import Foundation

let secs = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 1.5) : 1.5
let src = CGEventSource(stateID: .hidSystemState)
guard let down = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: true),
      let up = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: false) else {
    print("could not build events"); exit(1)
}
down.type = .flagsChanged
down.flags = CGEventFlags(rawValue: 0x20 | CGEventFlags.maskAlternate.rawValue)
up.type = .flagsChanged
up.flags = CGEventFlags(rawValue: 0)
down.post(tap: .cghidEventTap)
print("option down")
Thread.sleep(forTimeInterval: secs)
up.post(tap: .cghidEventTap)
print("option up after \(secs)s")
