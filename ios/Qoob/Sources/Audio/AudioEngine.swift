//
//  AudioEngine.swift
//  Qoob
//
//  A tiny procedural sound engine. Everything is synthesised into PCM buffers
//  at runtime, so the game ships with no audio asset files — a nod to
//  Endorfun's meditative rhythm-loop soundtrack, rebuilt from scratch.
//
//  - a soft looping ambient pad while playing
//  - a pentatonic bell that rises with your match streak
//

import AVFoundation

final class AudioEngine {

    private let engine = AVAudioEngine()
    private let padPlayer = AVAudioPlayerNode()
    private let bellPlayer = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    // A soothing pentatonic scale (C major pentatonic across two octaves).
    private let scale: [Double] = [
        261.63, 293.66, 329.63, 392.00, 440.00,
        523.25, 587.33, 659.25, 783.99, 880.00
    ]

    private var started = false
    var isEnabled = true

    func start() {
        guard isEnabled, !started else { return }
        configureSession()

        engine.attach(padPlayer)
        engine.attach(bellPlayer)
        engine.connect(padPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(bellPlayer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9

        do {
            try engine.start()
            started = true
        } catch {
            started = false
            return
        }

        if let pad = makePadBuffer() {
            padPlayer.scheduleBuffer(pad, at: nil, options: .loops, completionHandler: nil)
            padPlayer.volume = 0.22
            padPlayer.play()
        }
        bellPlayer.play()
    }

    func stop() {
        guard started else { return }
        padPlayer.stop()
        bellPlayer.stop()
        engine.stop()
        started = false
    }

    /// Plays a match bell. `streak` (0-based) climbs the scale for a rewarding
    /// rising feel; it resets when the player misses the flow.
    func playMatch(streak: Int) {
        guard started else { return }
        let note = scale[min(streak, scale.count - 1)]
        if let buf = makeBellBuffer(frequency: note, duration: 1.6, gain: 0.45) {
            bellPlayer.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    /// A warm chord flourish on level completion. Synthesised as one mixed
    /// buffer (a single player node can't overlap notes into a chord).
    func playWin() {
        guard started else { return }
        let chord = [scale[0], scale[2], scale[4], scale[7]]
        if let buf = makeChordBuffer(frequencies: chord, duration: 2.4, gain: 0.32) {
            bellPlayer.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    // MARK: - Session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // .ambient => respects the silent switch and mixes with other audio,
        // which suits a calm, optional soundscape.
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: - Synthesis

    /// A struck-bell tone: two partials with an exponential amplitude decay.
    private func makeBellBuffer(frequency f: Double, duration: Double, gain: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        let ch = data[0]
        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate
            let env = exp(-t * 3.2)                 // decay
            let attack = min(1.0, t / 0.005)        // 5 ms fade-in, avoids clicks
            var s = sin(2 * .pi * f * t)
            s += 0.5 * sin(2 * .pi * f * 2 * t)     // octave partial
            s += 0.25 * sin(2 * .pi * f * 3 * t)    // fifth-ish partial
            ch[n] = Float(s * env * attack * gain * 0.5)
        }
        return buffer
    }

    /// Several bell tones summed into a single buffer, forming a chord.
    private func makeChordBuffer(frequencies: [Double], duration: Double, gain: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        let ch = data[0]
        let norm = gain / Double(max(1, frequencies.count))
        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate
            let env = exp(-t * 1.8)
            let attack = min(1.0, t / 0.006)
            var s = 0.0
            for f in frequencies {
                s += sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * f * 2 * t)
            }
            ch[n] = Float(s * env * attack * norm * 0.5)
        }
        return buffer
    }

    /// A slowly beating drone chord that loops seamlessly.
    private func makePadBuffer() -> AVAudioPCMBuffer? {
        let loop = 8.0 // seconds; whole number of cycles keeps the loop clickless
        let frames = AVAudioFrameCount(loop * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        // Low, consonant voices (root, fifth, octave) with slight detune for warmth.
        let voices: [(freq: Double, amp: Double)] = [
            (130.81, 0.5),   // C3
            (196.00, 0.35),  // G3
            (261.63, 0.28),  // C4
            (130.81 * 1.003, 0.2) // detuned root for a gentle chorus/beat
        ]
        let ch = data[0]
        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate
            var s = 0.0
            for v in voices { s += v.amp * sin(2 * .pi * v.freq * t) }
            // Slow breathing tremolo.
            let tremolo = 0.85 + 0.15 * sin(2 * .pi * (1.0 / loop) * t)
            ch[n] = Float(s * tremolo * 0.18)
        }
        return buffer
    }
}
