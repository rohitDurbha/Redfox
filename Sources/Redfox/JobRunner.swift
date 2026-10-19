import AppKit
import SwiftUI

final class JobModel: ObservableObject {
    @Published var title: String
    @Published var detail = ""
    @Published var progress: Double = 0
    @Published var errors: [String] = []
    @Published var finished = false
    var outputs: [URL] = []

    init(title: String) { self.title = title }
}

struct JobView: View {
    @ObservedObject var model: JobModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(model.errors.isEmpty ? Theme.accent : Color.yellow)
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if model.finished {
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !model.finished {
                ProgressView(value: model.progress)
                    .tint(Theme.accent)
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if model.errors.isEmpty {
                Text(model.outputs.count == 1 ? "Done. The result is saved next to the original." : "Done. \(model.outputs.count) results are saved next to the originals.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(model.errors.joined(separator: "\n\n"))
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .frame(width: 340, height: 170, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var icon: String {
        if !model.finished { return "gearshape.2.fill" }
        return model.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

@MainActor
enum JobRunner {
    private static var panels: [NSPanel] = []

    /// Runs `work` once per file, off the main thread, and shows a small progress window.
    static func each(_ title: String, _ urls: [URL], work: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> [URL]) {
        guard !urls.isEmpty else { return }
        let model = JobModel(title: title)
        let panel = present(model)
        Task { @MainActor in
            let n = Double(urls.count)
            for (i, url) in urls.enumerated() {
                model.detail = urls.count > 1 ? "\(url.lastPathComponent)  (\(i + 1) of \(urls.count))" : url.lastPathComponent
                let base = Double(i) / n
                do {
                    let outputs = try await work(url) { p in
                        Task { @MainActor in model.progress = max(model.progress, base + min(max(p, 0), 1) / n) }
                    }
                    model.outputs.append(contentsOf: outputs)
                } catch {
                    model.errors.append("\(url.lastPathComponent)\n\(error.localizedDescription)")
                }
                model.progress = Double(i + 1) / n
            }
            finish(model, panel)
        }
    }

    /// Runs one job that handles all files together.
    static func batch(_ title: String, work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> [URL]) {
        let model = JobModel(title: title)
        let panel = present(model)
        Task { @MainActor in
            do {
                model.outputs = try await work { p in
                    Task { @MainActor in model.progress = min(max(p, 0), 1) }
                }
            } catch {
                model.errors.append(error.localizedDescription)
            }
            model.progress = 1
            finish(model, panel)
        }
    }

    private static func present(_ model: JobModel) -> NSPanel {
        let size = CGSize(width: 340, height: 170)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: JobView(model: model) { [weak panel] in
            if let panel { close(panel) }
        })
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(panels.count % 5) * 110
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 8, y: screen.maxY - size.height - 4 - offset))
        panel.orderFrontRegardless()
        panels.append(panel)
        return panel
    }

    private static func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }

    private static func finish(_ model: JobModel, _ panel: NSPanel) {
        model.finished = true
        if !model.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
        }
        if model.errors.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                close(panel)
            }
        } else {
            NSSound.beep()
        }
    }
}
