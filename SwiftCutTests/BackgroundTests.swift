import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// The Background section: what shows in transparent areas of a clip.
struct BackgroundTests {
    /// A half-transparent white still, made into a ProRes 4444 video with alpha.
    static func transparentClip() async throws -> URL {
        let dir = try TestVideo.tempDirectory()
        let png = try ImageSequenceTests.png(in: dir, name: "half.png", size: CGSize(width: 320, height: 240), gray: 1, alpha: 0.5)
        var still = ImageSequence(name: "half", imagePaths: [png.path(percentEncoded: false)])
        still.stillDuration = 1
        let out = dir.appending(path: "half.mov")
        try await BlockingWork.run { [still] _ in try ImageSequenceWriter.write(still, to: out) }
        return out
    }

    /// The middle pixel of a video's frame at 0.5 s, as 0…255 RGB.
    static func middlePixel(_ url: URL) async throws -> (r: Int, g: Int, b: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test @MainActor func transparencyIsFoundAndAColorShowsThrough() async throws {
        let url = try await Self.transparentClip()
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        #expect(clip.hasAlpha)
        // Transparent clips go through the background step even at full size.
        #expect(clip.enhanceSettings.layout != nil)

        clip.layout.background = .color
        clip.layout.backgroundColor = RGBAColor(red: 1, green: 0, blue: 0)
        let dir = url.deletingLastPathComponent()
        let job = try await EnhanceTests.export(url, clip.enhanceSettings, to: dir, name: "on-red")
        #expect(job.state == .finished, "\(job.state)")
        let pixel = try await Self.middlePixel(job.outputURL)
        // Half white over red: red stays full, green and blue come halfway up, as in Preview.
        #expect(pixel.r > 240, "\(pixel)")
        #expect(pixel.g > 110 && pixel.g < 170, "\(pixel)")
        #expect(abs(pixel.g - pixel.b) < 8, "\(pixel)")
    }

    @Test @MainActor func opaqueClipsSkipTheBackgroundAtFullSize() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "opaque", seconds: 1, size: CGSize(width: 320, height: 240))
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        #expect(!clip.hasAlpha)
        #expect(clip.enhanceSettings.layout == nil)
        clip.layout.scale = 0.5
        #expect(clip.enhanceSettings.layout != nil)
    }

    @Test func transparentIsTheDefault() throws {
        #expect(FrameLayout().background == .transparent)
        // Saved layouts keep the choice they were saved with.
        var black = FrameLayout(scale: 0.5)
        black.background = .color
        let decoded = try JSONDecoder().decode(FrameLayout.self, from: JSONEncoder().encode(black))
        #expect(decoded.background == .color)
    }

    @Test func swatches() {
        let names = RGBAColor.backgroundSwatches.map(\.name)
        #expect(names.first == "Black" && names.last == "White")
        // Video black and white are 16 and 235 of 255.
        let videoBlack = RGBAColor.backgroundSwatches[1].color
        #expect(abs(videoBlack.red * 255 - 16) < 0.01)
        #expect(RGBAColor.gray(235.0 / 255).swatchName == "Video White (92%)")
        #expect(RGBAColor(red: 1, green: 0, blue: 0).swatchName == "Custom")
        // Lightest last, so they read as a scale.
        let levels = RGBAColor.backgroundSwatches.map(\.color.red)
        #expect(levels == levels.sorted())
    }
}
