// A minimal Object3D / Material model with the three.js semantics the original depends on:
// hierarchical transforms (Euler XYZ), render order, transparency flags, depth tests and face sides.

import Metal
import simd

enum Blend { case none, normal, additive }
enum Side { case front, back, double }
enum ShaderKind { case lit, basic, sprite, points, water, fall, banner, mist, beam }

private let defaultGlowColor = color("#fff7e8")

final class Material {
    private static var nextId = 0
    let id: Int
    var kind: ShaderKind
    var color: F3
    var opacity: Float = 1
    var map: MTLTexture?
    var flat = false
    var transparent = false
    var depthTest = true
    var depthWrite = true
    var depthFunc: MTLCompareFunction = .lessEqual
    var side: Side = .front
    var blending: Blend = .normal
    var visible = true
    var polygonOffset = false
    // lit extras (userData in the original)
    var glow: Float = 0
    var glowColor = defaultGlowColor
    var cut: Float = 0
    var isWindow = false
    var baseColor: F3?
    var baseOpacity: Float?
    // custom shader parameters
    var extra = F4.zero
    var extra2 = F4.zero
    var phase: Float = 0
    var k: Float = 0
    var size: Float = 1

    init(_ kind: ShaderKind, color c: F3 = F3(1, 1, 1)) {
        Material.nextId += 1
        id = Material.nextId
        self.kind = kind
        self.color = c
    }

    /// Lambert material with height mist (`lit()` in materials.ts).
    static func lit(_ hex: String, map: MTLTexture? = nil, flat: Bool = false) -> Material {
        let m = Material(.lit, color: rgb(hex))
        m.map = map
        m.flat = flat
        return m
    }

    static func basic(_ hex: String, map: MTLTexture? = nil, transparent: Bool = false, opacity: Float = 1, depthWrite: Bool = true) -> Material {
        let m = Material(.basic, color: rgb(hex))
        m.map = map
        m.transparent = transparent
        m.opacity = opacity
        m.depthWrite = depthWrite
        return m
    }

    /// The pipeline blending three would actually use.
    var effectiveBlend: Blend {
        if blending == .normal && !transparent { return .none }
        return blending
    }
}

/// A range in a vertex arena plus a CPU copy for picking.
final class GPUMesh {
    let buffer: MTLBuffer
    let offset: Int
    let count: Int
    let primitive: MTLPrimitiveType
    /// Local-space triangle positions (for raycasting); nil for non-pickable meshes.
    let cpu: [F3]?
    let center: F3
    let radius: Float

    init(buffer: MTLBuffer, offset: Int, count: Int, primitive: MTLPrimitiveType = .triangle, cpu: [F3]?, center: F3, radius: Float) {
        self.buffer = buffer
        self.offset = offset
        self.count = count
        self.primitive = primitive
        self.cpu = cpu
        self.center = center
        self.radius = radius
    }
}

final class Node {
    private static var nextId = 0
    let id: Int
    var name = ""
    var position = F3.zero
    var rotation = F3.zero
    var scale = F3(1, 1, 1)
    var matrixAutoUpdate = true
    var matrix = M4.identity
    private(set) var worldMatrix = M4.identity
    var visible = true
    var renderOrder = 0
    private(set) var children: [Node] = []
    private(set) weak var parent: Node?
    var mesh: GPUMesh?
    var material: Material?
    var castShadow = false
    var receiveShadow = false
    var isSprite = false
    /// userData.body / userData.handle of the original.
    var body: String?
    var handle: String?

    init(_ name: String = "") {
        Node.nextId += 1
        id = Node.nextId
        self.name = name
    }

    convenience init(mesh: GPUMesh?, material: Material) {
        self.init()
        self.mesh = mesh
        self.material = material
    }

    func add(_ children: Node...) {
        for c in children {
            c.parent?.remove(c)
            c.parent = self
            self.children.append(c)
        }
    }

    func remove(_ c: Node) {
        children.removeAll { $0 === c }
        if c.parent === self { c.parent = nil }
    }

    func updateWorld(_ parentWorld: M4 = .identity) {
        if matrixAutoUpdate { matrix = M4.translation(position) * M4.euler(rotation) * M4.scale(scale) }
        worldMatrix = parentWorld * matrix
        for c in children { c.updateWorld(worldMatrix) }
    }

    /// World matrix computed on demand from the current local transforms up the chain.
    func computeWorld() -> M4 {
        let local = matrixAutoUpdate ? M4.translation(position) * M4.euler(rotation) * M4.scale(scale) : matrix
        return (parent?.computeWorld() ?? .identity) * local
    }

    func traverse(_ f: (Node) -> Void) {
        f(self)
        for c in children { c.traverse(f) }
    }

    func setScalar(_ s: Float) { scale = F3(repeating: s) }
}
