// JavaScript / three.js compatibility helpers for the logic port.
// Everything here reproduces the exact floating point behaviour of the web original
// (V8 Math.round / Math.hypot / Number#toString and three.js Matrix4 / Vector3 / Quaternion).

import Foundation
import simd

// MARK: - Numbers

/// JavaScript `Math.round`: nearest integer, ties toward +∞, keeps the sign of zero (-0.2 → -0).
@inline(__always)
func jsRound(_ x: Double) -> Double {
    if !x.isFinite { return x }
    let f = x.rounded(.down)
    let r = (x - f >= 0.5) ? f + 1 : f
    if r == 0 && (x < 0 || x.sign == .minus) { return -0.0 }
    return r
}

/// V8 `Math.hypot` (normalised Kahan summation), bit-identical to the JavaScript original.
func jsHypot(_ values: Double...) -> Double {
    var maxV = 0.0
    var nan = false
    var abs = [Double](repeating: 0, count: values.count)
    for (i, v) in values.enumerated() {
        if v.isNaN { nan = true } else {
            let a = Swift.abs(v)
            abs[i] = a
            if a > maxV { maxV = a }
        }
    }
    if maxV == .infinity { return .infinity }
    if nan { return .nan }
    if maxV == 0 { return 0 }
    var sum = 0.0
    var compensation = 0.0
    for a in abs {
        let n = a / maxV
        let summand = n * n - compensation
        let preliminary = sum + summand
        compensation = (preliminary - sum) - summand
        sum = preliminary
    }
    return sum.squareRoot() * maxV
}

