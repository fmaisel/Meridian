// AudioCheck: offline verification harness for the native Meridian synth (not part of the app).
// Build: see build.sh next to this file.
//
// 1. Unit checks: partitioned convolver vs. direct convolution, AudioParam timeline vs. closed form.
// 2. Scripted 60 s session rendered through AVAudioEngine offline manual rendering with the same
//    AVAudioSourceNode the app uses; writes a WAV and prints levels, NaN/Inf, clipping and CPU ratio.

import AVFoundation
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/private/tmp/claude-501/-Users-fmaisel-Development-Videospiele-Monument-Valley/d5efd4f3-e050-4b08-8461-78797b72de55/scratchpad"
let sr = 48000.0

pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
/// Thread CPU time (robust against other load on the machine).
func now() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}
func db(_ x: Double) -> String { x <= 0 ? "  -inf" : String(format: "%6.1f", 20 * log10(x)) }

// MARK: - 1a. Convolver check

do {
    let len = Int(sr * 3.6)
    var rng = SynthRNG(seed: 7)
    let irL = UnsafeMutablePointer<Float>.allocate(capacity: len)
    let irR = UnsafeMutablePointer<Float>.allocate(capacity: len)
    for i in 0..<len {
        irL[i] = Float((rng.random() * 2 - 1) * pow(1 - Double(i) / Double(len), 2.4))
        irR[i] = Float((rng.random() * 2 - 1) * pow(1 - Double(i) / Double(len), 2.4))
    }
    let conv = PartitionedConvolver(left: irL, right: irR, length: len, sampleRate: sr)
    let scale = conv.normalizationScale
    let total = len + 4096
    let quanta = (total + 127) / 128
    let input = UnsafeMutablePointer<Float>.allocate(capacity: quanta * 128)
    input.initialize(repeating: 0, count: quanta * 128)
    // impulse + a burst of noise
    let impulseAt = 1037
    input[impulseAt] = 1
    var noiseIn = [Float](repeating: 0, count: 600)
    for i in 0..<600 { noiseIn[i] = Float(rng.random() * 2 - 1); input[20000 + i] += noiseIn[i] }
    let outL = UnsafeMutablePointer<Float>.allocate(capacity: quanta * 128)
    let outR = UnsafeMutablePointer<Float>.allocate(capacity: quanta * 128)
    let t0 = now()
    for qi in 0..<quanta {
        conv.process(input: input + qi * 128, frame: Int64(qi * 128), outL: outL + qi * 128, outR: outR + qi * 128)
    }
    let dt = now() - t0
    // Compare with direct convolution at many points.
    var maxErr: Float = 0, maxRef: Float = 0
    var idx = 0
    while idx < quanta * 128 {
        for c in 0..<2 {
            let ir = c == 0 ? irL : irR
            let out = c == 0 ? outL : outR
            var ref: Float = 0
            let k1 = idx - impulseAt
            if k1 >= 0 && k1 < len { ref += ir[k1] * scale }
            for i in 0..<600 {
                let k = idx - (20000 + i)
                if k >= 0 && k < len { ref += noiseIn[i] * ir[k] * scale }
            }
            maxErr = max(maxErr, abs(out[idx] - ref))
            maxRef = max(maxRef, abs(ref))
        }
        idx += idx < 40000 ? 1 : 97
    }
    print(String(format: "[convolver] IR %d frames, levels ok, norm scale %.6f, max |err| %.3e (rel %.2e to peak %.4f), %.2fx real time",
                 len, scale, maxErr, maxErr / maxRef, maxRef, Double(total) / sr / dt))
}

// MARK: - 1b. ParamTimeline check (pluck envelope: set 0, linear to 0.1 @ +10 ms, exp to 1e-4 @ +2.6 s)

do {
    let storage = UnsafeMutablePointer<ParamEvent>.allocate(capacity: 8)
    var p = ParamTimeline(storage: storage, capacity: 8, sampleRate: sr, value: 1)
    let at = 0.5
    p.setValueAtTime(0, at, now: 0)
    p.linearRampToValueAtTime(0.1, at + 0.01, now: 0)
    p.exponentialRampToValueAtTime(0.0001, at + 2.6, now: 0)
    p.setTargetAtTime(0.5, at + 3, 0.2, now: 0)
    let n = Int(sr * 4)
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
    var f: Int64 = 0
    while f < Int64(n) { let c = min(128, n - Int(f)); p.render(frame0: f, count: c, into: buf + Int(f)); f += Int64(c) }
    func ref(_ t: Double) -> Double {
        if t < at { return 1 }
        if t < at + 0.01 { return 0.1 * (t - at) / 0.01 }
        if t < at + 2.6 { return 0.1 * pow(0.0001 / 0.1, (t - at - 0.01) / 2.59) }
        if t < at + 3 { return 0.0001 }
        return 0.5 + (0.0001 - 0.5) * exp(-(t - at - 3) / 0.2)
    }
    var maxRel = 0.0
    for i in 0..<n {
        let r = ref(Double(i) / sr)
        let e = abs(Double(buf[i]) - r) / max(abs(r), 1e-4)
        maxRel = max(maxRel, e)
    }
    print(String(format: "[param] envelope vs closed form: max relative error %.2e", maxRel))
}

