import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO

/// Writes an image sequence (or a still image) as a ProRes video: ProRes 422 HQ, or
/// ProRes 4444 when the images have transparency, so it keeps it. Camera RAW photos are
/// developed at full precision (`ImageSequence.RawDevelop`) and written as 12-bit ProRes 4444 XQ,
/// so the detail recovered from their highlights and shadows isn't lost to 8 bits.
nonisolated enum ImageSequenceWriter {
    enum WriteError: LocalizedError {
        case missingImages(Int)
        case unreadable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingImages(let count):
                count == 1 ? "1 image can't be found. It may have been moved or deleted."
                    : "\(count) images can't be found. They may have been moved or deleted."
            case .unreadable(let name): "“\(name)” can't be read as an image."
            case .failed(let reason): "Couldn't make the video: \(reason)"
            }
        }
    }

    /// Writes `sequence` to `url` (replacing what's there). Blocks until done: call it through
    /// `BlockingWork`. `progress` gets 0…1; `isCancelled` stops it early.
    static func write(_ sequence: ImageSequence, to url: URL,
                      progress: @Sendable (Double) -> Void = { _ in },
                      isCancelled: () -> Bool = { false }) throws {
        let urls = sequence.imageURLs
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }.count
        guard missing == 0, let firstURL = urls.first else { throw WriteError.missingImages(max(missing, 1)) }
        guard let first = Source(url: firstURL) else { throw WriteError.unreadable(firstURL.lastPathComponent) }

        let size = sequence.outputSize(firstImage: first.size)
        let develop = sequence.raw
        let hasAlpha = develop == nil && first.hasAlpha
        let frameDuration = sequence.frameDuration

        // Write next to the final file, then move it into place, so a half-written video never
        // sits where the app looks for it.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: partial) }

        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: develop != nil ? Self.proRes4444XQ : hasAlpha ? AVVideoCodecType.proRes4444 : AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw WriteError.failed("ProRes can't be written at \(Int(size.width)) × \(Int(size.height)).")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = max(frameDuration.timescale, 600)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            // 16 bits a channel for RAW, so the 12-bit file gets every level; 8 otherwise.
            kCVPixelBufferPixelFormatTypeKey as String: develop != nil ? kCVPixelFormatType_64RGBALE : kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw WriteError.failed("the video track couldn't be added.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriteError.failed(writer.error?.localizedDescription ?? "the file couldn't be written.")
        }
        writer.startSession(atSourceTime: .zero)

        let canvas = Canvas(size: size, fit: sequence.fit, opaque: !hasAlpha)
        let developer = develop.map { RawDeveloper(develop: $0, canvas: canvas) }
        let frameCount = sequence.frameCount
        var still: CVPixelBuffer?
        var reported = -1

        for index in 0..<frameCount {
            if isCancelled() {
                writer.cancelWriting()
                throw CancellationError()
            }
            let buffer: CVPixelBuffer
            if sequence.isStill, let still {
                buffer = still
            } else {
                guard let pool = adaptor.pixelBufferPool else {
                    writer.cancelWriting()
                    throw WriteError.failed(writer.error?.localizedDescription ?? "a frame couldn't be drawn.")
                }
                let drawn: CVPixelBuffer?
                if let developer {
                    drawn = try developer.draw(urls[index], pool: pool)
                } else {
                    guard let source = index == 0 ? first : Source(url: urls[index]) else {
                        writer.cancelWriting()
                        throw WriteError.unreadable(urls[index].lastPathComponent)
                    }
                    drawn = canvas.draw(source, pool: pool)
                }
                guard let drawn else {
                    writer.cancelWriting()
                    throw WriteError.failed(writer.error?.localizedDescription ?? "a frame couldn't be drawn.")
                }
                buffer = drawn
                if sequence.isStill { still = drawn }
            }
            while !input.isReadyForMoreMediaData {
                if isCancelled() || writer.status != .writing { break }
                usleep(2000)
            }
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            guard writer.status == .writing, adaptor.append(buffer, withPresentationTime: time) else {
                writer.cancelWriting()
                throw WriteError.failed(writer.error?.localizedDescription ?? "a frame couldn't be added.")
            }
            let percent = (index + 1) * 100 / frameCount
            if percent != reported {
                reported = percent
                progress(Double(index + 1) / Double(frameCount))
            }
        }

        input.markAsFinished()
        // The last frame lasts its full length.
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frameCount)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw WriteError.failed(writer.error?.localizedDescription ?? "the file couldn't be finished.")
        }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// Apple ProRes 4444 XQ (12-bit), which the SDK has no named constant for.
    static let proRes4444XQ = AVVideoCodecType(rawValue: "ap4x")

    /// Develops camera RAW photos with Core Image at full precision: exposure, shadows, and the
    /// highlights above white rolled off smoothly instead of clipped. Draws into 16-bit frames.
    private struct RawDeveloper {
        let develop: ImageSequence.RawDevelop
        let canvas: Canvas
        private let context = CIContext(options: [.cacheIntermediates: false])
        /// Frames are Rec. 709 video, as the rest of the app treats them.
        private let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

        init(develop: ImageSequence.RawDevelop, canvas: Canvas) {
            self.develop = develop
            self.canvas = canvas
        }

        /// The photo developed, upright and at full size. Non-RAW files in a RAW sequence are read as they are.
        func developed(_ url: URL, scale: Double = 1) throws -> CIImage {
            guard let raw = CIRAWFilter(imageURL: url) else {
                guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                    throw WriteError.unreadable(url.lastPathComponent)
                }
                return image
            }
            raw.scaleFactor = Float(min(1, max(0.01, scale)))
            raw.exposure = Float(min(ImageSequence.RawDevelop.exposureRange.upperBound,
                                     max(ImageSequence.RawDevelop.exposureRange.lowerBound, develop.exposure)))
            raw.boostShadowAmount *= Float(min(ImageSequence.RawDevelop.shadowsRange.upperBound, max(0, develop.shadows)))
            let recovery = Float(min(1, max(0, develop.highlightRecovery)))
            if raw.isHighlightRecoverySupported { raw.isHighlightRecoveryEnabled = recovery > 0 }
            // Detail above white comes out as values over 1, then is rolled off into the picture.
            // The same roll-off for every frame, so a timelapse doesn't flicker.
            raw.extendedDynamicRangeAmount = recovery
            guard var image = raw.outputImage else { throw WriteError.unreadable(url.lastPathComponent) }
            if recovery > 0 {
                image = image.applyingFilter("CIToneMapHeadroom", parameters: [
                    "inputSourceHeadroom": 1 + recovery,
                    "inputTargetHeadroom": 1,
                ])
            }
            return image
        }

        /// Develops `url` and draws it into a frame from `pool`, fitted or filled, over black.
        func draw(_ url: URL, pool: CVPixelBufferPool) throws -> CVPixelBuffer? {
            // The full size first (cheap: nothing is decoded yet), to decode only as big as needed.
            let full = try developed(url).extent
            guard full.width > 0, full.height > 0 else { throw WriteError.unreadable(url.lastPathComponent) }
            let target = canvas.rect(for: full.size)
            let scale = min(1, max(target.width / full.width, target.height / full.height))
            var image = try developed(url, scale: scale)
            let extent = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: target.width / extent.width, y: target.height / extent.height))
                .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)))
            let frame = CGRect(origin: .zero, size: canvas.size)
            image = image.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)

            var made: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
            context.render(image, to: buffer, bounds: frame, colorSpace: space)
            return buffer
        }
    }

    /// The first image's size (upright) and whether it has transparency, for the inspector.
    static func firstImageInfo(_ sequence: ImageSequence) -> (size: CGSize, hasAlpha: Bool)? {
        sequence.imageURLs.first.flatMap(Source.init(url:)).map { ($0.size, $0.hasAlpha) }
    }

    /// One image file: its upright size, read without decoding the picture.
    private struct Source {
        let imageSource: CGImageSource
        /// Upright, after the file's orientation is applied.
        let size: CGSize
        let hasAlpha: Bool

        init?(url: URL) {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return nil }
            self.imageSource = imageSource
            // Orientations 5–8 turn the picture on its side.
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        }

        /// The picture, upright, no bigger on its long side than `maxPixels`.
        func image(maxPixels: CGFloat) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels.rounded(.up))),
            ] as CFDictionary)
        }
    }

    /// Draws each image into a video frame: centered, fitted or filled, over black (or clear,
    /// for images with transparency).
    private struct Canvas {
        let size: CGSize
        let fit: TimelineSettings.Fit
        let opaque: Bool
        /// Frames are Rec. 709 video, as the rest of the app treats them.
        let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

        /// Where an image of `imageSize` goes in the frame.
        func rect(for imageSize: CGSize) -> CGRect {
            let scaleX = size.width / imageSize.width, scaleY = size.height / imageSize.height
            let scale = fit == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
            let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        }

        func draw(_ source: Source, pool: CVPixelBufferPool) -> CVPixelBuffer? {
            var made: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
            let target = rect(for: source.size)
            // Decode only as big as it's drawn (big photos decode much faster this way).
            let longSide = min(max(target.width, target.height), max(source.size.width, source.size.height))
            guard let image = source.image(maxPixels: longSide) else { return nil }

            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            let frame = CGRect(origin: .zero, size: size)
            context.clear(frame)
            if opaque {
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(frame)
            }
            context.interpolationQuality = .high
            context.draw(image, in: target)
            // The encoder takes colors as they are (straight alpha), but drawing leaves them
            // multiplied by their transparency; undone here, or see-through parts come out dark.
            if !opaque { Self.unpremultiply(buffer) }
            return buffer
        }

        /// Divides each pixel's color by its alpha (BGRA, 8 bits).
        static func unpremultiply(_ buffer: CVPixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    let pixel = row + x * 4
                    let alpha = UInt32(pixel[3])
                    guard alpha > 0, alpha < 255 else { continue }
                    for channel in 0..<3 {
                        pixel[channel] = UInt8(min(255, (UInt32(pixel[channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
    }
}
