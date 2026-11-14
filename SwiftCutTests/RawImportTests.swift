import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// Camera RAW photos in image sequences: developed at full precision, highlights recovered,
/// written as 12-bit ProRes 4444 XQ.
struct RawImportTests {
    /// A real camera RAW (a Sony a6600 .ARW), if one has been put in the test folder. There's
    /// no way to make a RAW file here, so these tests are skipped without one.
    nonisolated static let sample = FileManager.default.temporaryDirectory.appending(path: "raw-sample/DSC09989.ARW")
    nonisolated static var hasSample: Bool { FileManager.default.fileExists(atPath: sample.path(percentEncoded: false)) }

    /// How much of a frame is pure white (clipped), its middle and darkest-tenth brightness, and the video's codec.
    static func measure(_ url: URL) async throws -> (clipped: Double, median: Double, shadows: Double, codec: String) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        let context = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let clipped = Double(gray.filter { $0 >= 254 }.count) / Double(gray.count)
        let sorted = gray.sorted()
        return (clipped, Double(sorted[sorted.count / 2]), Double(sorted[sorted.count / 10]),
                MediaLoader.codecName(CMFormatDescriptionGetMediaSubType(format)))
    }

    static func write(_ sequence: ImageSequence, name: String) async throws -> URL {
        let out = try TestVideo.tempDirectory().appending(path: "\(name).mov")
        try await BlockingWork.run { [sequence] _ in try ImageSequenceWriter.write(sequence, to: out) }
        return out
    }

    @Test(.enabled(if: RawImportTests.hasSample, "Needs a camera RAW in the test folder"))
    func highlightsAreRecoveredInsteadOfClipped() async throws {
        var still = ImageSequence(name: "raw", imagePaths: [Self.sample.path(percentEncoded: false)])
        #expect(still.raw == ImageSequence.RawDevelop())
        still.stillDuration = 0.2
        still.frameSize = .init(width: 750, height: 500)

        // The camera's look, as before: highlights clipped.
        var clipping = still
        clipping.raw?.highlightRecovery = 0
        let before = try await Self.measure(try await Self.write(clipping, name: "clipped"))
        // Full recovery.
        let after = try await Self.measure(try await Self.write(still, name: "recovered"))
        print("RAW: clipped \(before.clipped * 100)% → \(after.clipped * 100)%, median \(before.median) → \(after.median), \(after.codec)")

        #expect(after.codec == "Apple ProRes 4444 XQ")
        // Much less of the picture is stuck at pure white…
        #expect(after.clipped < before.clipped / 4, "\(before.clipped) → \(after.clipped)")
        // …while the picture stays about as bright.
        #expect(abs(after.median - before.median) < 30, "\(before.median) → \(after.median)")
    }

    @Test(.enabled(if: RawImportTests.hasSample, "Needs a camera RAW in the test folder"))
    func exposureAndShadowsChangeThePicture() async throws {
        var still = ImageSequence(name: "raw", imagePaths: [Self.sample.path(percentEncoded: false)])
        still.stillDuration = 0.2
        still.frameSize = .init(width: 300, height: 200)
        let normal = try await Self.measure(try await Self.write(still, name: "normal"))
        still.raw?.exposure = -1
        let darker = try await Self.measure(try await Self.write(still, name: "darker"))
        #expect(darker.median < normal.median - 15, "\(normal.median) → \(darker.median)")
        still.raw?.exposure = 0
        still.raw?.shadows = 0
        let flatShadows = try await Self.measure(try await Self.write(still, name: "noshadows"))
        print("RAW shadows: darkest tenth \(normal.shadows) → \(flatShadows.shadows)")
        #expect(flatShadows.shadows < normal.shadows - 3, "\(normal.shadows) → \(flatShadows.shadows)")
    }

    @Test func rawPhotosGetDevelopSettings() throws {
        #expect(ImageSequence(name: "a", imagePaths: ["/x/DSC0001.ARW"]).raw != nil)
        #expect(ImageSequence(name: "a", imagePaths: ["/x/IMG_1.CR3", "/x/IMG_2.CR3"]).raw != nil)
        #expect(ImageSequence(name: "a", imagePaths: ["/x/photo.dng"]).raw != nil)
        #expect(ImageSequence(name: "a", imagePaths: ["/x/frame1.png"]).raw == nil)

        // Each setting makes a new video.
        let sequence = ImageSequence(name: "a", imagePaths: ["/x/DSC0001.ARW", "/x/DSC0002.ARW"])
        for change: (inout ImageSequence) -> Void in [
            { $0.raw?.exposure = 0.5 }, { $0.raw?.highlightRecovery = 0.5 }, { $0.raw?.shadows = 1.5 },
        ] {
            var changed = sequence
            change(&changed)
            #expect(changed.videoURL != sequence.videoURL)
        }
    }

    @Test func rawSequencesSavedBeforeThisAreDeveloped() throws {
        // A project from before RAW development: no "raw" saved.
        let old = try JSONDecoder().decode(ImageSequence.self, from: Data(#"{"name":"a","imagePaths":["/x/DSC0001.ARW"]}"#.utf8))
        #expect(old.raw == ImageSequence.RawDevelop())
        let png = try JSONDecoder().decode(ImageSequence.self, from: Data(#"{"name":"a","imagePaths":["/x/a.png"]}"#.utf8))
        #expect(png.raw == nil)

        var tuned = ImageSequence(name: "a", imagePaths: ["/x/DSC0001.ARW"])
        tuned.raw = .init(exposure: 0.7, highlightRecovery: 0.4, shadows: 1.3)
        let decoded = try JSONDecoder().decode(ImageSequence.self, from: JSONEncoder().encode(tuned))
        #expect(decoded.raw == tuned.raw)
    }

    @Test func stepsStayOnTheGrid() {
        var value = 0.0
        var shown: [Double] = []
        for _ in 0..<3 {
            value = (NumberStepper.stepped(value, 1, by: 1.0 / 3) * 100).rounded() / 100
            shown.append(value)
        }
        #expect(shown == [0.33, 0.67, 1])
        // And back down again.
        for _ in 0..<3 {
            value = (NumberStepper.stepped(value, -1, by: 1.0 / 3) * 100).rounded() / 100
        }
        #expect(value == 0)
        #expect(NumberStepper.stepped(0.5, 1, by: 1.0 / 3) * 3 == 2)
        #expect(abs(NumberStepper.stepped(0.5, -1, by: 1.0 / 3) - 1.0 / 3) < 1e-9)
        #expect(NumberStepper.stepped(45, 1, by: 10) == 50)
        #expect(NumberStepper.stepped(45, -1, by: 10) == 40)
    }
}
