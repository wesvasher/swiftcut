import AVFoundation
import CoreGraphics
import Observation

/// What the scopes show for one frame.
nonisolated struct ScopeData: Sendable {
    /// Red, green, blue, and brightness (luma): 256 levels each, 0…1 on a square-root scale of
    /// the busiest level.
    var histogram: [[Float]]
    /// The RGB parade: red, green, and blue side by side, each column of the picture with its
    /// levels from bottom (0) to top (255), brighter where more pixels sit.
    var parade: CGImage?
    /// How much of the picture is clipped: any channel at full black (shadows) or full white
    /// (highlights), 0…1.
    var clippedShadows = 0.0
    var clippedHighlights = 0.0

    /// More than this much clipped shows as a warning.
    static let clipWarning = 0.005
}

/// Works out the scopes for a frame. Small frames (a few hundred pixels across) are plenty.
nonisolated enum ScopeAnalysis {
    /// Levels (rows) in the parade.
    static let paradeLevels = 128

    /// The scopes for an 8-bit BGRA frame.
    static func analyze(_ buffer: CVPixelBuffer) -> ScopeData? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return analyze(base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                       rowBytes: CVPixelBufferGetBytesPerRow(buffer))
    }

    /// The scopes for BGRA pixels.
    static func analyze(base: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> ScopeData? {
        guard width > 0, height > 0 else { return nil }
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        let levels = paradeLevels
        // [channel][column][level]
        var parade = [Int](repeating: 0, count: 3 * width * levels)
        var shadows = 0, highlights = 0

        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                let pixel = row + x * 4
                let b = Int(pixel[0]), g = Int(pixel[1]), r = Int(pixel[2])
                if r == 0 || g == 0 || b == 0 { shadows += 1 }
                if r == 255 || g == 255 || b == 255 { highlights += 1 }
                bins[0][r] += 1
                bins[1][g] += 1
                bins[2][b] += 1
                // Rec. 709 brightness, on the gamma-encoded values (as video scopes show it).
                bins[3][(2126 * r + 7152 * g + 722 * b + 5000) / 10000] += 1
                parade[(0 * width + x) * levels + r * levels / 256] += 1
                parade[(1 * width + x) * levels + g * levels / 256] += 1
                parade[(2 * width + x) * levels + b * levels / 256] += 1
            }
        }

        // The very ends often hold far more (clipped black or white); scale to the busiest level
        // in between so the rest stays readable, and let the ends run off the top. Red, green,
        // and blue share one scale so they can be compared; brightness has its own.
        let colorPeak = max(1, (0..<3).compactMap { bins[$0][1..<255].max() }.max() ?? 1)
        let lumaPeak = max(1, bins[3][1..<255].max() ?? 1)
        let histogram = bins.enumerated().map { channel, counts -> [Float] in
            let peak = Float(channel < 3 ? colorPeak : lumaPeak)
            // Square root, so a few tall spikes don't flatten the rest.
            return counts.map { min(1, (Float($0) / peak).squareRoot()) }
        }
        let total = Double(width * height)
        return ScopeData(histogram: histogram, parade: paradeImage(parade, width: width, height: height),
                         clippedShadows: Double(shadows) / total, clippedHighlights: Double(highlights) / total)
    }

    /// Draws the parade: each channel in its own color, a gap between them.
    static func paradeImage(_ counts: [Int], width: Int, height: Int) -> CGImage? {
        let levels = paradeLevels, gap = max(2, width / 40)
        let imageWidth = width * 3 + gap * 2
        var pixels = [UInt8](repeating: 0, count: imageWidth * levels * 4)
        let colors: [(Double, Double, Double)] = [(1, 0.25, 0.25), (0.3, 1, 0.35), (0.35, 0.55, 1)]
        // Brightness follows the count on a log scale, so a few pixels still show.
        let full = log(1 + Double(max(1, height)) / 3)
        for channel in 0..<3 {
            let (red, green, blue) = colors[channel]
            for x in 0..<width {
                for level in 0..<levels {
                    let count = counts[(channel * width + x) * levels + level]
                    guard count > 0 else { continue }
                    let strength = min(1, 0.25 + 0.75 * log(1 + Double(count)) / full)
                    let column = channel * (width + gap) + x
                    let row = levels - 1 - level
                    let index = (row * imageWidth + column) * 4
                    pixels[index] = UInt8(255 * red * strength)
                    pixels[index + 1] = UInt8(255 * green * strength)
                    pixels[index + 2] = UInt8(255 * blue * strength)
                    pixels[index + 3] = UInt8(255 * strength)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: imageWidth, height: levels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: imageWidth * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Reads small frames from whichever player the scopes are following (the clip viewer's or the
/// timeline's) and works out their scopes. Adds its own scaled-down video output to the player's
/// item, so it sees what's on screen, effects and all, without slowing the player.
@MainActor
@Observable
final class ScopeTap {
    private(set) var data: ScopeData?

    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private weak var tappedItem: AVPlayerItem?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var isAnalyzing = false
    @ObservationIgnored private var askedForFrame = false

    /// The frames are scaled to this size first; scopes don't need more.
    static let frameSize = CGSize(width: 320, height: 180)

    func follow(_ player: AVPlayer?) {
        guard player !== self.player else { return }
        detach()
        self.player = player
        data = nil
    }

    /// Reads the newest frame, if there's one, and updates the scopes. Called a dozen times a second.
    func tick() {
        guard let player, let item = player.currentItem else {
            detach()
            return
        }
        if item !== tappedItem {
            detach()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(Self.frameSize.width),
                kCVPixelBufferHeightKey as String: Int(Self.frameSize.height),
            ])
            item.add(output)
            self.output = output
            tappedItem = item
            askedForFrame = false
        }
        guard let output, !isAnalyzing else { return }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            // Paused right after starting to follow: nothing new comes until the player draws
            // again, so ask it to draw this frame once more.
            if player.rate == 0, !askedForFrame, item.status == .readyToPlay {
                askedForFrame = true
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }
        isAnalyzing = true
        let frame = SendableBuffer(buffer: buffer)
        Task {
            let result = await Task.detached(priority: .utility) { ScopeAnalysis.analyze(frame.buffer) }.value
            isAnalyzing = false
            if let result { data = result }
        }
    }

    private func detach() {
        if let output, let tappedItem { tappedItem.remove(output) }
        output = nil
        tappedItem = nil
    }
}

/// A frame handed to the background for analysis; nothing else uses it meanwhile.
nonisolated private struct SendableBuffer: @unchecked Sendable { let buffer: CVPixelBuffer }