/// JavaScript `String(n)` (Number::toString) for any finite double.
func jsNumberString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return "0" }  // also -0
    if d == d.rounded(.towardZero) && Swift.abs(d) < 1e15 { return String(Int64(d)) }
    // Shortest round-trip digits from Swift, then re-layout with the ECMAScript rules.
    var s = Swift.abs(d).description
    var exp = 0
    if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exp = Int(s[s.index(after: e)...].replacingOccurrences(of: "+", with: ""))!
        s = String(s[..<e])
    }
    var intPart = s
    var frac = ""
    if let dot = s.firstIndex(of: ".") {
        intPart = String(s[..<dot])
        frac = String(s[s.index(after: dot)...])
    }
    var digits = Array(intPart + frac)
    var n = intPart.count + exp  // value = 0.digits × 10^n
    while digits.first == "0" { digits.removeFirst(); n -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count
    let ds = String(digits)
    var out: String
    if k <= n && n <= 21 {
        out = ds + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        out = String(digits[0..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        out = "0." + String(repeating: "0", count: -n) + ds
    } else {
        let e = n - 1
        let es = (e >= 0 ? "+" : "-") + String(Swift.abs(e))
        out = k == 1 ? ds + "e" + es : String(digits[0]) + "." + String(digits[1...]) + "e" + es
    }
    return d < 0 ? "-" + out : out
}

/// Round to 1e-6 like `Math.round(n * 1e6) / 1e6`.
@inline(__always)
func r6(_ n: Double) -> Double { jsRound(n * 1e6) / 1e6 }

@inline(__always)
func snapV(_ v: V3) -> V3 { V3(r6(v.x), r6(v.y), r6(v.z)) }

/// `${Math.round(x*4)},${Math.round(y*4)},${Math.round(z*4)}`
@inline(__always)
func key4(_ v: V3) -> String {
    jsNumberString(jsRound(v.x * 4)) + "," + jsNumberString(jsRound(v.y * 4)) + "," + jsNumberString(jsRound(v.z * 4))
}

// MARK: - three.js matrix semantics (column-major, elements te[c*4 + r] == m[c][r])

enum JSMat {
    static let identity = simd_double4x4(diagonal: SIMD4<Double>(1, 1, 1, 1))

    @inline(__always)
    static func makeTranslation(_ x: Double, _ y: Double, _ z: Double) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(x, y, z, 1)))
    }

    /// Quaternion.setFromAxisAngle + Matrix4.makeRotationFromQuaternion (compose with zero position, unit scale).
    static func makeRotationAxisAngle(_ axis: V3, _ angle: Double) -> simd_double4x4 {
        let halfAngle = angle / 2
        let s = sin(halfAngle)
        let x = axis.x * s, y = axis.y * s, z = axis.z * s, w = cos(halfAngle)
        let x2 = x + x, y2 = y + y, z2 = z + z
        let xx = x * x2, xy = x * y2, xz = x * z2
        let yy = y * y2, yz = y * z2, zz = z * z2
        let wx = w * x2, wy = w * y2, wz = w * z2
        let sx = 1.0, sy = 1.0, sz = 1.0
        return simd_double4x4(columns: (
            SIMD4((1 - (yy + zz)) * sx, (xy + wz) * sx, (xz - wy) * sx, 0),
            SIMD4((xy - wz) * sy, (1 - (xx + zz)) * sy, (yz + wx) * sy, 0),
            SIMD4((xz + wy) * sz, (yz - wx) * sz, (1 - (xx + yy)) * sz, 0),
            SIMD4(0, 0, 0, 1)))
    }

    /// Matrix4.multiplyMatrices(a, b) with the exact summation order of three.js.
    static func multiply(_ a: simd_double4x4, _ b: simd_double4x4) -> simd_double4x4 {
        let a11 = a[0][0], a12 = a[1][0], a13 = a[2][0], a14 = a[3][0]
        let a21 = a[0][1], a22 = a[1][1], a23 = a[2][1], a24 = a[3][1]
        let a31 = a[0][2], a32 = a[1][2], a33 = a[2][2], a34 = a[3][2]
        let a41 = a[0][3], a42 = a[1][3], a43 = a[2][3], a44 = a[3][3]
        let b11 = b[0][0], b12 = b[1][0], b13 = b[2][0], b14 = b[3][0]
        let b21 = b[0][1], b22 = b[1][1], b23 = b[2][1], b24 = b[3][1]
        let b31 = b[0][2], b32 = b[1][2], b33 = b[2][2], b34 = b[3][2]
        let b41 = b[0][3], b42 = b[1][3], b43 = b[2][3], b44 = b[3][3]
        var t0 = a11 * b11; t0 += a12 * b21; t0 += a13 * b31; t0 += a14 * b41
        var t4 = a11 * b12; t4 += a12 * b22; t4 += a13 * b32; t4 += a14 * b42
        var t8 = a11 * b13; t8 += a12 * b23; t8 += a13 * b33; t8 += a14 * b43
        var t12 = a11 * b14; t12 += a12 * b24; t12 += a13 * b34; t12 += a14 * b44
        var t1 = a21 * b11; t1 += a22 * b21; t1 += a23 * b31; t1 += a24 * b41
        var t5 = a21 * b12; t5 += a22 * b22; t5 += a23 * b32; t5 += a24 * b42
        var t9 = a21 * b13; t9 += a22 * b23; t9 += a23 * b33; t9 += a24 * b43
        var t13 = a21 * b14; t13 += a22 * b24; t13 += a23 * b34; t13 += a24 * b44
        var t2 = a31 * b11; t2 += a32 * b21; t2 += a33 * b31; t2 += a34 * b41
        var t6 = a31 * b12; t6 += a32 * b22; t6 += a33 * b32; t6 += a34 * b42
        var t10 = a31 * b13; t10 += a32 * b23; t10 += a33 * b33; t10 += a34 * b43
        var t14 = a31 * b14; t14 += a32 * b24; t14 += a33 * b34; t14 += a34 * b44
        var t3 = a41 * b11; t3 += a42 * b21; t3 += a43 * b31; t3 += a44 * b41
        var t7 = a41 * b12; t7 += a42 * b22; t7 += a43 * b32; t7 += a44 * b42
        var t11 = a41 * b13; t11 += a42 * b23; t11 += a43 * b33; t11 += a44 * b43
        var t15 = a41 * b14; t15 += a42 * b24; t15 += a43 * b34; t15 += a44 * b44
        return simd_double4x4(columns: (SIMD4(t0, t1, t2, t3), SIMD4(t4, t5, t6, t7), SIMD4(t8, t9, t10, t11), SIMD4(t12, t13, t14, t15)))
    }

    /// Matrix4.extractRotation.
    static func extractRotation(_ m: simd_double4x4) -> simd_double4x4 {
        let sX = 1 / length(m[0][0], m[0][1], m[0][2])
        let sY = 1 / length(m[1][0], m[1][1], m[1][2])
        let sZ = 1 / length(m[2][0], m[2][1], m[2][2])
        return simd_double4x4(columns: (
            SIMD4(m[0][0] * sX, m[0][1] * sX, m[0][2] * sX, 0),
            SIMD4(m[1][0] * sY, m[1][1] * sY, m[1][2] * sY, 0),
            SIMD4(m[2][0] * sZ, m[2][1] * sZ, m[2][2] * sZ, 0),
            SIMD4(0, 0, 0, 1)))
    }

    /// Vector3.length.
    @inline(__always)
    static func length(_ x: Double, _ y: Double, _ z: Double) -> Double {
        var s = x * x; s += y * y; s += z * z
        return s.squareRoot()
    }

    /// Vector3.applyMatrix4 (with the projective w divide).
    @inline(__always)
    static func apply(_ v: V3, _ m: simd_double4x4) -> V3 {
        let x = v.x, y = v.y, z = v.z
        var wd = m[0][3] * x; wd += m[1][3] * y; wd += m[2][3] * z; wd += m[3][3]
        let w = 1 / wd
        var rx = m[0][0] * x; rx += m[1][0] * y; rx += m[2][0] * z; rx += m[3][0]
        var ry = m[0][1] * x; ry += m[1][1] * y; ry += m[2][1] * z; ry += m[3][1]
        var rz = m[0][2] * x; rz += m[1][2] * y; rz += m[2][2] * z; rz += m[3][2]
        return V3(rx * w, ry * w, rz * w)
    }

    /// Vector3.distanceTo.
    @inline(__always)
    static func distance(_ a: V3, _ b: V3) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        var s = dx * dx; s += dy * dy; s += dz * dz
        return s.squareRoot()
    }

    /// Vector3.normalize (divideScalar(length || 1) == multiplyScalar(1 / len)).
    static func normalize(_ v: V3) -> V3 {
        var len = length(v.x, v.y, v.z)
        if len == 0 { len = 1 }
        let s = 1 / len
        return V3(v.x * s, v.y * s, v.z * s)
    }
}

/// JS Math.min / Math.max semantics for the non-NaN values used here (Math.min(-0, 0) = -0).
@inline(__always)
func jsMin(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0 }
    return a < b ? a : b
}

@inline(__always)
func jsMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == 0 && b == 0 { return (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0 }
    return a > b ? a : b
}
