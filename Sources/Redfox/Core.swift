import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Errors

struct RFError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - File kinds

enum FileKind {
    case image, video, audio, pdf, document, subtitle, archive, folder, other

    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "ogg", "opus", "m4b", "wma"]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "svg", "avif", "ico", "jp2", "psd", "dng", "cr2", "nef", "arw"]
    static let docExts: Set<String> = ["docx", "doc", "rtf", "rtfd", "txt", "md", "markdown", "html", "htm", "odt", "text"]
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, ext != "rtfd" {
            return .folder
        }
        if ext == "pdf" { return .pdf }
        if ext == "srt" || ext == "vtt" { return .subtitle }
        if archiveExts.contains(ext) { return .archive }
        if imageExts.contains(ext) { return .image }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if docExts.contains(ext) { return .document }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .text) { return .document }
        }
        return .other
    }

    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(of))
        if kinds.count == 1, let only = kinds.first { return only }
        return .other
    }
}

// MARK: - Paths and sizes

extension URL {
    var ext: String { pathExtension.lowercased() }
    var baseName: String { deletingPathExtension().lastPathComponent }
}

enum Paths {
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(name) : dir.appendingPathComponent(name + "." + ext)
        }
        var url = make(base)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(index)")
            index += 1
        }
        return url
    }

    static func output(for input: URL, ext: String, suffix: String = "") -> URL {
        unique(in: input.deletingLastPathComponent(), base: input.baseName + suffix, ext: ext)
    }

    static func folder(for input: URL, suffix: String) throws -> URL {
        let url = unique(in: input.deletingLastPathComponent(), base: input.baseName + suffix, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func temp(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }
}

func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
}

func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func durationString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "unknown" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

enum Thumbnails {
    static func load(_ url: URL, side: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .all)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

// MARK: - Shell and ffmpeg

enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let name = URL(fileURLWithPath: executable).lastPathComponent
            process.terminationHandler = { finished in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: RFError(detail.isEmpty ? "\(name) stopped with code \(finished.terminationStatus)." : String(detail.suffix(500))))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum FFmpeg {
    /// Redfox ships its own static ffmpeg inside the app bundle. A system copy is only
    /// used as a fallback, for example when running a development build without one.
    static var path: String? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var available: Bool { path != nil }

    static func convert(_ input: URL, to output: URL, args: [String]) async throws {
        guard let ffmpeg = path else {
            throw RFError("The media engine that ships inside Redfox is missing. Please reinstall Redfox from the latest release.")
        }
        try await Shell.run(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path] + args + [output.path])
    }
}

// MARK: - Conversion dispatcher

enum Converter {
    static func convert(_ url: URL, to target: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        switch FileKind.of(url) {
        case .image:
            return [try await Images.convert(url, to: target)]
        case .video:
            return [try await Media.convertVideo(url, to: target, progress: progress)]
        case .audio:
            return [try await Media.convertAudio(url, to: target, progress: progress)]
        case .pdf:
            return try await PDFTools.convert(url, to: target)
        case .document:
            let text = try await Documents.load(url)
            let out = Paths.output(for: url, ext: target)
            try Documents.write(text, to: out)
            return [out]
        case .subtitle:
            return [try Subtitles.convert(url, to: target)]
        default:
            throw RFError("Redfox can not convert \(url.lastPathComponent) to \(target.uppercased()).")
        }
    }
}

// MARK: - Wheel catalog

enum WheelMode {
    case convert, tools, actions
}

struct WheelOption {
    let title: String
    let symbol: String?
    let action: @MainActor ([URL]) -> Void
}

@MainActor
enum Catalog {
    static func options(_ mode: WheelMode, files: [URL]) -> [WheelOption] {
        guard !files.isEmpty else { return [] }
        let kind = FileKind.common(files)
        var list: [WheelOption]
        switch mode {
        case .convert: list = convertOptions(kind, files)
        case .tools: list = toolOptions(kind, files)
        case .actions: list = actionOptions()
        }
        if mode == .convert {
            let extras = archiveOptions
            if list.count < 10 { list.append(extras[0]) }
            var index = 1
            while list.count < 3 && index < extras.count {
                list.append(extras[index])
                index += 1
            }
        }
        return Array(list.prefix(10))
    }

