import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

/// The Develop RAW dialog: opening it on import and from a clip, its preview, output formats,
/// and the clips it makes.
struct RawDeveloperTests {
    static func rawSequence(name: String = "clicker") -> ImageSequence {
        ImageSequence(name: name, imagePaths: ["/x/DSC0001.ARW", "/x/DSC0002.ARW"])
    }

    @Test @MainActor func createClipAppliesTheSettings() throws {
        let store = ProjectStore(exporter: ExportManager.test("RawDeveloperTests"))
        let request = RawDevelopRequest(sequences: [Self.rawSequence()])
        store.requestRawDevelop(request)
        #expect(store.rawDevelopRequest?.id == request.id)

        var settings = RawDevelopSettings(from: request.sequences[0])
        #expect(settings.format == .proRes4444XQ)
        settings.develop = .init(exposure: -1, highlightRecovery: 0.5, shadows: 1.5)
        settings.format = .hevc10
        settings.frameSize = .init(width: 3840, height: 2160)
        settings.frameRate = 30
        let clips = store.finishRawDevelop(request, settings: settings)

        #expect(store.rawDevelopRequest == nil)
        let sequence = try #require(clips.first?.imageSequence)
        #expect(sequence.raw == settings.develop)
        #expect(sequence.outputFormat == .hevc10)
        #expect(sequence.frameSize == .init(width: 3840, height: 2160) && !sequence.isCustomSize)
        #expect(sequence.frameRate == 30)
        #expect(sequence.name == "clicker")
        #expect(store.selection == [.clip(clips[0].id)])
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test @MainActor func newClipFromAnExistingOneKeepsTheOld() throws {
        let store = ProjectStore(exporter: ExportManager.test("RawDeveloperTests"))
        let original = store.addSequences([Self.rawSequence()])[0]
        store.developNewClip(from: original)
        let request = try #require(store.rawDevelopRequest)
        #expect(request.isNewVersion)

        var settings = RawDevelopSettings(from: request.sequences[0])
        settings.develop.exposure = 0.67
        let first = store.finishRawDevelop(request, settings: settings)
        #expect(first[0].name == "clicker (Developed)")
        let second = store.finishRawDevelop(request, settings: settings)
        #expect(second[0].name == "clicker (Developed 2)")
        // The original is still there, as it was.
        #expect(store.clip(for: original.id)?.imageSequence?.raw == ImageSequence.RawDevelop())
        #expect(store.clips.count == 3)
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test @MainActor func droppingRawPhotosOpensTheDialog() async throws {
        let store = ProjectStore(exporter: ExportManager.test("RawDeveloperTests"))
        let raw = URL(filePath: "/x/DSC0001.ARW")
        store.pendingImageImport = PendingImageImport(folders: [], images: [raw], timelineIndex: 2)
        store.finishImageImport(asSequence: true)
        // Nothing is added yet; the dialog opens once the import sheet has closed.
        #expect(store.clips.isEmpty)
        try await ImageSequenceTests.waitUntil(seconds: 3) { store.rawDevelopRequest != nil }
        let request = try #require(store.rawDevelopRequest)
        #expect(request.timelineIndex == 2)
        #expect(request.imageURLs == [raw])
        store.cancelRawDevelop()
        #expect(store.rawDevelopRequest == nil && store.clips.isEmpty)
    }

    @Test @MainActor func otherImagesSkipTheDialog() throws {
        let (dir, _) = try ImageSequenceTests.folder(count: 2)
        let store = ProjectStore(exporter: ExportManager.test("RawDeveloperTests"))
        store.pendingImageImport = PendingImageImport(folders: [dir], images: [], timelineIndex: nil)
        store.finishImageImport(asSequence: true)
        #expect(store.clips.count == 1)
        #expect(store.rawDevelopRequest == nil)
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test func formatsAndEstimates() {
        #expect(ImageSequence.OutputFormat.allCases.count == 8)
        #expect(ImageSequence.OutputFormat.proRes4444XQ.bitDepth == 12)
        #expect(ImageSequence.OutputFormat.hevc10.bitDepth == 10)
        #expect(ImageSequence.OutputFormat.h264.bitDepth == 8)
        // ProRes 422 HQ at 1080p30 is about 220 Mb/s: about 27.5 MB a second.
        let hq = ImageSequence.OutputFormat.proRes422HQ.estimatedBytes(frameSize: CGSize(width: 1920, height: 1080), fps: 29.97, seconds: 1)
        #expect(abs(hq - 27_500_000) < 10_000)
        // Bigger frames, bigger files; compressed is smallest.
        let sizes = ImageSequence.OutputFormat.allCases.map { $0.estimatedBytes(frameSize: CGSize(width: 3840, height: 2160), fps: 24, seconds: 10) }
        #expect(sizes.dropFirst(2) == sizes.dropFirst(2).sorted()[...])
        #expect(sizes[1] < sizes[0])

        // A chosen format makes a new video; automatic keeps the old address.
        var sequence = Self.rawSequence()
        let automatic = sequence.videoURL
        #expect(sequence.format(hasAlpha: false) == .proRes4444XQ)
        sequence.outputFormat = .proRes422HQ
        #expect(sequence.videoURL != automatic)
    }

    @Test func filmstripSpacesOutLongSequences() {
        #expect(RawDeveloperSheet.shownIndexes(count: 5, width: 600) == [0, 1, 2, 3, 4])
        let shown = RawDeveloperSheet.shownIndexes(count: 400, width: 560)
        #expect(shown.count == 10)
        #expect(shown.first! < 40 && shown.last! > 360 && shown == shown.sorted())
    }

    // MARK: With a real RAW

    @Test(.enabled(if: RawImportTests.hasSample, "Needs a camera RAW in the test folder"))
    func previewMatchesTheDevelopment() throws {
        let normal = try ImageSequenceWriter.preview(RawImportTests.sample, develop: .init(), longSide: 600)
        #expect(max(normal.image.width, normal.image.height) == 600)
        let scopes = try #require(normal.scopes)
        #expect(scopes.waveform != nil && scopes.parade != nil)
        // Darker exposure: less clipped.
        let darker = try ImageSequenceWriter.preview(RawImportTests.sample, develop: .init(exposure: -1), longSide: 600)
        #expect(try #require(darker.scopes).clippedHighlights < scopes.clippedHighlights)
        #expect(ImageSequenceWriter.thumbnail(RawImportTests.sample) != nil)
    }

    @Test(.enabled(if: RawImportTests.hasSample, "Needs a camera RAW in the test folder"))
    func everyFormatWrites() async throws {
        for format in ImageSequence.OutputFormat.allCases {
            var still = ImageSequence(name: "raw", imagePaths: [RawImportTests.sample.path(percentEncoded: false)])
            still.stillDuration = 0.1
            still.frameSize = .init(width: 320, height: 214)
            still.outputFormat = format
            let url = try await RawImportTests.write(still, name: "format-\(format.rawValue)")
            let clip = Clip(url: url)
            await MediaLoader.load(clip)
            #expect(clip.videoCodec == format.title.replacingOccurrences(of: " 10-bit", with: ""), "\(format)")
            #expect(clip.bitDepth == format.bitDepth || (format == .h264 && clip.bitDepth == 8), "\(format): \(String(describing: clip.bitDepth))")
        }
    }
}
