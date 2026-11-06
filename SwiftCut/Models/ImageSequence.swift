import CoreMedia
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Images made into a source video: a numbered sequence (one image per frame), or a single
/// still image held for `stillDuration`. SwiftCut writes the video itself (see
/// `ImageSequenceWriter`) and keeps it in its cache; the project saves only this.
nonisolated struct ImageSequence: Codable, Hashable, Sendable {
    /// A file or folder SwiftCut was given access to, so the images can be read after relaunching.
    struct Access: Codable, Hashable, Sendable {
        var path: String
        var bookmark: Data?
    }

    struct FrameSize: Codable, Hashable, Sendable {
        var width: Int
        var height: Int

        var cgSize: CGSize { CGSize(width: width, height: height) }
        var title: String { "\(width) × \(height)" }
    }

    /// Shown in the sidebar: the folder's name, or the images' shared name.
    var name: String
    /// The images, in frame order.
    var imagePaths: [String]
    /// What was dropped or chosen (folders or files), for permission to read the images later.
    var access: [Access] = []

    /// `nil` uses the first image's size.
    var frameSize: FrameSize?
    /// The Frame Size menu shows Custom with width and height fields.
    var isCustomSize = false
    /// How images of a different shape than the frame are placed.
    var fit = TimelineSettings.Fit.fit
    var frameRate: Double
    /// The Frame Rate menu shows Custom with a field.
    var isCustomFrameRate = false
    /// How long a single image lasts, in seconds. Not used for sequences.
    var stillDuration = 5.0

    init(name: String, imagePaths: [String], access: [Access] = []) {
        self.name = name
        self.imagePaths = imagePaths
        self.access = access
        frameRate = imagePaths.count == 1 ? 30 : 24
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        imagePaths = try c.decode([String].self, forKey: .imagePaths)
        access = (try? c.decodeIfPresent([Access].self, forKey: .access)) ?? []
        frameSize = try? c.decodeIfPresent(FrameSize.self, forKey: .frameSize)
        isCustomSize = (try? c.decodeIfPresent(Bool.self, forKey: .isCustomSize)) ?? false
        fit = (try? c.decodeIfPresent(TimelineSettings.Fit.self, forKey: .fit)) ?? .fit
        frameRate = (try? c.decodeIfPresent(Double.self, forKey: .frameRate)) ?? 24
        isCustomFrameRate = (try? c.decodeIfPresent(Bool.self, forKey: .isCustomFrameRate)) ?? false
        stillDuration = (try? c.decodeIfPresent(Double.self, forKey: .stillDuration)) ?? 5
    }

    var imageURLs: [URL] { imagePaths.map { URL(filePath: $0) } }

    /// One image held on screen, rather than a sequence.
    var isStill: Bool { imagePaths.count == 1 }

    var frameCount: Int {
        isStill ? max(1, Int((stillDuration * frameRate).rounded())) : imagePaths.count
    }

    var duration: Double { Double(frameCount) * frameDuration.seconds }

    /// Exact frame length: 1001/30000 s for 29.97, 1/24 s for 24, 2/25 s for 12.5.
    var frameDuration: CMTime { Self.frameDuration(fps: frameRate) }

    static func frameDuration(fps: Double) -> CMTime {
        let fps = min(maxFrameRate, max(minFrameRate, fps))
        // NTSC rates (23.976, 29.97, 59.94…): 1001 over a whole number of thousands.
        let ntsc = (fps * 1.001).rounded()
        if abs(fps - fps.rounded()) > 0.005, abs(fps - ntsc / 1.001) < 0.005 {
            return CMTime(value: 1001, timescale: CMTimeScale(ntsc * 1000))
        }
        // Everything else to a thousandth of a frame per second.
        return CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
    }

    static let minFrameRate = 0.1
    static let maxFrameRate = 240.0

    /// The Frame Rate menu's choices.
    static let frameRates: [Double] = [1, 2, 5, 8, 10, 12, 12.5, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 120]

    static func frameRateTitle(_ fps: Double) -> String {
        let number = fps.formatted(.number.precision(.fractionLength(0...3)))
        switch fps {
        case 25: return "\(number) fps (PAL)"
        case 29.97: return "\(number) fps (NTSC)"
        default: return "\(number) fps"
        }
    }

    /// The Frame Size menu's choices (after Match Images).
    static let frameSizes: [(size: FrameSize, title: String)] = [
        (FrameSize(width: 3840, height: 2160), "4K UHD"),
        (FrameSize(width: 2560, height: 1440), "1440p"),
        (FrameSize(width: 1920, height: 1080), "HD 1080p"),
        (FrameSize(width: 1280, height: 720), "HD 720p"),
        (FrameSize(width: 1080, height: 1920), "Vertical 9:16"),
        (FrameSize(width: 1080, height: 1350), "Portrait 4:5"),
        (FrameSize(width: 1080, height: 1080), "Square"),
        (FrameSize(width: 720, height: 480), "SD 480p"),
    ]

    /// The frame size in pixels: the chosen size, or the first image's (made even, as video
    /// encoders need).
    func outputSize(firstImage: CGSize) -> CGSize {
        let size = frameSize?.cgSize ?? firstImage
        return CGSize(width: Self.even(size.width), height: Self.even(size.height))
    }

    static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }

    // MARK: The video file

    /// Identifies what the video shows: the images and every setting that changes the picture.
    /// The cached video is named after it, so changing a setting makes a new video.
    var contentKey: String {
        var key = imagePaths.joined(separator: "\n")
        key += "|\(frameSize.map(\.title) ?? "match")|\(fit.rawValue)|\(frameDuration.value)/\(frameDuration.timescale)"
        if isStill { key += "|\(frameCount)" }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Where SwiftCut keeps the video it made from these images.
    var videoURL: URL {
        Self.cacheFolder.appending(path: "\(contentKey).mov")
    }

    static var cacheFolder: URL {
        URL.cachesDirectory.appending(path: "Image Sequences", directoryHint: .isDirectory)
    }

    // MARK: Finding images

    static func isImage(_ url: URL) -> Bool {
        guard url.isFileURL, !isFolder(url) else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The images directly inside a folder, in name order with numbers compared as numbers
    /// (frame2 before frame10), the way Finder sorts.
    static func images(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return sorted(files.filter(isImage))
    }

    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A name for images picked by hand: "shot_0001.png", "shot_0002.png" → "shot".
    static func name(forImages urls: [URL]) -> String {
        guard let first = urls.first else { return "Image Sequence" }
        let base = first.deletingPathExtension().lastPathComponent
        guard urls.count > 1 else { return base }
        let trimmed = base.trimmingCharacters(in: .decimalDigits)
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-.").union(.whitespaces))
        return trimmed.isEmpty ? "Image Sequence" : trimmed
    }
}

/// Images dropped on the window, waiting for the user to choose how to import them.
struct PendingImageImport: Identifiable {
    let id = UUID()
    /// Folders of images.
    var folders: [URL]
    /// Loose image files.
    var images: [URL]
    /// Where on the timeline to put them, when they were dropped there.
    var timelineIndex: Int?

    var imageCount: Int {
        images.count + folders.reduce(0) { $0 + ImageSequence.images(in: $1).count }
    }
}
