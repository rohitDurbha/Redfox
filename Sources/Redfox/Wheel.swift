import AppKit
import SwiftUI

// MARK: - Geometry

enum WheelGeometry {
    static let panelSize = CGSize(width: 340, height: 384)
    static let center = CGPoint(x: 170, y: 170)
    static let ringRadius: CGFloat = 164
    static let outer: CGFloat = 152
    static let inner: CGFloat = 66
    static let corner: CGFloat = 14
    static let gap: CGFloat = 7
    static let hubRadius: CGFloat = 58

    static func angle(_ index: Int, _ count: Int) -> Double {
        Double(index) * 2 * Double.pi / Double(max(count, 1))
    }

    /// Angle 0 points straight up and increases clockwise, in a top-left origin space.
    static func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    static func labelPoint(_ index: Int, _ count: Int) -> CGPoint {
        point(angle(index, count), (outer + inner) / 2 + 3)
    }

    static func index(at p: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > Double(inner) - 4, distance < Double(ringRadius) + 30 else { return nil }
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * Double.pi }
        let step = 2 * Double.pi / Double(count)
        return Int(((a + step / 2) / step).rounded(.down)) % count
    }
}

// MARK: - Model

final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var options: [WheelOption] = []
    @Published var highlighted: Int? = nil
    @Published var thumbnail: NSImage? = nil
    @Published var sizeText = ""
    @Published var count = 0
    @Published var shown = false
    var files: [URL] = []
}

// MARK: - Views

struct SegmentShape: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let g = WheelGeometry.self
        let half = Double.pi / Double(max(count, 1))
        let mid = g.angle(index, count)
        let d = Double(g.corner + g.gap / 2)
        let ro = g.outer - g.corner
        let ri = g.inner + g.corner
        func inset(_ r: CGFloat) -> Double { count <= 1 ? 0 : asin(min(1, d / Double(r))) }
        let o0 = mid - half + inset(ro), o1 = mid + half - inset(ro)
        let i0 = mid - half + inset(ri), i1 = mid + half - inset(ri)
        let steps = 28
        var path = Path()
        for s in 0...steps {
            let a = o0 + (o1 - o0) * Double(s) / Double(steps)
            let pt = g.point(a, ro)
            if s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        for s in 0...steps {
            let a = i1 + (i0 - i1) * Double(s) / Double(steps)
            path.addLine(to: g.point(a, ri))
        }
        path.closeSubpath()
        return path
    }
}

/// Light frosted glass for the live wheel, matching the reference video.
/// The dark variant is only used for the illustrations on the welcome screens.
enum WheelStyle {
    case glass, dark

    var segment: Color { self == .glass ? Color.white : Color(white: 0.23) }
    var segmentOpacity: Double { self == .glass ? 0.55 : 1 }
    var label: Color { self == .glass ? Color(white: 0.13) : Color.white.opacity(0.92) }
    var pill: Color { self == .glass ? Color.white.opacity(0.78) : Color(white: 0.2) }
    var pillText: Color { self == .glass ? Color(white: 0.15) : Color.white }
    var scheme: ColorScheme { self == .glass ? .light : .dark }
}

struct SegmentView: View {
    let index: Int
    let count: Int
    let highlighted: Bool
    let style: WheelStyle

    var body: some View {
        let shape = SegmentShape(index: index, count: count)
        // Filling and stroking with one opaque color inside a compositing group gives
        // rounded petal corners without the overlap showing as a darker band.
        let stroke = StrokeStyle(lineWidth: WheelGeometry.corner * 2, lineJoin: .round)
        let glow = RadialGradient(
            colors: [Color(red: 0.99, green: 0.47, blue: 0.22), Color(red: 0.88, green: 0.22, blue: 0.11)],
            center: UnitPoint(x: WheelGeometry.labelPoint(index, count).x / WheelGeometry.panelSize.width,
                              y: WheelGeometry.labelPoint(index, count).y / (style == .glass ? WheelGeometry.panelSize.height : WheelGeometry.panelSize.width)),
            startRadius: 4,
            endRadius: 110
        )
        ZStack {
            ZStack {
                shape.fill(style.segment)
                shape.stroke(style.segment, style: stroke)
            }
            .compositingGroup()
            .opacity(highlighted ? 0 : style.segmentOpacity)

            ZStack {
                shape.fill(glow)
                shape.stroke(glow, style: stroke)
            }
            .compositingGroup()
            .opacity(highlighted ? 1 : 0)
        }
        .shadow(color: .black.opacity(style == .glass ? 0.08 : 0.35), radius: 2, y: 1)
    }
}

