import AppKit
import SwiftUI
import AVKit
import PDFKit

func fitRect(_ size: CGSize, in bounds: CGSize, inset: CGFloat) -> CGRect {
    let bw = max(bounds.width - inset * 2, 1), bh = max(bounds.height - inset * 2, 1)
    let scale = min(bw / max(size.width, 1), bh / max(size.height, 1))
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
}

// MARK: - Image editor (crop, redact, annotate, adjust)

enum EditorMode: Hashable {
    case crop, redact, annotate, adjust
}

struct Stroke {
    var points: [CGPoint]   // normalized 0...1, top-left origin
    var color: NSColor
    var width: CGFloat      // fraction of image width
}

final class ImageEditorModel: ObservableObject {
    let url: URL
    let original: CGImage
    let previewBase: CGImage

    @Published var mode: EditorMode
    @Published var crop: CGRect? = nil
    @Published var redactions: [CGRect] = []
    @Published var draftRect: CGRect? = nil
    @Published var strokes: [Stroke] = []
    @Published var live: Stroke? = nil
    @Published var penColor: Color = .red
    @Published var penSize: Double = 6
    @Published var brightness = 0.0 { didSet { refresh() } }
    @Published var contrast = 1.0 { didSet { refresh() } }
    @Published var saturation = 1.0 { didSet { refresh() } }
    @Published var exposure = 0.0 { didSet { refresh() } }
    @Published var preview: NSImage

    init(url: URL, mode: EditorMode) throws {
        let original = try Images.load(url)
        let base = (try? Images.resized(original, maxSide: 1400)) ?? original
        self.url = url
        self.original = original
        self.previewBase = base
        self.mode = mode
        self.preview = NSImage(cgImage: base, size: NSSize(width: base.width, height: base.height))
    }

    var aspect: CGSize { CGSize(width: original.width, height: original.height) }
    var isAdjusted: Bool { brightness != 0 || contrast != 1 || saturation != 1 || exposure != 0 }

    func refresh() {
        let image = isAdjusted
            ? Images.adjusted(previewBase, brightness: brightness, contrast: contrast, saturation: saturation, exposure: exposure)
            : previewBase
        preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func undo() {
        switch mode {
        case .annotate: if !strokes.isEmpty { strokes.removeLast() }
        case .redact: if !redactions.isEmpty { redactions.removeLast() }
        case .crop: crop = nil
        case .adjust:
            brightness = 0
            contrast = 1
            saturation = 1
            exposure = 0
        }
    }

    func render() throws -> CGImage {
        let base = isAdjusted
            ? Images.adjusted(original, brightness: brightness, contrast: contrast, saturation: saturation, exposure: exposure)
            : original
        let w = CGFloat(base.width), h = CGFloat(base.height)
        let redactions = self.redactions
        let strokes = self.strokes
        var image = try Images.bitmap(width: base.width, height: base.height) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for r in redactions {
                ctx.fill(CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h))
            }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes where !stroke.points.isEmpty {
                ctx.setStrokeColor(stroke.color.cgColor)
                ctx.setLineWidth(stroke.width * w)
                ctx.beginPath()
                let first = CGPoint(x: stroke.points[0].x * w, y: stroke.points[0].y * h)
                ctx.move(to: first)
                for p in stroke.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * w, y: p.y * h)) }
                if stroke.points.count == 1 { ctx.addLine(to: first) }
                ctx.strokePath()
            }
        }
        if let c = crop, c.width > 0.01, c.height > 0.01 {
            let rect = CGRect(x: c.minX * w, y: c.minY * h, width: c.width * w, height: c.height * h).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }
        return image
    }

    func save() throws -> URL {
        let image = try render()
        var ext = url.ext == "jpeg" ? "jpg" : url.ext
        if !Images.canWriteNatively(ext) { ext = "png" }
        let out = Paths.output(for: url, ext: ext, suffix: " edited")
        try Images.encode(image, ext: ext, quality: 0.93).write(to: out)
        return out
    }
}

