// SynthCore: the render-thread half of AudioManager. A faithful, sample-accurate re-implementation of
// the WebAudio graph built by src/game/Audio.ts:
//
//   pads   : 8 osc (sine/triangle, ±6 ct) -> gain env -> lowpass sweep -> musicBus  (+0.5 -> reverbSend)
//   plucks : osc + 2.01x sine*0.25         -> gain env                   -> music/sfx (+0.7 -> reverbSend)
//   noise  : brown noise buffer            -> biquad -> gain env         -> sfxBus
//   grind  : looping noise                 -> lowpass (setTarget)  -> gain (setTarget) -> sfxBus
//   musicBus + sfxBus + reverb(reverbSend*0.9) -> master 0.9 -> DynamicsCompressor(-16 dB, 3:1) -> out
//
// Rendering happens in 128-frame quanta (the Web Audio render quantum). `currentTime` is the frame
// counter of the next quantum. Commands from the main thread arrive through a lock-free queue and are
// executed at the start of a quantum, exactly like ctx.currentTime-stamped calls in the original.
// The 120 ms scheduler tick of the original setInterval is driven from the same sample clock.
// Nothing in the render path allocates, locks or sends Objective-C messages.

import AVFoundation
import Accelerate
import Foundation

@inline(__always) private func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

final class SynthCore: @unchecked Sendable {
    static let moodNames = ["dawn", "noon", "dusk", "radiant"]

    // Chord progressions per mood as MIDI notes (calm modal harmony).
    private static let progressions: [[[Int]]] = [
        [[50, 57, 62, 66], [47, 54, 59, 62], [43, 50, 55, 59], [45, 52, 57, 61]], // dawn: D major-ish
        [[48, 55, 60, 64], [45, 52, 57, 60], [41, 48, 53, 57], [43, 50, 55, 62]], // noon: C / Am / F / G
        [[46, 53, 58, 62], [43, 50, 55, 58], [39, 46, 51, 55], [41, 48, 53, 57]], // dusk: Bb lydian colour
        [[50, 57, 62, 69], [52, 59, 64, 71], [47, 54, 62, 66], [45, 52, 61, 66]], // radiant
    ]
    private static let scales: [[Int]] = [
        [62, 64, 66, 69, 71, 74, 76, 78, 81],
        [60, 62, 64, 67, 69, 72, 74, 76, 79],
        [58, 60, 62, 65, 67, 70, 72, 74, 77],
        [62, 64, 66, 69, 71, 74, 76, 78, 81, 83],
    ]

    static let quantum = 128
    /// Biquads with an automated cutoff get new coefficients every 32 frames (Chromium: every frame;
    /// per-frame updates made no measurable difference against the Chrome reference render).
    static let filterUpdateInterval = 32
    let sampleRate: Double
    private let invSR: Double

    /// Main thread -> render thread commands.
    let commands = CommandQueue()

    // Clock.
    private(set) var frame: Int64 = 0
    var currentTime: Double { Double(frame) * invSR }

    // Flattened static tables (no Swift arrays touched on the render thread).
    private let progTable: UnsafeMutablePointer<Int>  // [mood][chord][note] 4x4x4
    private let scaleTable: UnsafeMutablePointer<Int> // [mood][10]
    private let scaleLen: UnsafeMutablePointer<Int>   // [mood]
    private let degreeTable: UnsafeMutablePointer<Int> // awaken [0,2,4,7,9] then finale [0,2,4,7,9,11,14]

    // Sources.
    private let tables: Wavetables
    private let noise: UnsafeMutablePointer<Float>
    private let noiseLen: Int
    private let reverb: PartitionedConvolver
    private let compressor: DynamicsCompressor
    private var rng: SynthRNG

    // Scheduler state (mirrors the TS fields).
    private var mood: Int
    private var chordIdx = 0
    private var nextChordAt: Double
    private var nextPluckAt: Double
    private var nextTickAt: Double
    private static let tickInterval = 0.12

