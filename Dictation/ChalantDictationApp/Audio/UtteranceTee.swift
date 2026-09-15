import AVFoundation
import os

/// A 16 kHz mono copy of the utterance, taken as the buffers go past.
///
/// **Lifted out of `AppleTranscriber` on 2026-09-14, where it had been
/// `keepForHearing`.** It sat there because the only consumer was a second
/// ear that ran after Apple's, so the copy naturally belonged to Apple's
/// engine. Now it is the input to the primary engine and the audio a
/// fallback re-hears, so it belongs to neither and is shared by both.
///
/// The conversion is the same one that has been running since 2026-08-18: one
/// stateful `AVAudioConverter` per format, rebuilt when the microphone
/// changes under it, fed buffer by buffer off the drain (never off the
/// real-time thread, which Part 1 §2 forbids doing any work on).
///
/// Not an actor and not `Sendable`: it is a value held inside whichever
/// engine actor owns it, and it never crosses an isolation boundary.
struct UtteranceTee {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "audio")

    static let sampleRate = 16_000

    /// What every on-device recognizer in this project wants.
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
        interleaved: false)!

    /// **Five minutes, up from ninety seconds, and the reason is Part 1 §2
    /// rather than generosity.** The old cap was chosen when this audio fed
    /// an optional second opinion: losing the tail of a very long hold cost
    /// that utterance a nicety. It is now the audio the primary engine
    /// transcribes, so the cap is a hard limit on how long anyone may speak,
    /// and ninety seconds is well inside what people actually dictate. Five
    /// minutes of 16 kHz mono Float32 is 19.2 MB, which is less than the app
    /// was holding in speech models a moment ago.
    ///
    /// It is still a cap, and hitting it still costs the speaker the rest of
    /// their sentence. What changed is that it now says so (`truncated`)
    /// instead of returning quietly.
    static let capSeconds = 300
    static let capSamples = sampleRate * capSeconds

    private var converter: AVAudioConverter?
    private(set) var samples: [Float] = []
    /// Whether the cap was reached and audio was dropped. Read at the end of
    /// the utterance so the log and the corpus row can say so.
    private(set) var truncated = false

    var seconds: Double { Double(samples.count) / Double(Self.sampleRate) }
    var isEmpty: Bool { samples.isEmpty }

    /// Whether there is enough audio for any engine here to accept it.
    /// FluidAudio refuses under 300 ms outright (`ASRConstants`); WhisperKit
    /// has been refusing under 500 ms since 1.34.0. Take the longer bar so
    /// "too short" means the same thing whichever engine is chosen, and so a
    /// short hold is classed as silence rather than as an engine failure.
    static let minimumSamples = sampleRate / 2

    var hasEnoughForRecognition: Bool { samples.count >= Self.minimumSamples }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard samples.count < Self.capSamples else {
            if !truncated {
                truncated = true
                Self.log.error(
                    "utterance passed \(Self.capSeconds, privacy: .public)s; the rest is not being kept")
            }
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
        }
        guard let converter else { return }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        truncated = false
    }
}

/// The corpus's copy: the RAW microphone buffers, written to a file.
///
/// Raw rather than converted, and that is the whole value of it: a captured
/// utterance can be replayed through any engine or locale later, which is
/// what makes an engine bake-off possible at all. Best effort by design, so
/// losing a corpus buffer can never cost the user their words.
///
/// Lifted out of `AppleTranscriber` alongside the tee, for the same reason:
/// two engines needed identical behaviour and a file write with
/// swallow-everything semantics is not a thing to have two copies of.
struct RawCapture {
    private var url: URL?
    private var file: AVAudioFile?

    mutating func begin(writingTo url: URL?) {
        file = nil
        self.url = url
    }

    mutating func end() {
        file = nil
        url = nil
    }

    var isOn: Bool { url != nil }

    /// Created lazily on the first buffer, because that is the first moment
    /// the microphone's real format is known.
    mutating func write(_ buffer: AVAudioPCMBuffer) {
        guard let url else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        try? file?.write(from: buffer)
    }
}