    private static func convertOptions(_ kind: FileKind, _ files: [URL]) -> [WheelOption] {
        let sources = Set(files.map { $0.ext })
        let targets: [String]
        switch kind {
        case .image: targets = Images.targets(excluding: sources)
        case .video: targets = Media.videoTargets.filter { !sources.contains($0) }
        case .audio: targets = Media.audioTargets.filter { !sources.contains($0) }
        case .pdf: targets = ["docx", "txt", "rtf", "png", "jpg"]
        case .document: targets = Documents.targets.filter { !sources.contains($0) }
        case .subtitle: targets = ["srt", "vtt"].filter { !sources.contains($0) }
        case .archive:
            return [WheelOption(title: "EXTRACT", symbol: "shippingbox") { Jobs.extract($0) }]
        case .folder, .other: targets = []
        }
        return targets.map { target in
            WheelOption(title: target.uppercased(), symbol: nil) { Jobs.convert($0, to: target) }
        }
    }

    private static var archiveOptions: [WheelOption] {
        [("ZIP", "zip"), ("TAR", "tar"), ("TAR.GZ", "tar.gz")].map { pair in
            WheelOption(title: pair.0, symbol: nil) { Jobs.archive($0, format: pair.1) }
        }
    }

    private static func toolOptions(_ kind: FileKind, _ files: [URL]) -> [WheelOption] {
        let multi = files.count > 1
        let metadata = WheelOption(title: "METADATA", symbol: "tag") { Jobs.metadata($0) }
        let compress = WheelOption(title: "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left") { Jobs.compress($0) }

        switch kind {
        case .image:
            var list = [
                compress,
                metadata,
                WheelOption(title: "EDIT", symbol: "slider.horizontal.3") { Jobs.edit($0, mode: .adjust) },
                WheelOption(title: "ANNOTATE", symbol: "pencil.tip.crop.circle") { Jobs.edit($0, mode: .annotate) },
                WheelOption(title: "ADD BG", symbol: "photo") { Jobs.addBackground($0) },
                WheelOption(title: "CROP", symbol: "crop") { Jobs.edit($0, mode: .crop) },
                WheelOption(title: "REDACT", symbol: "eye.slash") { Jobs.edit($0, mode: .redact) },
            ]
            if #available(macOS 14.0, *) {
                list.append(WheelOption(title: "REMOVE BG", symbol: "person.crop.rectangle") { Jobs.removeBackground($0) })
            }
            if multi {
                list.append(WheelOption(title: "MAKE PDF", symbol: "doc.richtext") { Jobs.imagesToPDF($0) })
                list.append(WheelOption(title: "COLLAGE", symbol: "square.grid.2x2") { Jobs.collage($0) })
            } else {
                list.append(WheelOption(title: "READ QR", symbol: "qrcode.viewfinder") { Jobs.readCode($0) })
            }
            return list

        case .video:
            var list = [
                compress,
                WheelOption(title: "TRIM", symbol: "scissors") { Jobs.media($0, .trim) },
                WheelOption(title: "SPLIT", symbol: "square.split.2x1") { Jobs.media($0, .split) },
                WheelOption(title: "SNAPSHOT", symbol: "camera") { Jobs.media($0, .snapshot) },
                WheelOption(title: "2× SPEED", symbol: "hare") { Jobs.speed($0, 2) },
                WheelOption(title: "½ SPEED", symbol: "tortoise") { Jobs.speed($0, 0.5) },
                WheelOption(title: "MUTE", symbol: "speaker.slash") { Jobs.mute($0) },
                WheelOption(title: "ROTATE", symbol: "rotate.right") { Jobs.rotateVideo($0) },
                metadata,
            ]
            if multi {
                list.insert(WheelOption(title: "JOIN", symbol: "plus.rectangle.on.rectangle") { Jobs.join($0) }, at: 1)
            }
            return list

        case .audio:
            var list = [
                compress,
                WheelOption(title: "TRIM", symbol: "scissors") { Jobs.media($0, .trim) },
                WheelOption(title: "NORMALIZE", symbol: "waveform") { Jobs.normalize($0) },
                WheelOption(title: "CHANNELS", symbol: "speaker.wave.2") { Jobs.channels($0) },
                WheelOption(title: "2× SPEED", symbol: "hare") { Jobs.speed($0, 2) },
                WheelOption(title: "½ SPEED", symbol: "tortoise") { Jobs.speed($0, 0.5) },
                metadata,
            ]
            if multi {
                list.insert(WheelOption(title: "JOIN", symbol: "plus.rectangle.on.rectangle") { Jobs.join($0) }, at: 1)
            }
            return list

        case .pdf:
            var list = [
                compress,
                WheelOption(title: "ORGANIZE", symbol: "list.number") { Jobs.organizePDF($0) },
                WheelOption(title: "SPLIT", symbol: "square.split.1x2") { Jobs.splitPDF($0) },
                WheelOption(title: "ROTATE", symbol: "rotate.right") { Jobs.rotatePDF($0) },
                metadata,
            ]
            if multi {
                list.insert(WheelOption(title: "MERGE", symbol: "doc.on.doc") { Jobs.mergePDF($0) }, at: 1)
            }
            return list

        default:
            return [
                metadata,
                WheelOption(title: "ZIP", symbol: "doc.zipper") { Jobs.archive($0, format: "zip") },
                WheelOption(title: "COPY PATH", symbol: "doc.text") { FileActions.copyPath($0) },
            ]
        }
    }

    private static func actionOptions() -> [WheelOption] {
        [
            WheelOption(title: "AIRDROP", symbol: "antenna.radiowaves.left.and.right") { FileActions.airDrop($0) },
            WheelOption(title: "FLOAT", symbol: "pin.fill") { FloatShelf.show($0) },
            WheelOption(title: "COPY", symbol: "doc.on.doc") { FileActions.copy($0) },
            WheelOption(title: "MOVE", symbol: "folder") { FileActions.move($0) },
            WheelOption(title: "COPY PATH", symbol: "doc.text") { FileActions.copyPath($0) },
            WheelOption(title: "TERMINAL", symbol: "terminal") { FileActions.terminal($0) },
        ]
    }
}