    // Buses.
    private var musicGain: ParamTimeline
    private var sfxGain: ParamTimeline
    private let masterGain: Float = 0.9
    private let reverbSendGain: Float = 0.9

    // Voices.
    private struct PadVoice {
        var active = false
        var startFrame: Int64 = 0
        var stopFrame: Int64 = 0
        var gain: ParamTimeline
        var freq: ParamTimeline
        var filter = Biquad()
        var phase: UnsafeMutablePointer<Double> // 8 oscillators
        var inc: UnsafeMutablePointer<Double>
    }
    private struct PluckVoice {
        var active = false
        var startFrame: Int64 = 0
        var stopFrame: Int64 = 0
        var phase1 = 0.0, phase2 = 0.0, inc1 = 0.0, inc2 = 0.0
        var triangle = false
        var toMusic = false
        var gain: ParamTimeline
    }
    private struct NoiseVoice {
        var active = false
        var startFrame: Int64 = 0
        var stopFrame: Int64 = 0
        var readPos = 0.0
        var filter = Biquad()
        var gain: ParamTimeline
    }
    private static let padCount = 8
    private static let pluckCount = 64
    private static let noiseCount = 24
    private let pads: UnsafeMutablePointer<PadVoice>
    private let plucks: UnsafeMutablePointer<PluckVoice>
    private let noises: UnsafeMutablePointer<NoiseVoice>
    private var grindActive = false
    private var grindPos = 0
    private var grindFilter = Biquad()
    private var grindGain: ParamTimeline
    private var grindFreq: ParamTimeline

    // Scratch buffers (one quantum each).
    private let musicBuf: UnsafeMutablePointer<Float>
    private let sfxBuf: UnsafeMutablePointer<Float>
    private let revBuf: UnsafeMutablePointer<Float>
    private let tmpBuf: UnsafeMutablePointer<Float>
    private let paramBuf: UnsafeMutablePointer<Float>
    private let param2Buf: UnsafeMutablePointer<Float>
    private let wetL: UnsafeMutablePointer<Float>
    private let wetR: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private var outPos = SynthCore.quantum

    private var allocations: [UnsafeMutableRawPointer] = []

