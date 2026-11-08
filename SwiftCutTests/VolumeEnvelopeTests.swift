import AVFoundation
import Foundation
import Testing
@testable import SwiftCut

/// Volume keyframes: the line between them, editing, saving, and the sound following them.
struct VolumeEnvelopeTests {
    @Test func faderStepsRoundTrip() {
        #expect(VolumeEnvelope.position(forDB: VolumeEnvelope.maxDB) == 1)
        #expect(VolumeEnvelope.position(forDB: -.infinity) == 0)
        #expect(VolumeEnvelope.position(forDB: VolumeEnvelope.minDB) == 0)
        for db in [-40.0, -12, -6, 0, 3, 12] {
            #expect(abs(VolumeEnvelope.db(forPosition: VolumeEnvelope.position(forDB: db)) - db) < 1e-9)
        }
        #expect(VolumeEnvelope.label(forDB: 3) == "+3.0 dB")
        #expect(VolumeEnvelope.label(forDB: -6.04) == "−6.0 dB")
        #expect(VolumeEnvelope.label(forDB: -.infinity) == "−∞ dB")
    }

    @Test func withoutKeyframesNothingChanges() {
        let envelope = VolumeEnvelope()
        #expect(envelope.gain(at: 5) == 1)
        #expect(abs(envelope.gainDB(at: 5)) < 1e-9)
    }

    @Test func linearKeyframesMakeStraightLines() {
        var envelope = VolumeEnvelope()
        let a = envelope.addKeyframe(at: 1, smooth: false)
        let b = envelope.addKeyframe(at: 3, smooth: false)
        envelope.move(a, to: 1, gainDB: 0)
        envelope.move(b, to: 3, gainDB: -.infinity)
        // Held before the first and after the last.
        #expect(abs(envelope.gainDB(at: 0)) < 1e-9)
        #expect(envelope.gain(at: 4) == 0)
        // Halfway in fader steps.
        let middle = (VolumeEnvelope.position(forDB: 0) + 0) / 2
        #expect(abs(envelope.position(at: 2) - middle) < 1e-9)
        // A new keyframe lands on the line, so adding one changes nothing.
        let before = envelope.position(at: 1.5)
        envelope.addKeyframe(at: 1.5, smooth: false)
        #expect(abs(envelope.position(at: 1.5) - before) < 1e-9)
        #expect(envelope.keyframes.map(\.time) == [1, 1.5, 3])
    }

    @Test func smoothKeyframesCurveWithoutOvershooting() {
        var envelope = VolumeEnvelope()
        let ids = [0.0, 1, 2].map { envelope.addKeyframe(at: $0, smooth: false) }
        envelope.move(ids[0], to: 0, gainDB: -30)
        envelope.move(ids[1], to: 1, gainDB: 6)
        envelope.move(ids[2], to: 2, gainDB: -30)
        let corner = envelope.position(at: 0.9)
        for id in ids { envelope.setSmooth(id, true) }
        // The peak stays the highest point, and the curve differs from the straight line.
        let peak = VolumeEnvelope.position(forDB: 6)
        for step in 0...200 {
            #expect(envelope.position(at: Double(step) / 100) <= peak + 1e-9)
        }
        #expect(envelope.position(at: 0.9) > corner)
        #expect(abs(envelope.position(at: 1) - peak) < 1e-9)

        // Less curve sits between the straight line and the full ease.
        envelope.setCurve(ids[1], 0.5)
        envelope.setCurve(ids[0], 0.5)
        let half = envelope.position(at: 0.9)
        #expect(half > corner && half < curved(envelope, ids))
        // No curve is the straight line again.
        for id in ids { envelope.setCurve(id, 0) }
        #expect(abs(envelope.position(at: 0.9) - corner) < 1e-9)
    }

    private func curved(_ envelope: VolumeEnvelope, _ ids: [UUID]) -> Double {
        var full = envelope
        for id in ids { full.setCurve(id, 1) }
        return full.position(at: 0.9)
    }

    @Test func newKeyframesAreSplines() {
        var envelope = VolumeEnvelope()
        let id = envelope.addKeyframe(at: 1)
        #expect(envelope.keyframe(id)?.isSmooth == true)
        #expect(envelope.keyframe(id)?.curve == 1)
    }

