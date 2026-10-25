// SynthPrimitives: small real-time-safe DSP building blocks used by SynthCore.
// Everything here mirrors a Web Audio API primitive (AudioParam automation, BiquadFilterNode,
// OscillatorNode wavetables) so the native port sounds like the original WebAudio synth.
// No allocation happens in any method that is called from the render thread.

import Accelerate
import Foundation
import Synchronization
import os

// MARK: - Random numbers (render-thread safe, replaces Math.random)

/// xorshift128+ generator. `random()` returns a Double in [0, 1) like Math.random().
struct SynthRNG {
    private var s0: UInt64
    private var s1: UInt64

    init(seed: UInt64) {
        var z = seed
        s0 = SynthRNG.splitmix(&z)
        s1 = SynthRNG.splitmix(&z)
        if s0 == 0 && s1 == 0 { s1 = 0x9E3779B97F4A7C15 }
    }

    private static func splitmix(_ x: inout UInt64) -> UInt64 {
        x &+= 0x9E37_79B9_7F4A_7C15
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    @inline(__always)
    mutating func next() -> UInt64 {
        var a = s0
        let b = s1
        s0 = b
        a ^= a << 23
        s1 = a ^ b ^ (a >> 17) ^ (b >> 26)
        return s1 &+ b
    }

    @inline(__always)
    mutating func random() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

// MARK: - AudioParam automation timeline

/// One automation event, as in the Web Audio API's AudioParam event list.
struct ParamEvent {
    enum Kind: Int32 { case setValue, linearRamp, exponentialRamp, setTarget }
    var kind: Kind
    /// First sample frame at which the event is "reached" (frame/sampleRate >= time).
    var frame: Int64
    var time: Double
    var value: Double
    var tau: Double
}

/// A sample-accurate AudioParam timeline (a-rate), following the Web Audio spec:
///  - setValueAtTime holds V from T.
///  - linear/exponential ramps run from the previous event's (time, value) to (T1, V1).
///  - setTargetAtTime approaches the target from the value the param has at its start time.
///  - exponential ramps hold V0 when V0 and V1 have opposite signs or V0 == 0.
/// Event storage is a fixed, pre-allocated slab; no allocation in `render`.
struct ParamTimeline {
    private let events: UnsafeMutablePointer<ParamEvent>
    private let capacity: Int
    private var count = 0
    private let sampleRate: Double
    private let invSR: Double

    // Current segment state (the most recently reached event).
    private var holdValue: Double
    private var anchorT: Double = 0
    private var anchorV: Double
    private var targeting = false
    private var goal: Double = 0
    private var tau: Double = 1

    init(storage: UnsafeMutablePointer<ParamEvent>, capacity: Int, sampleRate: Double, value: Double) {
        events = storage
        self.capacity = capacity
        self.sampleRate = sampleRate
        invSR = 1 / sampleRate
        holdValue = value
        anchorV = value
    }

    /// Equivalent of creating a fresh node and assigning `param.value = v` (no events).
    mutating func reset(value: Double, at time: Double) {
        count = 0
        holdValue = value
        anchorV = value
        anchorT = time
        targeting = false
    }

    @inline(__always)
    private func frameFor(_ t: Double) -> Int64 {
        Int64((t * sampleRate - 1e-6).rounded(.up))
    }

    private mutating func insert(_ kind: ParamEvent.Kind, _ time: Double, _ value: Double, _ tau: Double, now: Double) {
        let t = fmax(time, now) // the spec clamps times in the past to currentTime
        if count == capacity {
            // Overflow fallback (never expected with the sizes used): apply the oldest event early.
            reach(events[0])
            removeFirst()
        }
        var pos = count
        while pos > 0 && events[pos - 1].time > t { pos -= 1 } // stable: after equal times
        var i = count
        while i > pos { events[i] = events[i - 1]; i -= 1 }
        events[pos] = ParamEvent(kind: kind, frame: frameFor(t), time: t, value: value, tau: tau)
        count += 1
    }

    mutating func setValueAtTime(_ v: Double, _ t: Double, now: Double) { insert(.setValue, t, v, 0, now: now) }
    mutating func linearRampToValueAtTime(_ v: Double, _ t: Double, now: Double) { insert(.linearRamp, t, v, 0, now: now) }
    mutating func exponentialRampToValueAtTime(_ v: Double, _ t: Double, now: Double) { insert(.exponentialRamp, t, v, 0, now: now) }
    mutating func setTargetAtTime(_ target: Double, _ t: Double, _ timeConstant: Double, now: Double) {
        insert(.setTarget, t, target, timeConstant, now: now)
    }

    private mutating func removeFirst() {
        count -= 1
        var i = 0
        while i < count { events[i] = events[i + 1]; i += 1 }
    }

    @inline(__always)
    private func segmentValue(_ t: Double) -> Double {
        targeting ? goal + (anchorV - goal) * exp(-(t - anchorT) / tau) : holdValue
    }

    private mutating func reach(_ e: ParamEvent) {
        switch e.kind {
        case .setTarget:
            let v0 = segmentValue(e.time)
            anchorT = e.time
            anchorV = v0
            holdValue = v0
            targeting = true
            goal = e.value
            tau = fmax(e.tau, 1e-9)
        default:
            targeting = false
            holdValue = e.value
            anchorT = e.time
            anchorV = e.value
        }
    }

    @inline(__always)
    private mutating func advance(to f: Int64) {
        while count > 0 && events[0].frame <= f {
            reach(events[0])
            removeFirst()
        }
    }

    /// Closed-form value at frame f (k-rate evaluation; also advances the event list).
    mutating func value(atFrame f: Int64) -> Double {
        advance(to: f)
        let t = Double(f) * invSR
        if count > 0 {
            let e = events[0]
            if e.kind == .linearRamp || e.kind == .exponentialRamp {
                return rampValue(e, t)
            }
        }
        return segmentValue(t)
    }

    @inline(__always)
    private func rampValue(_ e: ParamEvent, _ t: Double) -> Double {
        let span = e.time - anchorT
        if span <= 0 { return e.value }
        let x = (t - anchorT) / span
        if e.kind == .linearRamp { return anchorV + (e.value - anchorV) * x }
        if anchorV == 0 || anchorV * e.value < 0 { return anchorV }
        return anchorV * pow(e.value / anchorV, x)
    }

    @inline(__always)
    private func fill(_ out: UnsafeMutablePointer<Float>, _ from: Int, _ to: Int, _ v: Float) {
        var value = v
        vDSP_vfill(&value, out + from, 1, vDSP_Length(to - from))
    }

    /// Renders `n` a-rate values for frames [frame0, frame0 + n) into `out`.
    mutating func render(frame0: Int64, count n: Int, into out: UnsafeMutablePointer<Float>) {
        var i = 0
        while i < n {
            let f = frame0 + Int64(i)
            advance(to: f)
            var end = n
            if count > 0 {
                let ef = events[0].frame - frame0
                if ef < Int64(end) { end = Int(ef) }
            }
            if end <= i { end = i + 1 } // safety
            let t0 = Double(f) * invSR
            if count > 0 && (events[0].kind == .linearRamp || events[0].kind == .exponentialRamp) {
                let e = events[0]
                let span = e.time - anchorT
                if span <= 0 {
                    fill(out, i, end, Float(e.value))
                } else if e.kind == .linearRamp {
                    var v = anchorV + (e.value - anchorV) * (t0 - anchorT) / span
                    let dv = (e.value - anchorV) / span * invSR
                    var j = i
                    while j < end { out[j] = Float(v); v += dv; j += 1 }
                } else if anchorV == 0 || anchorV * e.value < 0 {
                    fill(out, i, end, Float(anchorV))
                } else {
                    let ratio = e.value / anchorV
                    var v = anchorV * pow(ratio, (t0 - anchorT) / span)
                    let r = pow(ratio, invSR / span)
                    var j = i
                    while j < end { out[j] = Float(v); v *= r; j += 1 }
                }
            } else if targeting {
                var d = (anchorV - goal) * exp(-(t0 - anchorT) / tau)
                let k = exp(-invSR / tau)
                let g = goal
                var j = i
                while j < end { out[j] = Float(g + d); d *= k; j += 1 }
            } else {
                fill(out, i, end, Float(holdValue))
            }
            i = end
        }
    }
}

// MARK: - BiquadFilterNode (Chromium / Web Audio spec coefficient formulas)

struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    mutating func resetState() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    private mutating func setNormalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        let s = 1 / a0
        self.b0 = b0 * s; self.b1 = b1 * s; self.b2 = b2 * s; self.a1 = a1 * s; self.a2 = a2 * s
    }

