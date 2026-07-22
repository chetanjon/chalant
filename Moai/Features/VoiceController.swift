import AudioToolbox
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class VoiceController: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var level: CGFloat = 0
    /// Why nothing was heard, when the answer is a permission or
    /// availability problem rather than silence.
    @Published var failure: String?
    /// The loudest moment of the session: tells silence (wrong input
    /// device) apart from sound that produced no words (recognizer).
    private(set) var peakLevel: CGFloat = 0

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishCompletion: ((String) -> Void)?
    private var finishTimeout: DispatchWorkItem?
    private var availabilityHint: String?
    /// The system locale's on-device model can be broken while
    /// reporting itself supported; one silent retry against en-US,
    /// still on-device, rescues the session.
    private var retriedWithFallbackLocale = false
    /// The last recognition error, for diagnostics and honest copy.
    private(set) var lastErrorNote = "none"

    /// The ear currently live, shown under the level bars so a wrong
    /// device is never a mystery.
    @Published private(set) var activeDeviceName: String?
    /// Settings key holding the UID of a user-pinned microphone.
    /// Empty means automatic.
    static let pinnedUIDKey = "voiceInputUID"
    /// The session's ear queue. Element zero is the proactive choice
    /// (pinned, then the Mac's own mic, then the default, then the
    /// rest); the silence watchdog and the error rescue hop down it.
    private var candidates: [SystemVolume.InputDevice] = []
    private var candidateIndex = 0
    /// Hard cap on mid-session hops so a quiet room cannot thrash.
    private var deviceSwitches = 0
    private var watchdogWork: DispatchWorkItem?
    /// What the session did about devices, for diagnostics.
    private(set) var deviceNote = "none"

    private var currentCandidate: SystemVolume.InputDevice? {
        candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }

    /// A session must never whisper to the recognizer: input gain
    /// below a healthy floor rises for the capture and returns after
    /// (found live at 17 percent, every word arriving as mush).
    private var gainBoostDevice: AudioObjectID?
    private var gainBoostOriginal: Float32?

    private func raiseInputGainIfTimid(_ device: AudioObjectID?) {
        guard let device,
              let current = SystemVolume.inputVolume(of: device),
              current < 0.8 else { return }
        gainBoostDevice = device
        gainBoostOriginal = current
        SystemVolume.setInputVolume(of: device, to: 0.9)
        deviceNote += ", gain raised from \(Int(current * 100))%"
    }

    private func restoreInputGain() {
        if let device = gainBoostDevice, let original = gainBoostOriginal {
            SystemVolume.setInputVolume(of: device, to: original)
        }
        gainBoostDevice = nil
        gainBoostOriginal = nil
    }

    /// The session's audio, mirrored to disk while streaming. On this
    /// machine the streaming recognizer returns "no speech" for audio
    /// the same on-device model transcribes perfectly from a file
    /// (proven live), so when streaming comes back empty the session
    /// re-reads its own recording before admitting defeat.
    private var liveFile: AVAudioFile?
    private var liveFileURL: URL?
    private var triedFileRescue = false
    private var fileTask: SFSpeechRecognitionTask?
    private var rescueTimeout: DispatchWorkItem?

    func begin() {
        transcript = ""
        level = 0
        peakLevel = 0
        failure = nil
        retriedWithFallbackLocale = false
        activeDeviceName = nil
        candidates = []
        candidateIndex = 0
        deviceSwitches = 0
        watchdogWork?.cancel()
        watchdogWork = nil
        triedFileRescue = false
        rescueTimeout?.cancel()
        rescueTimeout = nil
        fileTask?.cancel()
        fileTask = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        finishCompletion = nil

        // The mic first: without it the tap hears pure silence and the
        // session ends in "heard nothing" with no clue why. Ask
        // explicitly instead of hoping the engine start triggers it.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            ensureSpeechAuthorization()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.ensureSpeechAuthorization()
                    } else {
                        self.failure = "Mic access is off. System Settings, Privacy, Microphone."
                    }
                }
            }
        default:
            failure = "Mic access is off. System Settings, Privacy, Microphone."
        }
    }

    /// Speech recognition consent, awaited on first run rather than
    /// fired and forgotten (which let the first session start while
    /// the prompt was still on screen and hear nothing).
    private func ensureSpeechAuthorization() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            startSession()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if status == .authorized {
                        self.startSession()
                    } else {
                        self.failure = "Speech recognition is off."
                            + " System Settings, Privacy, Speech Recognition."
                    }
                }
            }
        default:
            failure = "Speech recognition is off. System Settings, Privacy, Speech Recognition."
        }
    }

    /// Choose the ear before listening starts. Round 35 waited for
    /// the recognizer to fail before rescuing, which lost whatever
    /// was said first; now the pinned mic, then the Mac's own, then
    /// the default lead the queue from word one.
    private func startSession() {
        let devices = SystemVolume.inputDevices()
        var ordered: [SystemVolume.InputDevice] = []
        func add(_ device: SystemVolume.InputDevice?) {
            guard let device,
                  !ordered.contains(where: { $0.id == device.id }) else { return }
            ordered.append(device)
        }
        let pinnedUID = UserDefaults.standard.string(forKey: Self.pinnedUIDKey) ?? ""
        if !pinnedUID.isEmpty {
            add(devices.first { $0.uid == pinnedUID })
        }
        // Earphones in the ear outrank the Mac's own mic: when the
        // system default is a real external input (AirPods, a boAt
        // headset, USB), it is the ear of intent. Only the dead jack
        // never leads; it trails the whole queue.
        if let defaultID = SystemVolume.defaultInputDevice(),
           let systemDefault = devices.first(where: { $0.id == defaultID }),
           !systemDefault.isJack {
            add(systemDefault)
        }
        add(devices.first { $0.isBuiltInMic })
        devices.filter { !$0.isJack }.forEach { add($0) }
        devices.forEach { add($0) }
        candidates = ordered
        candidateIndex = 0
        deviceSwitches = 0
        let pinned = !pinnedUID.isEmpty && ordered.first?.uid == pinnedUID
        deviceNote = "started on \(ordered.first?.name ?? "the system default")"
            + (pinned ? ", pinned" : "")
        startCapture(pinDeviceID: ordered.first?.id)
    }

    /// If the first 1.6 seconds are absolute silence, the ear is
    /// dead; hop to the next candidate while the user is still
    /// talking. The threshold is near zero on purpose: a live mic in
    /// a quiet room still reads ~0.01 of floor tone (measured), while
    /// a dead jack reads 0.00 exactly. Any sound vetoes the hop.
    private func armSilenceWatchdog() {
        watchdogWork?.cancel()
        guard deviceSwitches < 2, candidateIndex + 1 < candidates.count else {
            watchdogWork = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.peakLevel < 0.004, self.transcript.isEmpty,
                  self.failure == nil, self.finishCompletion == nil else { return }
            self.advanceToNextCandidate(reason: "heard nothing")
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Move the session to the next untried input. False when the
    /// queue is exhausted or the hop cap is reached.
    @discardableResult
    private func advanceToNextCandidate(reason: String) -> Bool {
        guard deviceSwitches < 2, candidateIndex + 1 < candidates.count else { return false }
        deviceSwitches += 1
        candidateIndex += 1
        let next = candidates[candidateIndex]
        deviceNote = "\(reason) on \(activeDeviceName ?? "the first input"),"
            + " moved to \(next.name)"
        restartCapture(pinDeviceID: next.id)
        return true
    }

    private func startCapture(locale: Locale? = nil, pinDeviceID: AudioObjectID? = nil) {
        recognizer = locale.map { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
        guard let recognizer else {
            failure = "Speech recognition isn't available on this Mac."
            return
        }
        // isAvailable / supportsOnDeviceRecognition can read false
        // spuriously right after launch while speech assets warm up,
        // never block on them. Record regardless; if recognition then
        // produces nothing, these become the diagnosis.
        availabilityHint = !recognizer.isAvailable
            ? "Speech recognition isn't available right now, try again in a moment."
            : (!recognizer.supportsOnDeviceRecognition
                ? "On-device speech may still be downloading for your language."
                : nil)

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Standard macOS dictation, the same path Notes and Messages
        // use: on-device when the model is warm, Apple's dictation
        // service when it is not. The strict on-device-only mode
        // spent a day saying "sound but no words" whenever the local
        // model was cold (its own copy admitted it, "may still be
        // downloading"), and a voice feature that answers sometimes
        // is worse than none (user verdict, 2026-07-21).
        request.requiresOnDeviceRecognition = false
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        if var deviceID = pinDeviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            if status != noErr {
                deviceNote = "pin failed (\(status)), using the system default"
            }
        }
        let format = input.outputFormat(forBus: 0)
        // A dead or half-departed device reports a zero format, and a
        // tap installed with one is an exception, not an error. Hop
        // instead of crash.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            if !advanceToNextCandidate(reason: "zero format") {
                failure = "No working microphone right now. Pick one in"
                    + " Moai settings, or check System Settings, Sound, Input."
            }
            return
        }
        // Mirror the session to disk for the file rescue. Recreated on
        // every device hop; only the last ear's audio matters.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moai-live-session.caf")
        try? FileManager.default.removeItem(at: fileURL)
        liveFile = try? AVAudioFile(forWriting: fileURL, settings: format.settings)
        liveFileURL = liveFile == nil ? nil : fileURL
        let file = liveFile
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            try? file?.write(from: buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for index in 0..<frames {
                sum += channel[index] * channel[index]
            }
            let rms = sqrt(sum / Float(frames))
            Task { @MainActor in
                guard let self else { return }
                let live = CGFloat(min(1, rms * 18))
                self.level = live
                if live > self.peakLevel { self.peakLevel = live }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            failure = "Mic didn't start. System Settings, Privacy, Microphone."
            audioEngine.inputNode.removeTap(onBus: 0)
            return
        }
        activeDeviceName = currentCandidate?.name ?? SystemVolume.inputDeviceName()
        raiseInputGainIfTimid(currentCandidate?.id ?? SystemVolume.defaultInputDevice())
        armSilenceWatchdog()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result else {
                // Recognition died without producing anything. The
                // system locale's on-device model can be broken while
                // claiming support; retry once on en-US, still fully
                // on-device, before admitting defeat by name.
                if let error {
                    Task { @MainActor in
                        guard let self, self.request === request,
                              self.transcript.isEmpty, self.failure == nil else { return }
                        let nsError = error as NSError
                        self.lastErrorNote = "\(nsError.domain) \(nsError.code)"
                        // Rescue one: the live ear errored before any
                        // words arrived; hop to the next untried one.
                        // Only while the user is still holding, a
                        // restart after release would capture a room
                        // nobody is talking to.
                        if self.finishCompletion == nil,
                           self.advanceToNextCandidate(reason: "error \(nsError.code)") {
                            return
                        }
                        // Rescue two: the locale's on-device model is
                        // broken while claiming support; en-US rerun
                        // on the same ear.
                        if self.finishCompletion == nil,
                           !self.retriedWithFallbackLocale,
                           Locale.current.identifier.hasPrefix("en_US") == false {
                            self.retriedWithFallbackLocale = true
                            self.restartCapture(
                                locale: Locale(identifier: "en-US"),
                                pinDeviceID: self.currentCandidate?.id
                            )
                            return
                        }
                        if nsError.code == 1110 {
                            // "No speech detected": the audio arrived
                            // but carried no words, which nearly always
                            // means the wrong microphone is listening.
                            let device = self.activeDeviceName
                                ?? SystemVolume.inputDeviceName()
                                ?? "the current input"
                            self.failure = "I heard sound but no words."
                                + " The mic in use is \(device);"
                                + " if that is not the right one, pick"
                                + " another in Moai settings."
                        } else {
                            self.failure = self.availabilityHint
                                ?? "Speech recognition hit an error (\(nsError.code)). Try again."
                        }
                    }
                }
                return
            }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in
                guard let self else { return }
                self.transcript = text
                // The final result carries the completed tail of the
                // sentence, deliver on it rather than on a fixed beat,
                // or trailing words ("...at 6 pm") get truncated.
                if isFinal {
                    self.deliver()
                }
            }
        }
    }

    /// Stop capture, wait for the recognizer's final transcription
    /// (with a safety timeout), then hand back the words.
    func end(completion: @escaping (String) -> Void) {
        watchdogWork?.cancel()
        watchdogWork = nil
        restoreInputGain()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()

        finishCompletion = completion
        let timeout = DispatchWorkItem { [weak self] in
            self?.deliver()
        }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: timeout)
    }

    /// Tear down without delivering anything, the user cancelled.
    func cancel() {
        watchdogWork?.cancel()
        watchdogWork = nil
        restoreInputGain()
        finishTimeout?.cancel()
        finishTimeout = nil
        finishCompletion = nil
        rescueTimeout?.cancel()
        rescueTimeout = nil
        fileTask?.cancel()
        fileTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        transcript = ""
        liveFile = nil
        if let url = liveFileURL {
            try? FileManager.default.removeItem(at: url)
            liveFileURL = nil
        }
    }

    /// Tear the capture chain down and start again with a different
    /// device or locale, mid-session, while the user is still holding.
    private func restartCapture(locale: Locale? = nil, pinDeviceID: AudioObjectID? = nil) {
        watchdogWork?.cancel()
        watchdogWork = nil
        restoreInputGain()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        startCapture(locale: locale, pinDeviceID: pinDeviceID)
    }

    /// Everything a stuck voice session needs to explain itself.
    var diagnostics: String {
        let recognizer = SFSpeechRecognizer()
        func name(_ status: AVAuthorizationStatus) -> String {
            switch status {
            case .authorized: return "granted"
            case .denied: return "denied"
            case .restricted: return "restricted"
            default: return "not asked yet"
            }
        }
        func speechName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
            switch status {
            case .authorized: return "granted"
            case .denied: return "denied"
            case .restricted: return "restricted"
            default: return "not asked yet"
            }
        }
        return """
        mic access · \(name(AVCaptureDevice.authorizationStatus(for: .audio)))
        speech access · \(speechName(SFSpeechRecognizer.authorizationStatus()))
        system locale · \(Locale.current.identifier)
        recognizer available · \((recognizer ?? SFSpeechRecognizer())?.isAvailable == true ? "yes" : "no")
        on-device supported · \((recognizer ?? SFSpeechRecognizer())?.supportsOnDeviceRecognition == true ? "yes" : "no")
        \(deviceTable)
        last device note · \(deviceNote)
        last session peak level · \(String(format: "%.2f", peakLevel))
        last recognition error · \(lastErrorNote)
        """
    }

    /// Every ear the Mac can currently offer, with the roles that
    /// explain which one a session would choose and why.
    private var deviceTable: String {
        let devices = SystemVolume.inputDevices()
        guard !devices.isEmpty else {
            return "input devices · none found (lid closed and nothing attached?)"
        }
        let defaultID = SystemVolume.defaultInputDevice()
        let pinnedUID = UserDefaults.standard.string(forKey: Self.pinnedUIDKey) ?? ""
        var lines = "input devices ·"
        for device in devices {
            var markers: [String] = []
            if device.isBuiltInMic { markers.append("built-in") }
            if device.isJack { markers.append("jack") }
            if device.id == defaultID { markers.append("default") }
            if !pinnedUID.isEmpty, device.uid == pinnedUID { markers.append("chosen") }
            if device.name == activeDeviceName { markers.append("last used") }
            lines += "\n  \(device.name)"
                + (markers.isEmpty ? "" : " · " + markers.joined(separator: " · "))
        }
        return lines
    }

    private func deliver() {
        watchdogWork?.cancel()
        watchdogWork = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        guard finishCompletion != nil else { return }
        // The streaming recognizer came back empty for a session that
        // plainly carried sound; re-read the recording with the same
        // on-device model, which hears files it ignores as streams.
        if transcript.isEmpty, failure == nil, !triedFileRescue,
           peakLevel >= 0.004, let url = liveFileURL {
            triedFileRescue = true
            recognizeRecording(url)
            return
        }
        guard let completion = finishCompletion else { return }
        finishCompletion = nil
        let text = transcript
        if text.isEmpty, failure == nil {
            // Never end in a shrug: name the layer that went quiet.
            failure = availabilityHint ?? (peakLevel < 0.03
                ? silentSessionCopy()
                : "Heard sound but no words. On-device speech may still be"
                    + " downloading for your language; try again in a minute.")
        }
        task?.cancel()
        task = nil
        request = nil
        level = 0
        if let url = liveFileURL {
            try? FileManager.default.removeItem(at: url)
            liveFileURL = nil
        }
        liveFile = nil
        completion(text)
    }

    /// The file rescue: the same on-device recognizer, fed the
    /// session's own recording instead of the live stream. The live
    /// task dies first; on-device recognition does not share the
    /// model between two tasks.
    private func recognizeRecording(_ url: URL) {
        liveFile = nil
        task?.cancel()
        task = nil
        request = nil
        guard let recognizer = SFSpeechRecognizer() else {
            deliver()
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = false
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishRescue(with: nil)
        }
        rescueTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        fileTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result, result.isFinal {
                    self.finishRescue(with: result.bestTranscription.formattedString)
                } else if error != nil, result == nil {
                    self.finishRescue(with: nil)
                }
            }
        }
    }

    private func finishRescue(with text: String?) {
        guard finishCompletion != nil else { return }
        rescueTimeout?.cancel()
        rescueTimeout = nil
        fileTask?.cancel()
        fileTask = nil
        if let text, !text.isEmpty {
            transcript = text
            deviceNote += ", transcript came from the recording"
        }
        deliver()
    }

    #if DEBUG
    /// Records the exact buffers a live session would feed the
    /// recognizer to a file, using the same device pick and tap; the
    /// harness inspects the file to tell a garbled capture chain from
    /// a deaf recognizer. Debug builds only, driven by "debug rec".
    func debugRecord(seconds: Double, completion: @escaping (String) -> Void) {
        let devices = SystemVolume.inputDevices()
        let pick = devices.first { $0.isBuiltInMic } ?? devices.first
        let input = audioEngine.inputNode
        if var deviceID = pick?.id, let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            completion("zero format on \(pick?.name ?? "no device")")
            return
        }
        let url = URL(fileURLWithPath: "/tmp/moai-tap.caf")
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            completion("could not open /tmp/moai-tap.caf for \(format)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            completion("engine start failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            completion("recorded \(seconds)s from \(pick?.name ?? "default")"
                + " at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch,"
                + " /tmp/moai-tap.caf")
        }
    }

    /// Runs the same on-device recognizer over a file, so the model
    /// can be judged apart from the live capture chain; an optional
    /// locale tests whether a different accent model hears better.
    func debugRecognizeFile(
        path: String,
        locale: String? = nil,
        completion: @escaping (String) -> Void
    ) {
        let recognizer = locale.flatMap {
            SFSpeechRecognizer(locale: Locale(identifier: $0))
        } ?? SFSpeechRecognizer()
        guard let recognizer else {
            completion("no recognizer for \(locale ?? "default")")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        request.requiresOnDeviceRecognition = true
        recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result, result.isFinal {
                    completion("file transcript: \(result.bestTranscription.formattedString)")
                } else if let error {
                    let nsError = error as NSError
                    completion("file recognition error: \(nsError.domain) \(nsError.code)")
                }
            }
        }
    }
    #endif

    /// Silence end to end: name the ear that was tried and where a
    /// working one might be. With the lid closed the Mac's own mic
    /// vanishes entirely, which deserves its own sentence.
    private func silentSessionCopy() -> String {
        if SystemVolume.builtInInputDevice() == nil {
            return "The Mac's own mic is off while the lid is closed."
                + " Pick a working mic in Moai settings, or open the lid."
        }
        let tried = activeDeviceName ?? "the current input"
        return "The mic heard silence on \(tried). Pick a mic in Moai"
            + " settings, or check System Settings, Sound, Input."
    }
}