struct ImageEditorView: View {
    @ObservedObject var m: ImageEditorModel
    let box: WindowBox
    @StateObject private var error = ViewState<String?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.background)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $m.mode) {
                Text("Crop").tag(EditorMode.crop)
                Text("Redact").tag(EditorMode.redact)
                Text("Annotate").tag(EditorMode.annotate)
                Text("Adjust").tag(EditorMode.adjust)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            Spacer()
            if m.mode == .annotate {
                ColorPicker("Pen", selection: $m.penColor, supportsOpacity: false)
                Slider(value: $m.penSize, in: 2...30) { Text("Size") }
                    .frame(width: 140)
            }
            Button { m.undo() } label: { Label(m.mode == .adjust ? "Reset" : "Undo", systemImage: "arrow.uturn.backward") }
        }
        .padding(12)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fit = fitRect(m.aspect, in: geo.size, inset: 20)
            ZStack(alignment: .topLeading) {
                Image(nsImage: m.preview)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                Canvas { context, _ in
                    drawOverlay(context, fit)
                }
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(drag(fit), including: m.mode == .adjust ? .none : .all)
        }
        .overlay(alignment: .bottom) {
            if m.mode == .adjust { adjustPanel }
        }
    }

    private var adjustPanel: some View {
        VStack(spacing: 8) {
            slider("Brightness", $m.brightness, -0.5...0.5)
            slider("Contrast", $m.contrast, 0.5...1.5)
            slider("Saturation", $m.saturation, 0...2)
            slider("Exposure", $m.exposure, -2...2)
        }
        .padding(16)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .padding(.bottom, 16)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if let message = error.value { Text(message).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2) }
            Button("Cancel") { box.close() }
            Button("Save Copy") {
                do {
                    let out = try m.save()
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                    box.close()
                } catch {
                    self.error.value = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var hint: String {
        switch m.mode {
        case .crop: return "Drag across the image to choose the area to keep."
        case .redact: return "Drag over anything private to cover it with a solid box."
        case .annotate: return "Draw freely on the image with the pen."
        case .adjust: return "Move the sliders to tune the look of the photo."
        }
    }

    private func drawOverlay(_ context: GraphicsContext, _ fit: CGRect) {
        func vp(_ p: CGPoint) -> CGPoint { CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height) }
        func vr(_ r: CGRect) -> CGRect {
            CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height, width: r.width * fit.width, height: r.height * fit.height)
        }
        for r in m.redactions { context.fill(Path(vr(r)), with: .color(.black)) }
        if let draft = m.draftRect { context.fill(Path(vr(draft)), with: .color(.black.opacity(0.75))) }

        var all = m.strokes
        if let live = m.live { all.append(live) }
        for stroke in all where !stroke.points.isEmpty {
            var path = Path()
            path.move(to: vp(stroke.points[0]))
            for p in stroke.points.dropFirst() { path.addLine(to: vp(p)) }
            if stroke.points.count == 1 { path.addLine(to: vp(stroke.points[0])) }
            context.stroke(path, with: .color(Color(nsColor: stroke.color)),
                           style: StrokeStyle(lineWidth: stroke.width * fit.width, lineCap: .round, lineJoin: .round))
        }

        if let c = m.crop {
            let rect = vr(c)
            var dim = Path(fit)
            dim.addRect(rect)
            context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
            var thirds = Path()
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: rect.minY))
                thirds.addLine(to: CGPoint(x: x, y: rect.maxY))
                thirds.move(to: CGPoint(x: rect.minX, y: y))
                thirds.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
    }

    private func normalized(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - fit.minX) / fit.width, 0), 1), y: min(max((p.y - fit.minY) / fit.height, 0), 1))
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func drag(_ fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = normalized(value.startLocation, fit)
                let b = normalized(value.location, fit)
                switch m.mode {
                case .crop:
                    m.crop = rect(a, b)
                case .redact:
                    m.draftRect = rect(a, b)
                case .annotate:
                    if m.live == nil {
                        m.live = Stroke(points: [a], color: NSColor(m.penColor), width: CGFloat(m.penSize) / max(fit.width, 1))
                    } else {
                        m.live?.points.append(b)
                    }
                case .adjust:
                    break
                }
            }
            .onEnded { _ in
                switch m.mode {
                case .redact:
                    if let d = m.draftRect, d.width > 0.003, d.height > 0.003 { m.redactions.append(d) }
                    m.draftRect = nil
                case .annotate:
                    if let s = m.live { m.strokes.append(s) }
                    m.live = nil
                case .crop:
                    if let c = m.crop, c.width < 0.01 || c.height < 0.01 { m.crop = nil }
                case .adjust:
                    break
                }
            }
    }
}