struct SegmentLabel: View {
    let option: WheelOption
    let highlighted: Bool
    let count: Int
    let style: WheelStyle

    var body: some View {
        VStack(spacing: 5) {
            if let symbol = option.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
            }
            Text(option.title)
                .font(.system(size: option.symbol == nil ? (count > 8 ? 13 : 16) : 10, weight: .bold, design: .rounded))
                .tracking(option.symbol == nil ? 0.3 : 0.6)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(highlighted ? Color.white : style.label)
        .frame(width: count > 8 ? 62 : 78)
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    var preview = false

    var body: some View {
        let g = WheelGeometry.self
        let n = model.options.count
        let style: WheelStyle = preview ? .dark : .glass
        let height = preview ? g.panelSize.width : g.panelSize.height
        let anchor = UnitPoint(x: g.center.x / g.panelSize.width, y: g.center.y / height)
        let shown = model.shown
        let pillText = model.highlighted.flatMap { model.options.indices.contains($0) ? model.options[$0].title : nil } ?? model.sizeText

        ZStack {
            ZStack {
                // Outer glass disc
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(style == .glass ? Color.white.opacity(0.16) : Color(white: 0.07).opacity(0.85)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(style == .glass ? 0.6 : 0.14), lineWidth: 1.5))
                    .overlay(Circle().inset(by: 5).strokeBorder(Color.white.opacity(style == .glass ? 0.25 : 0.05), lineWidth: 1))
                    .frame(width: g.ringRadius * 2, height: g.ringRadius * 2)
                    .shadow(color: .black.opacity(style == .glass ? 0.22 : 0.5), radius: 22, y: 10)
                    .position(g.center)

                ForEach(0..<n, id: \.self) { i in
                    SegmentView(index: i, count: n, highlighted: model.highlighted == i, style: style)
                }

                // Recessed hub
                Circle()
                    .fill(RadialGradient(
                        colors: style == .glass
                            ? [Color(red: 0.98, green: 0.55, blue: 0.3).opacity(0.55), Color.white.opacity(0.2)]
                            : [Color(white: 0.04), Color(white: 0.08)],
                        center: .center, startRadius: 4, endRadius: g.hubRadius))
                    .overlay(Circle().strokeBorder(Color.white.opacity(style == .glass ? 0.55 : 0.1), lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .frame(width: g.hubRadius * 2, height: g.hubRadius * 2)
                    .position(g.center)

                ForEach(0..<n, id: \.self) { i in
                    SegmentLabel(option: model.options[i], highlighted: model.highlighted == i, count: n, style: style)
                        .position(g.labelPoint(i, n))
                }
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.16).delay(shown ? 0.08 : 0), value: shown)

                Text(pillText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(style.pillText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 64, maxWidth: 92)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(style.pill))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(style == .glass ? 0.8 : 0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .position(g.center)
                    .animation(.easeOut(duration: 0.1), value: pillText)

                if model.count > 1 {
                    Text("\(model.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(Theme.accent))
                        .position(x: g.center.x + 36, y: g.center.y - 36)
                }
            }
            // The whole disc grows out of the cursor with a small overshoot, as in the video.
            .scaleEffect(shown ? 1 : 0.18, anchor: anchor)
            .opacity(shown ? 1 : 0)
            .animation(shown ? .spring(response: 0.3, dampingFraction: 0.66) : .easeIn(duration: 0.14), value: shown)

            if !preview {
                HStack(spacing: 6) {
                    chip("⇧", "Convert", .convert)
                    chip("⌘", "Tools", .tools)
                    chip("⌃", "Actions", .actions)
                }
                .position(x: g.center.x, y: g.panelSize.height - 22)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : -10)
                .animation(.easeOut(duration: 0.2).delay(shown ? 0.15 : 0), value: shown)
            }
        }
        .frame(width: g.panelSize.width, height: height)
        .animation(.easeOut(duration: 0.1), value: model.highlighted)
        .animation(.easeOut(duration: 0.15), value: model.mode)
        .environment(\.colorScheme, style.scheme)
    }

    private func chip(_ key: String, _ label: String, _ mode: WheelMode) -> some View {
        let active = model.mode == mode
        return Text("\(key) \(label)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? Color.white : Color(white: 0.15))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Theme.accent : Color.white.opacity(0.8)))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

// MARK: - Drop target sitting on top of the wheel

final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func segment(for info: NSDraggingInfo) -> Int? {
        let p = convert(info.draggingLocation, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        return WheelGeometry.index(at: flipped, count: controller?.model.options.count ?? 0)
    }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        if mask.contains(.move) { return .move }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = segment(for: sender)
        if controller?.model.highlighted != index {
            controller?.model.highlighted = index
            if index != nil { Feedback.hover() }
        }
        return index == nil ? [] : operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.model.highlighted = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        segment(for: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = segment(for: sender) else { return false }
        Feedback.drop()
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        controller?.perform(index: index, urls: urls)
        return true
    }
}

// MARK: - Controller

@MainActor
final class WheelController {
    static let shared = WheelController()

    let model = WheelModel()
    private let panel: NSPanel
    private var hideToken = 0

    var isVisible: Bool { panel.isVisible }

    private init() {
        let size = WheelGeometry.panelSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let host = NSHostingView(rootView: WheelView(model: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        let drop = WheelDropView(frame: container.bounds)
        drop.autoresizingMask = [.width, .height]
        container.addSubview(drop)
        panel.contentView = container
        drop.controller = self
    }

    func show(mode: WheelMode, files: [URL], at point: NSPoint) {
        let newFiles = files != model.files
        model.files = files
        model.mode = mode
        model.options = Catalog.options(mode, files: files)
        model.highlighted = nil

        if newFiles {
            model.count = files.count
            let kind = FileKind.common(files)
            if kind == .folder {
                model.sizeText = files.count == 1 ? "Folder" : "\(files.count) folders"
            } else {
                model.sizeText = byteString(files.map(fileSize).reduce(0, +))
            }
            model.thumbnail = NSWorkspace.shared.icon(forFile: files[0].path)
            let first = files[0]
            Task { @MainActor in
                if let image = await Thumbnails.load(first, side: 120), self.model.files.first == first {
                    self.model.thumbnail = image
                }
            }
        }

        hideToken += 1
        if panel.isVisible && model.shown { return }
        if !panel.isVisible {
            let size = WheelGeometry.panelSize
            let c = WheelGeometry.center
            var origin = NSPoint(x: point.x - c.x, y: point.y - (size.height - c.y))
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
                origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
            }
            panel.setFrameOrigin(origin)
            model.shown = false
            panel.orderFrontRegardless()
        }
        Task { @MainActor in
            // Let SwiftUI draw the collapsed state for one frame so the bloom always plays.
            try? await Task.sleep(nanoseconds: 16_000_000)
            self.model.shown = true
        }
    }

    /// Collapses the petals back into the hub, then removes the panel.
    func hide(animated: Bool = true) {
        guard panel.isVisible else { return }
        hideToken += 1
        let token = hideToken
        model.highlighted = nil
        model.shown = false
        Task { @MainActor in
            if animated { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard token == self.hideToken else { return }
            self.panel.orderOut(nil)
            self.model.files = []
        }
    }

    func perform(index: Int, urls: [URL]) {
        guard model.options.indices.contains(index) else { return }
        let option = model.options[index]
        let files = urls.isEmpty ? model.files : urls
        hide()
        Task { @MainActor in option.action(files) }
    }
}

// MARK: - Drag monitor

/// Polls the mouse, modifier keys and the system drag pasteboard. No Accessibility permission needed.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()

    var paused = false
    private var timer: Timer?
    private var mouseDown = false
    private var baseline = 0
    private var dragFiles: [URL] = []
    private var lastFlags: NSEvent.ModifierFlags = []
    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in DragMonitor.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        defer { lastFlags = flags }

        if down && !mouseDown {
            mouseDown = true
            baseline = dragPasteboard.changeCount
            dragFiles = []
        } else if !down && mouseDown {
            mouseDown = false
            dragFiles = []
            if WheelController.shared.isVisible { scheduleHide() }
            return
        }

        guard down, !paused else { return }

        if dragFiles.isEmpty, dragPasteboard.changeCount != baseline {
            baseline = dragPasteboard.changeCount
            dragFiles = (dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        guard !dragFiles.isEmpty else { return }

        let added = flags.subtracting(lastFlags)
        guard !added.isEmpty else { return }

        let mode: WheelMode
        if added.contains(.control) {
            mode = .actions
        } else if added.contains(.command) {
            mode = .tools
        } else if added.contains(.option) && flags.contains(.shift) {
            mode = .tools
        } else if added.contains(.shift) {
            mode = flags.contains(.option) ? .tools : .convert
        } else {
            return
        }
        WheelController.shared.show(mode: mode, files: dragFiles, at: NSEvent.mouseLocation)
    }

    private func scheduleHide() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if NSEvent.pressedMouseButtons & 1 == 0 { WheelController.shared.hide() }
        }
    }
}
