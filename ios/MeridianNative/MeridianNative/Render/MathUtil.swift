// Small float math layer mirroring the three.js conventions the original relies on
// (column-major matrices, Euler order XYZ, linear colour space with sRGB hex input).

import simd

typealias F3 = SIMD3<Float>
typealias F4 = SIMD4<Float>
typealias M4 = simd_float4x4

extension SIMD3 where Scalar == Double {
    var f: F3 { F3(Float(x), Float(y), Float(z)) }
}

extension SIMD3 where Scalar == Float {
    var d: V3 { V3(Double(x), Double(y), Double(z)) }
}

extension simd_double4x4 {
    var f: M4 {
        M4(columns: (
            F4(Float(columns.0.x), Float(columns.0.y), Float(columns.0.z), Float(columns.0.w)),
            F4(Float(columns.1.x), Float(columns.1.y), Float(columns.1.z), Float(columns.1.w)),
            F4(Float(columns.2.x), Float(columns.2.y), Float(columns.2.z), Float(columns.2.w)),
            F4(Float(columns.3.x), Float(columns.3.y), Float(columns.3.z), Float(columns.3.w))))
    }
}

extension M4 {
    /// Rotation-only matrix from a 3×3 (Double) rotation.
    init(_ r: simd_double3x3) {
        func c(_ v: SIMD3<Double>) -> F4 { F4(Float(v.x), Float(v.y), Float(v.z), 0) }
        self.init(columns: (c(r.columns.0), c(r.columns.1), c(r.columns.2), F4(0, 0, 0, 1)))
    }

    static let identity = matrix_identity_float4x4

    static func translation(_ t: F3) -> M4 {
        var m = matrix_identity_float4x4
        m.columns.3 = F4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: F3) -> M4 {
        M4(diagonal: F4(s.x, s.y, s.z, 1))
    }

    static func rotationX(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (F4(1, 0, 0, 0), F4(0, c, s, 0), F4(0, -s, c, 0), F4(0, 0, 0, 1)))
    }

    static func rotationY(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (F4(c, 0, -s, 0), F4(0, 1, 0, 0), F4(s, 0, c, 0), F4(0, 0, 0, 1)))
    }

    static func rotationZ(_ a: Float) -> M4 {
        let c = cos(a), s = sin(a)
        return M4(columns: (F4(c, s, 0, 0), F4(-s, c, 0, 0), F4(0, 0, 1, 0), F4(0, 0, 0, 1)))
    }

    /// three.js Euler order 'XYZ': R = Rx · Ry · Rz.
    static func euler(_ e: F3) -> M4 {
        rotationX(e.x) * rotationY(e.y) * rotationZ(e.z)
    }

    /// Object3D.lookAt for a camera: −Z points at the target, +Y towards `up`.
    static func lookAtWorld(eye: F3, target: F3, up: F3) -> M4 {
        var z = eye - target
        if simd_length_squared(z) == 0 { z.z = 1 }
        z = simd_normalize(z)
        var x = simd_cross(up, z)
        if simd_length_squared(x) == 0 {
            if abs(up.z) == 1 { z.x += 0.0001 } else { z.z += 0.0001 }
            z = simd_normalize(z)
            x = simd_cross(up, z)
        }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return M4(columns: (F4(x, 0), F4(y, 0), F4(z, 0), F4(eye, 1)))
    }

    /// Orthographic projection with Metal's [0, 1] depth range. Linear depth matches three's
    /// `0.5 * z_ndc + 0.5`, so shadow comparisons and biases carry over unchanged.
    static func orthographic(left: Float, right: Float, top: Float, bottom: Float, near: Float, far: Float) -> M4 {
        let w = 1 / (right - left), h = 1 / (top - bottom), p = 1 / (far - near)
        return M4(columns: (
            F4(2 * w, 0, 0, 0),
            F4(0, 2 * h, 0, 0),
            F4(0, 0, -p, 0),
            F4(-(right + left) * w, -(top + bottom) * h, -near * p, 1)))
    }

    var upperLeft3x3: simd_float3x3 {
        simd_float3x3(columns: (F3(columns.0.x, columns.0.y, columns.0.z), F3(columns.1.x, columns.1.y, columns.1.z), F3(columns.2.x, columns.2.y, columns.2.z)))
    }

    var translationPart: F3 { F3(columns.3.x, columns.3.y, columns.3.z) }

    func transformPoint(_ p: F3) -> F3 {
        let r = self * F4(p, 1)
        return F3(r.x, r.y, r.z) / r.w
    }

    func transformDirection(_ d: F3) -> F3 {
        simd_normalize(upperLeft3x3 * d)
    }
}

/// three.js `Color.set('#rrggbb')` with colour management: sRGB hex → linear.
func srgbToLinear(_ c: Float) -> Float {
    c < 0.04045 ? c * 0.0773993808 : pow(c * 0.9478672986 + 0.0521327014, 2.4)
}

func linearToSrgb(_ c: Float) -> Float {
    c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 0.41666) - 0.055
}

/// Linear RGB colour parsed from a CSS hex string.
func color(_ hex: String) -> F3 {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0xffffff
    let r = Float((v >> 16) & 0xff) / 255, g = Float((v >> 8) & 0xff) / 255, b = Float(v & 0xff) / 255
    return F3(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
}

func mix(_ a: F3, _ b: F3, _ t: Float) -> F3 { a + (b - a) * t }

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }

/// Frame-rate independent exponential smoothing factor.
func damp(_ rate: Double, _ dt: Double) -> Double { 1 - exp(-rate * dt) }

/// Same as `color(_:)`, for scopes where a `color` property shadows the function.
func rgb(_ hex: String) -> F3 { color(hex) }