    /// Lowpass: the spec/Chromium interpret Q in dB here (alpha = sin(w0) / (2 * 10^(Q/20))).
    mutating func setLowpass(frequency: Double, qDb: Double, sampleRate: Double) {
        let cutoff = min(max(frequency / (sampleRate * 0.5), 0), 1)
        if cutoff == 1 {
            setNormalized(1, 0, 0, 1, 0, 0)
        } else if cutoff > 0 {
            let resonance = pow(10, qDb / 20)
            let theta = Double.pi * cutoff
            let alpha = sin(theta) / (2 * resonance)
            let cosw = cos(theta)
            let beta = (1 - cosw) / 2
            setNormalized(beta, 2 * beta, beta, 1 + alpha, -2 * cosw, 1 - alpha)
        } else {
            setNormalized(0, 0, 0, 1, 0, 0)
        }
    }

    /// Bandpass: Q is linear (alpha = sin(w0) / (2Q)), constant 0 dB skirt gain.
    mutating func setBandpass(frequency: Double, q: Double, sampleRate: Double) {
        let f = max(frequency / (sampleRate * 0.5), 0)
        let q = max(q, 0)
        if f > 0 && f < 1 {
            if q > 0 {
                let w0 = Double.pi * f
                let alpha = sin(w0) / (2 * q)
                let k = cos(w0)
                setNormalized(alpha, 0, -alpha, 1 + alpha, -2 * k, 1 - alpha)
            } else {
                setNormalized(1, 0, 0, 1, 0, 0)
            }
        } else {
            setNormalized(0, 0, 0, 1, 0, 0)
        }
    }

