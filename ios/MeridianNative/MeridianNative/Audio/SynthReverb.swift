// SynthReverb: zero-latency, non-uniformly partitioned FFT convolution (ConvolverNode equivalent).
//
// The impulse response is split into three levels of uniformly partitioned overlap-save convolvers:
//   level 0: 128-sample blocks  (FFT 256),   IR [0, 2048)        - computed every render quantum
//   level 1: 1024-sample blocks (FFT 2048),  IR [2048, 16384)    - work spread over 8 quanta
//   level 2: 8192-sample blocks (FFT 16384), IR [16384, end)     - work spread over 64 quanta
// A level with block size B starts at IR offset 2B, so its result is only needed B samples after its
// input block completes; its FFT, complex multiply-accumulates and inverse FFTs are distributed over
// those B/128 quanta, keeping per-quantum CPU flat. Output is sample-exact (no added latency).
//
// Mono input, stereo impulse response -> stereo output (Web Audio "1 -> 2" convolver matrixing).
// The IR is scaled with the Web Audio spec's ConvolverNode normalisation (normalize = true).

import Accelerate
import Foundation

final class PartitionedConvolver {
    static let quantum = 128

    private final class Level {
        let blockSize: Int      // B
        let fftSize: Int        // N = 2B
        let half: Int           // N/2 complex bins (packed)
        let log2N: vDSP_Length
        let partitions: Int     // P
        let offset: Int         // IR offset of the first partition
        let delayed: Bool
        let stepsPerBlock: Int  // B / quantum

        let window: UnsafeMutablePointer<Float>     // [previous block | current block]
        var fill = 0
        let timeBuf: UnsafeMutablePointer<Float>    // N
        let fdlRe: UnsafeMutablePointer<Float>      // P * half (frequency-domain delay line)
        let fdlIm: UnsafeMutablePointer<Float>
        var fdlHead = 0
        let hReL, hImL, hReR, hImR: UnsafeMutablePointer<Float>         // per channel, P * half
        let accReL, accImL, accReR, accImR: UnsafeMutablePointer<Float> // per channel, half
        @inline(__always) func hRe(_ c: Int) -> UnsafeMutablePointer<Float> { c == 0 ? hReL : hReR }
        @inline(__always) func hIm(_ c: Int) -> UnsafeMutablePointer<Float> { c == 0 ? hImL : hImR }
        @inline(__always) func accRe(_ c: Int) -> UnsafeMutablePointer<Float> { c == 0 ? accReL : accReR }
        @inline(__always) func accIm(_ c: Int) -> UnsafeMutablePointer<Float> { c == 0 ? accImL : accImR }
        var accDC: (Float, Float) = (0, 0)
        var accNy: (Float, Float) = (0, 0)
        let ringL: UnsafeMutablePointer<Float>      // output ring (delayed levels), 4B
        let ringR: UnsafeMutablePointer<Float>
        let ringSize: Int
        var step = -1
        var unitsDone = 0
        var blockEndFrame: Int64 = 0

        init(blockSize: Int, partitions: Int, offset: Int) {
            self.blockSize = blockSize
            fftSize = 2 * blockSize
            half = blockSize
            log2N = vDSP_Length(log2(Double(2 * blockSize)).rounded())
            self.partitions = partitions
            self.offset = offset
            delayed = offset >= 2 * blockSize
            stepsPerBlock = blockSize / PartitionedConvolver.quantum
            func zeros(_ n: Int) -> UnsafeMutablePointer<Float> {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
                p.initialize(repeating: 0, count: n)
                return p
            }
            window = zeros(fftSize)
            timeBuf = zeros(fftSize)
            fdlRe = zeros(partitions * half)
            fdlIm = zeros(partitions * half)
            hReL = zeros(partitions * half); hImL = zeros(partitions * half)
            hReR = zeros(partitions * half); hImR = zeros(partitions * half)
            accReL = zeros(half); accImL = zeros(half)
            accReR = zeros(half); accImR = zeros(half)
            ringSize = delayed ? 4 * blockSize : 1
            ringL = zeros(ringSize)
            ringR = zeros(ringSize)
        }

        deinit {
            for p in [window, timeBuf, fdlRe, fdlIm, ringL, ringR, hReL, hImL, hReR, hImR, accReL, accImL, accReR, accImR] { p.deallocate() }
        }
    }

    private let setup: FFTSetup
    private let levels: [Level]
    private let levelPtrs: UnsafeMutablePointer<Unmanaged<Level>>
    private let levelCount: Int
    private let tmpL: UnsafeMutablePointer<Float>
    private let tmpR: UnsafeMutablePointer<Float>
    let normalizationScale: Float