    @Test @MainActor func subclipsKeepTheirOwnKeyframes() throws {
        let store = ProjectStore(exporter: ExportManager.test())
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.duration = 10
        clip.isLoaded = true
        store.clips = [clip]
        clip.volume.addKeyframe(at: 1)
        clip.inPoint = 2
        clip.outPoint = 5
        let subclip = try #require(store.addSubclip(from: clip))
        #expect(subclip.volume == clip.volume, "starts with what it played with")

        let key = subclip.volume.addKeyframe(at: 3)
        subclip.volume.move(key, to: 3, gainDB: -20)
        #expect(clip.volume.keyframes.count == 1, "the source video is unchanged")

        store.addToTimeline([.clip(clip.id)])
        let spans = store.timelineAudioSpans
        #expect(spans.map(\.envelope) == [subclip.volume, clip.volume])
        // Saved and opened again, each keeps its own.
        let record = try JSONDecoder().decode(ProjectFile.SubclipRecord.self, from: JSONEncoder().encode(subclip.record))
        #expect(record.volume == subclip.volume)
    }

    @Test func keyframesStayInOrderAndCanBeRemoved() {
        var envelope = VolumeEnvelope()
        let a = envelope.addKeyframe(at: 1)
        let b = envelope.addKeyframe(at: 2)
        #expect(envelope.addKeyframe(at: 2.004, minimumGap: 0.01) == b, "too close: the existing one")
        #expect(envelope.movableRange(of: a, duration: 10, gap: 0.1) == 0...1.9)
        #expect(envelope.movableRange(of: b, duration: 10, gap: 0.1) == 1.1...10)
        envelope.move(b, to: 5, gainDB: 40)
        #expect(envelope.keyframe(b)?.gainDB == VolumeEnvelope.maxDB, "held to the top")
        envelope.remove(a)
        #expect(envelope.keyframes.map(\.id) == [b])
        envelope.removeAll()
        #expect(envelope.isEmpty)
    }

    @Test @MainActor func clipsSaveTheirKeyframes() throws {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.volume.addKeyframe(at: 1)
        let id = clip.volume.addKeyframe(at: 2)
        clip.volume.move(id, to: 2, gainDB: -9)
        clip.volume.setSmooth(id, true)
        let data = try JSONEncoder().encode(clip.record)
        let record = try JSONDecoder().decode(ProjectFile.ClipRecord.self, from: data)
        let copy = Clip(url: URL(filePath: "/tmp/a.mov"))
        copy.apply(record)
        #expect(copy.volume == clip.volume)
        // No keyframes: nothing saved, and older files open without any.
        #expect(Clip(url: URL(filePath: "/tmp/b.mov")).record.volume == nil)
    }

