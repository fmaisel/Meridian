// UIManager: title screen, pause, settings, chapter cards, whispers and the ending. Observable state
// rendered by SwiftUI (port of src/game/UI.ts).

import Foundation
import Observation
import simd

/// One chapter as the gallery shows it.
struct ChapterCard: Identifiable, Equatable {
    let id: String
    let numeral: String
    let title: String
    let lines: [String]
    let unlocked: Bool
    let completed: Bool
    let inProgress: Bool
    let petals: String
    let tips: String
    let centre: String
}

struct UIHandlers {
    var begin: () -> Void = {}
    var continueGame: () -> Void = {}
    var pause: (Bool) -> Void = { _ in }
    var hint: () -> Void = {}
    var restart: () -> Void = {}
    var toTitle: () -> Void = {}
    var again: () -> Void = {}
    var turn: (Int) -> Void = { _ in }
    var settingsChanged: (Settings) -> Void = { _ in }
    var nextStep: () -> Void = {}
    var openChapter: (String) -> Void = { _ in }
    var startChapter: () -> Void = {}
    var leave: () -> Void = {}
    var complete: () -> Void = {}
}

@Observable
final class UIState {
    var handlers = UIHandlers()
    var settings: Settings {
        didSet { if settings != oldValue { handlers.settingsChanged(settings) } }
    }

    var titleShown = true
    var titleFading = false
    var hasSave = false
    var hudShown = false
    var pauseShown = false
    var settingsShown = false
    var confirmShown = false
    var confirmText = "Start again?"
    var endingShown = false
    var chapterNum = ""
    var chapterName = ""
    var chapterShow = false
    var hintText = ""
    var hintShow = false
    var turnHintShown = false
    var turnHintShow = false
    var turnButtonsShown = false
    var fadeClear = false
    var debugText: String?
    // chapter gallery
    var selectShown = false
    var selectLeaving = false
    var chapters: [ChapterCard] = []
    var selectIndex = 0
    // chapter card before play, and the card that closes a chapter
    var introShown = false
    var introNumeral = ""
    var introTitle = ""
    var introLines: [String] = []
    var introResume = false
    var completeShown = false
    var completeNumeral = ""
    var completeTitle = ""
    var leaveShown = false
    /// Mist rising over the lower screen behind cards and endings (linear colour of the mood's fog).
    var groundFade = false
    var groundColor = SIMD3<Float>(0.9, 0.9, 0.85)
    /// "Chapter I · The Drawbridge", shown above the pause screen.
    var playingLabel = ""
    /// Landscape layout: title on the left, monument on the right.
    var wide = false

    @ObservationIgnored private var hintToken = 0
    @ObservationIgnored private var chapterToken = 0
    @ObservationIgnored private var turnToken = 0
    @ObservationIgnored private var settingsReturn = "title"
    @ObservationIgnored private var confirmAction: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    func fadeIn() { after(0.04) { self.fadeClear = true } }

    func fadeOut(_ seconds: Double = 1.5, _ done: @escaping () -> Void) {
        fadeClear = false
        after(seconds, done)
    }

    func showTitle(hasSave: Bool) {
        titleShown = true
        titleFading = false
        self.hasSave = hasSave
        hudShown = false
    }

    func hideTitle(hud: Bool = true) {
        titleFading = true
        after(1.2) { if self.titleFading { self.titleShown = false } }
        hudShown = hud
    }

    func showSelect(_ cards: [ChapterCard], focus: Int) {
        chapters = cards
        selectIndex = max(0, min(cards.count - 1, focus))
        selectLeaving = false
        selectShown = true
    }

    /// The chosen shrine draws near while the gallery fades (the fade to the chapter follows).
    func leaveSelect() { selectLeaving = true }

    func hideSelect() {
        selectShown = false
        selectLeaving = false
    }

    func showIntro(numeral: String, title: String, lines: [String], resume: Bool) {
        introNumeral = numeral
        introTitle = title
        introLines = lines
        introResume = resume
        introShown = true
    }

    func hideIntro() { introShown = false }

    func showComplete(numeral: String, title: String) {
        completeNumeral = numeral
        completeTitle = title
        completeShown = true
    }

    func hideComplete() { completeShown = false }

    func askLeave() {
        pauseShown = false
        leaveShown = true
    }

    func cancelLeave() {
        leaveShown = false
        pauseShown = true
    }

    var titleVisible: Bool { titleShown && !titleFading }

    func setPause(_ on: Bool) {
        pauseShown = on
        if !on { settingsShown = false; confirmShown = false; leaveShown = false }
    }

    var paused: Bool { pauseShown || settingsShown || confirmShown || leaveShown }

    func openSettings(from: String) {
        settingsReturn = from
        pauseShown = false
        settingsShown = true
    }

    func closeSettings() {
        settingsShown = false
        if settingsReturn == "pause" { pauseShown = true }
    }

    var settingsFromPause: Bool { settingsReturn == "pause" }

    func confirm(_ text: String, _ action: @escaping () -> Void) {
        confirmText = text
        confirmAction = action
        pauseShown = false
        confirmShown = true
    }

    func confirmYes() {
        confirmShown = false
        let a = confirmAction
        confirmAction = nil
        a?()
    }

    func confirmNo() {
        confirmShown = false
        pauseShown = true
    }

    func chapter(_ title: String) {
        let parts = title.components(separatedBy: "·")
        chapterNum = parts[0].trimmingCharacters(in: .whitespaces)
        chapterName = parts.dropFirst().joined(separator: "·").trimmingCharacters(in: .whitespaces)
        chapterShow = true
        chapterToken += 1
        let t = chapterToken
        after(4.2) { if self.chapterToken == t { self.chapterShow = false } }
    }

    func whisper(_ text: String, _ seconds: Double = 6) {
        hintText = text
        hintShow = true
        hintToken += 1
        let t = hintToken
        after(seconds) { if self.hintToken == t { self.hintShow = false } }
    }

    func turnTutorial(_ on: Bool) {
        turnToken += 1
        let t = turnToken
        if on {
            turnHintShown = true
            after(0.03) { if self.turnToken == t { self.turnHintShow = true } }
        } else {
            turnHintShow = false
            after(1.4) { if self.turnToken == t { self.turnHintShown = false } }
        }
    }

    func hud(_ on: Bool) { hudShown = on }

    func turnButtons(_ on: Bool) { turnButtonsShown = on }

    func showEnding(_ on: Bool) {
        endingShown = on
        hudShown = !on
    }
}
