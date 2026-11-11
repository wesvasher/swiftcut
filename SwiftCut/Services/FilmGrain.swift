import CoreImage

/// Film grain (Effects › Film Grain): fine random speckle over the picture, different on every
/// frame, strongest in the midtones like real film.
nonisolated struct FilmGrain: Hashable, Sendable {
    /// How strong it is, 0…1.
    var amount: Float
    /// How big each grain is: 1 is fine (about a pixel), up to `maxSize` for coarse, old-film grain.
    var size: Float

    static let minSize: Float = 0.5
    static let maxSize: Float = 3
}

/// Draws film grain with Core Image.
nonisolated enum FilmGrainStage {
    /// Adds grain to `image` (covering `extent`). `frame` picks the grain pattern, so each frame
    /// differs but the same frame always looks the same (in the preview and in exports).
    /// `scale` is the picture's size relative to the source (smaller for a lighter preview,
    /// bigger after Enhance), so the grain looks the same at any size.
    static func apply(_ image: CIImage, grain: FilmGrain, frame: Int, scale: Double, extent: CGRect) -> CIImage {
        guard grain.amount > 0, let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }

        // A different part of the endless noise for each frame.
        let offset = Self.offset(forFrame: frame)
        let grainScale = max(0.25, Double(min(FilmGrain.maxSize, max(FilmGrain.minSize, grain.size))) * scale)
        // The noise has random transparency too; made opaque first, or the color step below
        // (which divides by it) turns nearly clear pixels into bright specks.
        var noise = random
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: extent.insetBy(dx: -8, dy: -8))
            .settingAlphaOne(in: extent.insetBy(dx: -8, dy: -8))

        // Gray grain around the middle, so it lightens and darkens evenly. `contrast` is how far it goes.
        let contrast = CGFloat(min(1, max(0, grain.amount))) * 0.8
        noise = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: contrast, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: contrast, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: contrast, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5 - contrast / 2, y: 0.5 - contrast / 2, z: 0.5 - contrast / 2, w: 1),
        ])
        // Bigger grain is softer, as on film.
        if grainScale > 1.2 {
            noise = noise.clampedToExtent().applyingGaussianBlur(sigma: (grainScale - 1) * 0.35)
        }
        noise = noise.cropped(to: extent)

        // Soft light: gray 0.5 changes nothing, so the grain shows most in the midtones. Blended in
        // gamma-encoded values (as the picture is seen), not Core Image's linear ones, where it
        // would brighten the picture.
        let seen = image.applyingFilter("CILinearToSRGBToneCurve")
        return noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: seen])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: extent)
    }

    /// Where frame `frame` reads the noise from: far apart from frame to frame, the same every time.
    static func offset(forFrame frame: Int) -> CGPoint {
        // A simple integer hash, so neighboring frames land far apart.
        var x = UInt64(bitPattern: Int64(frame)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 31
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 29
        return CGPoint(x: Double(x & 0xFFFF) * 7, y: Double((x >> 16) & 0xFFFF) * 7)
    }
}
