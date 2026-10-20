import AVFoundation

enum SoundProfile: String, CaseIterable, Identifiable {
    case mechanical, typewriter, soft, thock, clicky, bubble
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mechanical: "Mechanical"
        case .typewriter: "Typewriter"
        case .soft: "Soft Keys"
        case .thock: "Thock"
        case .clicky: "Clicky"
        case .bubble: "Bubble"
        }
    }
    var detail: String {
        switch self {
        case .mechanical: "Balanced tactile switches"
        case .typewriter: "Metal strikes and a bell on Return"
        case .soft: "Quiet laptop-style keys"
        case .thock: "Deep, muted linear switches"
        case .clicky: "Crisp two-stage blue switches"
        case .bubble: "Gentle, playful pops"
        }
    }
}

/// Typing sounds, synthesized at launch so no audio assets are needed.
/// Several variants per key type keep it from sounding robotic.
final class TypingSounds {
    static let shared = TypingSounds()

    enum Kind: CaseIterable { case key, space, returnKey, delete }

    var volume: Float = 0.6 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }
    var profile: SoundProfile = .mechanical

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var cache: [SoundProfile: [Kind: [AVAudioPCMBuffer]]] = [:]
    private var next = 0
    private var started = false
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private init() {}

    func play(_ kind: Kind, profile: SoundProfile? = nil) {
        if !started { start() }
        guard started, let buffer = buffers(for: profile ?? self.profile)[kind]?.randomElement() else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// Plays a short demo phrase.
    func preview(_ profile: SoundProfile) {
        let kinds: [Kind] = [.key, .key, .key, .space, .key, .key, .delete, .key, .returnKey]
        for (i, k) in kinds.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.11) { self.play(k, profile: profile) }
        }
    }

    func buffers(for profile: SoundProfile) -> [Kind: [AVAudioPCMBuffer]] {
        if let cached = cache[profile] { return cached }
        var set: [Kind: [AVAudioPCMBuffer]] = [:]
        for kind in Kind.allCases { set[kind] = (0..<4).map { make(profile, kind, seed: $0) } }
        cache[profile] = set
        return set
    }

    private func start() {
        for _ in 0..<10 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = volume
        do {
            try engine.start()
            started = true
        } catch {
            NSLog("Type: audio engine failed to start: \(error)")
        }
    }

    // MARK: Synthesis

    /// Parameters for one percussive voice: filtered-noise click + damped "body" tone.
    private struct Voice {
        var duration: Double
        var bodyHz: Double
        var bodyDecay: Double
        var bodyGain: Double
        var clickDecay: Double
        var clickGain: Double
        var brightness: Double      // 0…1 low-pass coefficient for the click
        var secondClickAt: Double?  // two-stage switches
        var partials: [(hz: Double, decay: Double, gain: Double)] = []
        var sweep: (from: Double, to: Double, time: Double)?
        var tailAt: Double?         // later contact (return key / carriage)
        var tailGain: Double = 0
    }

    private func voice(_ profile: SoundProfile, _ kind: Kind, seed: Int) -> Voice {
        let s = Double(seed)
        switch profile {
        case .mechanical:
            switch kind {
            case .key: return Voice(duration: 0.045, bodyHz: 210 + s * 22, bodyDecay: 90, bodyGain: 0.45, clickDecay: 260, clickGain: 0.55, brightness: 0.45)
            case .space: return Voice(duration: 0.075, bodyHz: 130 + s * 12, bodyDecay: 55, bodyGain: 0.6, clickDecay: 180, clickGain: 0.45, brightness: 0.45)
            case .returnKey: return Voice(duration: 0.11, bodyHz: 105 + s * 10, bodyDecay: 38, bodyGain: 0.7, clickDecay: 140, clickGain: 0.5, brightness: 0.45, tailAt: 0.05, tailGain: 0.35)
            case .delete: return Voice(duration: 0.04, bodyHz: 260 + s * 25, bodyDecay: 110, bodyGain: 0.35, clickDecay: 320, clickGain: 0.4, brightness: 0.45)
            }
        case .typewriter:
            let metal: [(hz: Double, decay: Double, gain: Double)] = [(1850 + s * 90, 70, 0.12), (2950 + s * 120, 90, 0.07)]
            switch kind {
            case .key: return Voice(duration: 0.09, bodyHz: 150 + s * 15, bodyDecay: 70, bodyGain: 0.55, clickDecay: 160, clickGain: 0.85, brightness: 0.75, partials: metal)
            case .space: return Voice(duration: 0.12, bodyHz: 95 + s * 8, bodyDecay: 40, bodyGain: 0.65, clickDecay: 120, clickGain: 0.6, brightness: 0.55, partials: [(1300, 60, 0.06)])
            case .returnKey:
                return Voice(duration: 0.75, bodyHz: 80, bodyDecay: 18, bodyGain: 0.45, clickDecay: 14, clickGain: 0.22, brightness: 0.3,
                             partials: [(2093 + s * 8, 4.5, 0.22), (4186, 7, 0.06)], tailAt: 0.28, tailGain: 0.6)
            case .delete: return Voice(duration: 0.07, bodyHz: 190 + s * 15, bodyDecay: 90, bodyGain: 0.4, clickDecay: 220, clickGain: 0.6, brightness: 0.7, partials: [(2400, 110, 0.05)])
            }
        case .soft:
            switch kind {
            case .key: return Voice(duration: 0.04, bodyHz: 240 + s * 18, bodyDecay: 140, bodyGain: 0.25, clickDecay: 300, clickGain: 0.32, brightness: 0.12)
            case .space: return Voice(duration: 0.06, bodyHz: 170 + s * 10, bodyDecay: 90, bodyGain: 0.32, clickDecay: 220, clickGain: 0.3, brightness: 0.1)
            case .returnKey: return Voice(duration: 0.07, bodyHz: 150 + s * 8, bodyDecay: 75, bodyGain: 0.35, clickDecay: 200, clickGain: 0.32, brightness: 0.1)
            case .delete: return Voice(duration: 0.035, bodyHz: 280 + s * 20, bodyDecay: 160, bodyGain: 0.22, clickDecay: 340, clickGain: 0.28, brightness: 0.12)
            }
        case .thock:
            switch kind {
            case .key: return Voice(duration: 0.08, bodyHz: 105 + s * 9, bodyDecay: 34, bodyGain: 0.9, clickDecay: 240, clickGain: 0.25, brightness: 0.22)
            case .space: return Voice(duration: 0.12, bodyHz: 72 + s * 5, bodyDecay: 24, bodyGain: 1.0, clickDecay: 160, clickGain: 0.22, brightness: 0.18)
            case .returnKey: return Voice(duration: 0.13, bodyHz: 66 + s * 5, bodyDecay: 22, bodyGain: 1.0, clickDecay: 150, clickGain: 0.25, brightness: 0.18, tailAt: 0.045, tailGain: 0.4)
            case .delete: return Voice(duration: 0.07, bodyHz: 125 + s * 9, bodyDecay: 40, bodyGain: 0.8, clickDecay: 260, clickGain: 0.22, brightness: 0.22)
            }
        case .clicky:
            switch kind {
            case .key: return Voice(duration: 0.05, bodyHz: 320 + s * 30, bodyDecay: 140, bodyGain: 0.25, clickDecay: 520, clickGain: 0.75, brightness: 0.85, secondClickAt: 0.011 + s * 0.001)
            case .space: return Voice(duration: 0.07, bodyHz: 190 + s * 15, bodyDecay: 80, bodyGain: 0.4, clickDecay: 420, clickGain: 0.6, brightness: 0.8, secondClickAt: 0.014)
            case .returnKey: return Voice(duration: 0.09, bodyHz: 170 + s * 12, bodyDecay: 65, bodyGain: 0.45, clickDecay: 380, clickGain: 0.65, brightness: 0.8, secondClickAt: 0.016, tailAt: 0.05, tailGain: 0.3)
            case .delete: return Voice(duration: 0.045, bodyHz: 360 + s * 30, bodyDecay: 160, bodyGain: 0.2, clickDecay: 560, clickGain: 0.65, brightness: 0.85, secondClickAt: 0.01)
            }
        case .bubble:
            switch kind {
            case .key: return Voice(duration: 0.06, bodyHz: 0, bodyDecay: 60, bodyGain: 0.5, clickDecay: 900, clickGain: 0.05, brightness: 0.3, sweep: (380 + s * 40, 900 + s * 70, 0.035))
            case .space: return Voice(duration: 0.08, bodyHz: 0, bodyDecay: 45, bodyGain: 0.55, clickDecay: 900, clickGain: 0.05, brightness: 0.3, sweep: (260 + s * 20, 600 + s * 40, 0.05))
            case .returnKey: return Voice(duration: 0.12, bodyHz: 0, bodyDecay: 30, bodyGain: 0.55, clickDecay: 900, clickGain: 0.05, brightness: 0.3, sweep: (220, 760, 0.07))
            case .delete: return Voice(duration: 0.05, bodyHz: 0, bodyDecay: 70, bodyGain: 0.45, clickDecay: 900, clickGain: 0.05, brightness: 0.3, sweep: (900 + s * 50, 420, 0.03))
            }
        }
    }

    private func make(_ profile: SoundProfile, _ kind: Kind, seed: Int) -> AVAudioPCMBuffer {
        let v = voice(profile, kind, seed: seed)
        var rng = SeededRandom(seed: UInt64(seed + 1) &* 2_654_435_761
            &+ UInt64(Kind.allCases.firstIndex(of: kind)! * 7919)
            &+ UInt64(SoundProfile.allCases.firstIndex(of: profile)! * 104_729))
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(v.duration * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        var lastNoise = 0.0, lowpass = 0.0, tailLow = 0.0
        var phase = 0.0

        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let noise = rng.nextSigned()
            let hp = noise - lastNoise
            lastNoise = noise
            lowpass += (hp - lowpass) * v.brightness
            var sample = lowpass * exp(-t * v.clickDecay) * v.clickGain
            if let second = v.secondClickAt, t >= second {
                sample += lowpass * exp(-(t - second) * v.clickDecay) * v.clickGain * 0.8
            }
            if let sweep = v.sweep {
                let progress = min(1, t / sweep.time)
                let hz = sweep.from + (sweep.to - sweep.from) * progress
                phase += 2 * .pi * hz / sr
                sample += sin(phase) * exp(-t * v.bodyDecay) * v.bodyGain
            } else if v.bodyHz > 0 {
                sample += sin(2 * .pi * v.bodyHz * t) * exp(-t * v.bodyDecay) * v.bodyGain
            }
            for p in v.partials {
                sample += sin(2 * .pi * p.hz * t) * exp(-t * p.decay) * p.gain
            }
            if let tailAt = v.tailAt, t > tailAt {
                let t2 = t - tailAt
                tailLow += (rng.nextSigned() - tailLow) * 0.3
                sample += (tailLow * exp(-t2 * 160) + sin(2 * .pi * 90 * t2) * exp(-t2 * 40)) * v.tailGain
            }
            let attack = min(1, t * 4000)
            let release = min(1, (v.duration - t) * 400)
            out[i] = Float(sample * attack * release * 0.5)
        }
        return buffer
    }
}

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func nextSigned() -> Double { Double(next() % 2_000_001) / 1_000_000 - 1 }
}