// MARK: - Jobs (what each wheel segment does)

@MainActor
enum Jobs {
    static func convert(_ urls: [URL], to target: String) {
        JobRunner.each("Converting to \(target.uppercased())", urls) { url, progress in
            try await Converter.convert(url, to: target, progress: progress)
        }
    }

    static func archive(_ urls: [URL], format: String) {
        JobRunner.batch("Creating \(format.uppercased())") { _ in
            [try await Archives.create(urls, format: format)]
        }
    }

    static func extract(_ urls: [URL]) {
        JobRunner.each("Extracting", urls) { url, _ in [try await Archives.extract(url)] }
    }

    static func compress(_ urls: [URL]) { CompressWindow.show(urls) }

    static func runCompress(_ urls: [URL], kind: FileKind, fraction: Double) {
        JobRunner.each("Compressing", urls) { url, progress in
            switch kind {
            case .image: return [try Images.compress(url, fraction: fraction)]
            case .video: return [try await Media.compressVideo(url, fraction: fraction, progress: progress)]
            case .audio: return [try await Media.compressAudio(url, fraction: fraction, progress: progress)]
            case .pdf: return [try PDFTools.compress(url)]
            default: throw RFError("This file type can not be compressed.")
            }
        }
    }

    static func metadata(_ urls: [URL]) {
        for url in urls.prefix(3) { MetadataViewer.show(url) }
    }