    /// Direct form I, in place (same structure as Chromium's Biquad::Process).
    mutating func process(_ buf: UnsafeMutablePointer<Float>, _ n: Int) {
        var x1 = self.x1, x2 = self.x2, y1 = self.y1, y2 = self.y2
        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        var i = 0
        while i < n {
            let x = Double(buf[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            buf[i] = Float(y)
            x2 = x1; x1 = x; y2 = y1; y1 = y
            i += 1
        }
        // flush denormals
        if y1.magnitude < 1e-25 && y2.magnitude < 1e-25 && x1 == 0 && x2 == 0 { y1 = 0; y2 = 0 }
        self.x1 = x1; self.x2 = x2; self.y1 = y1; self.y2 = y2
    }
}

// MARK: - Oscillator wavetables

/// Band-limited wavetables equivalent to Chromium's built-in PeriodicWaves for 'sine' and 'triangle'.
final class Wavetables {
    static let size = 4096
    static let mask = 4095
    let sine: UnsafeMutablePointer<Float>
    let triangle: UnsafeMutablePointer<Float>

    /// `maxTriangleFrequency`: highest fundamental that will use the triangle table; partials are
    /// limited to below Nyquist for it (like Chromium's per-range band-limited tables).
    init(sampleRate: Double, maxTriangleFrequency: Double) {
        let n = Wavetables.size
        sine = .allocate(capacity: n + 1)
        triangle = .allocate(capacity: n + 1)
        for i in 0...n { sine[i] = Float(sin(2 * Double.pi * Double(i) / Double(n))) }

        // Triangle Fourier series (Chromium): b[k] = 8 / (pi^2 k^2) * (+1, -1, ...) for odd k.
        func coeff(_ k: Int) -> Double {
            guard k & 1 == 1 else { return 0 }
            let sign: Double = (((k - 1) >> 1) & 1) == 1 ? -1 : 1
            return 8 / (Double.pi * Double.pi * Double(k * k)) * sign
        }
        // Chromium normalises by the peak of the full-band table. That peak is at phase 1/4, where
        // every partial adds with the same sign, so it is simply the sum of |b[k]|.
        var fullPeak = 0.0
        var kk = 1
        while kk < n / 2 { fullPeak += abs(coeff(kk)); kk += 2 }
        let tmp = UnsafeMutablePointer<Double>.allocate(capacity: n)
        defer { tmp.deallocate() }
        let maxK = max(1, Int((sampleRate * 0.5) / maxTriangleFrequency))
        for i in 0..<n {
            var s = 0.0
            var k = 1
            while k <= maxK {
                s += coeff(k) * sin(2 * Double.pi * Double(k) * Double(i) / Double(n))
                k += 2
            }
            tmp[i] = s / fullPeak
        }
        for i in 0..<n { triangle[i] = Float(tmp[i]) }
        triangle[n] = triangle[0]
    }

    deinit {
        sine.deallocate()
        triangle.deallocate()
    }

}

/// Linear-interpolated wavetable read; `phase` in [0, 1). Table has `Wavetables.size + 1` entries.
@inline(__always)
func wavetableLookup(_ table: UnsafeMutablePointer<Float>, _ phase: Double) -> Float {
    let x = phase * 4096
    let i = Int(x)
    let frac = Float(x - Double(i))
    let a = table[i & 4095]
    let b = table[(i & 4095) + 1]
    return a + (b - a) * frac
}

@inline(__always) func minFrame(_ a: Int64, _ b: Int64) -> Int64 { a < b ? a : b }
@inline(__always) func maxFrame(_ a: Int64, _ b: Int64) -> Int64 { a > b ? a : b }

// MARK: - Commands (main thread -> render thread)

enum SynthCommand {
    case setVolumes(music: Double, sfx: Double)
    case setMood(Int)
    case tap
    case nope
    case step(Int)
    case grind(Double)
    case detent(Int)
    case snap
    case plate
    case rumble(Double)
    case connect(Bool)
    case worldTurn
    case awaken
    case chapter
    case finale
}

/// Lock-free single-consumer ring buffer. Producers serialise among themselves with an unfair lock
/// (only ever contended by other producers); the render thread never takes a lock.
final class CommandQueue: @unchecked Sendable {
    private let capacity = 1024
    private let mask = 1023
    private let buffer: UnsafeMutablePointer<SynthCommand>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let producerLock = OSAllocatedUnfairLock()

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: .tap, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Producer side. Returns false (command dropped) if the queue is full.
    @discardableResult
    func push(_ c: SynthCommand) -> Bool {
        producerLock.withLock {
            let w = writeIndex.load(ordering: .relaxed)
            let r = readIndex.load(ordering: .acquiring)
            if w &- r >= capacity { return false }
            buffer[w & mask] = c
            writeIndex.store(w &+ 1, ordering: .releasing)
            return true
        }
    }

    /// Consumer side (render thread). Wait-free.
    @inline(__always)
    func pop() -> SynthCommand? {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        if r == w { return nil }
        let c = buffer[r & mask]
        readIndex.store(r &+ 1, ordering: .releasing)
        return c
    }
}
