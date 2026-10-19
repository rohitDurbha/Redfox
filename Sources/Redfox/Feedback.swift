import AppKit
import SwiftUI

// MARK: - Stored preferences

final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Haptic: Int, CaseIterable, Identifiable {
        case off, light, medium, strong
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .light: return "Light"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }
        var pattern: NSHapticFeedbackManager.FeedbackPattern? {
            switch self {
            case .off: return nil
            case .light: return .alignment
            case .medium: return .generic
            case .strong: return .levelChange
            }
        }
    }

    enum Sound: String, CaseIterable, Identifiable {
        case off, click, tink, pop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .click: return "Soft click"
            case .tink: return "Tink"
            case .pop: return "Pop"
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var haptic: Haptic { didSet { defaults.set(haptic.rawValue, forKey: "feedback.haptic") } }
    @Published var sound: Sound { didSet { defaults.set(sound.rawValue, forKey: "feedback.sound") } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "feedback.volume") } }
    @Published var feedbackOnDrop: Bool { didSet { defaults.set(feedbackOnDrop, forKey: "feedback.onDrop") } }

    private init() {
        defaults.register(defaults: [
            "feedback.haptic": Haptic.medium.rawValue,
            "feedback.sound": Sound.click.rawValue,
            "feedback.volume": 0.35,
            "feedback.onDrop": true,
        ])
        haptic = Haptic(rawValue: defaults.integer(forKey: "feedback.haptic")) ?? .medium
        sound = Sound(rawValue: defaults.string(forKey: "feedback.sound") ?? "") ?? .click
        volume = defaults.double(forKey: "feedback.volume")
        feedbackOnDrop = defaults.bool(forKey: "feedback.onDrop")
    }
}

// MARK: - Haptics and sound

/// The tactile tick that plays as the highlight moves from petal to petal.
/// Haptics come from the Force Touch trackpad, so they are felt while a finger rests on it,
/// which is always true during a trackpad drag.
@MainActor
enum Feedback {
    private static var cache: [Preferences.Sound: NSSound] = [:]

    static func hover() {
        let prefs = Preferences.shared
        play(haptic: prefs.haptic, sound: prefs.sound, volume: prefs.volume)
    }

    static func drop() {
        let prefs = Preferences.shared
        guard prefs.feedbackOnDrop else { return }
        let firmer: Preferences.Haptic = prefs.haptic == .off ? .off : .strong
        play(haptic: firmer, sound: prefs.sound, volume: min(1, prefs.volume * 1.4))
    }

    static func play(haptic: Preferences.Haptic, sound: Preferences.Sound, volume: Double) {
        if let pattern = haptic.pattern {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        guard sound != .off, volume > 0, let player = player(for: sound) else { return }
        player.stop()
        player.volume = Float(volume)
        player.play()
    }

    private static func player(for sound: Preferences.Sound) -> NSSound? {
        if let cached = cache[sound] { return cached }
        let loaded: NSSound?
        switch sound {
        case .off:
            loaded = nil
        case .click:
            if let path = Bundle.main.path(forResource: "Click", ofType: "wav") {
                loaded = NSSound(contentsOfFile: path, byReference: true)
            } else {
                loaded = NSSound(named: "Tink")?.copy() as? NSSound
            }
        case .tink:
            loaded = NSSound(named: "Tink")?.copy() as? NSSound
        case .pop:
            loaded = NSSound(named: "Pop")?.copy() as? NSSound
        }
        cache[sound] = loaded
        return loaded
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @StateObject private var launchAtLogin = ViewState(LoginItem.isEnabled)
    let box: WindowBox

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Wheel feedback")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Haptic strength")
                Picker("Haptic strength", selection: $prefs.haptic) {
                    ForEach(Preferences.Haptic.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: prefs.haptic) { _ in sample() }
                Text("You feel this through the trackpad while your finger rests on it during a drag. It needs a Force Touch trackpad, which every recent MacBook has.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sound")
                    Spacer()
                    Picker("Sound", selection: $prefs.sound) {
                        ForEach(Preferences.Sound.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: prefs.sound) { _ in sample() }
                }
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $prefs.volume, in: 0...1, onEditingChanged: { editing in
                        if !editing { sample() }
                    })
                    .tint(Theme.accent)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(prefs.sound == .off)
                .opacity(prefs.sound == .off ? 0.4 : 1)
            }

            Toggle("Give a firmer tap when a file is dropped", isOn: $prefs.feedbackOnDrop)

            Button {
                Task { @MainActor in
                    for _ in 0..<4 {
                        sample()
                        try? await Task.sleep(nanoseconds: 180_000_000)
                    }
                }
            } label: {
                Label("Try the feedback", systemImage: "hand.tap")
            }

            Divider()

            Text("General")
                .font(.system(size: 15, weight: .semibold))
            Toggle("Launch Redfox when I log in", isOn: $launchAtLogin.value)
                .onChange(of: launchAtLogin.value) { LoginItem.set($0) }

            HStack {
                Text("Version \(Updater.currentVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { box.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .padding(24)
        .frame(width: 420)
    }

    private func sample() {
        Feedback.play(haptic: prefs.haptic, sound: prefs.sound, volume: prefs.volume)
    }
}

@MainActor
enum SettingsWindow {
    private static weak var window: NSWindow?

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        window = Windows.present(title: "Redfox Settings", size: CGSize(width: 420, height: 480), resizable: false) { box in
            SettingsView(box: box)
        }
    }
}
