import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// The Histogram and RGB Parade, and the color details in the File section.
struct ScopesTests {
    /// A 100 × 50 BGRA frame: the left half black, the right half pure red.
    static func blackAndRed() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 100 * 50 * 4)
        for y in 0..<50 {
            for x in 0..<100 {
                let i = (y * 100 + x) * 4
                pixels[i + 3] = 255
                if x >= 50 { pixels[i + 2] = 255 }  // red (BGRA)
            }
        }
        return pixels
    }

    @Test func histogramCountsEachChannel() throws {
        let pixels = Self.blackAndRed()
        let data = try #require(pixels.withUnsafeBufferPointer {
            ScopeAnalysis.analyze(base: $0.baseAddress!, width: 100, height: 50, rowBytes: 400)
        })
        let (red, green, blue, luma) = (data.histogram[0], data.histogram[1], data.histogram[2], data.histogram[3])
        // Half the red channel is at 0 and half at 255; green and blue are all at 0.
        #expect(red[0] > 0 && red[255] > 0 && red[128] == 0)
        #expect(green[255] == 0 && blue[255] == 0 && green[0] > 0)
        // Pure red is about 21% bright (Rec. 709).
        #expect(luma[54] > 0 || luma[55] > 0)
        #expect(luma[255] == 0)
        #expect(data.histogram.allSatisfy { $0.count == 256 && $0.allSatisfy { (0...1).contains($0) } })
    }

    @Test func paradeShowsRedOnTheRightHalfOnly() throws {
        let pixels = Self.blackAndRed()
        let data = try #require(pixels.withUnsafeBufferPointer {
            ScopeAnalysis.analyze(base: $0.baseAddress!, width: 100, height: 50, rowBytes: 400)
        })
        let parade = try #require(data.parade)
        #expect(parade.height == ScopeAnalysis.paradeLevels)
        // Read it back: the red panel's top row (level 255) is lit on its right half only.
        let width = parade.width
        var rgba = [UInt8](repeating: 0, count: width * parade.height * 4)
        let context = CGContext(data: &rgba, width: width, height: parade.height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(parade, in: CGRect(x: 0, y: 0, width: width, height: parade.height))
        func alpha(x: Int, row: Int) -> UInt8 { rgba[(row * width + x) * 4 + 3] }
        #expect(alpha(x: 75, row: 0) > 0, "red at the top on the right")
        #expect(alpha(x: 25, row: 0) == 0, "no red at the top on the left")
        #expect(alpha(x: 25, row: parade.height - 1) > 0, "red at the bottom on the left")
        // The green panel (after the red one and a gap) has nothing at the top.
        let gap = max(2, 100 / 40)
        #expect(alpha(x: 100 + gap + 75, row: 0) == 0)
    }

    @Test func clippingIsMeasured() throws {
        // Black and red: every pixel has a channel at 0 (shadows clipped), half have one at 255.
        let pixels = Self.blackAndRed()
        let data = try #require(pixels.withUnsafeBufferPointer {
            ScopeAnalysis.analyze(base: $0.baseAddress!, width: 100, height: 50, rowBytes: 400)
        })
        #expect(data.clippedShadows == 1)
        #expect(data.clippedHighlights == 0.5)

        // Mid gray clips nothing.
        let gray = [UInt8](repeating: 128, count: 10 * 10 * 4)
        let mid = try #require(gray.withUnsafeBufferPointer {
            ScopeAnalysis.analyze(base: $0.baseAddress!, width: 10, height: 10, rowBytes: 40)
        })
        #expect(mid.clippedShadows == 0 && mid.clippedHighlights == 0)
    }

    @Test @MainActor func scopesFollowAPausedClip() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "gray", seconds: 1, size: CGSize(width: 320, height: 240), codec: .proRes422) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 200, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        let controller = ClipPlayerController()
        controller.load(clip)
        let tap = ScopeTap()
        tap.follow(controller.player)
        // Paused the whole time: the tap has to ask for the frame itself.
        let deadline = Date().addingTimeInterval(10)
        while tap.data == nil, Date() < deadline {
            tap.tick()
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = try #require(tap.data)
        // A light gray frame: the brightness peaks near the light end.
        let peak = try #require(data.histogram[3].indices.max { data.histogram[3][$0] < data.histogram[3][$1] })
        #expect(peak > 170 && peak < 230, "\(peak)")
    }

    @Test @MainActor func colorDetailsFromTheFile() async throws {
        // Image sequence videos are tagged Rec. 709 ProRes 422 HQ (10-bit).
        let (dir, _) = try ImageSequenceTests.folder(count: 2)
        let store = ProjectStore(exporter: ExportManager.test("ScopesTests"))
        let imported = try #require(store.importImages(folders: [dir], images: [], asSequence: true).first)
        try await ImageSequenceTests.waitUntil { store.clip(for: imported.id)?.isLoaded == true }
        let clip = try #require(store.clip(for: imported.id))
        #expect(clip.colorPrimaries == "Rec. 709")
        #expect(clip.transferFunction == "Rec. 709")
        #expect(clip.colorMatrix == "Rec. 709")
        #expect(clip.bitDepth == 10)
        try? FileManager.default.removeItem(at: clip.url)
        store.removeClips([clip.id])
    }

    @Test(.enabled(if: RawImportTests.hasSample, "Needs a camera RAW in the test folder"))
    @MainActor func rawSequencesAreTwelveBit() async throws {
        var still = ImageSequence(name: "raw", imagePaths: [RawImportTests.sample.path(percentEncoded: false)])
        still.stillDuration = 0.2
        still.frameSize = .init(width: 300, height: 200)
        let url = try await RawImportTests.write(still, name: "depth")
        let clip = Clip(url: url)
        await MediaLoader.load(clip)
        #expect(clip.bitDepth == 12)
        #expect(clip.videoCodec == "Apple ProRes 4444 XQ")
        #expect(!clip.hasAlpha)
    }
}
