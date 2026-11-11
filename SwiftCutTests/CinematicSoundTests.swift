import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

/// Cinematic Sound (evening out loud and quiet parts), and resetting the audio settings.
struct CinematicSoundTests {
    @Test func quietPartsGoUpAndLoudPartsComeDown() {
        // Well under the threshold: the make-up gain alone.
        #expect(abs(CinematicDynamics.gainDB(forLevel: -40) - 6) < 1e-9)
        // Loud: 15 dB over, which comes out 5 dB over, then the make-up gain.
        #expect(abs(CinematicDynamics.gainDB(forLevel: -5) - (-10 + 6)) < 1e-9)
        // Near silence isn't raised, so hiss stays down.
        #expect(CinematicDynamics.gainDB(forLevel: -60) == 0)
        #expect(abs(CinematicDynamics.gainDB(forLevel: -55) - 3) < 1e-9)
        // Nothing comes out above the ceiling.
        #expect(CinematicDynamics.outputDB(forLevel: 0) <= CinematicDynamics.ceiling)
        // The gap between −40 and −5 shrinks from 35 dB to 25.
        let gap = CinematicDynamics.outputDB(forLevel: -5) - CinematicDynamics.outputDB(forLevel: -40)
        #expect(abs(gap - 25) < 1e-9)
    }

    @Test func limiterHoldsSuddenPeaksUnderTheCeiling() {
        var dynamics = CinematicDynamics(sampleRate: 48_000)
        let ceiling = Float(pow(10, CinematicDynamics.ceiling / 20))
        // Quiet, then a full-scale hit the compressor hasn't caught up with yet.
        for _ in 0..<48_000 { _ = dynamics.gain(forPeak: 0.01) }
        for _ in 0..<480 {
            let gain = dynamics.gain(forPeak: 1)
            #expect(gain * 1 <= ceiling + 1e-5)
        }
    }

    @Test func timelineSoundIsEvenedOut() async throws {
        let dir = try TestVideo.tempDirectory()
        let quiet = try LoudnessTests.tone(in: dir, name: "quiet", amplitude: 0.02, seconds: 2)  // peaks at −34 dB
        let loud = try LoudnessTests.tone(in: dir, name: "loud", amplitude: 0.5, seconds: 2)    // peaks at −6 dB
        let clips: [CompositionBuilder.Segment] = [.init(url: quiet, start: 0, end: 2), .init(url: loud, start: 0, end: 2)]

        func levels(cinematic: Bool) async throws -> (quiet: Double, loud: Double) {
            let audio = TimelineAudio(spans: [
                .init(start: 0, end: 2, gainDB: 0, isCinematic: cinematic),
                .init(start: 2, end: 4, gainDB: 0, isCinematic: cinematic),
            ])
            let result = try await CompositionBuilder.build(clips, audio: audio)
            return (try #require(try LoudnessTests.measureMix(result, range: 0.8...1.8)),
                    try #require(try LoudnessTests.measureMix(result, range: 2.8...3.8)))
        }
        let plain = try await levels(cinematic: false)
        let cinematic = try await levels(cinematic: true)
        // The quiet clip comes up about 6 dB; the loud one comes down; the gap shrinks.
        #expect(abs((cinematic.quiet - plain.quiet) - 6) < 1, "\(plain) → \(cinematic)")
        #expect(cinematic.loud < plain.loud, "\(plain) → \(cinematic)")
        #expect((cinematic.loud - cinematic.quiet) < (plain.loud - plain.quiet) - 6, "\(plain) → \(cinematic)")
    }

    @Test @MainActor func savedWithTheClipAndTimeline() throws {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.isCinematicSound = true
        let record = clip.record
        #expect(record.cinematicSound)
        let decoded = try JSONDecoder().decode(ProjectFile.ClipRecord.self, from: JSONEncoder().encode(record))
        let reopened = Clip(url: clip.url, id: clip.id)
        reopened.apply(decoded)
        #expect(reopened.isCinematicSound)

        var settings = TimelineSettings()
        settings.cinematicSound = true
        let saved = try JSONDecoder().decode(TimelineSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.cinematicSound)
        // Sound only: the picture doesn't need rebuilding.
        #expect(saved.pictureOnly == TimelineSettings().pictureOnly)
        // Older projects open with it off.
        let old = try JSONDecoder().decode(TimelineSettings.self, from: Data("{}".utf8))
        #expect(!old.cinematicSound)
    }

    @Test @MainActor func timelineAppliesItToEveryClip() throws {
        let store = ProjectStore(exporter: ExportManager.test("CinematicSoundTests"))
        let a = Clip(url: URL(filePath: "/tmp/a.mov")), b = Clip(url: URL(filePath: "/tmp/b.mov"))
        for clip in [a, b] {
            clip.duration = 2
            clip.isLoaded = true
        }
        store.clips = [a, b]
        store.addToTimeline([a, b])
        #expect(store.timelineAudioSpans.map(\.isCinematic) == [false, false])
        a.isCinematicSound = true
        #expect(store.timelineAudioSpans.map(\.isCinematic) == [true, false])
        store.timelineSettings.cinematicSound = true
        #expect(store.timelineAudioSpans.map(\.isCinematic) == [true, true])
    }

    @Test @MainActor func resetTimelineAudio() throws {
        let store = ProjectStore(exporter: ExportManager.test("CinematicSoundTests"))
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.duration = 2
        clip.isLoaded = true
        clip.isCinematicSound = true
        store.clips = [clip]
        store.addToTimeline([clip])
        #expect(!store.hasTimelineAudioChanges)

        store.timelineSettings.matchLoudness = true
        store.timelineSettings.loudnessTarget = -23
        store.timelineSettings.cinematicSound = true
        store.setAudio(ItemAudio(matchesTarget: false, adjustDB: 4), for: store.timeline[0].id)
        #expect(store.hasTimelineAudioChanges)

        store.resetTimelineAudio()
        #expect(!store.hasTimelineAudioChanges)
        #expect(store.timeline[0].audio.isDefault)
        // The clip's own setting is kept; it's changed in the clip viewer.
        #expect(clip.isCinematicSound)
    }
}
