import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// With effects on, every frame must show its own picture, in the preview and in exports.
/// (The effects reuse their buffers from frame to frame, so a stale picture would show here.)
struct EffectsFrameTests {
    /// A clip that gets brighter every frame: frame n is gray level 20 + 6n.
    static func rampClip() async throws -> URL {
        let dir = try TestVideo.tempDirectory()
        return try await TestVideo.make(in: dir, name: "ramp", seconds: 1, size: CGSize(width: 320, height: 240)) { frame, pixels in
            let level = UInt8(min(255, 20 + 6 * frame))
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: CVPixelBufferGetDataSize(pixels), by: 4) {
                base[i] = level; base[i + 1] = level; base[i + 2] = level; base[i + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }

    /// Brightness (0…255) at the center of the frame at `seconds`.
    static func brightness(_ asset: AVAsset, _ composition: AVVideoComposition?, at seconds: Double) async throws -> Double {
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!,
                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[1])
    }

    static let times = [0.1, 0.4, 0.7, 0.9]

    /// Each later time must be clearly brighter than the one before.
    static func expectRising(_ levels: [Double], _ label: String) {
        for (earlier, later) in zip(levels, levels.dropFirst()) {
            #expect(later > earlier + 20, "\(label): \(levels)")
        }
    }

    static let settings = EnhanceSettings(grade: ColorGrade(contrast: 0.0001))

    @Test func timelineScrubbingShowsEachFrame() async throws {
        let url = try await Self.rampClip()
        let built = try await CompositionBuilder.build([.init(url: url, start: 0, end: 1, settings: Self.settings)])
        var levels: [Double] = []
        // Scrub forward, then back to the start: each must match its own moment.
        for time in Self.times + [0.1] {
            levels.append(try await Self.brightness(built.composition, built.videoComposition, at: time))
        }
        Self.expectRising(Array(levels.prefix(Self.times.count)), "timeline")
        #expect(abs(levels.last! - levels.first!) < 8, "back at the start: \(levels)")
    }

    @Test func clipScrubbingShowsEachFrame() async throws {
        let url = try await Self.rampClip()
        let playable = try await Enhancer.makePlayable(url: url, settings: Self.settings)
        var levels: [Double] = []
        for time in Self.times {
            levels.append(try await Self.brightness(playable.asset, playable.videoComposition, at: time))
        }
        Self.expectRising(levels, "clip")
    }

    @Test func timelineExportHasEachFrame() async throws {
        let url = try await Self.rampClip()
        let built = try await CompositionBuilder.build([.init(url: url, start: 0, end: 1, settings: Self.settings)])
        let manager = ExportManager.test()
        let job = manager.export(asset: built.composition, videoComposition: built.videoComposition, name: "ramp",
                                 preset: .builtIn("ProRes 422"), folder: try TestVideo.tempDirectory())
        await job.task?.value
        #expect(job.state == .finished, "\(job.state)")
        let exported = AVURLAsset(url: job.outputURL)
        var levels: [Double] = []
        for time in Self.times {
            levels.append(try await Self.brightness(exported, nil, at: time))
        }
        Self.expectRising(levels, "export")
    }
    /// Brightness of what an `AVPlayer` shows after seeking to each time, like scrubbing the timeline.
    @MainActor static func playerLevels(_ asset: AVAsset, _ composition: AVVideoComposition?, times: [Double]) async throws -> [Double] {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        for _ in 0..<100 where item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
        var levels: [Double] = []
        for time in times {
            player.pause()
            let target = CMTime(seconds: time, preferredTimescale: 600)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            // Wait for the frame drawn for this seek (up to 2 seconds).
            var buffer: CVPixelBuffer?
            for _ in 0..<100 {
                if output.hasNewPixelBuffer(forItemTime: target) {
                    var shown = CMTime.invalid
                    let candidate = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &shown)
                    // Skip a leftover frame from before the seek.
                    if candidate != nil, abs(shown.seconds - time) < 0.04 { buffer = candidate; break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let buffer else { levels.append(-1); continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let center = (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer) + (CVPixelBufferGetWidth(buffer) / 2) * 4
            levels.append(Double(base[center + 1]))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return levels
    }

    @Test(arguments: [1, 4]) @MainActor func timelinePlayerFollowsSeeks(divisor: Int) async throws {
        let url = try await Self.rampClip()
        let built = try await CompositionBuilder.build([.init(url: url, start: 0, end: 1, settings: Self.settings)],
                                                       previewDivisor: divisor)
        let levels = try await Self.playerLevels(built.composition, built.videoComposition, times: Self.times + [0.1])
        print("player levels (divisor \(divisor)): \(levels)")
        Self.expectRising(Array(levels.prefix(Self.times.count)), "player 1/\(divisor)")
        #expect(abs(levels.last! - levels.first!) < 8, "back at the start: \(levels)")
    }

    @Test @MainActor func timelinePlayerWithoutEffectsFollowsSeeks() async throws {
        let url = try await Self.rampClip()
        let built = try await CompositionBuilder.build([.init(url: url, start: 0, end: 1)])
        let levels = try await Self.playerLevels(built.composition, built.videoComposition, times: Self.times)
        print("player levels (no effects): \(levels)")
        Self.expectRising(levels, "player, no effects")
    }
}
