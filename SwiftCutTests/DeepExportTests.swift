import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// ProRes 4444 XQ exports, and exports that keep a 10- or 12-bit source's precision.
struct DeepExportTests {
    /// A 12-bit ProRes 4444 XQ video (HD, so it gets HD color) of a very gentle gradient (40% to 42% gray across 1280
    /// pixels): 8 bits can hold only a handful of steps across it, 12 bits dozens.
    static func gentleGradient(in dir: URL) async throws -> URL {
        let url = dir.appending(path: "gradient.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType(rawValue: "ap4x"), AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBALE,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 2
            for y in 0..<720 {
                for x in 0..<1280 {
                    let value = UInt16((0.40 + 0.02 * Double(x) / 1279) * 65535)
                    let p = base + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 65535
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 24))
        await writer.finishWriting()
        return url
    }

    /// The middle row of the first frame's green values, read at 16 bits.
    static func middleRow(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBALE])
        reader.add(output)
        reader.startReading()
        let buffer = try #require(output.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 2
        let row = base + (CVPixelBufferGetHeight(buffer) / 2) * stride
        return (0..<CVPixelBufferGetWidth(buffer)).map { Double(row[$0 * 4 + 1]) }
    }

    /// How far a row is from another on average, in 16-bit units (one 8-bit step is 257).
    static func averageError(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(min(a.count, b.count))
    }

    static let xq = ExportPreset.defaults.first { $0.id == ExportPreset.proRes4444XQID }!

    @Test func thereIsAProRes4444XQPreset() {
        #expect(Self.xq.video?.codec == .proRes4444XQ)
        #expect(Self.xq.container == .mov)
        #expect(ExportPreset.VideoCodec.proRes4444XQ.bitDepth == 12)
        #expect(ExportPreset.VideoCodec.proRes4444XQ.title == "Apple ProRes 4444 XQ")
    }

    @Test @MainActor func unchangedClipsKeepTwelveBits() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await Self.gentleGradient(in: dir)
        let sourceRow = try await Self.middleRow(source)

        let store = ProjectStore(exporter: ExportManager.test("DeepExportTests"))
        let clip = try #require(store.importFiles([source]).first)
        try await ImageSequenceTests.waitUntil { clip.isLoaded }
        #expect(ProjectStore.canExportDirectly(clip, as: Self.xq))

        // Straight from the file, as Export does for a clip with nothing to draw.
        let job = store.exporter.export(asset: AVURLAsset(url: source), name: "direct", preset: Self.xq, folder: dir)
        await job.task?.value
        #expect(job.state == .finished, "\(job.state)")
        let directError = Self.averageError(sourceRow, try await Self.middleRow(job.outputURL))

        // Through SwiftCut's own drawing (as with effects): rounded to 8 bits on the way.
        let built = try await CompositionBuilder.build([.init(url: source, start: 0, end: clip.duration)])
        let drawn = store.exporter.export(asset: built.composition, videoComposition: built.videoComposition,
                                          name: "drawn", preset: Self.xq, folder: dir)
        await drawn.task?.value
        let drawnError = Self.averageError(sourceRow, try await Self.middleRow(drawn.outputURL))

        print("DEEP: average error direct \(directError), through 8-bit drawing \(drawnError) (one 8-bit step is 257)")
        // The direct export stays well inside one 8-bit step of the source; 8 bits can't.
        #expect(directError < drawnError / 2, "\(directError) vs \(drawnError)")
        #expect(directError < 40)
        #expect(try await MediaLoader.bitDepth(#require(AVURLAsset(url: job.outputURL).loadTracks(withMediaType: .video).first?.load(.formatDescriptions).first)) == 12)
    }

    @Test @MainActor func clipsWithEffectsOrOddPixelsAreDrawn() {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.displaySize = CGSize(width: 1920, height: 1080)
        clip.encodedSize = clip.displaySize
        #expect(ProjectStore.canExportDirectly(clip, as: Self.xq))
        // An 8-bit format gains nothing from it.
        #expect(!ProjectStore.canExportDirectly(clip, as: ExportPreset.defaults[0]))
        clip.sharpenPercent = 20
        #expect(!ProjectStore.canExportDirectly(clip, as: Self.xq))
        clip.sharpen = 0
        clip.pixelAspectRatio = CGSize(width: 10, height: 11)
        #expect(!ProjectStore.canExportDirectly(clip, as: Self.xq))
    }

    @Test func savedPresetListsGetTheNewPresetOnce() throws {
        let suite = "DeepExportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A list saved before 4444 XQ existed.
        let old = ExportPreset.defaults.filter { $0.id != ExportPreset.proRes4444XQID }
        defaults.set(try JSONEncoder().encode(old), forKey: "exportPresets")

        let manager = ExportManager(defaults: defaults)
        #expect(manager.preset(id: ExportPreset.proRes4444XQID) != nil)
        // Deleted, it stays deleted.
        manager.deletePresets([ExportPreset.proRes4444XQID])
        #expect(ExportManager(defaults: defaults).preset(id: ExportPreset.proRes4444XQID) == nil)
    }
}