    init(sampleRate: Double = 48000, mood: Int = 0, musicVolume: Double = 0.6, sfxVolume: Double = 0.8, seed: UInt64? = nil) {
        self.sampleRate = sampleRate
        invSR = 1 / sampleRate
        var sys = SystemRandomNumberGenerator()
        rng = SynthRNG(seed: seed ?? sys.next())
        self.mood = mood

        var allocs: [UnsafeMutableRawPointer] = []
        func floats(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            allocs.append(UnsafeMutableRawPointer(p))
            return p
        }
        func doubles(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            allocs.append(UnsafeMutableRawPointer(p))
            return p
        }
        func timeline(_ capacity: Int, _ value: Double) -> ParamTimeline {
            let p = UnsafeMutablePointer<ParamEvent>.allocate(capacity: capacity)
            p.initialize(repeating: ParamEvent(kind: .setValue, frame: 0, time: 0, value: 0, tau: 0), count: capacity)
            allocs.append(UnsafeMutableRawPointer(p))
            return ParamTimeline(storage: p, capacity: capacity, sampleRate: sampleRate, value: value)
        }
        func ints(_ n: Int) -> UnsafeMutablePointer<Int> {
            let p = UnsafeMutablePointer<Int>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            allocs.append(UnsafeMutableRawPointer(p))
            return p
        }

        progTable = ints(64)
        scaleTable = ints(40)
        scaleLen = ints(4)
        degreeTable = ints(12)
        for (i, d) in [0, 2, 4, 7, 9, 0, 2, 4, 7, 9, 11, 14].enumerated() { degreeTable[i] = d }
        for m in 0..<4 {
            for c in 0..<4 { for n in 0..<4 { progTable[m * 16 + c * 4 + n] = SynthCore.progressions[m][c][n] } }
            scaleLen[m] = SynthCore.scales[m].count
            for (i, v) in SynthCore.scales[m].enumerated() { scaleTable[m * 10 + i] = v }
        }

        tables = Wavetables(sampleRate: sampleRate, maxTriangleFrequency: mtof(71) * 1.005)

        // Reverb impulse: 3.6 s stereo noise with (1 - i/len)^2.4 decay.
        let irLen = Int(sampleRate * 3.6)
        let irL = UnsafeMutablePointer<Float>.allocate(capacity: irLen)
        let irR = UnsafeMutablePointer<Float>.allocate(capacity: irLen)
        defer { irL.deallocate(); irR.deallocate() }
        for c in 0..<2 {
            let d = c == 0 ? irL : irR
            for i in 0..<irLen {
                d[i] = Float((rng.random() * 2 - 1) * pow(1 - Double(i) / Double(irLen), 2.4))
            }
        }
        reverb = PartitionedConvolver(left: irL, right: irR, length: irLen, sampleRate: sampleRate)

        // 2 s of brownish noise.
        noiseLen = Int(sampleRate * 2)
        noise = floats(noiseLen)
        var b = 0.0
        for i in 0..<noiseLen {
            b = 0.97 * b + 0.03 * (rng.random() * 2 - 1)
            noise[i] = Float(b * 6)
        }

        compressor = DynamicsCompressor(sampleRate: sampleRate, threshold: -16, ratio: 3)

        musicGain = timeline(32, 1)
        sfxGain = timeline(32, 1)
        grindGain = timeline(32, 0)
        grindFreq = timeline(32, 220)

        pads = .allocate(capacity: SynthCore.padCount)
        for i in 0..<SynthCore.padCount {
            (pads + i).initialize(to: PadVoice(gain: timeline(8, 1), freq: timeline(8, 350), phase: doubles(8), inc: doubles(8)))
        }
        plucks = .allocate(capacity: SynthCore.pluckCount)
        for i in 0..<SynthCore.pluckCount { (plucks + i).initialize(to: PluckVoice(gain: timeline(8, 1))) }
        noises = .allocate(capacity: SynthCore.noiseCount)
        for i in 0..<SynthCore.noiseCount { (noises + i).initialize(to: NoiseVoice(gain: timeline(8, 1))) }

        let q = SynthCore.quantum
        musicBuf = floats(q); sfxBuf = floats(q); revBuf = floats(q); tmpBuf = floats(q)
        paramBuf = floats(q); param2Buf = floats(q)
        wetL = floats(q); wetR = floats(q); outL = floats(q); outR = floats(q)
        allocations = allocs

        // start(): applyVolumes at currentTime 0, first chord at 0.2 s, first pluck at 2.5 s.
        nextChordAt = 0.2
        nextPluckAt = 2.5
        nextTickAt = SynthCore.tickInterval
        applyVolumes(music: musicVolume, sfx: sfxVolume, now: 0)
    }

    deinit {
        pads.deinitialize(count: SynthCore.padCount); pads.deallocate()
        plucks.deinitialize(count: SynthCore.pluckCount); plucks.deallocate()
        noises.deinitialize(count: SynthCore.noiseCount); noises.deallocate()
        for p in allocations { p.deallocate() }
    }

    /// Reverb normalisation scale and compressor makeup gain (diagnostics).
    var diagnostics: (reverbScale: Float, makeupGain: Float) { (reverb.normalizationScale, compressor.makeupGain) }

    // MARK: AVAudioSourceNode