    /// - Parameters:
    ///   - left/right: impulse response channels (same length), at the context sample rate.
    init(left: UnsafePointer<Float>, right: UnsafePointer<Float>, length: Int, sampleRate: Double) {
        // Web Audio spec: ConvolverNode normalisation (calculateNormalizationScale).
        let gainCalibration = 0.00125
        let gainCalibrationSampleRate = 44100.0
        let minPower = 0.000125
        var power = 0.0
        for i in 0..<length { power += Double(left[i]) * Double(left[i]) }
        for i in 0..<length { power += Double(right[i]) * Double(right[i]) }
        power = (power / Double(2 * length)).squareRoot()
        if !power.isFinite || power < minPower { power = minPower }
        var scale = 1 / power
        scale *= gainCalibration
        scale *= gainCalibrationSampleRate / sampleRate
        normalizationScale = Float(scale)

        // Partition layout.
        var lv: [Level] = []
        let q = PartitionedConvolver.quantum
        let l0Len = min(length, 2048)
        lv.append(Level(blockSize: q, partitions: max(1, (l0Len + q - 1) / q), offset: 0))
        if length > 2048 {
            let l1Len = min(length, 16384) - 2048
            lv.append(Level(blockSize: 1024, partitions: (l1Len + 1023) / 1024, offset: 2048))
        }
        if length > 16384 {
            let l2Len = length - 16384
            lv.append(Level(blockSize: 8192, partitions: (l2Len + 8191) / 8192, offset: 16384))
        }
        levels = lv
        levelCount = lv.count
        levelPtrs = .allocate(capacity: lv.count)
        for (i, l) in lv.enumerated() { (levelPtrs + i).initialize(to: Unmanaged.passUnretained(l)) }
        setup = vDSP_create_fftsetup(14, FFTRadix(kFFTRadix2))!
        tmpL = .allocate(capacity: q)
        tmpR = .allocate(capacity: q)

        // Pre-transform the IR partitions. The vDSP real FFT scales forward by 2 and the inverse by N,
        // so x*h comes back scaled by 4N: fold 1/(4N) and the normalisation into H.
        for l in lv {
            let n = l.fftSize
            let s = Float(scale) / Float(4 * n)
            for c in 0..<2 {
                let src = c == 0 ? left : right
                for k in 0..<l.partitions {
                    let start = l.offset + k * l.blockSize
                    for i in 0..<n {
                        let idx = start + i
                        l.timeBuf[i] = (i < l.blockSize && idx < length) ? src[idx] * s : 0
                    }
                    forward(l, l.timeBuf, l.hRe(c) + k * l.half, l.hIm(c) + k * l.half)
                }
            }
            l.timeBuf.initialize(repeating: 0, count: n)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        levelPtrs.deallocate()
        tmpL.deallocate()
        tmpR.deallocate()
    }

    private func forward(_ l: Level, _ input: UnsafeMutablePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        input.withMemoryRebound(to: DSPComplex.self, capacity: l.half) { c in
            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(l.half))
        }
        vDSP_fft_zrip(setup, &split, 1, l.log2N, FFTDirection(kFFTDirection_Forward))
    }

    /// One complex multiply-accumulate unit: channel c, partition k.
    private func mac(_ l: Level, channel c: Int, partition k: Int) {
        let xi = (l.fdlHead - k + l.partitions) % l.partitions
        let xr = l.fdlRe + xi * l.half, xim = l.fdlIm + xi * l.half
        let hr = l.hRe(c) + k * l.half, him = l.hIm(c) + k * l.half
        var x = DSPSplitComplex(realp: xr, imagp: xim)
        var h = DSPSplitComplex(realp: hr, imagp: him)
        var acc = DSPSplitComplex(realp: l.accRe(c), imagp: l.accIm(c))
        let n = vDSP_Length(l.half)
        // Packed format: bin 0 holds DC (real) and Nyquist (imag); handle them separately.
        let dc = xr[0] * hr[0], ny = xim[0] * him[0]
        if k == 0 {
            vDSP_zvmul(&x, 1, &h, 1, &acc, 1, n, 1)
            if c == 0 { l.accDC.0 = dc; l.accNy.0 = ny } else { l.accDC.1 = dc; l.accNy.1 = ny }
        } else {
            vDSP_zvma(&x, 1, &h, 1, &acc, 1, &acc, 1, n)
            if c == 0 { l.accDC.0 += dc; l.accNy.0 += ny } else { l.accDC.1 += dc; l.accNy.1 += ny }
        }
    }

