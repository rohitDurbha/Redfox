import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Entry point

@main
struct RedfoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(nsImage: MenuIcon.image)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            DragMonitor.shared.start()
            Updater.checkInBackgroundIfDue()
            if !UserDefaults.standard.bool(forKey: "redfox.onboarded") {
                Onboarding.show()
            }
        }
    }
}

struct MenuContent: View {
    @StateObject private var launchAtLogin = ViewState(LoginItem.isEnabled)
    @StateObject private var paused = ViewState(false)

    var body: some View {
        Button("How to Use Redfox") { Onboarding.show() }
        Button("Check for Updates…") { Updater.check(userInitiated: true) }
        Divider()
        Toggle("Launch at Login", isOn: $launchAtLogin.value)
            .onChange(of: launchAtLogin.value) { LoginItem.set($0) }
        Toggle("Pause Redfox", isOn: $paused.value)
            .onChange(of: paused.value) { DragMonitor.shared.paused = $0 }
        Divider()
        Text("Version \(Updater.currentVersion)")
        Button("Quit Redfox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Menu bar icon

enum MenuIcon {
    /// The fox silhouette, drawn as a template so it follows the menu bar's light or dark look.
    static let image: NSImage = {
        if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: image.size.width * 18 / max(image.size.height, 1), height: 18)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Redfox") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()
}

// MARK: - View state

/// Holds a single value for a view. Used in place of @State, which needs a compiler
/// plugin that only ships with full Xcode on the newest SDKs.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Login item

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Redfox login item error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.91, green: 0.32, blue: 0.18)
    static let accentLight = Color(red: 0.99, green: 0.55, blue: 0.22)
    static let gradient = LinearGradient(colors: [accentLight, accent], startPoint: .top, endPoint: .bottom)
    static let segment = Color(white: 0.23)
    static let background = Color(white: 0.09)
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 46)
            .padding(.vertical, 15)
            .background(Capsule().fill(Theme.accent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Windows

@MainActor
final class WindowBox {
    weak var window: NSWindow?
    func close() { window?.close() }
}

@MainActor
enum Windows {
    private static var open: [NSWindow] = []

    @discardableResult
    static func present<V: View>(title: String, size: CGSize, resizable: Bool = true, content: (WindowBox) -> V) -> NSWindow {
        let box = WindowBox()
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: content(box))
        box.window = window
        window.center()
        open.append(window)
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in open.removeAll { ObjectIdentifier($0) == id } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

// MARK: - Alerts and toasts

@MainActor
enum Alerts {
    static func show(_ error: Error) {
        message("Redfox", error.localizedDescription)
    }

    static func message(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

@MainActor
enum Toast {
    static func show(_ text: String) {
        let size = CGSize(width: 320, height: 44)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView:
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .frame(width: size.width, height: size.height)
        )
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 24))
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            panel.orderOut(nil)
        }
    }
}
