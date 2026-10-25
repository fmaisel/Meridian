// Controlled palette (port of src/render/palette.ts). Architecture palettes are fixed per area;
// moods (sky, mist, light) blend as the camera ascends.

import Metal
import simd

let PALETTES: [String: [String: String]] = [
    "lily": ["stone": "#86c39c", "lily": "#86c39c", "flower": "#f4a9bb"],
    "sand": [
        "stone": "#e9cf9f", "accent": "#dcb17c", "trim": "#f3e2c0", "cap": "#f8edd5", "roof": "#6d9ea6", "roofCoral": "#e27c63",
        "foliage": "#ec8a33", "gate": "#c7785a", "window": "#9a6f55",
    ],
    "coral": [
        "stone": "#ea7f69", "accent": "#f2b48f", "trim": "#f6d7c2", "cap": "#f8c3a8", "roof": "#6d9ea6", "roofCoral": "#c9584a",
        "foliage": "#e07a3c", "gate": "#f3e3cf", "window": "#a2473f",
    ],
    "ivory": [
        "shrineRoof": "#6d9ea6",
        "stone": "#f1e7d7", "accent": "#e8a491", "trim": "#e79d8b", "cap": "#fbf5ea", "roof": "#e78c9e", "roofCoral": "#e78c9e",
        "foliage": "#ef9a52", "gate": "#d9897a", "window": "#b98d7c",
    ],
    "dusk": [
        "stone": "#f5dbe3", "accent": "#a690dd", "trim": "#fdf2f5", "cap": "#fdeff4", "roof": "#9b84d6", "roofCoral": "#e8879c",
        "roofViolet": "#8f78cf", "foliage": "#f0a1b8", "gate": "#8f78cf", "window": "#9a7fb8",
    ],
    // II · the olive garden (khaki sky, ochre platforms, orange domes, teal pennants)
    "olive": [
        "shrineRoof": "#c47a2e",
        "stone": "#a9a57c", "accent": "#d29a45", "trim": "#e2dcb8", "cap": "#e8e2c0", "roof": "#c47a2e", "roofCoral": "#c9673f",
        "foliage": "#7d9147", "gate": "#8f8a5f", "window": "#5f5a3c", "banner": "#3f9690",
    ],
    // III · the rose spire (pink walls, pale tiled caps, magenta domes, cypresses)
    "rose": [
        "shrineRoof": "#c4467d",
        "stone": "#d98f8f", "accent": "#f1c4ad", "trim": "#f6dfd6", "cap": "#ece6da", "roof": "#c4467d", "roofCoral": "#e0627a",
        "foliage": "#3b8f6c", "gate": "#b85d6e", "window": "#7d3b4a", "banner": "#f2c46b",
    ],
    // IV · the white temple under the stars
    "temple": [
        "shrineRoof": "#6fd3d8",
        "stone": "#e4e9e6", "accent": "#e2d3ad", "trim": "#f8faf9", "cap": "#f3f6f3", "roof": "#eff3f1", "roofCoral": "#6fd3d8",
        "foliage": "#86bfa9", "gate": "#1e2a2c", "window": "#24363a", "banner": "#6fd3d8",
    ],
    // V · the deep blue hall
    "slate": [
        "shrineRoof": "#3d56d8",
        "stone": "#a3b3e8", "accent": "#3d56d8", "trim": "#e4e9fc", "cap": "#d2dcf8", "roof": "#bccaf4", "roofCoral": "#7f93e8",
        "roofViolet": "#5b70da", "foliage": "#86a0e4", "gate": "#2d3fa8", "window": "#2e3c90", "banner": "#eef1fd",
    ],
]

private let COMMON: [String: String] = [
    "handle": "#fbf3e4", "handlePin": "#e9735c", "gold": "#f2c46b", "roofViolet": "#8f78cf", "banner": "#e27c63",
    "shrineRoof": "#8f78cf",
]

func paletteColor(_ palette: String, _ key: String) -> String {
    let p = PALETTES[palette] ?? PALETTES["sand"]!
    return p[key] ?? COMMON[key] ?? p["stone"]!
}

struct Mood {
    var skyTop: F3
    var skyBottom: F3
    var fog: F3
    var sun: F3
    var hemiSky: F3
    var hemiGround: F3
    var glow: F3
    /// Starlight in the sky (night moods).
    var stars: Float = 0

