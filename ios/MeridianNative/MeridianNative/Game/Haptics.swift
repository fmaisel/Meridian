// Tactile feedback for the touch platform: detents tick, architecture snaps, plates thud, the world turns.

import UIKit

final class Haptics {
    var enabled = true
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    func prepare() {
        guard enabled else { return }
        selection.prepare()
        light.prepare()
    }

    func detent() { if enabled { selection.selectionChanged(); selection.prepare() } }
    func tap() { if enabled { light.impactOccurred(intensity: 0.45) } }
    func nope() { if enabled { rigid.impactOccurred(intensity: 0.35) } }
    func snap() { if enabled { rigid.impactOccurred(intensity: 0.7) } }
    func plate() { if enabled { medium.impactOccurred(intensity: 0.8) } }
    func turnStart() { if enabled { soft.impactOccurred(intensity: 0.6) } }
    func turnEnd() { if enabled { soft.impactOccurred(intensity: 1) } }
    func connect() { if enabled { light.impactOccurred(intensity: 0.6) } }
}
