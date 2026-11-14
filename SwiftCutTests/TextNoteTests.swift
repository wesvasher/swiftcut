import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// Text notes over the picture.
struct TextNoteTests {
    @Test func fadesInAndOut() {
        let note = TextNote(start: 1, end: 4)
        #expect(note.fades)
        #expect(note.opacity(at: 0.9) == 0)
        #expect(abs(note.opacity(at: 1.25) - 0.5) < 1e-9)
        #expect(note.opacity(at: 2.5) == 1)
        #expect(abs(note.opacity(at: 3.75) - 0.5) < 1e-9)
        #expect(note.opacity(at: 4) == 0)
        // A short note fades quicker, so it still reaches full strength.
        #expect(abs(TextNote(start: 0, end: 0.6).fadeDuration - 0.2) < 1e-9)
        var still = note
        still.fades = false
        #expect(still.opacity(at: 1.01) == 1)
    }

    @Test @MainActor func addingAndEditingNotes() {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.duration = 10
        let first = clip.addNote(at: 2)
        #expect(clip.notes.first?.start == 2 && clip.notes.first?.end == 5)
        // Near the end, it moves earlier to fit.
        let late = clip.addNote(at: 9)
        let lateNote = clip.notes.first { $0.id == late }
        #expect(lateNote?.start == 7 && lateNote?.end == 10)
        // Edits stay inside the clip, with the in before the out.
        clip.updateNote(first) { $0.end = 1 }
        let edited = clip.notes.first { $0.id == first }!
        #expect(abs(edited.end - 2.1) < 1e-9)
        clip.updateNote(first) { $0.start = -3 }
        #expect(clip.notes.first { $0.id == first }?.start == 0)
        clip.removeNote(late)
        #expect(clip.notes.count == 1)
    }

    @Test @MainActor func savedAndDrawnLive() throws {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.duration = 10
        clip.displaySize = CGSize(width: 1920, height: 1080)
        #expect(!clip.enhanceSettings.isActive)
        let id = clip.addNote(at: 1, text: "Hello")
        clip.updateNote(id) { $0.size = 6; $0.position = .top; $0.fontFamily = "Futura"; $0.fades = false }
        #expect(clip.enhanceSettings.isActive)

        let decoded = try JSONDecoder().decode(ProjectFile.ClipRecord.self, from: JSONEncoder().encode(clip.record))
        let reopened = Clip(url: clip.url, id: clip.id)
        reopened.apply(decoded)
        #expect(reopened.notes == clip.notes)

        // Typing or dragging doesn't rebuild the preview (the notes follow live).
        let before = clip.enhanceSettings.structure
        clip.updateNote(id) { $0.text = "Hello there"; $0.start = 2 }
        #expect(clip.enhanceSettings.structure == before)
    }

    /// How many near-white pixels a frame has (the note's text).
    @MainActor static func whitePixels(_ asset: AVAsset, _ composition: AVVideoComposition?, at seconds: Double) async throws -> Int {
        // Used only here, start to finish.
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        let context = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return gray.filter { $0 > 235 }.count
    }

    static func grayClip(_ name: String, seconds: Int = 2) async throws -> URL {
        try await TestVideo.make(in: try TestVideo.tempDirectory(), name: name, seconds: seconds,
                                 size: CGSize(width: 640, height: 360), codec: .proRes422) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 110, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }

    @Test @MainActor func notesShowInExportsBetweenInAndOut() async throws {
        let url = try await Self.grayClip("gray")
        let settings = EnhanceSettings(notes: [TextNote(text: "Hello", start: 0.5, end: 1.5)])
        let playable = try await Enhancer.makePlayable(url: url, settings: settings)
        let before = try await Self.whitePixels(playable.asset, playable.videoComposition, at: 0.2)
        let during = try await Self.whitePixels(playable.asset, playable.videoComposition, at: 1.0)
        let after = try await Self.whitePixels(playable.asset, playable.videoComposition, at: 1.8)
        #expect(before == 0 && after == 0, "\(before) \(after)")
        #expect(during > 50, "\(during)")
    }

    @Test @MainActor func notesFollowTheSourceOnTheTimeline() async throws {
        let first = try await Self.grayClip("first", seconds: 1)
        let second = try await Self.grayClip("second", seconds: 3)
        // The second clip's note is at 2–2.5 s in its source; the timeline plays it from 1 s, after the first clip's second.
        let notes = [TextNote(text: "Here", start: 2, end: 2.5)]
        let result = try await CompositionBuilder.build([
            .init(url: first, start: 0, end: 1),
            .init(url: second, start: 1, end: 3, settings: EnhanceSettings(notes: notes)),
        ])
        // Timeline 2.25 s is source 2.25 s of the second clip: showing. Timeline 1.5 s is source 1.5 s: not yet.
        let showing = try await Self.whitePixels(result.composition, result.videoComposition, at: 2.25)
        let notYet = try await Self.whitePixels(result.composition, result.videoComposition, at: 1.5)
        #expect(showing > 50 && notYet == 0, "\(showing) \(notYet)")
    }
}
