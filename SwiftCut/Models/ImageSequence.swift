import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
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

    /// How camera RAW photos are developed: decoded at full precision with these settings
    /// (Image Sequence section › RAW) instead of the camera's default look, which clips the
    /// brightest highlights. `nil` for other kinds of images.
    struct RawDevelop: Codable, Hashable, Sendable {
        /// Brighter or darker, in stops.
        var exposure = 0.0
        /// 0 clips highlights like the camera's look; 1 keeps all the detail above white,
        /// rolled off smoothly into the picture.
        var highlightRecovery = 1.0
        /// How much the shadows are lifted: 1 is the camera's default, 0 none, 2 twice as much.
        var shadows = 1.0

        static let exposureRange = -3.0...3.0
        static let shadowsRange = 0.0...2.0

        init(exposure: Double = 0, highlightRecovery: Double = 1, shadows: Double = 1) {
            self.exposure = exposure
            self.highlightRecovery = highlightRecovery
            self.shadows = shadows
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exposure = (try? c.decodeIfPresent(Double.self, forKey: .exposure)) ?? 0
            highlightRecovery = (try? c.decodeIfPresent(Double.self, forKey: .highlightRecovery)) ?? 1
            shadows = (try? c.decodeIfPresent(Double.self, forKey: .shadows)) ?? 1
        }

        var isDefault: Bool { self == RawDevelop() }
    }

    /// What the images are made into, from small compressed files to the highest-quality ProRes.
    enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
        case h264, hevc10, proRes422Proxy, proRes422LT, proRes422, proRes422HQ, proRes4444, proRes4444XQ

        var id: Self { self }

        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc10: "HEVC (H.265) 10-bit"
            case .proRes422Proxy: "Apple ProRes 422 Proxy"
            case .proRes422LT: "Apple ProRes 422 LT"
            case .proRes422: "Apple ProRes 422"
            case .proRes422HQ: "Apple ProRes 422 HQ"
            case .proRes4444: "Apple ProRes 4444"
            case .proRes4444XQ: "Apple ProRes 4444 XQ"
            }
        }

        /// What it's good for, in a few words.
        var detail: String {
            switch self {
            case .h264: "Compressed. Smallest files, but heavy grading can show banding."
            case .hevc10: "Compressed. Small files that keep more tones than H.264; slower to edit."
            case .proRes422Proxy: "Lightest ProRes, for rough edits."
            case .proRes422LT: "Light ProRes; good for most viewing."
            case .proRes422: "Standard ProRes for editing."
            case .proRes422HQ: "High-quality ProRes for editing and grading."
            case .proRes4444: "Very high quality, with full color detail."
            case .proRes4444XQ: "Highest quality ProRes. Keeps the most RAW detail; largest files."
            }
        }

        var bitDepth: Int {
            switch self {
            case .h264: 8
            case .hevc10, .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ: 10
            case .proRes4444, .proRes4444XQ: 12
            }
        }

        var isCompressed: Bool { self == .h264 || self == .hevc10 }

        var codecType: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc10: .hevc
            case .proRes422Proxy: .proRes422Proxy
            case .proRes422LT: .proRes422LT
            case .proRes422: .proRes422
            case .proRes422HQ: .proRes422HQ
            case .proRes4444: .proRes4444
            case .proRes4444XQ: AVVideoCodecType(rawValue: "ap4x")
            }
        }

        /// Megabits a second at 1920 × 1080, 29.97 fps (Apple's ProRes targets; typical for the others).
        var megabitsAt1080p30: Double {
            switch self {
            case .h264: 24
            case .hevc10: 16
            case .proRes422Proxy: 45
            case .proRes422LT: 102
            case .proRes422: 147
            case .proRes422HQ: 220
            case .proRes4444: 330
            case .proRes4444XQ: 500
            }
        }

        /// About how big a video this size, rate, and length comes out, in bytes.
        func estimatedBytes(frameSize: CGSize, fps: Double, seconds: Double) -> Double {
            let scale = Double(frameSize.width * frameSize.height) / (1920 * 1080) * (fps / 29.97)
            return megabitsAt1080p30 * 1_000_000 / 8 * scale * seconds
        }

        /// The bit rate to ask a compressed format for at this size and rate, in bits a second.
        func bitRate(frameSize: CGSize, fps: Double) -> Int {
            Int(estimatedBytes(frameSize: frameSize, fps: fps, seconds: 1) * 8)
        }
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
    /// RAW development, for camera RAW photos.
    var raw: RawDevelop?
    /// What the video is made as; `nil` picks automatically (see `format`).
    var outputFormat: OutputFormat?
    /// The sidebar folder the clip goes in (from a dropped folder). Not part of the picture.
    var folderID: UUID?

    /// The format used: as chosen, or ProRes 4444 XQ for RAW, 4444 for images with
    /// transparency (it keeps it), and 422 HQ otherwise.
    func format(hasAlpha: Bool) -> OutputFormat {
        outputFormat ?? (raw != nil ? .proRes4444XQ : hasAlpha ? .proRes4444 : .proRes422HQ)
    }

    init(name: String, imagePaths: [String], access: [Access] = []) {
        self.name = name
        self.imagePaths = imagePaths
        self.access = access
        frameRate = imagePaths.count == 1 ? 30 : 24
        raw = Self.isRaw(imagePaths.first) ? RawDevelop() : nil
    }

    /// Whether `path` is a camera RAW photo (Sony ARW, Canon CR3, Nikon NEF, DNG…).
    static func isRaw(_ path: String?) -> Bool {
        guard let path else { return false }
        let type = UTType(filenameExtension: URL(filePath: path).pathExtension)
        return type?.conforms(to: .rawImage) ?? false
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
        // RAW sequences from before RAW development get it now (and their videos are made again).
        raw = (try? c.decodeIfPresent(RawDevelop.self, forKey: .raw)) ?? (Self.isRaw(imagePaths.first) ? RawDevelop() : nil)
        outputFormat = try? c.decodeIfPresent(OutputFormat.self, forKey: .outputFormat)
        folderID = try? c.decodeIfPresent(UUID.self, forKey: .folderID)
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

    /// The frame rate chosen when importing last time, for the next import.
    static var savedFrameRate: Double {
        get {
            let fps = UserDefaults.standard.double(forKey: "imageImportFrameRate")
            return fps > 0 ? fps : 24
        }
        set { UserDefaults.standard.set(newValue, forKey: "imageImportFrameRate") }
    }

    /// Keeps a typed rate within what SwiftCut can make.
    static func clampedFrameRate(_ fps: Double) -> Double {
        min(maxFrameRate, max(minFrameRate, fps))
    }

    /// Sets the frame rate, as Custom when it isn't one of the menu's choices.
    mutating func setFrameRate(_ fps: Double) {
        frameRate = Self.clampedFrameRate(fps)
        isCustomFrameRate = !Self.frameRates.contains(frameRate)
    }

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
        // The version changes when SwiftCut makes the videos differently, so old ones are made again
        // (2: see-through parts kept their brightness).
        var key = "v2|" + imagePaths.joined(separator: "\n")
        key += "|\(frameSize.map(\.title) ?? "match")|\(fit.rawValue)|\(frameDuration.value)/\(frameDuration.timescale)"
        if isStill { key += "|\(frameCount)" }
        if let raw { key += "|raw \(raw.exposure) \(raw.highlightRecovery) \(raw.shadows)" }
        if let outputFormat { key += "|format \(outputFormat.rawValue)" }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Where SwiftCut keeps the video it made from these images.
    var videoURL: URL {
        Self.cacheFolder.appending(path: "\(contentKey).mov")
    }

    static var cacheFolder: URL {
        // Under the test runner, a folder of its own, so test videos don't pile up in the app's cache.
        isTesting
            ? URL.temporaryDirectory.appending(path: "Test Image Sequences", directoryHint: .isDirectory)
            : URL.cachesDirectory.appending(path: "Image Sequences", directoryHint: .isDirectory)
    }

    private static let isTesting = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }

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
    static func images(in folder: URL, order: Order = .nameAscending) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return sorted(files.filter(isImage), by: order)
    }

    /// How images are put in order when they're imported.
    enum Order: String, CaseIterable, Identifiable, Sendable {
        case nameAscending, nameDescending
        case createdAscending, createdDescending
        case modifiedAscending, modifiedDescending
        case takenAscending, takenDescending
        case sizeAscending, sizeDescending

        var id: Self { self }

        var title: String {
            switch self {
            case .nameAscending: "Name (A to Z)"
            case .nameDescending: "Name (Z to A)"
            case .createdAscending: "Date Created (Oldest First)"
            case .createdDescending: "Date Created (Newest First)"
            case .modifiedAscending: "Date Modified (Oldest First)"
            case .modifiedDescending: "Date Modified (Newest First)"
            case .takenAscending: "Date Taken (Oldest First)"
            case .takenDescending: "Date Taken (Newest First)"
            case .sizeAscending: "File Size (Smallest First)"
            case .sizeDescending: "File Size (Largest First)"
            }
        }

        /// The menu's choices in pairs; a divider goes between pairs.
        static let groups: [[Order]] = [
            [.nameAscending, .nameDescending],
            [.createdAscending, .createdDescending],
            [.modifiedAscending, .modifiedDescending],
            [.takenAscending, .takenDescending],
            [.sizeAscending, .sizeDescending],
        ]

        var isDescending: Bool {
            switch self {
            case .nameDescending, .createdDescending, .modifiedDescending, .takenDescending, .sizeDescending: true
            default: false
            }
        }

        /// The last order used, for the next import.
        static var saved: Order {
            get { UserDefaults.standard.string(forKey: "imageImportOrder").flatMap(Order.init) ?? .nameAscending }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "imageImportOrder") }
        }
    }

    /// Puts images in `order`. Names compare numbers as numbers (frame2 before frame10), the
    /// way Finder sorts; images with the same date or size go in name order.
    static func sorted(_ urls: [URL], by order: Order = .nameAscending) -> [URL] {
        let byName = { (a: URL, b: URL) in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        switch order {
        case .nameAscending: return urls.sorted(by: byName)
        case .nameDescending: return urls.sorted { byName($1, $0) }
        default: break
        }
        // Read each file's value once.
        let keyed: [(url: URL, key: Double)] = urls.map { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let key: Double
            switch order {
            case .createdAscending, .createdDescending:
                key = values?.creationDate?.timeIntervalSinceReferenceDate ?? 0
            case .modifiedAscending, .modifiedDescending:
                key = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            case .takenAscending, .takenDescending:
                // Photos without the date they were taken use the date the file was made.
                key = (dateTaken(url) ?? values?.creationDate)?.timeIntervalSinceReferenceDate ?? 0
            default:
                key = Double(values?.fileSize ?? 0)
            }
            return (url, key)
        }
        return keyed.sorted { a, b in
            if a.key != b.key { return order.isDescending ? a.key > b.key : a.key < b.key }
            return byName(a.url, b.url)
        }.map(\.url)
    }

    /// When a photo was taken, from its camera details (EXIF), if it says.
    static func dateTaken(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var date = formatter.date(from: text) else { return nil }
        // Fractions of a second, for bursts taken within the same second.
        if let fraction = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, let value = Double("0.\(fraction)") {
            date += value
        }
        return date
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
nonisolated struct PendingImageImport: Identifiable, Sendable {
    let id = UUID()
    /// Folders of images.
    var folders: [URL]
    /// Loose image files.
    var images: [URL]
    /// Where on the timeline to put them, when they were dropped there.
    var timelineIndex: Int?
    /// The sidebar folder each dropped folder's images go into (keys are standardized folder URLs).
    var destinations: [URL: UUID] = [:]

    var imageCount: Int {
        images.count + folders.reduce(0) { $0 + ImageSequence.images(in: $1).count }
    }
}
