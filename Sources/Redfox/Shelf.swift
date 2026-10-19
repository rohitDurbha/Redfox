import AppKit
import SwiftUI

// MARK: - File actions (Control wheel)

@MainActor
enum FileActions {
    static func airDrop(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            Alerts.message("AirDrop", "AirDrop is not available right now. Check that Wi-Fi and Bluetooth are turned on and try again.")
            return
        }
        service.perform(withItems: urls)
    }

    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        Toast.show(urls.count == 1 ? "Copied, paste in Finder to duplicate" : "Copied \(urls.count) items")
    }

    static func copyPath(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
        Toast.show(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied")
    }

    static func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = urls.count == 1 ? "Choose where to move \(urls[0].lastPathComponent)" : "Choose where to move \(urls.count) items"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var moved: [URL] = []
        for url in urls {
            let dest = Paths.unique(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                moved.append(dest)
            } catch {
                Alerts.show(error)
            }
        }
        if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
    }

    static func terminal(_ urls: [URL]) {
        guard let url = urls.first else { return }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

// MARK: - Floating shelf

final class ShelfModel: ObservableObject {
    @Published var urls: [URL]
    @Published var thumbnail: NSImage?

    init(urls: [URL]) {
        self.urls = urls
        self.thumbnail = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func add(_ more: [URL]) {
        for url in more where !urls.contains(url) { urls.append(url) }
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(model.urls.count == 1 ? model.urls[0].lastPathComponent : "\(model.urls.count) items")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

            ZStack(alignment: .topTrailing) {
                if let thumb = model.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.urls.count > 1 {
                    Text("\(model.urls.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(Theme.accent))
                        .padding(10)
                }
            }
            Text("Drag out to drop anywhere")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(width: 160, height: 190)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
    }
}

/// Lets the user drag the shelved files back out, and accepts more files dropped onto it.
final class ShelfDragView: NSView, NSDraggingSource {
    var model: ShelfModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let urls = model?.urls, !urls.isEmpty else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { pair in
            let item = NSDraggingItem(pasteboardWriter: pair.element as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: pair.element.path)
            let offset = CGFloat(min(pair.offset, 4)) * 4
            item.setDraggingFrame(NSRect(x: origin.x - 32 + offset, y: origin.y - 32 - offset, width: 64, height: 64), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? ShelfDragView) === self ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        model?.add(urls)
        return !urls.isEmpty
    }
}

final class MoveHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
enum FloatShelf {
    private static var panels: [NSPanel] = []

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let size = CGSize(width: 160, height: 190)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let model = ShelfModel(urls: urls)
        let first = urls[0]
        Task { @MainActor in
            if let image = await Thumbnails.load(first, side: 160) { model.thumbnail = image }
        }

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: ShelfView(model: model) { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        })
        host.frame = container.bounds
        container.addSubview(host)

        let drag = ShelfDragView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - 28))
        drag.model = model
        container.addSubview(drag)

        let handle = MoveHandleView(frame: NSRect(x: 0, y: size.height - 28, width: size.width - 34, height: 28))
        container.addSubview(handle)

        panel.contentView = container
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + 40, y: mouse.y - size.height / 2))
        panel.orderFrontRegardless()
        panels.append(panel)
    }
}