@MainActor
enum ImageEditor {
    static func show(_ url: URL, mode: EditorMode) {
        do {
            let model = try ImageEditorModel(url: url, mode: mode)
            Windows.present(title: "Redfox Editor  \(url.lastPathComponent)", size: CGSize(width: 1000, height: 740)) { box in
                ImageEditorView(m: model, box: box)
            }
        } catch {
            Alerts.show(error)
        }
    }
}

// MARK: - Add background

final class BackgroundModel: ObservableObject {
    let url: URL
    let original: CGImage
    let small: CGImage
    @Published var color: Color = .white { didSet { refresh() } }
    @Published var padding: Double = 0.08 { didSet { refresh() } }
    @Published var preview: NSImage

    init(url: URL) throws {
        let original = try Images.load(url)
        let small = (try? Images.resized(original, maxSide: 900)) ?? original
        self.url = url
        self.original = original
        self.small = small
        self.preview = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        refresh()
    }

    var cgColor: CGColor { NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? Images.white }

    func refresh() {
        if let image = try? Images.withBackground(small, color: cgColor, padding: padding) {
            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    func save() throws -> URL {
        let image = try Images.withBackground(original, color: cgColor, padding: padding)
        let ext = ["jpg", "jpeg", "heic"].contains(url.ext) ? "jpg" : "png"
        let out = Paths.output(for: url, ext: ext, suffix: " background")
        try Images.encode(image, ext: ext, quality: 0.93).write(to: out)
        return out
    }
}

struct BackgroundView: View {
    @ObservedObject var m: BackgroundModel
    let box: WindowBox
    @StateObject private var error = ViewState<String?>(nil)
    private let presets: [Color] = [.white, .black, Color(white: 0.93), Theme.accent, Color(red: 0.13, green: 0.36, blue: 0.85), Color(red: 0.98, green: 0.88, blue: 0.62)]

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let size = CGSize(width: m.preview.size.width, height: m.preview.size.height)
                let fit = fitRect(size, in: geo.size, inset: 24)
                Image(nsImage: m.preview)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .shadow(color: .black.opacity(0.4), radius: 12)
                    .position(x: fit.midX, y: fit.midY)
            }
            .background(Color.black.opacity(0.35))

            VStack(alignment: .leading, spacing: 16) {
                Text("Background").font(.headline)
                HStack(spacing: 8) {
                    ForEach(0..<presets.count, id: \.self) { i in
                        Button { m.color = presets[i] } label: {
                            Circle().fill(presets[i]).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("Custom color", selection: $m.color, supportsOpacity: false)
                Text("Padding").font(.headline)
                Slider(value: $m.padding, in: 0...0.4)
                Text("Transparent areas are filled with the color, and the padding adds a border around the image.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let message = error.value { Text(message).foregroundStyle(.red).font(.system(size: 12)) }
                HStack {
                    Button("Cancel") { box.close() }
                    Spacer()
                    Button("Save Copy") {
                        do {
                            let out = try m.save()
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                            box.close()
                        } catch {
                            self.error.value = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 280)
        }
        .frame(minWidth: 780, minHeight: 500)
        .background(Theme.background)
    }
}

@MainActor
enum BackgroundEditor {
    static func show(_ url: URL) {
        do {
            let model = try BackgroundModel(url: url)
            Windows.present(title: "Add Background  \(url.lastPathComponent)", size: CGSize(width: 860, height: 560)) { box in
                BackgroundView(m: model, box: box)
            }
        } catch {
            Alerts.show(error)
        }
    }
}

// MARK: - Compress

struct CompressView: View {
    let urls: [URL]
    let kind: FileKind
    let box: WindowBox
    @StateObject private var percent = ViewState(50.0)

    private var total: Int64 { urls.map(fileSize).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(urls.count == 1 ? "Compress \(urls[0].lastPathComponent)" : "Compress \(urls.count) files")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if kind == .pdf {
                Text("Redfox will recompress the images inside the PDF and optimize it for reading on screen. Text stays selectable.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("Target size")
                    Spacer()
                    Text("\(Int(percent.value))% of original, about \(byteString(Int64(Double(total) * percent.value / 100)))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $percent.value, in: 10...90, step: 5)
                    .tint(Theme.accent)
            }
            HStack {
                Spacer()
                Button("Cancel") { box.close() }
                Button("Compress") {
                    let fraction = percent.value / 100
                    box.close()
                    Jobs.runCompress(urls, kind: kind, fraction: fraction)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

@MainActor
enum CompressWindow {
    static func show(_ urls: [URL]) {
        let kind = FileKind.common(urls)
        guard [.image, .video, .audio, .pdf].contains(kind) else {
            Alerts.message("Compress", "Drag images, videos, audio files or PDFs of a single kind to compress them together.")
            return
        }
        Windows.present(title: "Compress", size: CGSize(width: 460, height: 190), resizable: false) { box in
            CompressView(urls: urls, kind: kind, box: box)
        }
    }
}

// MARK: - Trim, split and snapshot

struct PlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let trim: Bool
    let onTrim: @MainActor (CMTimeRange?) -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        if trim { beginTrimming(view, attempt: 0) }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    private func beginTrimming(_ view: AVPlayerView, attempt: Int) {
        let player = self.player
        let onTrim = self.onTrim
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if view.canBeginTrimming {
                let result = await view.beginTrimming()
                guard result == .okButton, let item = player.currentItem else {
                    onTrim(nil)
                    return
                }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                onTrim(CMTimeRange(start: start, end: end))
            } else if attempt < 20 {
                beginTrimming(view, attempt: attempt + 1)
            } else {
                onTrim(nil)
            }
        }
    }
}

struct MediaToolView: View {
    let url: URL
    let kind: MediaEditor.Kind
    let player: AVPlayer
    let box: WindowBox

    var body: some View {
        VStack(spacing: 0) {
            PlayerRepresentable(player: player, trim: kind == .trim) { range in
                box.close()
                guard let range else { return }
                let source = url
                JobRunner.batch("Trimming") { _ in [try await Media.exportRange(source, range: range, suffix: " trimmed")] }
            }
            if kind != .trim {
                HStack(spacing: 12) {
                    Text(kind == .split ? "Move the playhead to where the file should be split." : "Move the playhead to the frame you want to save.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { box.close() }
                    Button(kind == .split ? "Split Here" : "Save Frame") { act() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onDisappear { player.pause() }
    }

    private func act() {
        let time = player.currentTime()
        let source = url
        player.pause()
        box.close()
        if kind == .split {
            JobRunner.batch("Splitting") { _ in try await Media.split(source, at: time) }
        } else {
            JobRunner.batch("Saving frame") { _ in [try await Media.snapshot(source, at: time)] }
        }
    }
}

@MainActor
enum MediaEditor {
    enum Kind { case trim, split, snapshot }

    static func show(_ url: URL, kind: Kind) {
        guard Media.isNative(url) else {
            Alerts.message("Redfox", "This tool works with MP4, MOV, M4V and common audio files. Convert the file to MP4 first and try again.")
            return
        }
        let titles: [Kind: String] = [.trim: "Trim", .split: "Split", .snapshot: "Snapshot"]
        let player = AVPlayer(url: url)
        Windows.present(title: "\(titles[kind] ?? "Media")  \(url.lastPathComponent)", size: CGSize(width: 900, height: 600)) { box in
            MediaToolView(url: url, kind: kind, player: player, box: box)
        }
    }
}

// MARK: - Metadata viewer

struct MetadataView: View {
    let url: URL
    let rows: [(String, String)]
    let box: WindowBox

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Text(rows[i].0)
                            .foregroundStyle(.secondary)
                            .frame(width: 220, alignment: .leading)
                        Text(rows[i].1)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12))
                }
            }
            Divider()
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n"), forType: .string)
                    Toast.show("Metadata copied")
                }
                Spacer()
                if Metadata.canStrip(url) {
                    Button("Save Copy Without Metadata") {
                        box.close()
                        Jobs.stripMetadata([url])
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                Button("Done") { box.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

@MainActor
enum MetadataViewer {
    static func show(_ url: URL) {
        Task { @MainActor in
            let rows = await Metadata.rows(for: url)
            Windows.present(title: "Metadata  \(url.lastPathComponent)", size: CGSize(width: 640, height: 580)) { box in
                MetadataView(url: url, rows: rows, box: box)
            }
        }
    }
}

// MARK: - PDF organizer

final class OrganizerModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let page: PDFPage
        let thumb: NSImage
        let base: Int
        var rotation: Int
    }

    let url: URL
    @Published var items: [Item]

    init(url: URL) throws {
        let doc = try PDFTools.open(url)
        self.url = url
        self.items = (0..<doc.pageCount).compactMap { i -> Item? in
            guard let page = doc.page(at: i) else { return nil }
            return Item(page: page, thumb: page.thumbnail(of: NSSize(width: 120, height: 160), for: .mediaBox), base: page.rotation, rotation: page.rotation)
        }
    }

    func rotate(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rotation = (items[i].rotation + 90) % 360
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func save() throws -> URL {
        guard !items.isEmpty else { throw RFError("Keep at least one page before saving.") }
        let doc = PDFDocument()
        for item in items {
            if let page = item.page.copy() as? PDFPage {
                page.rotation = item.rotation
                doc.insert(page, at: doc.pageCount)
            }
        }
        let out = Paths.output(for: url, ext: "pdf", suffix: " organized")
        try PDFTools.save(doc, to: out)
        return out
    }
}

struct OrganizerView: View {
    @ObservedObject var m: OrganizerModel
    let box: WindowBox
    @StateObject private var error = ViewState<String?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            Text("Drag rows to reorder pages. Use the buttons to rotate or delete a page.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(10)
            List {
                ForEach(Array(m.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 14) {
                        Image(nsImage: item.thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 78)
                            .rotationEffect(.degrees(Double(item.rotation - item.base)))
                        Text("Page \(index + 1)")
                        Spacer()
                        Button { m.rotate(item.id) } label: { Image(systemName: "rotate.right") }
                            .buttonStyle(.borderless)
                        Button { m.remove(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in m.items.move(fromOffsets: from, toOffset: to) }
            }
            Divider()
            HStack {
                if let message = error.value { Text(message).foregroundStyle(.red).font(.system(size: 12)) }
                Spacer()
                Button("Cancel") { box.close() }
                Button("Save Copy") {
                    do {
                        let out = try m.save()
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                        box.close()
                    } catch {
                        self.error.value = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}

@MainActor
enum PDFOrganizer {
    static func show(_ url: URL) {
        do {
            let model = try OrganizerModel(url: url)
            Windows.present(title: "Organize  \(url.lastPathComponent)", size: CGSize(width: 520, height: 680)) { box in
                OrganizerView(m: model, box: box)
            }
        } catch {
            Alerts.show(error)
        }
    }
}