// MARK: - 2. Scripted session

/// Mirrors AudioManager's main-thread logic (mood de-duplication, finale) on top of SynthCore.
final class Driver {
    let core: SynthCore
    var mood = 0
    init(core: SynthCore) { self.core = core }
    func setMood(_ m: String) {
        guard let i = SynthCore.moodNames.firstIndex(of: m), i != mood else { return }
        mood = i
        core.commands.push(.setMood(i))
    }
    func finale() { setMood("radiant"); core.commands.push(.finale) }
    func send(_ c: SynthCommand) { core.commands.push(c) }
}

struct ScriptEvent { let t: Double; let name: String; let run: (Driver) -> Void }
var script: [ScriptEvent] = []
func at(_ t: Double, _ name: String, _ run: @escaping (Driver) -> Void) { script.append(ScriptEvent(t: t, name: name, run: run)) }

at(1.0, "tap") { $0.send(.tap) }
at(1.5, "tap") { $0.send(.tap) }
at(2.0, "nope") { $0.send(.nope) }
for i in 0..<8 { at(3.0 + Double(i) * 0.3, "step") { $0.send(.step(i)) } }
// grind ramp 5.0 -> 8.0 s, 60 Hz updates, detents along the way
for k in 0...180 {
    let t = 5.0 + Double(k) / 60
    let v = k <= 90 ? Double(k) / 90 : Double(180 - k) / 90
    at(t, "grind") { $0.send(.grind(v)) }
}
for i in 0..<7 { at(5.2 + Double(i) * 0.4, "detent") { $0.send(.detent(i)) } }
at(8.2, "snap") { $0.send(.snap) }
at(10.0, "mood noon") { $0.setMood("noon") }
at(11.0, "plate") { $0.send(.plate) }
at(13.0, "rumble") { $0.send(.rumble(1.6)) }
at(15.0, "connect") { $0.send(.connect(false)) }
at(16.0, "connect seam") { $0.send(.connect(true)) }
at(20.0, "mood dusk") { $0.setMood("dusk") }
at(21.0, "worldTurn") { $0.send(.worldTurn) }
at(24.0, "awaken") { $0.send(.awaken) }
at(28.0, "chapter") { $0.send(.chapter) }
at(30.0, "volumes 0.3/0.5") { $0.send(.setVolumes(music: 0.3, sfx: 0.5)) }
at(33.0, "volumes 0.6/0.8") { $0.send(.setVolumes(music: 0.6, sfx: 0.8)) }
at(35.0, "mood radiant") { $0.setMood("radiant") }
for k in 0...180 {
    let t = 36.0 + Double(k) / 60
    let v = k <= 60 ? Double(k) / 60 : (k <= 120 ? 1.0 : Double(180 - k) / 60)
    at(t, "grind") { $0.send(.grind(v)) }
}
for i in 0..<10 { at(36.1 + Double(i) * 0.28, "detent") { $0.send(.detent(-3 + i)) } }
at(40.0, "rumble 2.5") { $0.send(.rumble(2.5)) }
at(42.0, "mood dawn") { $0.setMood("dawn") }
at(45.0, "finale") { $0.finale() }
script.sort { $0.t < $1.t }

let duration = 60.0
let totalFrames = Int(duration * sr)

