// AudioManager: generative ambient music and soft, tonal effects (native port of src/game/Audio.ts).
// Music and effects have independent volume controls.
//
// Threading: all public methods are meant for the main thread. They only post small commands into a
// lock-free queue; SynthCore executes them on the audio render thread at the start of the next
// 128-frame render quantum (the equivalent of `ctx.currentTime` in the WebAudio original).

import AVFoundation
import Foundation

final class AudioManager {
    var musicVolume: Double = 0.6
    var sfxVolume: Double = 0.8

    /// True once start() has created the synth (like `!!this.ctx` in the original).
    var ready: Bool { core != nil }

    private var core: SynthCore?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var mood = 0 // index into SynthCore.moodNames; "dawn"
    private var userSuspended = false
    private var interrupted = false
    private var disposed = false
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?

    /// The synth always renders at 48 kHz; AVAudioEngine's mixer converts if the hardware differs
    /// (e.g. after a route change to a 44.1 kHz Bluetooth device).
    private let renderSampleRate = 48000.0

    init() {}

    deinit {
        tearDownEngine()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Must be called from a user gesture on the web; on iOS any time. First call creates and starts
    /// the engine; later calls resume it.
    func start() {
        guard !disposed else { return }
        if core != nil {
            userSuspended = false
            resumeEngine()
            return
        }
        configureSession()
        core = SynthCore(sampleRate: renderSampleRate, mood: mood, musicVolume: musicVolume, sfxVolume: sfxVolume)
        installSessionObservers()
        buildEngine()
        resumeEngine()
    }

    func setVolumes(music: Double, sfx: Double) {
        musicVolume = music
        sfxVolume = sfx
        post(.setVolumes(music: music, sfx: sfx))
    }

    func suspend(_ on: Bool) {
        guard core != nil, !disposed else { return }
        userSuspended = on
        if on {
            engine?.pause()
        } else {
            resumeEngine()
        }
    }

    func setMood(_ m: String) {
        guard let idx = SynthCore.moodNames.firstIndex(of: m), idx != mood else { return }
        mood = idx
        post(.setMood(idx))
    }

    // MARK: Effects (no-ops before start())

    func tap() { post(.tap) }
    func nope() { post(.nope) }
    func step(_ i: Int) { post(.step(i)) }
    /// Continuous stone grind while architecture moves; intensity 0..1.
    func grindLevel(_ v: Double) { post(.grind(v)) }
    /// Tonal click whenever a mechanism passes a detent.
    func detent(_ i: Int) { post(.detent(i)) }
    func snap() { post(.snap) }
    func plate() { post(.plate) }
    func rumble(_ dur: Double = 1.6) { post(.rumble(dur)) }
    /// A connection formed (physical or perspective).
    func connect(_ seam: Bool) { post(.connect(seam)) }
    func worldTurn() { post(.worldTurn) }
    func awaken() { post(.awaken) }
    func chapter() { post(.chapter) }

    func finale() {
        guard core != nil, !disposed else { return }
        setMood("radiant")
        post(.finale)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        tearDownEngine()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Private

    private func post(_ c: SynthCommand) {
        guard let core, !disposed else { return }
        core.commands.push(c)
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .ambient: obeys the silent switch and mixes with other apps' audio.
        try? session.setCategory(.ambient, mode: .default, options: [])
        try? session.setPreferredSampleRate(renderSampleRate)
        try? session.setActive(true)
        #endif
    }

    private func buildEngine() {
        guard let core else { return }
        tearDownEngine()
        let engine = AVAudioEngine()
        let node = core.makeSourceNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: core.format)
        engine.prepare()
        self.engine = engine
        sourceNode = node
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // The engine stops itself on hardware format changes (route change, sample-rate change).
            self?.resumeEngine()
        }
    }

    private func tearDownEngine() {
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = nil
        engine?.stop()
        if let engine, let sourceNode { engine.detach(sourceNode) }
        engine = nil
        sourceNode = nil
    }

    /// Starts (or restarts) the engine unless the game suspended audio or an interruption is active.
    private func resumeEngine() {
        guard !disposed, !userSuspended, !interrupted, let engine else { return }
        if engine.isRunning { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        do {
            try engine.start()
        } catch {
            // Typically fails while another app holds a non-mixable session or during an interruption;
            // the next start()/suspend(false)/interruption-end will retry.
        }
    }

    private func installSessionObservers() {
        #if os(iOS)
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.interrupted = true
            case .ended:
                self.interrupted = false
                // A game's ambient soundtrack resumes regardless of the .shouldResume hint.
                self.resumeEngine()
            @unknown default:
                break
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            // Engine configuration changes are handled by AVAudioEngineConfigurationChange; this covers
            // routes that stop the engine without one.
            self?.resumeEngine()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            // All audio objects are invalid now: rebuild session + engine; the synth state survives.
            guard let self, !self.disposed else { return }
            self.interrupted = false
            self.configureSession()
            self.buildEngine()
            self.resumeEngine()
        })
        #endif
    }
}