    static func blend(_ a: Mood, _ b: Mood, _ t: Float) -> Mood {
        Mood(skyTop: mix(a.skyTop, b.skyTop, t), skyBottom: mix(a.skyBottom, b.skyBottom, t), fog: mix(a.fog, b.fog, t),
             sun: mix(a.sun, b.sun, t), hemiSky: mix(a.hemiSky, b.hemiSky, t), hemiGround: mix(a.hemiGround, b.hemiGround, t),
             glow: mix(a.glow, b.glow, t), stars: a.stars + (b.stars - a.stars) * t)
    }
}

private func mk(_ o: [String: String], stars: Float = 0) -> Mood {
    Mood(skyTop: color(o["skyTop"]!), skyBottom: color(o["skyBottom"]!), fog: color(o["fog"]!), sun: color(o["sun"]!),
         hemiSky: color(o["hemiSky"]!), hemiGround: color(o["hemiGround"]!), glow: color(o["glow"]!), stars: stars)
}

/// The synthesiser knows four moods; the chapters' skies borrow the nearest one.
let AUDIO_MOOD: [String: String] = ["garden": "noon", "rose": "dawn", "night": "dusk", "deep": "dusk"]

let MOODS: [String: Mood] = [
    "dawn": mk(["skyTop": "#bfe4da", "skyBottom": "#f7eedb", "fog": "#eef0de", "sun": "#fff1dc", "hemiSky": "#fff8ee", "hemiGround": "#d9e6d8", "glow": "#fff6dc"]),
    "noon": mk(["skyTop": "#9fd2c4", "skyBottom": "#eef2e3", "fog": "#dfeee4", "sun": "#fff1e2", "hemiSky": "#fff6ee", "hemiGround": "#d3e6da", "glow": "#fdf6e6"]),
    "dusk": mk(["skyTop": "#9a88d2", "skyBottom": "#f5dbe3", "fog": "#ecd5e3", "sun": "#fff0e6", "hemiSky": "#fff1f6", "hemiGround": "#dccbe8", "glow": "#ffe6ee"]),
    "garden": mk(["skyTop": "#b2a86f", "skyBottom": "#ddd5a6", "fog": "#cdc392", "sun": "#fff3da", "hemiSky": "#fff8e6", "hemiGround": "#d6cea0", "glow": "#f3ecc8"]),
    "rose": mk(["skyTop": "#7fa9bd", "skyBottom": "#cfe0db", "fog": "#bcd3cf", "sun": "#fff1ea", "hemiSky": "#fff4f2", "hemiGround": "#dcc8cc", "glow": "#eef5ef"]),
    "night": mk(["skyTop": "#101817", "skyBottom": "#4a514d", "fog": "#3a413e", "sun": "#eef4f2", "hemiSky": "#cdd9da", "hemiGround": "#4d5957", "glow": "#5c6662"], stars: 1),
    "deep": mk(["skyTop": "#141f4c", "skyBottom": "#2c3f8c", "fog": "#24336f", "sun": "#eef0ff", "hemiSky": "#dfe5ff", "hemiGround": "#5d6bb4", "glow": "#3e56b6"], stars: 0.55),
    "radiant": mk(["skyTop": "#f6d39a", "skyBottom": "#fff4e2", "fog": "#fff0dc", "sun": "#fff6e8", "hemiSky": "#fffaf0", "hemiGround": "#f7e1c6", "glow": "#fff3d6"]),
]

/// Material cache (MaterialLibrary in materials.ts).
final class MaterialLibrary {
    private var cache: [String: Material] = [:]
    let tile: MTLTexture

    init(tile: MTLTexture) { self.tile = tile }

    func get(_ palette: String, _ key: String) -> Material {
        let k = "\(palette):\(key)"
        if let m = cache[k] { return m }
        let m = Material.lit(paletteColor(palette, key), flat: key == "foliage")
        cache[k] = m
        return m
    }

    /// Material owned by one body (so the body can fade on its own when it hides the action).
    func forBody(_ body: String, _ palette: String, _ key: String, cap: Bool = false) -> Material {
        let k = "body:\(body):\(palette):\(key):\(cap)"
        if let m = cache[k] { return m }
        let m = cap ? Material.lit(paletteColor(palette, key), map: tile) : Material.lit(paletteColor(palette, key), flat: key == "foliage")
        cache[k] = m
        return m
    }

    /// A unique material instance (for handles that glow individually).
    func unique(_ palette: String, _ key: String) -> Material {
        Material.lit(paletteColor(palette, key))
    }
}
