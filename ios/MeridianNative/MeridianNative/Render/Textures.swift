// Canvas-drawn textures of the original (glyphs, soft light, blob shadow, cap tile pattern), painted with
// Core Graphics in canvas coordinates and uploaded like three's CanvasTexture: flipY, straight alpha,
// sRGB, mipmapped.

import CoreGraphics
import Metal

final class TextureLibrary {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cache: [String: MTLTexture] = [:]

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// Subtle tile pattern for walkable caps (one cell per texture repeat).
    lazy var tile: MTLTexture = make(size: 128) { g, s in
        g.setFillColor(rgba(255, 255, 255, 1))
        g.fill(CGRect(x: 0, y: 0, width: s, height: s))
        g.setStrokeColor(rgba(120, 90, 70, 0.10))
        g.setLineWidth(3)
        g.stroke(CGRect(x: 1.5, y: 1.5, width: s - 3, height: s - 3))
        g.setStrokeColor(rgba(255, 255, 255, 0.6))
        g.setLineWidth(2)
        g.stroke(CGRect(x: 6, y: 6, width: s - 12, height: s - 12))
        g.setFillColor(rgba(120, 90, 70, 0.035))
        g.fill(CGRect(x: 22, y: 22, width: s - 44, height: s - 44))
    }

    func glyph(_ kind: String) -> MTLTexture {
        if let t = cache[kind] { return t }
        let t = make(size: 256) { g, s in
            g.setLineCap(.round)
            g.setLineJoin(.round)
            Self.paint(kind, g, s)
        }
        cache[kind] = t
        return t
    }

    private static func paint(_ kind: String, _ g: CGContext, _ s: CGFloat) {
        let white = rgba(255, 255, 255, 1)
        let c = CGPoint(x: s / 2, y: s / 2)
        func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
        switch kind {
        case "plate":
            g.setStrokeColor(white)
            g.setLineWidth(s * 0.045)
            g.stroke(CGRect(x: s * 0.16, y: s * 0.16, width: s * 0.68, height: s * 0.68))
            g.addPath(circle(s * 0.2)); g.strokePath()
            g.setFillColor(white)
            g.addPath(circle(s * 0.08)); g.fillPath()
        case "eye":
            g.setStrokeColor(white)
            g.setLineWidth(s * 0.04)
            g.move(to: CGPoint(x: s * 0.14, y: s / 2))
            g.addQuadCurve(to: CGPoint(x: s * 0.86, y: s / 2), control: CGPoint(x: s / 2, y: s * 0.12))
            g.addQuadCurve(to: CGPoint(x: s * 0.14, y: s / 2), control: CGPoint(x: s / 2, y: s * 0.88))
            g.strokePath()
            g.addPath(circle(s * 0.13)); g.strokePath()
            g.setFillColor(white)
            g.addPath(circle(s * 0.055)); g.fillPath()
        case "step":
            // two arrows chasing each other round a hub: this stone turns something every time
            g.setStrokeColor(white)
            g.setFillColor(white)
            g.setLineWidth(s * 0.045)
            for k in 0..<2 {
                let a0 = CGFloat(k) * .pi + 0.35, a1 = a0 + .pi - 0.7
                g.addArc(center: c, radius: s * 0.27, startAngle: a0, endAngle: a1, clockwise: false)
                g.strokePath()
                let tip = CGPoint(x: c.x + cos(a1) * s * 0.27, y: c.y + sin(a1) * s * 0.27)
                let tan = CGPoint(x: -sin(a1), y: cos(a1)), nrm = CGPoint(x: cos(a1), y: sin(a1))
                g.move(to: CGPoint(x: tip.x + tan.x * s * 0.09, y: tip.y + tan.y * s * 0.09))
                g.addLine(to: CGPoint(x: tip.x + nrm.x * s * 0.07, y: tip.y + nrm.y * s * 0.07))
                g.addLine(to: CGPoint(x: tip.x - nrm.x * s * 0.07, y: tip.y - nrm.y * s * 0.07))
                g.closePath()
                g.fillPath()
            }
            g.stroke(CGRect(x: s * 0.12, y: s * 0.12, width: s * 0.76, height: s * 0.76))
            g.addPath(circle(s * 0.07)); g.fillPath()
        case "start":
            g.setStrokeColor(white)
            g.setLineWidth(s * 0.035)
            g.addPath(circle(s * 0.26)); g.strokePath()
        case "goal":
            g.setStrokeColor(white)
            g.setFillColor(white)
            g.setLineWidth(s * 0.035)
            g.addPath(circle(s * 0.14)); g.fillPath()
            for i in 0..<8 {
                let a = CGFloat(i) / 8 * .pi * 2
                let r2: CGFloat = i % 2 == 1 ? 0.3 : 0.37
                g.move(to: CGPoint(x: s / 2 + cos(a) * s * 0.22, y: s / 2 + sin(a) * s * 0.22))
                g.addLine(to: CGPoint(x: s / 2 + cos(a) * s * r2, y: s / 2 + sin(a) * s * r2))
                g.strokePath()
            }
        case "soft":
            radial(g, s, [(0, rgba(255, 255, 255, 1)), (0.4, rgba(255, 255, 255, 0.45)), (1, rgba(255, 255, 255, 0))])
        case "shadow":
            radial(g, s, [(0, rgba(40, 20, 30, 0.55)), (0.55, rgba(40, 20, 30, 0.25)), (1, rgba(40, 20, 30, 0))])
        default: // ring
            g.setStrokeColor(white)
            g.setLineWidth(s * 0.05)
            g.stroke(CGRect(x: s * 0.12, y: s * 0.12, width: s * 0.76, height: s * 0.76))
        }
    }

    private static func radial(_ g: CGContext, _ s: CGFloat, _ stops: [(CGFloat, CGColor)]) {
        let grad = CGGradient(colorsSpace: srgb, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
        g.drawRadialGradient(grad, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                             endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [.drawsAfterEndLocation])
    }

    /// Paint in canvas coordinates (origin top-left), then upload with three's flipY.
    private func make(size: Int, paint: (CGContext, CGFloat) -> Void) -> MTLTexture {
        let bytesPerRow = size * 4
        var data = [UInt8](repeating: 0, count: size * bytesPerRow)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            paint(ctx, CGFloat(size))
        }
        // un-premultiply (canvas pixels reach WebGL as straight alpha) and flip rows (flipY)
        var flipped = [UInt8](repeating: 0, count: data.count)
        for y in 0..<size {
            let src = y * bytesPerRow, dst = (size - 1 - y) * bytesPerRow
            for x in 0..<size {
                let i = src + x * 4, o = dst + x * 4
                let a = data[i + 3]
                flipped[o + 3] = a
                if a == 0 { continue }
                for k in 0..<3 { flipped[o + k] = UInt8(min(255, (Int(data[i + k]) * 255 + Int(a) / 2) / Int(a))) }
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: true)
        desc.usage = .shaderRead
        let tex = device.makeTexture(descriptor: desc)!
        tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: flipped, bytesPerRow: bytesPerRow)
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }
}

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
}
