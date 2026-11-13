import CoreImage
import Foundation

/// Where a source video's picture sits in its frame: made smaller or larger and moved (the
/// inspector's Video section), over a background (the Background section): transparent, shown
/// as a checkerboard in the viewer, or a color. The background also shows through a clip's own
/// transparency. The frame itself keeps its size. Subclips share it, like color.
nonisolated struct FrameLayout: Codable, Hashable, Sendable {
    enum Background: String, Codable, Hashable, Sendable {
        case color
        /// Clear: only files that keep transparency (ProRes 4444) show through.
        case transparent
    }

    /// 1 fills the frame as before; 0.5 is half the width and height.
    var scale = 1.0
    /// How far the picture's middle moves from the frame's middle, as a fraction of the frame's
    /// width and height. Positive X is right, positive Y is up.
    var offsetX = 0.0
    var offsetY = 0.0
    var background = Background.transparent
    var backgroundColor = RGBAColor.black

    static let scaleRange = 0.1...4.0

    /// Fills the frame exactly, so nothing changes.
    var isIdentity: Bool { scale == 1 && offsetX == 0 && offsetY == 0 }

    init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0,
         background: Background = .transparent, backgroundColor: RGBAColor = .black) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.background = background
        self.backgroundColor = backgroundColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? .transparent
        backgroundColor = try c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor) ?? .black
    }
}

/// A color that can be saved (sRGB, 0…1).
nonisolated struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha = 1.0

    static let black = RGBAColor(red: 0, green: 0, blue: 0)

    static func gray(_ level: Double) -> RGBAColor { RGBAColor(red: level, green: level, blue: level) }

    /// The Background section's swatches, darkest first. Pure black and white are there, but
    /// video usually looks better a little off them: "video black" and "video white" are the
    /// darkest and lightest levels broadcast video uses (16 and 235 of 255).
    static let backgroundSwatches: [(name: String, color: RGBAColor)] = [
        ("Black", .gray(0)),
        ("Video Black (6%)", .gray(16.0 / 255)),
        ("Charcoal (20%)", .gray(0.2)),
        ("Middle Gray (50%)", .gray(0.5)),
        ("Light Gray (80%)", .gray(0.8)),
        ("Video White (92%)", .gray(235.0 / 255)),
        ("White", .gray(1)),
    ]

    /// Its swatch's name, or "Custom".
    var swatchName: String {
        Self.backgroundSwatches.first { $0.color.isClose(to: self) }?.name ?? "Custom"
    }

    /// Equal to the eye: within half a step of 255 in each channel.
    func isClose(to other: RGBAColor) -> Bool {
        abs(red - other.red) < 0.002 && abs(green - other.green) < 0.002 && abs(blue - other.blue) < 0.002
            && abs(alpha - other.alpha) < 0.002
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `nil` when the color can't be expressed in sRGB.
    init?(_ color: CGColor) {
        guard let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3 else { return nil }
        self.init(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]),
                  alpha: parts.count > 3 ? Double(parts[3]) : 1)
    }
}

/// The framing the preview shows, changed without rebuilding it while a slider moves.
/// Exports get one holding the clip's settings.
nonisolated final class LiveLayout: @unchecked Sendable {
    private let lock = NSLock()
    private var layout: FrameLayout
    /// Shows transparency as a checkerboard (the viewer), rather than leaving it clear (exports).
    let showsCheckerboard: Bool

    init(_ layout: FrameLayout = FrameLayout(), showsCheckerboard: Bool = false) {
        self.layout = layout
        self.showsCheckerboard = showsCheckerboard
    }

    var value: FrameLayout {
        get { lock.withLock { layout } }
        set { lock.withLock { layout = newValue } }
    }
}

/// Places a frame's picture according to its `FrameLayout`.
nonisolated enum FrameLayoutStage {
    /// `image` fills `frame`; the result is the same size, with the picture scaled and moved.
    static func apply(_ image: CIImage, layout: FrameLayout, frame: CGRect, checkerboard: Bool) -> CIImage {
        let w = frame.width, h = frame.height
        let scale = min(FrameLayout.scaleRange.upperBound, max(FrameLayout.scaleRange.lowerBound, layout.scale))
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: frame.midX + layout.offsetX * w,
                                                 y: frame.midY + layout.offsetY * h)))
        let back = background(layout, frame: frame, checkerboard: checkerboard)
        // Laid over the background in gamma-encoded values, as design apps and other video apps
        // do and as transparency in graphics is made for. (In Core Image's linear values,
        // half-transparent white over black would come out much lighter than in Preview.)
        return placed.applyingFilter("CILinearToSRGBToneCurve")
            .composited(over: back.applyingFilter("CILinearToSRGBToneCurve"))
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: frame)
    }

    private static func background(_ layout: FrameLayout, frame: CGRect, checkerboard: Bool) -> CIImage {
        switch layout.background {
        case .color:
            let color = layout.backgroundColor
            return CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
                .cropped(to: frame)
        case .transparent:
            guard checkerboard else { return CIImage.clear.cropped(to: frame) }
            let filter = CIFilter(name: "CICheckerboardGenerator")!
            filter.setValue(CIVector(x: frame.minX, y: frame.minY), forKey: kCIInputCenterKey)
            filter.setValue(CIColor(red: 0.42, green: 0.42, blue: 0.42), forKey: "inputColor0")
            filter.setValue(CIColor(red: 0.30, green: 0.30, blue: 0.30), forKey: "inputColor1")
            filter.setValue(max(3, frame.height / 30), forKey: kCIInputWidthKey)
            filter.setValue(1, forKey: kCIInputSharpnessKey)
            return (filter.outputImage ?? CIImage.clear).cropped(to: frame)
        }
    }
}
