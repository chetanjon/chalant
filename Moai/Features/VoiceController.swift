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
    /// A monitor's dead audio jack can be the default input while the
    /// Mac's own mic sits unused (seen live: "External Microphone",
    /// peak 0.00). One silent retry pinned to the built-in mic.
    private var retriedWithBuiltInMic = false
    /// The last recognition error, for diagnostics and honest copy.
    private(set) var lastErrorNote = "none"

    func begin() {
        transcript = ""
        level = 0
        peakLevel = 0
        failure = nil
        retriedWithFallbackLocale = false
        retriedWithBuiltInMic = false
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
            startCapture()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if status == .authorized {
                        self.startCapture()
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

    private func startCapture(locale: Locale? = nil, pinBuiltInMic: Bool = false) {
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
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        if pinBuiltInMic, var builtIn = SystemVolume.builtInInputDevice(),
           let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &builtIn,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
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
                        // Rescue one: the default input is not the
                        // Mac's own mic; pin the built-in and rerun.
                        if !self.retriedWithBuiltInMic,
                           !SystemVolume.defaultInputIsBuiltIn(),
                           SystemVolume.builtInInputDevice() != nil {
                            self.retriedWithBuiltInMic = true
                            self.restartCapture(pinBuiltInMic: true)
                            return
                        }
                        // Rescue two: the locale's on-device model is
                        // broken while claiming support; en-US rerun.
                        if !self.retriedWithFallbackLocale,
                           Locale.current.identifier.hasPrefix("en_US") == false {
                            self.retriedWithFallbackLocale = true
                            self.restartCapture(locale: Locale(identifier: "en-US"))
                            return
                        }
                        if nsError.code == 1110 {
                            // "No speech detected": the audio arrived
                            // but carried no words, which nearly always
                            // means the wrong microphone is listening.
                            let device = SystemVolume.inputDeviceName() ?? "the current input"
                            self.failure = "I heard sound but no words."
                                + " The mic in use is \(device);"
                                + " if that is not the right one, change it in"
                                + " System Settings, Sound, Input."
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
        finishTimeout?.cancel()
        finishTimeout = nil
        finishCompletion = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        transcript = ""
    }

    /// Tear the capture chain down and start again with a different
    /// device or locale, mid-session, while the user is still holding.
    private func restartCapture(locale: Locale? = nil, pinBuiltInMic: Bool = false) {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        startCapture(locale: locale, pinBuiltInMic: pinBuiltInMic)
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
        input device · \(SystemVolume.inputDeviceName() ?? "unknown")
        last session peak level · \(String(format: "%.2f", peakLevel))
        last recognition error · \(lastErrorNote)
        """
    }

    private func deliver() {
        finishTimeout?.cancel()
        finishTimeout = nil
        guard let completion = finishCompletion else { return }
        finishCompletion = nil
        let text = transcript
        if text.isEmpty, failure == nil {
            // Never end in a shrug: name the layer that went quiet.
            failure = availabilityHint ?? (peakLevel < 0.03
                ? "The mic heard silence. Check the input device in System Settings, Sound."
                : "Heard sound but no words. On-device speech may still be"
                    + " downloading for your language; try again in a minute.")
        }
        task?.cancel()
        task = nil
        request = nil
        level = 0
        completion(text)
    }
}