    var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)! }

    /// A source node whose render block pulls from this core. The node does not retain the core;
    /// the owner must keep the core alive while the engine runs.
    func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [unowned(unsafe) self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            if buffers.count >= 2,
               let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                self.render(frames: n, left: l, right: r)
            } else if buffers.count == 1, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                self.render(frames: n, left: l, right: nil)
            }
            return noErr
        }
    }

    // MARK: Rendering

    /// Render `frames` stereo frames. Real-time safe.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        var done = 0
        let q = SynthCore.quantum
        while done < frames {
            if outPos >= q { renderQuantum(); outPos = 0 }
            let n = q - outPos < frames - done ? q - outPos : frames - done
            (left + done).update(from: outL + outPos, count: n)
            if let right { (right + done).update(from: outR + outPos, count: n) }
            outPos += n
            done += n
        }
    }

    private func renderQuantum() {
        let q = SynthCore.quantum
        let f0 = frame
        let now = Double(f0) * invSR

        while let c = commands.pop() { execute(c, now: now) }
        if now >= nextTickAt {
            tick(now)
            nextTickAt += SynthCore.tickInterval
            if nextTickAt <= now { nextTickAt = now + SynthCore.tickInterval }
        }

        vDSP_vclr(musicBuf, 1, vDSP_Length(q))
        vDSP_vclr(sfxBuf, 1, vDSP_Length(q))
        vDSP_vclr(revBuf, 1, vDSP_Length(q))

        renderPads(f0)
        renderPlucks(f0)
        renderNoises(f0)
        renderGrind(f0)

        // Bus gains (a-rate setTargetAtTime smoothing).
        musicGain.render(frame0: f0, count: q, into: paramBuf)
        sfxGain.render(frame0: f0, count: q, into: param2Buf)
        // dry = music * gM + sfx * gS
        vDSP_vmul(musicBuf, 1, paramBuf, 1, musicBuf, 1, vDSP_Length(q))
        vDSP_vma(sfxBuf, 1, param2Buf, 1, musicBuf, 1, musicBuf, 1, vDSP_Length(q))

        // Reverb: reverbSend (0.9) -> convolver (mono in, stereo IR).
        var send = reverbSendGain
        vDSP_vsmul(revBuf, 1, &send, revBuf, 1, vDSP_Length(q))
        reverb.process(input: revBuf, frame: f0, outL: wetL, outR: wetR)

        // master = 0.9 * (dry upmixed to L=R + wet)
        var mg = masterGain
        vDSP_vadd(musicBuf, 1, wetL, 1, outL, 1, vDSP_Length(q))
        vDSP_vadd(musicBuf, 1, wetR, 1, outR, 1, vDSP_Length(q))
        vDSP_vsmul(outL, 1, &mg, outL, 1, vDSP_Length(q))
        vDSP_vsmul(outR, 1, &mg, outR, 1, vDSP_Length(q))

        compressor.process(outL, outR, q)

        // Destination: clamp to [-1, 1] like the browser's output stage.
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(outL, 1, &lo, &hi, outL, 1, vDSP_Length(q))
        vDSP_vclip(outR, 1, &lo, &hi, outR, 1, vDSP_Length(q))

        frame += Int64(q)
    }

    @inline(__always) private func frameFor(_ t: Double) -> Int64 {
        Int64((t * sampleRate - 1e-6).rounded(.up))
    }

    // Note: render-path loops are `while` loops on purpose. In unoptimised (Debug) builds a
    // `for i in 0..<n` loop goes through generic IndexingIterator/coroutine code that calls malloc.

    private func renderPads(_ f0: Int64) {
        let q = SynthCore.quantum
        let fEnd = f0 + Int64(q)
        var v = 0
        while v < SynthCore.padCount {
            let p = pads + v
            v += 1
            if !p.pointee.active { continue }
            let s = maxFrame(f0, p.pointee.startFrame)
            let e = minFrame(fEnd, p.pointee.stopFrame)
            if e > s {
                let i0 = Int(s - f0), n = Int(e - s)
                let out = tmpBuf
                vDSP_vclr(out, 1, vDSP_Length(n))
                var o = 0
                while o < 8 {
                    // note 0: sine pair at 0.5, notes 1-3: triangle pairs at 0.22
                    let table = o < 2 ? tables.sine : tables.triangle
                    let amp: Float = o < 2 ? 0.5 : 0.22
                    var ph = p.pointee.phase[o]
                    let inc = p.pointee.inc[o]
                    var j = 0
                    while j < n {
                        out[j] += wavetableLookup(table, ph) * amp
                        ph += inc
                        if ph >= 1 { ph -= 1 }
                        j += 1
                    }
                    p.pointee.phase[o] = ph
                    o += 1
                }
                p.pointee.gain.render(frame0: s, count: n, into: paramBuf)
                vDSP_vmul(out, 1, paramBuf, 1, out, 1, vDSP_Length(n))
                // Automated cutoff: coefficients recomputed every `filterUpdateInterval` frames
                // (Chromium recomputes them every frame while the frequency param is automated).
                var j = 0
                while j < n {
                    let len = n - j < SynthCore.filterUpdateInterval ? n - j : SynthCore.filterUpdateInterval
                    let fc = p.pointee.freq.value(atFrame: s + Int64(j))
                    p.pointee.filter.setLowpass(frequency: fc, qDb: 0.4, sampleRate: sampleRate)
                    p.pointee.filter.process(out + j, len)
                    j += len
                }
                vDSP_vadd(musicBuf + i0, 1, out, 1, musicBuf + i0, 1, vDSP_Length(n))
                var sendGain: Float = 0.5
                vDSP_vsma(out, 1, &sendGain, revBuf + i0, 1, revBuf + i0, 1, vDSP_Length(n))
            }
            if p.pointee.stopFrame <= fEnd { p.pointee.active = false }
        }
    }

    private func renderPlucks(_ f0: Int64) {
        let q = SynthCore.quantum
        let fEnd = f0 + Int64(q)
        let sine = tables.sine
        var v = 0
        while v < SynthCore.pluckCount {
            let p = plucks + v
            v += 1
            if !p.pointee.active { continue }
            let s = maxFrame(f0, p.pointee.startFrame)
            let e = minFrame(fEnd, p.pointee.stopFrame)
            if e > s {
                let i0 = Int(s - f0), n = Int(e - s)
                p.pointee.gain.render(frame0: s, count: n, into: paramBuf)
                let t1 = p.pointee.triangle ? tables.triangle : sine
                var ph1 = p.pointee.phase1, ph2 = p.pointee.phase2
                let inc1 = p.pointee.inc1, inc2 = p.pointee.inc2
                let out = tmpBuf
                let g = paramBuf
                var j = 0
                while j < n {
                    out[j] = (wavetableLookup(t1, ph1) + 0.25 * wavetableLookup(sine, ph2)) * g[j]
                    ph1 += inc1; if ph1 >= 1 { ph1 -= 1 }
                    ph2 += inc2; if ph2 >= 1 { ph2 -= 1 }
                    j += 1
                }
                p.pointee.phase1 = ph1
                p.pointee.phase2 = ph2
                let bus = (p.pointee.toMusic ? musicBuf : sfxBuf) + i0
                vDSP_vadd(bus, 1, out, 1, bus, 1, vDSP_Length(n))
                var sendGain: Float = 0.7
                vDSP_vsma(out, 1, &sendGain, revBuf + i0, 1, revBuf + i0, 1, vDSP_Length(n))
            }
            if p.pointee.stopFrame <= fEnd { p.pointee.active = false }
        }
    }

    private func renderNoises(_ f0: Int64) {
        let q = SynthCore.quantum
        let fEnd = f0 + Int64(q)
        let len = noiseLen
        let lenD = Double(len)
        var v = 0
        while v < SynthCore.noiseCount {
            let p = noises + v
            v += 1
            if !p.pointee.active { continue }
            let s = maxFrame(f0, p.pointee.startFrame)
            let e = minFrame(fEnd, p.pointee.stopFrame)
            if e > s {
                let i0 = Int(s - f0), n = Int(e - s)
                let out = tmpBuf
                var pos = p.pointee.readPos
                var j = 0
                while j < n {
                    // AudioBufferSourceNode, playbackRate 1; output stops at the end of the
                    // (non-looping) buffer. readPos is integral, so the interpolation is a plain read.
                    if pos < lenD {
                        let i = Int(pos)
                        let frac = Float(pos - Double(i))
                        let a = noise[i]
                        let b = i + 1 < len ? noise[i + 1] : a
                        out[j] = a + (b - a) * frac
                    } else {
                        out[j] = 0
                    }
                    pos += 1
                    j += 1
                }
                p.pointee.readPos = pos
                p.pointee.filter.process(out, n)
                p.pointee.gain.render(frame0: s, count: n, into: paramBuf)
                vDSP_vmul(out, 1, paramBuf, 1, out, 1, vDSP_Length(n))
                vDSP_vadd(sfxBuf + i0, 1, out, 1, sfxBuf + i0, 1, vDSP_Length(n))
            }
            if p.pointee.stopFrame <= fEnd { p.pointee.active = false }
        }
    }

    private func renderGrind(_ f0: Int64) {
        guard grindActive else { return }
        let q = SynthCore.quantum
        let out = tmpBuf
        // Looping buffer source from offset 0: copy in at most two contiguous pieces.
        let first = q < noiseLen - grindPos ? q : noiseLen - grindPos
        out.update(from: noise + grindPos, count: first)
        if first < q { out.advanced(by: first).update(from: noise, count: q - first) }
        grindPos = (grindPos + q) % noiseLen
        var j = 0
        while j < q {
            let fc = grindFreq.value(atFrame: f0 + Int64(j))
            grindFilter.setLowpass(frequency: fc, qDb: 2, sampleRate: sampleRate)
            grindFilter.process(out + j, SynthCore.filterUpdateInterval)
            j += SynthCore.filterUpdateInterval
        }
        grindGain.render(frame0: f0, count: q, into: paramBuf)
        vDSP_vmul(out, 1, paramBuf, 1, out, 1, vDSP_Length(q))
        vDSP_vadd(sfxBuf, 1, out, 1, sfxBuf, 1, vDSP_Length(q))
    }

    // MARK: Music

    private func tick(_ now: Double) {
        if now >= nextChordAt - 0.05 {
            playChord(mood: mood, chord: chordIdx % 4, at: nextChordAt, dur: 11, now: now)
            chordIdx += 1
            nextChordAt += 9
        }
        if now >= nextPluckAt {
            let len = scaleLen[mood]
            let n = Double(scaleTable[mood * 10 + Int(rng.random() * Double(len))])
            pluck(freq: mtof(n), at: now + 0.02, vol: 0.07 + rng.random() * 0.05, toMusic: true, now: now)
            if rng.random() < 0.35 {
                pluck(freq: mtof(n + (rng.random() < 0.5 ? 7 : 12)), at: now + 0.42, vol: 0.04, toMusic: true, now: now)
            }
            nextPluckAt = now + 2.2 + rng.random() * 4.5
        }
    }

    private func playChord(mood m: Int, chord c: Int, at: Double, dur: Double, now: Double) {
        // Reuse a free voice, else steal the one that ends first.
        let idx = findVoice(SynthCore.padCount) { pads[$0].active ? pads[$0].stopFrame : nil }
        let p = pads + idx
        p.pointee.active = true
        p.pointee.startFrame = frameFor(fmax(at, now))
        p.pointee.stopFrame = frameFor(at + dur + 0.1)
        p.pointee.gain.reset(value: 1, at: now)
        p.pointee.gain.setValueAtTime(0, at, now: now)
        p.pointee.gain.linearRampToValueAtTime(0.11, at + 3.5, now: now)
        p.pointee.gain.setValueAtTime(0.11, at + dur - 4, now: now)
        p.pointee.gain.linearRampToValueAtTime(0, at + dur, now: now)
        p.pointee.freq.reset(value: 350, at: now)
        p.pointee.freq.setValueAtTime(700, at, now: now)
        p.pointee.freq.linearRampToValueAtTime(1500, at + dur / 2, now: now)
        p.pointee.freq.linearRampToValueAtTime(600, at + dur, now: now)
        p.pointee.filter.resetState()
        var o = 0
        while o < 8 {
            let f = mtof(Double(progTable[m * 16 + c * 4 + o / 2]))
            let detune = (o & 1 == 0 ? -6.0 : 6.0) + (rng.random() - 0.5) * 3
            p.pointee.inc[o] = f * pow(2, detune / 1200) * invSR
            p.pointee.phase[o] = 0
            o += 1
        }
    }

    private func pluck(freq: Double, at: Double, vol: Double, toMusic: Bool, decay: Double = 2.6, triangle: Bool = false, now: Double) {
        let idx = findVoice(SynthCore.pluckCount) { plucks[$0].active ? plucks[$0].stopFrame : nil }
        let p = plucks + idx
        p.pointee.active = true
        p.pointee.startFrame = frameFor(fmax(at, now))
        p.pointee.stopFrame = frameFor(at + decay + 0.05)
        p.pointee.phase1 = 0
        p.pointee.phase2 = 0
        p.pointee.inc1 = freq * invSR
        p.pointee.inc2 = freq * 2.01 * invSR
        p.pointee.triangle = triangle
        p.pointee.toMusic = toMusic
        p.pointee.gain.reset(value: 1, at: now)
        p.pointee.gain.setValueAtTime(0, at, now: now)
        p.pointee.gain.linearRampToValueAtTime(vol, at + 0.01, now: now)
        p.pointee.gain.exponentialRampToValueAtTime(0.0001, at + decay, now: now)
    }

    /// First free voice index, else the active voice that stops first (voice stealing).
    @inline(__always)
    private func findVoice(_ count: Int, _ stopFrameIfActive: (Int) -> Int64?) -> Int {
        var idx = 0
        var earliest = Int64.max
        var i = 0
        while i < count {
            guard let stop = stopFrameIfActive(i) else { return i }
            if stop < earliest { earliest = stop; idx = i }
            i += 1
        }
        return idx
    }

    private func noiseHit(at: Double, dur: Double, freq: Double, vol: Double, q: Double = 1, bandpass: Bool = false, now: Double) {
        let idx = findVoice(SynthCore.noiseCount) { noises[$0].active ? noises[$0].stopFrame : nil }
        let p = noises + idx
        p.pointee.active = true
        p.pointee.startFrame = frameFor(fmax(at, now))
        p.pointee.stopFrame = frameFor(at + dur + 0.05)
        // src.start(at, Math.random()): offset in seconds. Chrome starts at the nearest sample frame
        // (verified against an OfflineAudioContext render), so the offset is rounded, not interpolated.
        p.pointee.readPos = (rng.random() * sampleRate).rounded()
        p.pointee.filter.resetState()
        if bandpass {
            p.pointee.filter.setBandpass(frequency: freq, q: q, sampleRate: sampleRate)
        } else {
            p.pointee.filter.setLowpass(frequency: freq, qDb: q, sampleRate: sampleRate)
        }
        p.pointee.gain.reset(value: 1, at: now)
        p.pointee.gain.setValueAtTime(0, at, now: now)
        p.pointee.gain.linearRampToValueAtTime(vol, at + fmin(0.05, dur * 0.2), now: now)
        p.pointee.gain.exponentialRampToValueAtTime(0.0001, at + dur, now: now)
    }

    // MARK: Effects

    private func scaleNote(_ i: Int) -> Double {
        let len = scaleLen[mood]
        let idx = ((i % len) + len) % len
        let oct = Int((Double(i) / Double(len)).rounded(.down))
        return Double(scaleTable[mood * 10 + idx] + 12 * oct)
    }

    private func applyVolumes(music: Double, sfx: Double, now: Double) {
        musicGain.setTargetAtTime(music * 0.55, now, 0.3, now: now)
        sfxGain.setTargetAtTime(sfx * 0.9, now, 0.1, now: now)
    }

    private func execute(_ c: SynthCommand, now t: Double) {
        switch c {
        case let .setVolumes(music, sfx):
            applyVolumes(music: music, sfx: sfx, now: t)
        case let .setMood(m):
            mood = m
            chordIdx = 0
            nextChordAt = fmin(nextChordAt, t + 1.5)
        case .tap:
            pluck(freq: mtof(scaleNote(4) + 12), at: t, vol: 0.05, toMusic: false, decay: 0.6, now: t)
        case .nope:
            pluck(freq: mtof(scaleNote(0) - 12), at: t, vol: 0.06, toMusic: false, decay: 0.5, triangle: true, now: t)
            noiseHit(at: t, dur: 0.15, freq: 300, vol: 0.05, now: t)
        case let .step(i):
            noiseHit(at: t, dur: 0.07, freq: 900 + Double(i % 2) * 300, vol: 0.035, q: 0.7, bandpass: true, now: t)
        case let .grind(v):
            if !grindActive && v > 0.01 {
                grindActive = true
                grindPos = 0
                grindFilter.resetState()
                grindFreq.reset(value: 220, at: t)
                grindGain.reset(value: 0, at: t)
            }
            if grindActive {
                grindGain.setTargetAtTime(fmin(0.32, v * 0.32), t, 0.05, now: t)
                grindFreq.setTargetAtTime(160 + v * 260, t, 0.08, now: t)
            }
        case let .detent(i):
            pluck(freq: mtof(scaleNote(i + 2)), at: t, vol: 0.07, toMusic: false, decay: 1.6, now: t)
        case .snap:
            noiseHit(at: t, dur: 0.25, freq: 180, vol: 0.22, q: 1, now: t)
            pluck(freq: mtof(scaleNote(0) - 12), at: t, vol: 0.07, toMusic: false, decay: 1.2, now: t)
        case .plate:
            pluck(freq: mtof(scaleNote(0) - 12), at: t, vol: 0.12, toMusic: false, decay: 3.5, now: t)
            pluck(freq: mtof(scaleNote(2)), at: t + 0.12, vol: 0.06, toMusic: false, decay: 2.5, now: t)
            pluck(freq: mtof(scaleNote(4)), at: t + 0.24, vol: 0.05, toMusic: false, decay: 2.5, now: t)
        case let .rumble(dur):
            noiseHit(at: t, dur: dur, freq: 120, vol: 0.35, q: 1.5, now: t)
        case let .connect(seam):
            let base = seam ? 5 : 3
            var i = 0
            while i < (seam ? 4 : 2) {
                pluck(freq: mtof(scaleNote(base + i * 2) + (seam ? 12 : 0)), at: t + Double(i) * 0.09, vol: 0.05,
                      toMusic: false, decay: 2.4, now: t)
                i += 1
            }
        case .worldTurn:
            noiseHit(at: t, dur: 1.3, freq: 140, vol: 0.18, q: 0.8, now: t)
            pluck(freq: mtof(scaleNote(0) - 12), at: t, vol: 0.08, toMusic: false, decay: 3, now: t)
            pluck(freq: mtof(scaleNote(4) - 12), at: t + 0.5, vol: 0.06, toMusic: false, decay: 3, now: t)
        case .awaken:
            var i = 0
            while i < 5 {
                pluck(freq: mtof(scaleNote(degreeTable[i])), at: t + Double(i) * 0.16, vol: 0.06, toMusic: false, decay: 4, now: t)
                i += 1
            }
            noiseHit(at: t, dur: 2.5, freq: 2500, vol: 0.05, q: 0.5, bandpass: true, now: t)
        case .chapter:
            pluck(freq: mtof(scaleNote(0)), at: t, vol: 0.05, toMusic: false, decay: 4, now: t)
            pluck(freq: mtof(scaleNote(4)), at: t + 0.3, vol: 0.04, toMusic: false, decay: 4, now: t)
        case .finale:
            // The main thread already switched the mood to radiant (setMood command precedes this one).
            var i = 0
            while i < 7 {
                pluck(freq: mtof(scaleNote(degreeTable[5 + i])), at: t + Double(i) * 0.22, vol: 0.07, toMusic: false, decay: 5, now: t)
                i += 1
            }
            playChord(mood: 3, chord: 0, at: t + 0.1, dur: 14, now: t)
        }
    }
}
