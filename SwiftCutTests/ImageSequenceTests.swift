import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SwiftCut

struct ImageSequenceTests {
    /// Writes a solid-color PNG.
    static func png(in dir: URL, name: String, size: CGSize = CGSize(width: 64, height: 48),
                    gray: CGFloat = 0.5, alpha: CGFloat = 1) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: (alpha < 1 ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: alpha))
        context.fill(CGRect(origin: .zero, size: size))
        let url = dir.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A folder of numbered PNGs: frame1.png … frameN.png.
    static func folder(count: Int, size: CGSize = CGSize(width: 64, height: 48)) throws -> (URL, [URL]) {
        let dir = try TestVideo.tempDirectory().appending(path: "Shots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try (1...count).map { try png(in: dir, name: "frame\($0).png", size: size, gray: CGFloat($0) / CGFloat(count + 1)) }
        return (dir, urls)
    }

    static func frames(in url: URL) async throws -> (count: Int, size: CGSize, duration: Double, codec: String) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
        let codec = MediaLoader.codecName(CMFormatDescriptionGetMediaSubType(try #require(formats.first)))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return (count, size, try await asset.load(.duration).seconds, codec)
    }

    // MARK: Settings

    @Test func frameDurationsAreExact() {
        #expect(ImageSequence.frameDuration(fps: 29.97) == CMTime(value: 1001, timescale: 30000))
        #expect(ImageSequence.frameDuration(fps: 23.976) == CMTime(value: 1001, timescale: 24000))
        #expect(ImageSequence.frameDuration(fps: 24).seconds == 1.0 / 24)
        #expect(ImageSequence.frameDuration(fps: 12.5).seconds == 0.08)
        #expect(abs(ImageSequence.frameDuration(fps: 7.5).seconds - 1 / 7.5) < 1e-9)
        // Out of range is held to the limits.
        #expect(ImageSequence.frameDuration(fps: 0).seconds == 10)
    }

    @Test func lengthOfSequencesAndStills() {
        var sequence = ImageSequence(name: "Shots", imagePaths: (1...48).map { "/tmp/frame\($0).png" })
        #expect(sequence.frameRate == 24)
        #expect(sequence.frameCount == 48)
        #expect(abs(sequence.duration - 2) < 1e-9)

        var still = ImageSequence(name: "Photo", imagePaths: ["/tmp/photo.jpg"])
        #expect(still.isStill)
        #expect(still.frameRate == 30)
        #expect(still.frameCount == 150)
        still.stillDuration = 2
        #expect(still.frameCount == 60)
        sequence.frameRate = 12
        #expect(abs(sequence.duration - 4) < 1e-9)
    }

    @Test func changingAPictureSettingMakesANewVideo() {
        let sequence = ImageSequence(name: "Shots", imagePaths: ["/a/1.png", "/a/2.png"])
        var other = sequence
        #expect(other.videoURL == sequence.videoURL)
        // The name and permissions don't change the picture.
        other.name = "Renamed"
        other.access = [.init(path: "/a", bookmark: nil)]
        #expect(other.videoURL == sequence.videoURL)

        for change: (inout ImageSequence) -> Void in [
            { $0.frameRate = 30 },
            { $0.frameSize = .init(width: 1920, height: 1080) },
            { $0.fit = .fill },
            { $0.imagePaths.reverse() },
        ] {
            var changed = sequence
            change(&changed)
            #expect(changed.videoURL != sequence.videoURL)
        }
        var still = ImageSequence(name: "Photo", imagePaths: ["/a/1.png"])
        let before = still.videoURL
        still.stillDuration = 3
        #expect(still.videoURL != before)
        #expect(sequence.videoURL.deletingLastPathComponent() == ImageSequence.cacheFolder)
    }

    @Test func outputSizeIsEven() {
        var sequence = ImageSequence(name: "Shots", imagePaths: ["/a/1.png", "/a/2.png"])
        #expect(sequence.outputSize(firstImage: CGSize(width: 1001, height: 667)) == CGSize(width: 1000, height: 666))
        sequence.frameSize = .init(width: 1280, height: 720)
        #expect(sequence.outputSize(firstImage: CGSize(width: 1001, height: 667)) == CGSize(width: 1280, height: 720))
    }

    @Test func savedAndOpened() throws {
        var sequence = ImageSequence(name: "Shots", imagePaths: ["/a/1.png", "/a/2.png"])
        sequence.frameRate = 12.5
        sequence.isCustomFrameRate = true
        sequence.frameSize = .init(width: 640, height: 480)
        sequence.isCustomSize = true
        sequence.fit = .fill
        var record = ProjectFile.ClipRecord(url: URL(filePath: "/a/1.png"), bookmark: nil)
        record.imageSequence = sequence
        let file = ProjectFile(clips: [record], timeline: [])
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(file))
        #expect(decoded.clips.first?.imageSequence == sequence)

        // Projects saved before image sequences still open.
        let old = try JSONDecoder().decode(ImageSequence.self, from: Data(#"{"name":"X","imagePaths":["/a.png"]}"#.utf8))
        #expect(old.frameRate == 24 && old.fit == .fit && old.frameSize == nil && old.stillDuration == 5)
    }

    // MARK: Finding images

    @Test func imagesSortTheWayFinderDoes() throws {
        let (dir, _) = try Self.folder(count: 11)
        try Data("not an image".utf8).write(to: dir.appending(path: "notes.txt"))
        let names = ImageSequence.images(in: dir).map(\.lastPathComponent)
        #expect(names == (1...11).map { "frame\($0).png" })
        #expect(ImageSequence.isFolder(dir))
        #expect(!ImageSequence.isImage(dir))
        #expect(!ImageSequence.isImage(dir.appending(path: "notes.txt")))
    }

    /// Three images whose name, dates, and size each put them in a different order.
    static func orderedImages() throws -> (a: URL, b: URL, c: URL) {
        let dir = try TestVideo.tempDirectory()
        let a = try png(in: dir, name: "a.png", size: CGSize(width: 40, height: 40), gray: 0.2)
        let b = try png(in: dir, name: "b.png", size: CGSize(width: 10, height: 10), gray: 0.4)
        let c = try png(in: dir, name: "c.png", size: CGSize(width: 90, height: 90), gray: 0.6)
        let day = 86_400.0, base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        // Created: c, a, b. Modified: b, c, a.
        try FileManager.default.setAttributes([.creationDate: base + day, .modificationDate: base + 9 * day], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.creationDate: base + 2 * day, .modificationDate: base + 5 * day], ofItemAtPath: b.path)
        try FileManager.default.setAttributes([.creationDate: base, .modificationDate: base + 7 * day], ofItemAtPath: c.path)
        return (a, b, c)
    }

    /// Adds the date a photo was taken, as a camera would.
    static func setDateTaken(_ text: String, on url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: text],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func ordersByNameDatesAndSize() throws {
        let (a, b, c) = try Self.orderedImages()
        let names = { (order: ImageSequence.Order) in
            ImageSequence.sorted([b, c, a], by: order).map { $0.deletingPathExtension().lastPathComponent }
        }
        #expect(names(.nameAscending) == ["a", "b", "c"])
        #expect(names(.nameDescending) == ["c", "b", "a"])
        #expect(names(.createdAscending) == ["c", "a", "b"])
        #expect(names(.createdDescending) == ["b", "a", "c"])
        #expect(names(.modifiedAscending) == ["b", "c", "a"])
        #expect(names(.modifiedDescending) == ["a", "c", "b"])
        #expect(names(.sizeAscending) == ["b", "a", "c"])
        #expect(names(.sizeDescending) == ["c", "a", "b"])
        // Without camera details, Date Taken is the date the file was made.
        #expect(names(.takenAscending) == ["c", "a", "b"])
    }

    @Test func ordersByDateTaken() throws {
        let (a, b, c) = try Self.orderedImages()
        try Self.setDateTaken("2024:06:01 12:00:00", on: a)
        try Self.setDateTaken("2024:06:01 11:00:00", on: b)
        try Self.setDateTaken("2024:06:01 13:00:00", on: c)
        #expect(ImageSequence.dateTaken(b) != nil)
        #expect(ImageSequence.sorted([a, b, c], by: .takenAscending) == [b, a, c])
        #expect(ImageSequence.sorted([a, b, c], by: .takenDescending) == [c, a, b])
    }

    @Test func sameValuesGoInNameOrder() throws {
        let dir = try TestVideo.tempDirectory()
        let urls = try ["shot10.png", "shot2.png", "shot1.png"].map { try Self.png(in: dir, name: $0) }
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for url in urls { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        #expect(ImageSequence.sorted(urls, by: .modifiedDescending).map(\.lastPathComponent) == ["shot1.png", "shot2.png", "shot10.png"])
    }

    @Test @MainActor func importUsesTheChosenOrder() throws {
        let (a, b, c) = try Self.orderedImages()
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))
        store.askAboutImages(in: [a, b, c])
        store.finishImageImport(asSequence: true, order: .sizeDescending)
        let paths = try #require(store.clips.first?.imageSequence?.imagePaths)
        #expect(paths == [c, a, b].map { $0.path(percentEncoded: false) })

        store.askAboutImages(in: [a.deletingLastPathComponent()])
        store.finishImageImport(asSequence: false, order: .createdAscending)
        #expect(store.clips.dropFirst().map(\.name) == ["c", "a", "b"])
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test func frameRateFromTheImportDialog() {
        var sequence = ImageSequence(name: "Shots", imagePaths: ["/a/1.png", "/a/2.png"])
        sequence.setFrameRate(12.5)
        #expect(sequence.frameRate == 12.5 && !sequence.isCustomFrameRate)
        sequence.setFrameRate(7.5)
        #expect(sequence.frameRate == 7.5 && sequence.isCustomFrameRate)
        sequence.setFrameRate(1000)
        #expect(sequence.frameRate == ImageSequence.maxFrameRate)
    }

    @Test @MainActor func importMakesTheVideoAtTheChosenRate() async throws {
        let (dir, _) = try Self.folder(count: 6)
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))
        store.askAboutImages(in: [dir])
        store.finishImageImport(asSequence: true, frameRate: 12)
        let clip = try #require(store.clips.first)
        #expect(clip.imageSequence?.frameRate == 12)
        try await Self.waitUntil { store.clip(for: clip.id)?.isLoaded == true }
        // Made at 12 fps straight away: 6 images last half a second.
        let loaded = try #require(store.clip(for: clip.id))
        // A fresh clip once the video is made, so a viewer already showing it reloads.
        #expect(loaded !== clip)
        #expect(abs(loaded.duration - 0.5) < 0.001)
        #expect(abs(Double(loaded.frameRate) - 12) < 0.01)

        store.askAboutImages(in: [dir])
        store.finishImageImport(asSequence: false, frameRate: 7.5)
        #expect(store.clips.dropFirst().allSatisfy { $0.imageSequence?.frameRate == 7.5 && $0.imageSequence?.isCustomFrameRate == true })
        try? FileManager.default.removeItem(at: loaded.url)
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test func namesForChosenImages() {
        let urls = ["shot_0001.png", "shot_0002.png"].map { URL(filePath: "/tmp/\($0)") }
        #expect(ImageSequence.name(forImages: urls) == "shot")
        #expect(ImageSequence.name(forImages: [URL(filePath: "/tmp/IMG_0001.jpg")]) == "IMG_0001")
        #expect(ImageSequence.name(forImages: ["0001.png", "0002.png"].map { URL(filePath: "/tmp/\($0)") }) == "Image Sequence")
    }

    // MARK: Writing the video

    @Test func writesOneFramePerImage() async throws {
        let (_, urls) = try Self.folder(count: 3)
        var sequence = ImageSequence(name: "Shots", imagePaths: urls.map { $0.path(percentEncoded: false) })
        sequence.frameRate = 10
        let out = try TestVideo.tempDirectory().appending(path: "shots.mov")
        try await BlockingWork.run { [sequence] _ in try ImageSequenceWriter.write(sequence, to: out) }

        let video = try await Self.frames(in: out)
        #expect(video.count == 3)
        #expect(abs(video.duration - 0.3) < 0.001)
        #expect(video.size == CGSize(width: 64, height: 48))
        #expect(video.codec == "Apple ProRes 422 HQ")
    }

    @Test func aStillLastsItsDuration() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try Self.png(in: dir, name: "photo.png", size: CGSize(width: 101, height: 75))
        var still = ImageSequence(name: "photo", imagePaths: [url.path(percentEncoded: false)])
        still.stillDuration = 2
        let out = dir.appending(path: "photo.mov")
        try await BlockingWork.run { [still] _ in try ImageSequenceWriter.write(still, to: out) }

        let video = try await Self.frames(in: out)
        #expect(video.count == 60)
        #expect(abs(video.duration - 2) < 0.001)
        // Made even for the encoder.
        #expect(video.size == CGSize(width: 100, height: 74))
    }

    @Test func chosenFrameSizeAndTransparency() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try Self.png(in: dir, name: "logo.png", gray: 1, alpha: 0.5)
        var sequence = ImageSequence(name: "logo", imagePaths: [url.path(percentEncoded: false)])
        sequence.stillDuration = 0.5
        sequence.frameSize = .init(width: 320, height: 320)
        let out = dir.appending(path: "logo.mov")
        try await BlockingWork.run { [sequence] _ in try ImageSequenceWriter.write(sequence, to: out) }

        let video = try await Self.frames(in: out)
        #expect(video.size == CGSize(width: 320, height: 320))
        #expect(video.codec == "Apple ProRes 4444")
    }

    @Test func missingImagesSaySo() async throws {
        let sequence = ImageSequence(name: "Gone", imagePaths: ["/nowhere/1.png", "/nowhere/2.png"])
        let out = try TestVideo.tempDirectory().appending(path: "gone.mov")
        await #expect(throws: ImageSequenceWriter.WriteError.self) {
            try await BlockingWork.run { [sequence] _ in try ImageSequenceWriter.write(sequence, to: out) }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path(percentEncoded: false)))
    }

    @Test func cancellingStopsAndLeavesNoFile() async throws {
        let (_, urls) = try Self.folder(count: 5)
        let sequence = ImageSequence(name: "Shots", imagePaths: urls.map { $0.path(percentEncoded: false) })
        let out = try TestVideo.tempDirectory().appending(path: "cancelled.mov")
        #expect(throws: CancellationError.self) {
            try ImageSequenceWriter.write(sequence, to: out, isCancelled: { true })
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path(percentEncoded: false))
        #expect(leftovers.isEmpty)
    }

    // MARK: Importing

    @Test @MainActor func importAsSequenceOrSeparateImages() async throws {
        let (dir, urls) = try Self.folder(count: 4)
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))

        let sequence = store.importImages(folders: [dir], images: [], asSequence: true)
        #expect(sequence.count == 1)
        #expect(sequence[0].name == "Shots")
        #expect(sequence[0].imageSequence?.imagePaths.count == 4)

        let stills = store.importImages(folders: [], images: urls.reversed(), asSequence: false)
        #expect(stills.map(\.name) == ["frame1", "frame2", "frame3", "frame4"])
        #expect(stills.allSatisfy { $0.imageSequence?.isStill == true })
        #expect(store.clips.count == 5)

        // The project saves the images, not the cached video.
        let record = try #require(store.projectFile.clips.first)
        #expect(record.path == urls[0].path(percentEncoded: false))
        #expect(record.imageSequence?.name == "Shots")
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test @MainActor func makesTheVideoAndRemakesItWhenASettingChanges() async throws {
        let (dir, _) = try Self.folder(count: 3)
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))
        let clip = try #require(store.importImages(folders: [dir], images: [], asSequence: true).first)
        let id = clip.id

        try await Self.waitUntil { store.clip(for: id)?.isLoaded == true }
        let first = try #require(store.clip(for: id))
        #expect(abs(first.duration - 3.0 / 24) < 0.001)
        #expect(first.displaySize == CGSize(width: 64, height: 48))

        first.imageSequence?.frameRate = 6
        store.refreshImageSequences()
        try await Self.waitUntil { store.clip(for: id).map { $0 !== first && $0.isLoaded } == true }
        let second = try #require(store.clip(for: id))
        #expect(abs(second.duration - 0.5) < 0.001)
        #expect(second.imageSequence?.frameRate == 6)
        // The old video is cleaned up.
        #expect(!FileManager.default.fileExists(atPath: first.url.path(percentEncoded: false)))

        try? FileManager.default.removeItem(at: second.url)
        store.removeClips([id])
    }

    /// The viewer opens a newly imported sequence before its video exists. When the video is
    /// ready the store hands over a new clip (same id), which is what makes the viewer reload.
    @Test @MainActor func viewerGetsAFreshClipWhenTheFirstVideoIsReady() async throws {
        let (dir, _) = try Self.folder(count: 3)
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))
        let imported = try #require(store.importImages(folders: [dir], images: [], asSequence: true).first)
        store.selection = [.clip(imported.id)]
        // What the viewer opened: not there yet.
        #expect(!FileManager.default.fileExists(atPath: imported.url.path(percentEncoded: false)))
        let controller = ClipPlayerController()
        controller.load(imported)

        try await Self.waitUntil { store.clip(for: imported.id)?.isLoaded == true }
        let ready = try #require(store.singleSelectedMedia?.clip)
        #expect(ready !== imported && ready.id == imported.id)
        #expect(ready.url == imported.url)
        #expect(FileManager.default.fileExists(atPath: ready.url.path(percentEncoded: false)))
        #expect(store.selection == [.clip(imported.id)])

        // Loading the new clip gives the player a playable item.
        controller.load(ready)
        let item = try #require(controller.player.currentItem)
        try await Self.waitUntil { item.status != .unknown }
        #expect(item.status == .readyToPlay)
        try? FileManager.default.removeItem(at: ready.url)
        store.removeClips([ready.id])
    }

    @Test @MainActor func saveVideoAsCopiesItExactly() async throws {
        let (dir, _) = try Self.folder(count: 3)
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))
        let imported = try #require(store.importImages(folders: [dir], images: [], asSequence: true).first)
        try await Self.waitUntil { store.clip(for: imported.id)?.isLoaded == true }
        let clip = try #require(store.clip(for: imported.id))
        #expect(ProjectStore.sequenceVideoName(clip) == "Shots (ProRes 422 HQ).mov")

        let destination = try TestVideo.tempDirectory().appending(path: "Saved.mov")
        try Data("old".utf8).write(to: destination)
        try ProjectStore.copySequenceVideo(from: clip.url, to: destination)
        // The very same file, replacing what was there.
        #expect(try Data(contentsOf: destination) == Data(contentsOf: clip.url))
        // Saving onto itself leaves it alone.
        try ProjectStore.copySequenceVideo(from: clip.url, to: clip.url)
        #expect(FileManager.default.fileExists(atPath: clip.url.path(percentEncoded: false)))

        try? FileManager.default.removeItem(at: clip.url)
        store.removeClips([clip.id])
    }

    @Test @MainActor func droppingImagesAsks() throws {
        let (dir, urls) = try Self.folder(count: 3)
        let store = ProjectStore(exporter: ExportManager.test("ImageSequenceTests"))
        #expect(store.handleDrop([dir, urls[0]]))
        let pending = try #require(store.pendingImageImport)
        #expect(pending.imageCount == 4)
        #expect(store.clips.isEmpty)

        store.cancelImageImport()
        #expect(store.pendingImageImport == nil)
        #expect(store.clips.isEmpty)

        store.handleDrop([dir])
        store.finishImageImport(asSequence: false)
        #expect(store.clips.count == 3)
        #expect(store.selection == Set(store.clips.map { .clip($0.id) }))
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @MainActor static func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("Timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
