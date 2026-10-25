// SynthCompressor: port of Chromium's DynamicsCompressorKernel (the DynamicsCompressorNode
// implementation used by Chrome/Edge and, via WebKit's identical kernel, Safari).
// Includes the 6 ms look-ahead pre-delay, knee curve solved for the ratio, adaptive release
// polynomial (release zones 0.09/0.16/0.42/0.98), the asin/sin gain warp and the
// (1/saturate(1))^0.6 automatic makeup gain. Metering (the `reduction` attribute) is omitted.

import Foundation

final class DynamicsCompressor {
    // Node parameters (Web Audio defaults except threshold/ratio, which the game sets).
    let threshold: Float
    let knee: Float
    let ratio: Float
    let attack: Float
    let release: Float
    // Chromium internal fixed parameters.
    private let preDelayTime: Float = 0.006
    private let releaseZone1: Float = 0.09
    private let releaseZone2: Float = 0.16
    private let releaseZone3: Float = 0.42
    private let releaseZone4: Float = 0.98
    private let postGainDb: Float = 0
    private let effectBlend: Float = 1

    private let sampleRate: Float
    private static let maxPreDelayFrames = 1024
    private static let maxPreDelayMask = 1023
    private static let divisionFrames = 32

    // Static curve.
    private var linearThreshold: Float = 0
    private var kneeThresholdDb: Float = 0
    private var kneeThreshold: Float = 0
    private var yKneeThresholdDb: Float = 0
    private var slope: Float = 0
    private var k: Float = 0

    // Derived per-render constants.
    private var masterLinearGain: Float = 1
    private var attackFrames: Float = 0
    private var satReleaseFrames: Float = 0
    private var kA: Float = 0, kB: Float = 0, kC: Float = 0, kD: Float = 0, kE: Float = 0

    // Dynamic state.
    private var detectorAverage: Float = 0
    private var compressorGain: Float = 1
    private var maxAttackCompressionDiffDb: Float = -1
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var writeIndex = 0

    init(sampleRate: Double, threshold: Float = -24, knee: Float = 30, ratio: Float = 12, attack: Float = 0.003, release: Float = 0.25) {
        self.sampleRate = Float(sampleRate)
        self.threshold = threshold
        self.knee = knee
        self.ratio = ratio
        self.attack = attack
        self.release = release
        delayL = .allocate(capacity: DynamicsCompressor.maxPreDelayFrames)
        delayR = .allocate(capacity: DynamicsCompressor.maxPreDelayFrames)
        delayL.initialize(repeating: 0, count: DynamicsCompressor.maxPreDelayFrames)
        delayR.initialize(repeating: 0, count: DynamicsCompressor.maxPreDelayFrames)

        var preDelayFrames = Int(preDelayTime * self.sampleRate)
        preDelayFrames = min(preDelayFrames, DynamicsCompressor.maxPreDelayFrames - 1)
        readIndex = 0
        writeIndex = preDelayFrames

        updateStaticCurve()

        // Makeup gain (empirical/perceptual tuning in Chromium).
        let fullRangeGain = saturate(1, k)
        var fullRangeMakeupGain = 1 / fullRangeGain
        fullRangeMakeupGain = powf(fullRangeMakeupGain, 0.6)
        masterLinearGain = dbToLin(postGainDb) * fullRangeMakeupGain

        attackFrames = max(0.001, attack) * self.sampleRate
        let releaseFrames = self.sampleRate * release
        satReleaseFrames = 0.0025 * self.sampleRate
        let y1 = releaseFrames * releaseZone1
        let y2 = releaseFrames * releaseZone2
        let y3 = releaseFrames * releaseZone3
        let y4 = releaseFrames * releaseZone4
        kA = 0.9999999999999998 * y1 + 1.8432219684323923e-16 * y2 - 1.9373394351676423e-16 * y3 + 8.824516011816245e-18 * y4
        kB = -1.5788320352845888 * y1 + 2.3305837032074286 * y2 - 0.9141194204840429 * y3 + 0.1623677525612032 * y4
        kC = 0.5334142869106424 * y1 - 1.272736789213631 * y2 + 0.9258856042207512 * y3 - 0.18656310191776226 * y4
        kD = 0.08783463138207234 * y1 - 0.1694162967925622 * y2 + 0.08588057951595272 * y3 - 0.00429891410546283 * y4
        kE = -0.042416883008123074 * y1 + 0.1115693827987602 * y2 - 0.09764676325265872 * y3 + 0.028494263462021576 * y4
    }

    deinit {
        delayL.deallocate()
        delayR.deallocate()
    }

    /// Effective makeup gain (for diagnostics).
    var makeupGain: Float { masterLinearGain }

    @inline(__always) private func dbToLin(_ db: Float) -> Float { powf(10, 0.05 * db) }
    @inline(__always) private func linToDb(_ x: Float) -> Float { 20 * log10f(x) }

    private func kneeCurve(_ x: Float, _ k: Float) -> Float {
        if x < linearThreshold { return x }
        return linearThreshold + (1 - expf(-k * (x - linearThreshold))) / k
    }

