import AppKit
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - PDF

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw RFError("Could not open \(url.lastPathComponent).") }
        if doc.isLocked { throw RFError("\(url.lastPathComponent) is password protected.") }
        return doc
    }

    static func save(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url) else { throw RFError("Could not save \(url.lastPathComponent).") }
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let sideways = page.rotation % 180 != 0
        let size = NSSize(width: (sideways ? bounds.height : bounds.width) * scale,
                          height: (sideways ? bounds.width : bounds.height) * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw RFError("Could not render a PDF page.")
        }
        return cg
    }

    static func attributed(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.attributedString {
                result.append(text)
                result.append(NSAttributedString(string: "\n\n"))
            }
        }
        return result
    }

    static func convert(_ url: URL, to target: String) async throws -> [URL] {
        switch target {
        case "png", "jpg":
            let doc = try open(url)
            if doc.pageCount == 1, let page = doc.page(at: 0) {
                let out = Paths.output(for: url, ext: target)
                try Images.encode(try render(page), ext: target, quality: 0.9).write(to: out)
                return [out]
            }
            let folder = try Paths.folder(for: url, suffix: " images")
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let out = folder.appendingPathComponent("\(url.baseName) page \(i + 1).\(target)")
                try Images.encode(try render(page), ext: target, quality: 0.9).write(to: out)
            }
            return [folder]
        default:
            let text = try attributed(url)
            let out = Paths.output(for: url, ext: target)
            try Documents.write(text, to: out)
            return [out]
        }
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let output = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage {
                    output.insert(page, at: output.pageCount)
                }
            }
        }
        let out = Paths.unique(in: urls[0].deletingLastPathComponent(), base: "Merged", ext: "pdf")
        try save(output, to: out)
        return out
    }

    static func split(_ url: URL) throws -> [URL] {
        let doc = try open(url)
        let folder = try Paths.folder(for: url, suffix: " pages")
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            try save(single, to: folder.appendingPathComponent("\(url.baseName) page \(i + 1).pdf"))
        }
        return [folder]
    }

    static func rotate(_ url: URL) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
        let out = Paths.output(for: url, ext: "pdf", suffix: " rotated")
        try save(doc, to: out)
        return out
    }

    static func compress(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = Paths.output(for: url, ext: "pdf", suffix: " compressed")
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard doc.write(to: out, withOptions: options) else { throw RFError("Could not save the compressed PDF.") }
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let out = Paths.output(for: url, ext: "pdf", suffix: " clean")
        try save(doc, to: out)
        return out
    }

    static func metadata(_ url: URL) -> [(String, String)] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var rows: [(String, String)] = [
            ("PDF › Pages", "\(doc.pageCount)"),
            ("PDF › Version", "\(doc.majorVersion).\(doc.minorVersion)"),
            ("PDF › Encrypted", doc.isEncrypted ? "Yes" : "No"),
        ]
        for (key, value) in doc.documentAttributes ?? [:] {
            rows.append(("PDF › \(key)", "\(value)"))
        }
        return rows
    }
}

// MARK: - Documents

enum Documents {
    static let targets = ["pdf", "docx", "txt", "rtf", "html"]

    static func load(_ url: URL) async throws -> NSAttributedString {
        switch url.ext {
        case "pdf":
            return try PDFTools.attributed(url)
        case "md", "markdown":
            let source = try String(contentsOf: url, encoding: .utf8)
            if let parsed = try? NSAttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return parsed
            }
            return NSAttributedString(string: source)
        case "html", "htm":
            return try await loadHTML(url)
        default:
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
    }

    /// The HTML importer uses WebKit, which must run on the main thread.
    @MainActor
    private static func loadHTML(_ url: URL) throws -> NSAttributedString {
        try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
    }