    static func stripMetadata(_ urls: [URL]) {
        JobRunner.each("Removing metadata", urls) { url, _ in [try await Metadata.strip(url)] }
    }

    static func edit(_ urls: [URL], mode: EditorMode) {
        guard let first = urls.first else { return }
        ImageEditor.show(first, mode: mode)
    }

    static func addBackground(_ urls: [URL]) {
        guard let first = urls.first else { return }
        BackgroundEditor.show(first)
    }

    static func removeBackground(_ urls: [URL]) {
        if #available(macOS 14.0, *) {
            JobRunner.each("Removing background", urls) { url, _ in [try Images.removeBackground(url)] }
        }
    }

    static func imagesToPDF(_ urls: [URL]) {
        JobRunner.batch("Building PDF") { _ in
            let out = Paths.unique(in: urls[0].deletingLastPathComponent(), base: "Images", ext: "pdf")
            try Images.makePDF(urls, to: out)
            return [out]
        }
    }

    static func collage(_ urls: [URL]) {
        JobRunner.batch("Making collage") { _ in [try Images.collage(urls)] }
    }

    static func readCode(_ urls: [URL]) {
        guard let first = urls.first else { return }
        Task { @MainActor in
            do {
                let codes = try await Task.detached { try Images.readCodes(first) }.value
                guard let code = codes.first else {
                    Alerts.message("No code found", "Redfox could not find a QR code or barcode in this image.")
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = codes.count > 1 ? "Found \(codes.count) codes" : "Code found"
                alert.informativeText = codes.joined(separator: "\n\n")
                alert.addButton(withTitle: "Copy")
                let link = URL(string: code)
                let isLink = link?.scheme?.hasPrefix("http") == true
                if isLink { alert.addButton(withTitle: "Open Link") }
                alert.addButton(withTitle: "Close")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(codes.joined(separator: "\n"), forType: .string)
                } else if response == .alertSecondButtonReturn, isLink, let link {
                    NSWorkspace.shared.open(link)
                }
            } catch {
                Alerts.show(error)
            }
        }
    }

    static func media(_ urls: [URL], _ kind: MediaEditor.Kind) {
        guard let first = urls.first else { return }
        MediaEditor.show(first, kind: kind)
    }

    static func speed(_ urls: [URL], _ factor: Double) {
        JobRunner.each(factor > 1 ? "Speeding up" : "Slowing down", urls) { url, _ in
            [try await Media.changeSpeed(url, factor: factor)]
        }
    }

    static func mute(_ urls: [URL]) {
        JobRunner.each("Removing audio", urls) { url, _ in [try await Media.mute(url)] }
    }

    static func rotateVideo(_ urls: [URL]) {
        JobRunner.each("Rotating", urls) { url, _ in [try await Media.rotate(url)] }
    }

    static func join(_ urls: [URL]) {
        JobRunner.batch("Joining \(urls.count) files") { _ in [try await Media.join(urls)] }
    }

    static func normalize(_ urls: [URL]) {
        JobRunner.each("Normalizing", urls) { url, _ in [try Media.normalize(url)] }
    }

    static func channels(_ urls: [URL]) {
        JobRunner.each("Changing channels", urls) { url, _ in [try Media.toggleChannels(url)] }
    }

    static func organizePDF(_ urls: [URL]) {
        guard let first = urls.first else { return }
        PDFOrganizer.show(first)
    }

    static func splitPDF(_ urls: [URL]) {
        JobRunner.each("Splitting PDF", urls) { url, _ in try PDFTools.split(url) }
    }

    static func rotatePDF(_ urls: [URL]) {
        JobRunner.each("Rotating PDF", urls) { url, _ in [try PDFTools.rotate(url)] }
    }

    static func mergePDF(_ urls: [URL]) {
        JobRunner.batch("Merging \(urls.count) PDFs") { _ in [try PDFTools.merge(urls)] }
    }
}