    @Test func soundFollowsTheKeyframes() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try LoudnessTests.tone(in: dir, name: "tone", amplitude: 0.1, seconds: 6)
        // −20 dB for the first two seconds, a fade to silence over the next two, then silence.
        var envelope = VolumeEnvelope()
        let a = envelope.addKeyframe(at: 2), b = envelope.addKeyframe(at: 4)
        envelope.move(a, to: 2, gainDB: -20)
        envelope.move(b, to: 4, gainDB: -.infinity)
        // The timeline plays seconds 1–6 of the file, starting at 0.
        let audio = TimelineAudio(spans: [.init(start: 0, end: 5, gainDB: 0, envelope: envelope, sourceStart: 1)])
        let result = try await CompositionBuilder.build([.init(url: url, start: 1, end: 6)], audio: audio)
        let start = try #require(try LoudnessTests.measureMix(result, range: 0.2...0.8))
        #expect(abs(start - (-20 - 20)) < 0.5, "\(start)")
        let end = try LoudnessTests.measureMix(result, range: 3.5...4.5)
        #expect(end == nil, "silent after the last keyframe")
    }

    // MARK: Dragging a segment

    /// Keyframes at 1 s (−6 dB), 3 s (−12 dB), and 5 s (0 dB).
    private func threeKeys() -> (VolumeEnvelope, UUID, UUID, UUID) {
        var envelope = VolumeEnvelope()
        let a = envelope.addKeyframe(at: 1, smooth: false)
        let b = envelope.addKeyframe(at: 3, smooth: false)
        let c = envelope.addKeyframe(at: 5, smooth: false)
        envelope.move(a, to: 1, gainDB: -6)
        envelope.move(b, to: 3, gainDB: -12)
        envelope.move(c, to: 5, gainDB: 0)
        return (envelope, a, b, c)
    }

    @Test func segmentsLieBetweenKeyframes() throws {
        let (envelope, a, b, c) = threeKeys()
        #expect(envelope.segment(at: 2) == .init(start: a, end: b))
        #expect(envelope.segment(at: 3) == .init(start: b, end: c))
        #expect(envelope.segment(at: 4.9) == .init(start: b, end: c))
        // Before the first and after the last, the line holds level to the clip's edges.
        #expect(envelope.segment(at: 0.5) == .init(start: nil, end: a))
        #expect(envelope.segment(at: 9) == .init(start: c, end: nil))
        #expect(envelope.timeRange(of: .init(start: nil, end: a), duration: 10) == 0...1)
        #expect(envelope.timeRange(of: .init(start: c, end: nil), duration: 10) == 5...10)
        #expect(envelope.timeRange(of: .init(start: a, end: b), duration: 10) == 1...3)
    }

    @Test func draggingTheLineWithoutKeyframesSetsTheWholeClip() throws {
        var envelope = VolumeEnvelope()
        let whole = try #require(envelope.segment(at: 4))
        #expect(whole == .init(start: nil, end: nil))
        #expect(envelope.timeRange(of: whole, duration: 10) == 0...10)
        #expect(envelope.label(of: whole) == "0.0 dB")

        // Dragging adds one keyframe at the start, at the level already there (0 dB).
        let segment = envelope.prepareToDrag(whole)
        #expect(envelope.keyframes.count == 1)
        let key = try #require(envelope.keyframes.first)
        #expect(key.time == 0 && abs(key.gainDB) < 1e-9)
        #expect(segment == .init(start: key.id, end: nil))
        #expect(envelope.timeRange(of: segment, duration: 10) == 0...10)

        envelope.shiftLevels(from: envelope.positions(of: segment), by: -0.1)
        #expect(envelope.gainDB(at: 0) < 0)
        #expect(abs(envelope.gainDB(at: 9) - envelope.gainDB(at: 0)) < 1e-9)

        // Segments that already have keyframes are left as they are.
        #expect(envelope.prepareToDrag(segment) == segment)
        #expect(envelope.keyframes.count == 1)
    }

    @Test func draggingASegmentMovesBothEndsTogether() throws {
        var (envelope, a, b, c) = threeKeys()
        let segment = VolumeEnvelope.Segment(start: a, end: b)
        let start = envelope.positions(of: segment)
        envelope.shiftLevels(from: start, by: 0.05)
        let newA = try #require(envelope.keyframe(a)), newB = try #require(envelope.keyframe(b))
        #expect(abs(VolumeEnvelope.position(forDB: newA.gainDB) - (start[a]! + 0.05)) < 1e-9)
        #expect(abs(VolumeEnvelope.position(forDB: newB.gainDB) - (start[b]! + 0.05)) < 1e-9)
        // Both got louder, the fade still goes down, and the times and the other keyframe stay put.
        #expect(newA.gainDB > -6 && newB.gainDB > -12 && newA.gainDB > newB.gainDB)
        #expect(newA.time == 1 && newB.time == 3)
        #expect(envelope.keyframe(c)?.gainDB == 0)
        // Dragging always starts from the levels when the drag began, not where it's got to.
        envelope.shiftLevels(from: start, by: 0)
        #expect(abs(envelope.keyframe(a)!.gainDB - -6) < 1e-9)
    }

    @Test func draggingStopsAtTheTopAndBottomKeepingTheShape() throws {
        var (envelope, a, b, _) = threeKeys()
        let start = envelope.positions(of: .init(start: a, end: b))
        envelope.shiftLevels(from: start, by: 5)
        // The louder end reaches the top; the other keeps the same gap below it.
        #expect(abs(envelope.keyframe(a)!.gainDB - VolumeEnvelope.maxDB) < 1e-9)
        let gap = start[a]! - start[b]!
        #expect(abs(VolumeEnvelope.position(forDB: envelope.keyframe(b)!.gainDB) - (1 - gap)) < 1e-9)

        envelope.shiftLevels(from: start, by: -5)
        // The quieter end reaches silence.
        #expect(envelope.keyframe(b)!.gainDB == VolumeEnvelope.minDB)
        #expect(envelope.keyframe(a)!.gainDB > VolumeEnvelope.minDB)
    }

    @Test func edgeSegmentsMoveOneKeyframe() throws {
        var (envelope, a, b, _) = threeKeys()
        let segment = try #require(envelope.segment(at: 0))
        #expect(segment.keyframeIDs == [a])
        envelope.shiftLevels(from: envelope.positions(of: segment), by: -0.1)
        #expect(envelope.keyframe(a)!.gainDB < -6)
        #expect(envelope.keyframe(b)!.gainDB == -12)
    }

    @Test func segmentLabels() {
        let (envelope, a, b, c) = threeKeys()
        #expect(envelope.label(of: .init(start: a, end: b)) == "−6.0 dB → −12.0 dB")
        #expect(envelope.label(of: .init(start: c, end: nil)) == "0.0 dB")
        var flat = envelope
        flat.move(b, to: 3, gainDB: -6)
        #expect(flat.label(of: .init(start: a, end: b)) == "−6.0 dB")
    }
}