    static func write(_ text: NSAttributedString, to out: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        switch out.ext {
        case "txt":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case "rtf":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: out)
        case "docx":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: out)
        case "html":
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]).write(to: out)
        case "pdf":
            try renderPDF(text, to: out)
        default:
            throw RFError("Redfox can not write .\(out.ext) documents.")
        }
    }

    /// Lays text out on US Letter pages with the AppKit text system and draws each page into a PDF.
    static func renderPDF(_ text: NSAttributedString, to out: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw RFError("Could not create the PDF file.") }

        let storage = NSTextStorage(attributedString: text)
        var missingFont: [NSRange] = []
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value == nil { missingFont.append(range) }
        }
        for range in missingFont { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }

        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: box.width - margin * 2, height: box.height - margin * 2)
        var containers: [NSTextContainer] = []
        while containers.count < 3000 {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            if range.length == 0 && containers.count > 1 { break }
        }

        for container in containers {
            let range = layout.glyphRange(for: container)
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

// MARK: - Subtitles

enum Subtitles {
    static func convert(_ url: URL, to ext: String) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let out = Paths.output(for: url, ext: ext)
        try (ext == "vtt" ? toVTT(text) : toSRT(text)).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func toVTT(_ srt: String) -> String {
        var lines = ["WEBVTT", ""]
        for line in srt.components(separatedBy: "\n") {
            lines.append(line.contains("-->") ? line.replacingOccurrences(of: ",", with: ".") : line)
        }
        return lines.joined(separator: "\n")
    }

    static func toSRT(_ vtt: String) -> String {
        var cues: [String] = []
        var number = 1
        for block in vtt.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let start = fixTime(parts[0])
            let end = fixTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            let body = lines[(timing + 1)...].joined(separator: "\n")
            cues.append("\(number)\n\(start) --> \(end)\n\(body)")
            number += 1
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    private static func fixTime(_ time: String) -> String {
        var value = time.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
        if value.components(separatedBy: ":").count == 2 { value = "00:" + value }
        return value
    }
}

// MARK: - Archives

enum Archives {
    static func create(_ urls: [URL], format: String) async throws -> URL {
        let dir = urls[0].deletingLastPathComponent()
        let base = urls.count == 1 ? urls[0].baseName : "Archive"
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().path == dir.path }
        switch format {
        case "zip":
            let out = Paths.unique(in: dir, base: base, ext: "zip")
            if urls.count == 1 {
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            } else if sameParent {
                try await Shell.run("/usr/bin/zip", ["-r", "-q", out.path] + urls.map { $0.lastPathComponent }, cwd: dir)
            } else {
                try await Shell.run("/usr/bin/zip", ["-r", "-q", "-j", out.path] + urls.map { $0.path })
            }
            return out
        default:
            let gzip = format != "tar"
            let out = Paths.unique(in: dir, base: base, ext: gzip ? "tar.gz" : "tar")
            let flag = gzip ? "-czf" : "-cf"
            if sameParent {
                try await Shell.run("/usr/bin/tar", [flag, out.path, "-C", dir.path] + urls.map { $0.lastPathComponent })
            } else {
                try await Shell.run("/usr/bin/tar", [flag, out.path] + urls.map { $0.path })
            }
            return out
        }
    }

    static func extract(_ url: URL) async throws -> URL {
        var base = url.baseName
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let dest = Paths.unique(in: url.deletingLastPathComponent(), base: base, ext: "")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        if url.ext == "zip" {
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path])
        } else {
            try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path])
        }
        return dest
    }
}

// MARK: - Metadata

enum Metadata {
    static func canStrip(_ url: URL) -> Bool {
        switch FileKind.of(url) {
        case .image, .pdf: return true
        case .video, .audio: return ["mp4", "mov", "m4v", "m4a"].contains(url.ext) || FFmpeg.available
        default: return false
        }
    }

    static func strip(_ url: URL) async throws -> URL {
        switch FileKind.of(url) {
        case .image: return try Images.stripMetadata(url)
        case .pdf: return try PDFTools.stripMetadata(url)
        case .video, .audio: return try await Media.stripMetadata(url)
        default: throw RFError("Redfox can not remove metadata from this kind of file.")
        }
    }

    static func rows(for url: URL) async -> [(String, String)] {
        var rows: [(String, String)] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attributes[.size] as? NSNumber { rows.append(("File › Size", byteString(size.int64Value))) }
            if let created = attributes[.creationDate] as? Date { rows.append(("File › Created", formatter.string(from: created))) }
            if let modified = attributes[.modificationDate] as? Date { rows.append(("File › Modified", formatter.string(from: modified))) }
        }
        rows.append(("File › Kind", UTType(filenameExtension: url.ext)?.localizedDescription ?? url.ext.uppercased()))
        rows.append(("File › Location", url.deletingLastPathComponent().path))

        switch FileKind.of(url) {
        case .image: rows += Images.metadata(url)
        case .pdf: rows += PDFTools.metadata(url)
        case .video, .audio: rows += await mediaRows(url)
        default: break
        }
        return rows
    }

    private static func mediaRows(_ url: URL) async -> [(String, String)] {
        let asset = AVURLAsset(url: url)
        var rows: [(String, String)] = []
        if let duration = try? await asset.load(.duration) {
            rows.append(("Media › Duration", durationString(duration.seconds)))
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let video = tracks.first {
            if let size = try? await video.load(.naturalSize) {
                rows.append(("Video › Dimensions", "\(Int(abs(size.width))) × \(Int(abs(size.height)))"))
            }
            if let fps = try? await video.load(.nominalFrameRate) {
                rows.append(("Video › Frame rate", String(format: "%.2f fps", fps)))
            }
            if let rate = try? await video.load(.estimatedDataRate) {
                rows.append(("Video › Bitrate", "\(Int(rate / 1000)) kbps"))
            }
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .audio), let audio = tracks.first {
            if let rate = try? await audio.load(.estimatedDataRate) {
                rows.append(("Audio › Bitrate", "\(Int(rate / 1000)) kbps"))
            }
        }
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "Item"
                let loaded = try? await item.load(.stringValue)
                let value = loaded.flatMap { $0 } ?? "(binary data)"
                rows.append(("Tags › \(key)", value))
            }
        }
        return rows
    }
}