    @inline(__always)
    private func saturate(_ x: Float, _ k: Float) -> Float {
        if x < kneeThreshold { return kneeCurve(x, k) }
        let xDb = linToDb(x)
        let yDb = yKneeThresholdDb + slope * (xDb - kneeThresholdDb)
        return dbToLin(yDb)
    }

    private func slopeAt(_ x: Float, _ k: Float) -> Float {
        if x < linearThreshold { return 1 }
        let x2 = x * 1.001
        let xDb = linToDb(x)
        let x2Db = linToDb(x2)
        let yDb = linToDb(kneeCurve(x, k))
        let y2Db = linToDb(kneeCurve(x2, k))
        return (y2Db - yDb) / (x2Db - xDb)
    }

    private func kAtSlope(_ desiredSlope: Float) -> Float {
        let xDb = threshold + knee
        let x = dbToLin(xDb)
        var minK: Float = 0.1
        var maxK: Float = 10000
        var k: Float = 5
        for _ in 0..<15 {
            let s = slopeAt(x, k)
            if s < desiredSlope { maxK = k } else { minK = k }
            k = sqrtf(minK * maxK)
        }
        return k
    }

    private func updateStaticCurve() {
        linearThreshold = dbToLin(threshold)
        slope = 1 / ratio
        let k = kAtSlope(1 / ratio)
        kneeThresholdDb = threshold + knee
        kneeThreshold = dbToLin(kneeThresholdDb)
        yKneeThresholdDb = linToDb(kneeCurve(kneeThreshold, k))
        self.k = k
    }

    /// In-place stereo processing; `n` must be a multiple of 32 (render quantum is 128).
    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ n: Int) {
        let dryMix = 1 - effectBlend
        let wetMix = effectBlend
        let k = self.k
        let halfPi = Float.pi / 2
        let divisions = n / DynamicsCompressor.divisionFrames
        var frameIndex = 0
        var division = 0
        while division < divisions {
            division += 1
            if detectorAverage.isNaN || detectorAverage.isInfinite { detectorAverage = 1 }
            let desiredGain = detectorAverage
            let scaledDesiredGain = asinf(desiredGain) / halfPi
            var envelopeRate: Float
            let isReleasing = scaledDesiredGain > compressorGain
            var compressionDiffDb = linToDb(compressorGain / scaledDesiredGain)
            if isReleasing {
                maxAttackCompressionDiffDb = -1
                if compressionDiffDb.isNaN || compressionDiffDb.isInfinite { compressionDiffDb = -1 }
                var x = fminf(fmaxf(compressionDiffDb, -12), 0)
                x = 0.25 * (x + 12)
                let x2 = x * x, x3 = x2 * x, x4 = x2 * x2
                let releaseFrames = kA + kB * x + kC * x2 + kD * x3 + kE * x4
                let dbPerFrame = 5 / releaseFrames
                envelopeRate = dbToLin(dbPerFrame)
            } else {
                if compressionDiffDb.isNaN || compressionDiffDb.isInfinite { compressionDiffDb = 1 }
                if maxAttackCompressionDiffDb == -1 || maxAttackCompressionDiffDb < compressionDiffDb {
                    maxAttackCompressionDiffDb = compressionDiffDb
                }
                let effAttenDiffDb = fmaxf(0.5, maxAttackCompressionDiffDb)
                let x = 0.25 / effAttenDiffDb
                envelopeRate = 1 - powf(x, 1 / attackFrames)
            }

            var detector = detectorAverage
            var gain = compressorGain
            var ri = readIndex, wi = writeIndex
            var loopFrames = DynamicsCompressor.divisionFrames
            while loopFrames > 0 {
                loopFrames -= 1
                let l = left[frameIndex], r = right[frameIndex]
                delayL[wi] = l
                delayR[wi] = r
                let absInput = fmaxf(l.magnitude, r.magnitude)
                let shapedInput = saturate(absInput, k)
                let attenuation: Float = absInput <= 0.0001 ? 1 : shapedInput / absInput
                var attenuationDb = -linToDb(attenuation)
                attenuationDb = fmaxf(2, attenuationDb)
                let dbPerFrame = attenuationDb / satReleaseFrames
                let satReleaseRate = dbToLin(dbPerFrame) - 1
                let rate: Float = attenuation > detector ? satReleaseRate : 1
                detector += (attenuation - detector) * rate
                detector = fminf(1, detector)
                if detector.isNaN || detector.isInfinite { detector = 1 }

                if envelopeRate < 1 {
                    gain += (scaledDesiredGain - gain) * envelopeRate
                } else {
                    gain *= envelopeRate
                    gain = fminf(1, gain)
                }
                let postWarp = sinf(halfPi * gain)
                let totalGain = dryMix + wetMix * masterLinearGain * postWarp
                left[frameIndex] = delayL[ri] * totalGain
                right[frameIndex] = delayR[ri] * totalGain
                frameIndex += 1
                ri = (ri + 1) & DynamicsCompressor.maxPreDelayMask
                wi = (wi + 1) & DynamicsCompressor.maxPreDelayMask
            }
            detectorAverage = detector
            compressorGain = gain
            readIndex = ri
            writeIndex = wi
        }
    }
}
