import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import PDFKit
import Vision

enum Images {
    static let ciContext = CIContext()
    static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let allTargets = ["jpg", "png", "heic", "webp", "tiff", "bmp", "gif", "avif", "ico", "pdf"]

    static func uti(_ ext: String) -> UTType? {
        switch ext {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "webp": return .webP
        case "ico": return .ico
        case "avif": return UTType("public.avif")
        default: return UTType(filenameExtension: ext)
        }
    }

    static func canWriteNatively(_ ext: String) -> Bool {
        guard let type = uti(ext) else { return false }
        return writable.contains(type.identifier)
    }

    static func targets(excluding sources: Set<String>) -> [String] {
        allTargets.filter { target in
            if sources.contains(target) { return false }
            if target == "jpg" && sources.contains("jpeg") { return false }
            if target == "tiff" && sources.contains("tif") { return false }
            if target == "heic" && sources.contains("heif") { return false }
            if target == "pdf" { return true }
            return canWriteNatively(target) || ((target == "webp" || target == "avif") && FFmpeg.available)
        }
    }

    // MARK: Loading and encoding

    /// Loads an image with its EXIF orientation already applied.
    static func load(_ url: URL) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        }
        if let ns = NSImage(contentsOf: url) {
            let scale: CGFloat = url.ext == "svg" ? 4 : 1
            let w = Int(max(ns.size.width, 1) * scale), h = Int(max(ns.size.height, 1) * scale)
            return try bitmap(width: w, height: h) { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        throw RFError("Could not read \(url.lastPathComponent) as an image.")
    }

    static func bitmap(width: Int, height: Int, opaque: Bool = false, draw: (CGContext) -> Void) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw RFError("Could not create an image canvas.")
        }
        ctx.interpolationQuality = .high
        draw(ctx)
        guard let image = ctx.makeImage() else { throw RFError("Could not render the image.") }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    static func flatten(_ image: CGImage, color: CGColor = Images.white) throws -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return try bitmap(width: image.width, height: image.height, opaque: true) { ctx in
            ctx.setFillColor(color)
            ctx.fill(rect)
            ctx.draw(image, in: rect)
        }
    }

    static func resized(_ image: CGImage, maxSide: CGFloat) throws -> CGImage {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        if scale >= 1 { return image }
        let w = Int((CGFloat(image.width) * scale).rounded()), h = Int((CGFloat(image.height) * scale).rounded())
        return try bitmap(width: max(w, 1), height: max(h, 1)) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: max(w, 1), height: max(h, 1)))
        }
    }

    static func encode(_ image: CGImage, ext: String, quality: Double = 0.9) throws -> Data {
        guard let type = uti(ext) else { throw RFError("Unknown image format \(ext.uppercased()).") }
        var output = image
        if ["jpg", "jpeg", "bmp"].contains(ext), hasAlpha(image) { output = try flatten(image) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw RFError("\(ext.uppercased()) export is not supported on this Mac.")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RFError("Could not encode the image as \(ext.uppercased()).") }
        return data as Data
    }

    // MARK: Conversion

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        if ext == "pdf" {
            try makePDF([url], to: out)
            return out
        }
        if !canWriteNatively(ext) {
            let temp = Paths.temp(ext: "png")
            defer { try? FileManager.default.removeItem(at: temp) }
            try encode(try load(url), ext: "png").write(to: temp)
            let args = ext == "webp"
                ? ["-c:v", "libwebp", "-quality", "85"]
                : ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "30", "-cpu-used", "6"]
            try await FFmpeg.convert(temp, to: out, args: args)
            return out
        }
        var image = try load(url)
        if ext == "ico" { image = try resized(image, maxSide: 256) }
        try encode(image, ext: ext, quality: 0.92).write(to: out)
        return out
    }

    static func makePDF(_ urls: [URL], to out: URL) throws {
        let doc = PDFDocument()
        for url in urls {
            let image = try load(url)
            let longest = CGFloat(max(image.width, image.height))
            let scale = longest > 842 ? 842 / longest : 1
            let ns = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
            guard let page = PDFPage(image: ns) else { throw RFError("Could not add \(url.lastPathComponent) to the PDF.") }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.write(to: out) else { throw RFError("Could not save the PDF.") }
    }

    // MARK: Tools

    static func compress(_ url: URL, fraction: Double) throws -> URL {
        let target = Int(Double(fileSize(url)) * fraction)
        var image = try load(url)
        let ext = (url.ext == "heic" || url.ext == "heif") ? "heic" : "jpg"
        var best: Data?
        for _ in 0..<5 {
            var low = 0.05, high = 0.95
            var found: Data?
            for _ in 0..<7 {
                let q = (low + high) / 2
                let data = try encode(image, ext: ext, quality: q)
                if data.count <= target { found = data; low = q } else { high = q }
            }
            if let found { best = found; break }
            image = try resized(image, maxSide: CGFloat(max(image.width, image.height)) * 0.72)
        }
        let data = try best ?? encode(image, ext: ext, quality: 0.05)
        let out = Paths.output(for: url, ext: ext, suffix: " compressed")
        try data.write(to: out)
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let image = try load(url)
        var ext = url.ext == "jpeg" ? "jpg" : url.ext
        if !canWriteNatively(ext) { ext = "png" }
        let out = Paths.output(for: url, ext: ext, suffix: " clean")
        try encode(image, ext: ext, quality: 0.95).write(to: out)
        return out
    }

    static func metadata(_ url: URL) -> [(String, String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        return flattenMetadata(props)
    }

    static func readCodes(_ url: URL) throws -> [String] {
        let image = try load(url)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    @available(macOS 14.0, *)
    static func removeBackground(_ url: URL) throws -> URL {
        let image = try load(url)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { throw RFError("Redfox could not find a clear subject in this image.") }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let output = ciContext.createCGImage(ci, from: ci.extent) else { throw RFError("Could not render the cut out image.") }
        let out = Paths.output(for: url, ext: "png", suffix: " no bg")
        try encode(output, ext: "png").write(to: out)
        return out
    }

    static func withBackground(_ image: CGImage, color: CGColor, padding: Double) throws -> CGImage {
        let pad = Int(Double(max(image.width, image.height)) * padding)
        let w = image.width + pad * 2, h = image.height + pad * 2
        return try bitmap(width: w, height: h, opaque: true) { ctx in
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        }
    }

    static func collage(_ urls: [URL]) throws -> URL {
        let images = try urls.map(load)
        let n = images.count
        let cols = Int(ceil(Double(n).squareRoot()))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cell = 800, gap = 16
        let w = cols * cell + (cols + 1) * gap, h = rows * cell + (rows + 1) * gap
        let canvas = try bitmap(width: w, height: h, opaque: true) { ctx in
            ctx.setFillColor(white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for (i, image) in images.enumerated() {
                let col = i % cols, row = i / cols
                let x = gap + col * (cell + gap)
                let y = h - (gap + row * (cell + gap)) - cell
                let cellRect = CGRect(x: x, y: y, width: cell, height: cell)
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let s = max(CGFloat(cell) / iw, CGFloat(cell) / ih)
                let dw = iw * s, dh = ih * s
                ctx.saveGState()
                ctx.clip(to: cellRect)
                ctx.draw(image, in: CGRect(x: cellRect.midX - dw / 2, y: cellRect.midY - dh / 2, width: dw, height: dh))
                ctx.restoreGState()
            }
        }
        let out = Paths.unique(in: urls[0].deletingLastPathComponent(), base: "Collage", ext: "jpg")
        try encode(canvas, ext: "jpg", quality: 0.9).write(to: out)
        return out
    }

    static func adjusted(_ image: CGImage, brightness: Double, contrast: Double, saturation: Double, exposure: Double) -> CGImage {
        var ci = CIImage(cgImage: image)
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(brightness, forKey: kCIInputBrightnessKey)
            filter.setValue(contrast, forKey: kCIInputContrastKey)
            filter.setValue(saturation, forKey: kCIInputSaturationKey)
            if let output = filter.outputImage { ci = output }
        }
        if exposure != 0, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(exposure, forKey: kCIInputEVKey)
            if let output = filter.outputImage { ci = output }
        }
        return ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
    }
}

func flattenMetadata(_ dict: [String: Any], prefix: String = "") -> [(String, String)] {
    var rows: [(String, String)] = []
    for key in dict.keys.sorted() {
        guard let value = dict[key] else { continue }
        let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if let sub = value as? [String: Any] {
            rows += flattenMetadata(sub, prefix: prefix + name + " › ")
        } else if let array = value as? [Any] {
            rows.append((prefix + name, array.map { "\($0)" }.joined(separator: ", ")))
        } else {
            rows.append((prefix + name, "\(value)"))
        }
    }
    return rows
}