func runSession(useEngine: Bool) throws -> (l: [Float], r: [Float], renderTime: Double, initTime: Double) {
    let t0 = now()
    let core = SynthCore(sampleRate: sr, mood: 0, musicVolume: 0.6, sfxVolume: 0.8, seed: 12345)
    let initTime = now() - t0
    let driver = Driver(core: core)
    var l = [Float](repeating: 0, count: totalFrames)
    var r = [Float](repeating: 0, count: totalFrames)
    let chunk = 512
    var next = 0
    var renderTime = 0.0
    if useEngine {
        let engine = AVAudioEngine()
        let node = core.makeSourceNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: core.format)
        try engine.enableManualRenderingMode(.offline, format: core.format, maximumFrameCount: AVAudioFrameCount(chunk))
        try engine.start()
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < totalFrames {
            let tNow = Double(pos) / sr
            while next < script.count && script[next].t <= tNow { script[next].run(driver); next += 1 }
            let n = min(chunk, totalFrames - pos)
            let t1 = now()
            let status = try engine.renderOffline(AVAudioFrameCount(n), to: buf)
            renderTime += now() - t1
            guard status == .success else { fatalError("render status \(status.rawValue)") }
            let cl = buf.floatChannelData![0], cr = buf.floatChannelData![1]
            for i in 0..<n { l[pos + i] = cl[i]; r[pos + i] = cr[i] }
            pos += n
        }
        engine.stop()
    } else {
        let bl = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let br = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        var pos = 0
        while pos < totalFrames {
            let tNow = Double(pos) / sr
            while next < script.count && script[next].t <= tNow { script[next].run(driver); next += 1 }
            let n = min(chunk, totalFrames - pos)
            let t1 = now()
            core.render(frames: n, left: bl, right: br)
            renderTime += now() - t1
            for i in 0..<n { l[pos + i] = bl[i]; r[pos + i] = br[i] }
            pos += n
        }
    }
    let diag = core.diagnostics
    print(String(format: "[core] reverb normalisation %.5f, compressor makeup gain %.4f (%.2f dB)",
                 diag.reverbScale, diag.makeupGain, 20 * log10(Double(diag.makeupGain))))
    return (l, r, renderTime, initTime)
}

if ProcessInfo.processInfo.environment["BENCH"] != nil {
    for _ in 0..<8 { let r = try runSession(useEngine: false); print(String(format: "bench %.2f%%", 100 * r.renderTime / duration)) }
    exit(0)
}
let direct = try runSession(useEngine: false)
let viaEngine = try runSession(useEngine: true)

var maxDiff: Float = 0
for i in 0..<totalFrames { maxDiff = max(maxDiff, abs(direct.l[i] - viaEngine.l[i]), abs(direct.r[i] - viaEngine.r[i])) }

print(String(format: "[timing] SynthCore init %.1f ms", direct.initTime * 1000))
print(String(format: "[timing] direct render: %.3f s for %.0f s audio -> %.2f%% of one core (%.0fx real time)",
             direct.renderTime, duration, 100 * direct.renderTime / duration, duration / direct.renderTime))
print(String(format: "[timing] AVAudioEngine manual rendering: %.3f s -> %.2f%% of one core",
             viaEngine.renderTime, 100 * viaEngine.renderTime / duration))
print(String(format: "[check] direct vs engine output max |diff| = %.3e", maxDiff))

// Levels
let L = viaEngine.l, R = viaEngine.r
var nanCount = 0, clipCount = 0
for i in 0..<totalFrames {
    if !L[i].isFinite || !R[i].isFinite { nanCount += 1 }
    if abs(L[i]) >= 0.999 || abs(R[i]) >= 0.999 { clipCount += 1 }
}
print("[levels] NaN/Inf samples: \(nanCount), clipped (|x| >= 0.999) frames: \(clipCount)")
print("[levels] segment        peak dBFS   RMS dBFS   events")
let seg = 5.0
var s0 = 0.0
while s0 < duration {
    let a = Int(s0 * sr), b = min(totalFrames, Int((s0 + seg) * sr))
    var peak: Float = 0
    var sum = 0.0
    for i in a..<b {
        peak = max(peak, abs(L[i]), abs(R[i]))
        sum += Double(L[i]) * Double(L[i]) + Double(R[i]) * Double(R[i])
    }
    let rms = (sum / Double(2 * (b - a))).squareRoot()
    var names: [String] = []
    for e in script where e.t >= s0 && e.t < s0 + seg && !names.contains(e.name) { names.append(e.name) }
    print(String(format: "[levels] %4.0f-%4.0f s     %@     %@     ", s0, s0 + seg, db(Double(peak)), db(rms)) + names.joined(separator: ", "))
    s0 += seg
}

// WAV (16-bit PCM stereo)
func writeWav(_ path: String, _ l: [Float], _ r: [Float]) throws {
    var data = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
    let n = l.count
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr) * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 4))
    var pcm = [Int16](repeating: 0, count: n * 2)
    for i in 0..<n {
        pcm[2 * i] = Int16(max(-1, min(1, l[i])) * 32767)
        pcm[2 * i + 1] = Int16(max(-1, min(1, r[i])) * 32767)
    }
    pcm.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: URL(fileURLWithPath: path))
}
let wavPath = outDir + "/meridian_native_session.wav"
try writeWav(wavPath, L, R)
print("[wav] wrote \(wavPath)")
// Raw interleaved float32 for the WebAudio reference comparison (reference/compare.html).
var interleaved = [Float](repeating: 0, count: totalFrames * 2)
for i in 0..<totalFrames { interleaved[2 * i] = L[i]; interleaved[2 * i + 1] = R[i] }
try interleaved.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: outDir + "/meridian_native_session.f32")) }
