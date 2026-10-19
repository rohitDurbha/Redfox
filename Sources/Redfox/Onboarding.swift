import AppKit
import SwiftUI
import Combine

@MainActor
enum Onboarding {
    private static weak var window: NSWindow?

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = Windows.present(title: "Welcome to Redfox", size: CGSize(width: 880, height: 520), resizable: false) { box in
            OnboardingView(box: box)
        }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        window = w
    }
}

struct KeyCap: View {
    let symbol: String
    let label: String
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text(symbol).font(.system(size: 17, weight: .medium))
            }
            Spacer()
            Text(label).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(9)
        .frame(width: wide ? 170 : 104, height: 78)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
    }
}

struct OnboardingView: View {
    let box: WindowBox
    @StateObject private var wheel = WheelModel()
    @StateObject private var page = ViewState(0)
    @StateObject private var launchAtLogin = ViewState(LoginItem.isEnabled)
    private let timer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()
    private let pageCount = 5

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                switch page.value {
                case 0: welcome
                case 1: step(title: "File Converter", text: "Hold a file from Finder, tap Shift, and drop it on a format. The copy is saved right next to the original.", key: KeyCap(symbol: "⇧", label: "shift", wide: true))
                case 2: step(title: "File Tools", text: "Tap Command while dragging to compress, crop, redact, annotate, trim or read metadata.", key: KeyCap(symbol: "⌘", label: "command", wide: false))
                case 3: step(title: "File Actions", text: "Tap Control while dragging to AirDrop, float, copy, move or open a file in Terminal.", key: KeyCap(symbol: "⌃", label: "control", wide: false))
                default: ready
                }
            }
            .foregroundStyle(.white)
            VStack {
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == page.value ? Theme.accent : Color.white.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(width: 880, height: 520)
        .onAppear { configure() }
        .onChange(of: page.value) { _ in configure() }
        .onChange(of: launchAtLogin.value) { LoginItem.set($0) }
        .onReceive(timer) { _ in
            guard (1...3).contains(page.value), !wheel.options.isEmpty else { return }
            wheel.highlighted = ((wheel.highlighted ?? -1) + 1) % wheel.options.count
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Welcome to Redfox")
                .font(.system(size: 38, weight: .bold))
            Text("Convert, compress and edit files right where you drag them.\nEverything happens on your Mac, so nothing is ever uploaded.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            Button("Continue") { page.value = 1 }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 8)
        }
    }

    private func step(title: String, text: String, key: KeyCap) -> some View {
        HStack(spacing: 48) {
            WheelView(model: wheel, preview: true)
                .frame(width: 340, height: 340)
            VStack(alignment: .leading, spacing: 22) {
                Button { page.value -= 1 } label: {
                    Label("Back", systemImage: "arrow.left")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Drag files")
                    .font(.system(size: 26, weight: .medium))
                HStack(spacing: 14) {
                    Text("2. Tap").font(.system(size: 26, weight: .medium))
                    key
                }
                Button("Continue") { page.value += 1 }
                    .buttonStyle(PillButtonStyle())
            }
            .frame(width: 380, alignment: .leading)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { page.value -= 1 } label: {
                Label("Back", systemImage: "arrow.left")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            Text("You are all set")
                .font(.system(size: 36, weight: .bold))
            Text("Redfox lives in the menu bar as a small fox icon. Start a drag in Finder and tap a key whenever you need it.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Launch Redfox when I log in", isOn: $launchAtLogin.value)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(FFmpeg.available ? "ffmpeg is installed, so MKV, WebM, AVI, MP3, FLAC, OGG and Opus are enabled." : "For MKV, WebM, AVI, MP3, FLAC, OGG and Opus, install ffmpeg once with Homebrew by running this command in Terminal.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if !FFmpeg.available {
                    Text("brew install ffmpeg")
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
            }
            Button("Start Using Redfox") {
                UserDefaults.standard.set(true, forKey: "redfox.onboarded")
                box.close()
            }
            .buttonStyle(PillButtonStyle())
            .padding(.top, 6)
        }
        .frame(width: 520, alignment: .leading)
    }

    private func configure() {
        let items: [(String, String?)]
        switch page.value {
        case 1:
            wheel.mode = .convert
            items = [("PNG", nil), ("WEBP", nil), ("HEIC", nil), ("TIFF", nil), ("AVIF", nil), ("BMP", nil), ("PDF", nil), ("JPG", nil)]
        case 2:
            wheel.mode = .tools
            items = [("COMPRESS", "arrow.down.right.and.arrow.up.left"), ("METADATA", "tag"), ("EDIT", "slider.horizontal.3"), ("ANNOTATE", "pencil.tip.crop.circle"), ("ADD BG", "photo"), ("CROP", "crop"), ("REDACT", "eye.slash")]
        case 3:
            wheel.mode = .actions
            items = [("AIRDROP", "antenna.radiowaves.left.and.right"), ("FLOAT", "pin.fill"), ("COPY", "doc.on.doc"), ("MOVE", "folder"), ("COPY PATH", "doc.text"), ("TERMINAL", "terminal")]
        default:
            items = []
        }
        wheel.options = items.map { item in WheelOption(title: item.0, symbol: item.1) { _ in } }
        wheel.highlighted = nil
        wheel.sizeText = "2.4 MB"
        wheel.thumbnail = nil
        wheel.count = 1
        wheel.shown = false
        let model = wheel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            model.shown = true
        }
    }
}
