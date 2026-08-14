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
    private var isEnabled = true
    private var wired = false
    private var observers: [any NSObjectProtocol] = []
    /// True between a `start()` and the corresponding `stop()`. Session
    /// activation is asynchronous, so its callback has to check that playback is
    /// still wanted before bringing the engine up.
    private var wantsPlayback = false

    /// The match bells, synthesised once. Each is ~70k frames of summed sines;
    /// building one on demand meant a visible hitch on the frame a match landed.
    private lazy var bells: [AVAudioPCMBuffer?] = scale.map {
        makeBellBuffer(frequency: $0, duration: 1.6, gain: 0.45)
    }

    /// Turns the whole soundscape on or off, ambient pad included. Gating only
    /// the bells would leave the drone playing after the player muted the game.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    func start() {
        guard isEnabled, !started else { return }
        wantsPlayback = true
        observeInterruptions()
        activateSession { [weak self] in self?.startEngine() }
    }

    func stop() {
        wantsPlayback = false
        guard started else { return }
        teardown()
    }

    private func teardown() {
        padPlayer.stop()
        bellPlayer.stop()
        engine.stop()
        started = false
    }

    private func startEngine() {
        guard wantsPlayback, isEnabled, !started else { return }

        // Attaching and connecting is one-time setup; redoing it on every
        // restart (after an interruption, say) would stack up connections.
        if !wired {
            engine.attach(padPlayer)
            engine.attach(bellPlayer)
            engine.connect(padPlayer, to: engine.mainMixerNode, format: format)
            engine.connect(bellPlayer, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.9
            wired = true
        }

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

    /// Plays a match bell. `streak` (0-based) climbs the scale for a rewarding
    /// rising feel; it resets when the player misses the flow.
    func playMatch(streak: Int) {
        guard started else { return }
        guard let buf = bells[min(max(0, streak), bells.count - 1)] else { return }
        bellPlayer.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
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

    /// Configures and activates the session off the main thread, then calls back
    /// on the main queue.
    ///
    /// `setActive(true)` blocks its caller, and doing that on the main thread is
    /// a documented hang risk that the runtime warns about. It matters more now
    /// that the game activates on every return to the foreground rather than
    /// only at launch. (iOS 27 adds an async `activate(options:)`; a serial
    /// background queue does the same job on every version the app supports.)
    private func activateSession(then ready: @escaping () -> Void) {
        sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            // .ambient => respects the silent switch and mixes with other audio,
            // which suits a calm, optional soundscape.
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            // Activation failure isn't fatal for an ambient, mixable session —
            // bring the engine up either way.
            try? session.setActive(true)
            DispatchQueue.main.async(execute: ready)
        }
    }

    private let sessionQueue = DispatchQueue(label: "com.qoob.audio-session")

    /// A call, Siri, or an audio-route change stops the engine, and it does not
    /// come back by itself — without this the game went permanently silent after
    /// the first interruption. Restart on the way out of one.
    private func observeInterruptions() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began:
                // `teardown`, not `stop`: the player still wants sound, so the
                // intent to play must survive for `.ended` to act on.
                self.teardown()
            case .ended:
                self.restart()
            default:
                break
            }
        })

        // The engine also tears itself down when the hardware configuration
        // changes (headphones in or out, for instance).
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        })
    }

    /// Brings the soundscape back after an interruption, if it's still wanted.
    /// Tears down unconditionally first: the pad is scheduled as a looping
    /// buffer, so restarting without stopping the player would layer a second
    /// drone on top of the first.
    private func restart() {
        guard isEnabled, wantsPlayback else { return }
        teardown()
        start()
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
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