    /// Inverse transform of channel c's accumulator into l.timeBuf; valid output is timeBuf[B..<2B].
    private func inverse(_ l: Level, channel c: Int) {
        let re = l.accRe(c), im = l.accIm(c)
        re[0] = c == 0 ? l.accDC.0 : l.accDC.1
        im[0] = c == 0 ? l.accNy.0 : l.accNy.1
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(setup, &split, 1, l.log2N, FFTDirection(kFFTDirection_Inverse))
        l.timeBuf.withMemoryRebound(to: DSPComplex.self, capacity: l.half) { c in
            vDSP_ztoc(&split, 1, c, 2, vDSP_Length(l.half))
        }
    }

    /// Process one 128-frame render quantum. `frame` is the absolute frame of input[0].
    /// Writes (not accumulates) the stereo wet signal to outL/outR.
    func process(input: UnsafePointer<Float>, frame: Int64, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        let q = PartitionedConvolver.quantum
        vDSP_vclr(outL, 1, vDSP_Length(q))
        vDSP_vclr(outR, 1, vDSP_Length(q))
        var li = 0
        while li < levelCount {
            let l = levelPtrs[li].takeUnretainedValue()
            if !l.delayed {
                processDirect(l, input, outL, outR)
            } else {
                processDelayed(l, input, frame, outL, outR)
            }
            li += 1
        }
    }

    private func processDirect(_ l: Level, _ input: UnsafePointer<Float>, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        let b = l.blockSize // == quantum
        l.window.update(from: l.window + b, count: b)
        (l.window + b).update(from: input, count: b)
        l.fdlHead = (l.fdlHead + 1) % l.partitions
        forward(l, l.window, l.fdlRe + l.fdlHead * l.half, l.fdlIm + l.fdlHead * l.half)
        var c = 0
        while c < 2 {
            var k = 0
            while k < l.partitions { mac(l, channel: c, partition: k); k += 1 }
            inverse(l, channel: c)
            let out = c == 0 ? outL : outR
            vDSP_vadd(out, 1, l.timeBuf + b, 1, out, 1, vDSP_Length(b))
            c += 1
        }
    }

    private func processDelayed(_ l: Level, _ input: UnsafePointer<Float>, _ frame: Int64, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        let q = PartitionedConvolver.quantum
        // 1. Read this quantum's output from the ring.
        let rs = Int64(l.ringSize)
        let pos = Int(frame % rs) // ring size is a multiple of the quantum: never wraps inside one
        vDSP_vadd(outL, 1, l.ringL + pos, 1, outL, 1, vDSP_Length(q))
        vDSP_vadd(outR, 1, l.ringR + pos, 1, outR, 1, vDSP_Length(q))
        // 2. Append input; on block completion transform it into the delay line.
        (l.window + l.blockSize + l.fill).update(from: input, count: q)
        l.fill += q
        if l.fill == l.blockSize {
            l.fill = 0
            l.fdlHead = (l.fdlHead + 1) % l.partitions
            forward(l, l.window, l.fdlRe + l.fdlHead * l.half, l.fdlIm + l.fdlHead * l.half)
            l.window.update(from: l.window + l.blockSize, count: l.blockSize)
            l.step = 0
            l.unitsDone = 0
            l.blockEndFrame = frame + Int64(q)
        } else if l.step >= 0 {
            l.step += 1
        }
        guard l.step >= 0 else { return }
        // 3. Spread the multiply-accumulate units over steps 0...Q-2, inverse FFTs at Q-2 and Q-1.
        let total = 2 * l.partitions
        let macSteps = l.stepsPerBlock > 2 ? l.stepsPerBlock - 1 : 1
        let wanted = (total * (l.step + 1) + macSteps - 1) / macSteps
        let target = wanted < total ? wanted : total
        while l.unitsDone < target {
            let u = l.unitsDone
            mac(l, channel: u / l.partitions, partition: u % l.partitions)
            l.unitsDone += 1
        }
        let last = l.stepsPerBlock - 1
        if l.step == last - 1 || l.step == last {
            if l.step == last - 1 || last == 0 {
                while l.unitsDone < total { let u = l.unitsDone; mac(l, channel: u / l.partitions, partition: u % l.partitions); l.unitsDone += 1 }
            }
            let c = l.step == last - 1 ? 0 : 1
            inverse(l, channel: c)
            // Result covers output times [blockEnd - B + offset, blockEnd + offset).
            let ring = c == 0 ? l.ringL : l.ringR
            // Block-aligned start and ring size 4B: the B samples are contiguous in the ring.
            let wp = Int((l.blockEndFrame - Int64(l.blockSize) + Int64(l.offset)) % rs)
            (ring + wp).update(from: l.timeBuf + l.blockSize, count: l.blockSize)
            if l.step == last { l.step = -1 }
        }
    }
}
