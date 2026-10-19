import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Media {
    static let nativeVideo: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let nativeAudio: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "m4b"]
    static let videoTargets = ["mp4", "mov", "gif", "m4a", "mp3", "webm", "mkv", "avi"]
    static let audioTargets = ["mp3", "m4a", "wav", "aiff", "flac", "ogg", "opus"]
    static let aacRates = [48_000, 64_000, 80_000, 96_000, 112_000, 128_000, 160_000, 192_000, 224_000, 256_000]

    static func isNative(_ url: URL) -> Bool { nativeVideo.contains(url.ext) || nativeAudio.contains(url.ext) }

    static func fileType(_ ext: String) -> AVFileType {
        switch ext {
        case "mov": return .mov
        case "m4v": return .m4v
        case "m4a": return .m4a
        case "wav": return .wav
        case "aiff", "aif": return .aiff
        default: return .mp4
        }
    }

    static func snapAAC(_ bitrate: Int) -> Int {
        aacRates.last { $0 <= bitrate } ?? aacRates[0]
    }

    // MARK: Export helper

    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType, range: CMTimeRange? = nil, configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RFError("This file can not be exported with these settings.")
        }
        guard session.supportedFileTypes.contains(type) else {
            throw RFError("This export can not produce a .\(out.pathExtension) file.")
        }
        session.outputURL = out
        session.outputFileType = type
        if let range { session.timeRange = range }
        configure?(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            try? FileManager.default.removeItem(at: out)
            throw session.error ?? RFError("Export failed.")
        }
    }

    /// Fast container change when possible, full re-encode otherwise.
    static func exportPreferPassthrough(_ asset: AVAsset, to out: URL, type: AVFileType, range: CMTimeRange? = nil, configure: ((AVAssetExportSession) -> Void)? = nil) async throws {
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, type: type, range: range, configure: configure)
        } catch {
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: type, range: range, configure: configure)
        }
    }

    // MARK: Conversion

    static func convertVideo(_ url: URL, to ext: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        let native = nativeVideo.contains(url.ext)
        switch ext {
        case "gif" where native:
            try await makeGIF(url, to: out, progress: progress)
        case "mp4" where native, "mov" where native, "m4v" where native:
            try await exportPreferPassthrough(AVURLAsset(url: url), to: out, type: fileType(ext))
        case "m4a" where native:
            try await Transcoder.run(input: url, output: out, options: TranscodeOptions(includeVideo: false, audio: .aac(256_000), fileType: .m4a), progress: progress)
        default:
            try await FFmpeg.convert(url, to: out, args: ffmpegArgs(ext, sourceExt: url.ext))
        }
        return out
    }

    static func convertAudio(_ url: URL, to ext: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        if nativeAudio.contains(url.ext), ["m4a", "wav", "aiff"].contains(ext) {
            let audio: TranscodeOptions.Audio = ext == "m4a" ? .aac(256_000) : .pcm(bigEndian: ext == "aiff")
            try await Transcoder.run(input: url, output: out, options: TranscodeOptions(includeVideo: false, audio: audio, fileType: fileType(ext)), progress: progress)
        } else {
            try await FFmpeg.convert(url, to: out, args: ffmpegArgs(ext, sourceExt: url.ext))
        }
        return out
    }

    static func ffmpegArgs(_ ext: String, sourceExt: String) -> [String] {
        switch ext {
        case "mp4", "mov", "m4v":
            return ["-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mkv":
            if ["mp4", "mov", "m4v"].contains(sourceExt) { return ["-c", "copy"] }
            return ["-c:v", "libx264", "-crf", "22", "-c:a", "aac", "-b:a", "192k"]
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "gif":
            return ["-vf", "fps=12,scale=480:-1:flags=lanczos", "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        default: return []
        }
    }

    static func makeGIF(_ url: URL, to out: URL, fps: Double = 10, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        let duration = min(total, 30)
        let count = max(1, Int(duration * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw RFError("Could not create the GIF file.")
        }
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            CGImageDestinationAddImage(dest, frame, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw RFError("Could not finish the GIF.") }
    }

    // MARK: Compression

    static func compressVideo(_ url: URL, fraction: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = Paths.output(for: url, ext: "mp4", suffix: " compressed")
        if !nativeVideo.contains(url.ext) {
            let crf = Int(23 + (1 - fraction) * 12)
            try await FFmpeg.convert(url, to: out, args: ["-c:v", "libx264", "-crf", "\(crf)", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
            return out
        }
        let rawDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let duration = max(rawDuration, 0.1)
        let targetBits = Double(fileSize(url)) * fraction * 8 * 0.94
        let audioBits = 96_000.0
        let videoBitrate = max(150_000, Int(targetBits / duration - audioBits))
        let maxShortSide: CGFloat?
        if videoBitrate < 900_000 { maxShortSide = 540 }
        else if videoBitrate < 2_500_000 { maxShortSide = 720 }
        else if videoBitrate < 5_000_000 { maxShortSide = 1080 }
        else { maxShortSide = nil }
        let options = TranscodeOptions(videoBitrate: videoBitrate, maxShortSide: maxShortSide, audio: .aac(96_000), fileType: .mp4)
        try await Transcoder.run(input: url, output: out, options: options, progress: progress)
        return out
    }

    static func compressAudio(_ url: URL, fraction: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = Paths.output(for: url, ext: "m4a", suffix: " compressed")
        if !nativeAudio.contains(url.ext) {
            let kbps = max(48, Int(256 * fraction))
            try await FFmpeg.convert(url, to: out, args: ["-vn", "-c:a", "aac", "-b:a", "\(kbps)k"])
            return out
        }
        let rawDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let duration = max(rawDuration, 1)
        let bitrate = snapAAC(Int(Double(fileSize(url)) * fraction * 8 / duration))
        try await Transcoder.run(input: url, output: out, options: TranscodeOptions(includeVideo: false, audio: .aac(bitrate), fileType: .m4a), progress: progress)
        return out
    }

    // MARK: Edits built on compositions

    static func changeSpeed(_ url: URL, factor: Double) async throws -> URL {
        let comp = try await Compose.build([AVURLAsset(url: url)])
        let duration = comp.duration
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / factor))
        let isAudio = comp.tracks(withMediaType: .video).isEmpty
        let ext = isAudio ? "m4a" : (url.ext == "mov" ? "mov" : "mp4")
        let out = Paths.output(for: url, ext: ext, suffix: factor > 1 ? " fast" : " slow")
        try await export(comp, preset: isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality, to: out, type: fileType(ext)) { session in
            session.audioTimePitchAlgorithm = .spectral
        }
        return out
    }

    static func mute(_ url: URL) async throws -> URL {
        let comp = try await Compose.build([AVURLAsset(url: url)], includeAudio: false)
        let ext = ["mov", "m4v"].contains(url.ext) ? url.ext : "mp4"
        let out = Paths.output(for: url, ext: ext, suffix: " muted")
        try await exportPreferPassthrough(comp, to: out, type: fileType(ext))
        return out
    }

    static func rotate(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let comp = try await Compose.build([asset])
        guard let source = try await asset.loadTracks(withMediaType: .video).first,
              let track = comp.tracks(withMediaType: .video).first else {
            throw RFError("This file has no video track to rotate.")
        }
        let natural = try await source.load(.naturalSize)
        var transform = track.preferredTransform.concatenating(CGAffineTransform(rotationAngle: .pi / 2))
        let bounds = CGRect(origin: .zero, size: natural).applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        track.preferredTransform = transform
        let ext = ["mov", "m4v"].contains(url.ext) ? url.ext : "mp4"
        let out = Paths.output(for: url, ext: ext, suffix: " rotated")
        try await exportPreferPassthrough(comp, to: out, type: fileType(ext))
        return out
    }

    static func join(_ urls: [URL]) async throws -> URL {
        let comp = try await Compose.build(urls.map { AVURLAsset(url: $0) })
        let isAudio = comp.tracks(withMediaType: .video).isEmpty
        let ext = isAudio ? "m4a" : "mp4"
        let out = Paths.unique(in: urls[0].deletingLastPathComponent(), base: "Joined", ext: ext)
        try await export(comp, preset: isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality, to: out, type: fileType(ext))
        return out
    }

    static func exportRange(_ url: URL, range: CMTimeRange, suffix: String) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let hasVideo = !videoTracks.isEmpty
        if hasVideo {
            let ext = ["mov", "m4v"].contains(url.ext) ? url.ext : "mp4"
            let out = Paths.output(for: url, ext: ext, suffix: suffix)
            try await exportPreferPassthrough(asset, to: out, type: fileType(ext), range: range)
            return out
        }
        let out = Paths.output(for: url, ext: "m4a", suffix: suffix)
        try await export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a, range: range)
        return out
    }

    static func split(_ url: URL, at time: CMTime) async throws -> [URL] {
        let duration = try await AVURLAsset(url: url).load(.duration)
        guard time.seconds > 0.1, time.seconds < duration.seconds - 0.1 else {
            throw RFError("Move the playhead somewhere inside the clip before splitting.")
        }
        let first = try await exportRange(url, range: CMTimeRange(start: .zero, end: time), suffix: " part 1")
        let second = try await exportRange(url, range: CMTimeRange(start: time, end: duration), suffix: " part 2")
        return [first, second]
    }

    static func snapshot(_ url: URL, at time: CMTime) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        let seconds = time.seconds.isFinite ? Int(time.seconds) : 0
        let out = Paths.output(for: url, ext: "png", suffix: String(format: " frame %02dm%02ds", seconds / 60, seconds % 60))
        try Images.encode(image, ext: "png").write(to: out)
        return out
    }

    static func stripMetadata(_ url: URL) async throws -> URL {
        let out = Paths.output(for: url, ext: url.ext, suffix: " clean")
        if ["mp4", "mov", "m4v", "m4a"].contains(url.ext) {
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetPassthrough, to: out, type: fileType(url.ext)) { session in
                session.metadata = []
                session.metadataItemFilter = .forSharing()
            }
        } else {
            try await FFmpeg.convert(url, to: out, args: ["-map_metadata", "-1", "-c", "copy"])
        }
        return out
    }

    // MARK: Sample level audio tools

    static func normalize(_ url: URL) throws -> URL {
        try processAudio(url, suffix: " normalized") { buffer in
            guard let data = buffer.floatChannelData else { throw RFError("Could not read the audio samples.") }
            let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
            var peak: Float = 0
            for c in 0..<channels {
                for i in 0..<frames { peak = max(peak, abs(data[c][i])) }
            }
            guard peak > 0 else { throw RFError("This audio is silent.") }
            let gain = 0.977 / peak
            for c in 0..<channels {
                for i in 0..<frames { data[c][i] *= gain }
            }
            return buffer
        }
    }

    static func toggleChannels(_ url: URL) throws -> URL {
        try processAudio(url, suffix: " channels") { buffer in
            let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
            let targetChannels: AVAudioChannelCount = channels > 1 ? 1 : 2
            guard let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: targetChannels),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData,
                  let target = output.floatChannelData else {
                throw RFError("Could not prepare the audio buffer.")
            }
            output.frameLength = buffer.frameLength
            if targetChannels == 1 {
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += source[c][i] }
                    target[0][i] = sum / Float(channels)
                }
            } else {
                for i in 0..<frames {
                    target[0][i] = source[0][i]
                    target[1][i] = source[0][i]
                }
            }
            return output
        }
    }

    private static func processAudio(_ url: URL, suffix: String, transform: (AVAudioPCMBuffer) throws -> AVAudioPCMBuffer) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RFError("This audio file is too large to process.")
        }
        try file.read(into: buffer)
        let result = try transform(buffer)
        let ext = ["wav", "aiff", "aif"].contains(url.ext) ? url.ext : "m4a"
        let out = Paths.output(for: url, ext: ext, suffix: suffix)
        let format = result.format
        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        if ext == "m4a" {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = format.channelCount == 1 ? 128_000 : 256_000
            if format.sampleRate > 48_000 { settings[AVSampleRateKey] = 48_000 }
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = ext != "wav"
        }
        try writeAudio(result, to: out, settings: settings)
        return out
    }

    private static func writeAudio(_ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

// MARK: - Compositions

enum Compose {
    static func build(_ assets: [AVAsset], includeAudio: Bool = true) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = includeAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var cursor = CMTime.zero
        var transformSet = false
        for asset in assets {
            let duration = try await asset.load(.duration)
            if let videoTrack, let source = try await asset.loadTracks(withMediaType: .video).first {
                let range = try await source.load(.timeRange)
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                if !transformSet {
                    videoTrack.preferredTransform = try await source.load(.preferredTransform)
                    transformSet = true
                }
            }
            if let audioTrack, let source = try await asset.loadTracks(withMediaType: .audio).first {
                let range = try await source.load(.timeRange)
                try audioTrack.insertTimeRange(range, of: source, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        if let videoTrack, videoTrack.segments.isEmpty { comp.removeTrack(videoTrack) }
        if let audioTrack, audioTrack.segments.isEmpty { comp.removeTrack(audioTrack) }
        if comp.tracks.isEmpty { throw RFError("No audio or video could be read from this file.") }
        return comp
    }
}

// MARK: - Reader and writer transcoder

struct TranscodeOptions {
    enum Audio {
        case aac(Int)
        case pcm(bigEndian: Bool)
    }

    var includeVideo = true
    var includeAudio = true
    var videoBitrate: Int? = nil
    var maxShortSide: CGFloat? = nil
    var audio: Audio = .aac(160_000)
    var fileType: AVFileType = .mp4
}

/// Bundles one reader output with its writer input. Each pump runs on its own serial queue,
/// so sharing these AVFoundation objects with that queue is safe.
private final class Pump: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    var done = false

    init(reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }
}

enum Transcoder {
    static func run(input: URL, output: URL, options: TranscodeOptions, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        var videoTracks: [AVAssetTrack] = []
        var audioTracks: [AVAssetTrack] = []
        if options.includeVideo { videoTracks = try await asset.loadTracks(withMediaType: .video) }
        if options.includeAudio { audioTracks = try await asset.loadTracks(withMediaType: .audio) }
        if videoTracks.isEmpty && audioTracks.isEmpty {
            throw RFError("No usable audio or video tracks were found.")
        }

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: options.fileType)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []

        if let track = videoTracks.first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let fps = try await track.load(.nominalFrameRate)
            let estimated = try await track.load(.estimatedDataRate)
            var w = abs(natural.width), h = abs(natural.height)
            if let limit = options.maxShortSide, min(w, h) > limit {
                let s = limit / min(w, h)
                w *= s
                h *= s
            }
            let width = Int((w / 2).rounded()) * 2
            let height = Int((h / 2).rounded()) * 2
            let bitrate = options.videoBitrate ?? Int(max(Double(estimated), 2_000_000))

            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            readerOutput.alwaysCopiesSampleData = false
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: fps > 0 ? fps : 30,
                ],
            ]
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerInput.transform = transform
            writerInput.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
                throw RFError("This video can not be re-encoded.")
            }
            reader.add(readerOutput)
            writer.add(writerInput)
            pairs.append((readerOutput, writerInput))
        }

        if !audioTracks.isEmpty {
            var pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let writerSettings: [String: Any]
            switch options.audio {
            case .aac(let bitrate):
                writerSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: Media.snapAAC(bitrate),
                ]
            case .pcm(let bigEndian):
                pcm[AVLinearPCMIsBigEndianKey] = bigEndian
                writerSettings = pcm
            }
            let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
            readerOutput.alwaysCopiesSampleData = false
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
            writerInput.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
                throw RFError("This audio can not be re-encoded.")
            }
            reader.add(readerOutput)
            writer.add(writerInput)
            pairs.append((readerOutput, writerInput))
        }

        guard writer.startWriting() else { throw writer.error ?? RFError("Could not start writing the file.") }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? RFError("Could not start reading the file.")
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, pair) in pairs.enumerated() {
                group.enter()
                let pump = Pump(reader: reader, output: pair.0, input: pair.1)
                let queue = DispatchQueue(label: "redfox.transcode.\(index)")
                pump.input.requestMediaDataWhenReady(on: queue) {
                    while pump.input.isReadyForMoreMediaData && !pump.done {
                        if let buffer = pump.output.copyNextSampleBuffer() {
                            if index == 0 && duration > 0 {
                                progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration))
                            }
                            if !pump.input.append(buffer) {
                                pump.done = true
                                pump.reader.cancelReading()
                            }
                        } else {
                            pump.done = true
                        }
                        if pump.done {
                            pump.input.markAsFinished()
                            group.leave()
                        }
                    }
                }
            }
            group.notify(queue: .global()) { continuation.resume() }
        }

        if writer.status == .failed || reader.status == .failed {
            let error = writer.error ?? reader.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error ?? RFError("Transcoding failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RFError("Transcoding failed.")
        }
        progress(1)
    }
}
