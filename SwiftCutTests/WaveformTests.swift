import Foundation
import Testing
@testable import SwiftCut

struct WaveformTests {
    @Test func readsSoundAndSkipsSilentFiles() async throws {
        let dir = try TestVideo.tempDirectory()
        let withSound = try await TestVideo.make(in: dir, name: "sound", seconds: 2, size: CGSize(width: 160, height: 90), audio: true)
        let waveform = try #require(try await Waveform.read(url: withSound, duration: 2))
        #expect(waveform.peaks.count == Waveform.sliceCount(duration: 2))
        #expect(waveform.peaks.contains { $0 > Waveform.floorDB })

        let silent = try await TestVideo.make(in: dir, name: "silent", seconds: 1, size: CGSize(width: 160, height: 90))
        #expect(try await Waveform.read(url: silent, duration: 1) == nil)
    }

    @Test func heightsUseDecibels() {
        let waveform = Waveform(peaks: [0, -30, -60, -90])
        #expect(waveform.height(at: 0) == 1)
        #expect(waveform.height(at: 1) == 0.5)
        #expect(waveform.height(at: 2) == 0)
        #expect(waveform.height(at: 3) == 0)
        #expect(waveform.height(at: 9) == 0)
    }
}

/// The waveform's warning lines and colors, which follow the volume changes.
struct WaveformWarningTests {
    @Test func linesMatchTheMeters() {
        // The waveform's scale runs from −60 dB at the middle to 0 dB at the edge.
        #expect(abs(WaveformView.warningHeight - 0.8) < 1e-6)
        #expect(abs(WaveformView.dangerHeight - 0.95) < 1e-6)
        #expect(WaveformView.height(forDB: 0) == 1)
        #expect(WaveformView.height(forDB: -60) == 0)
    }

    @Test func levelsFollowVolumeKeyframesAndTimelineGain() {
        // Ten seconds at −6 dB: past the warning line, under the danger line.
        let waveform = Waveform(peaks: Array(repeating: -6, count: 2000))
        let plain = WaveformView.levels(waveform, columns: 100, contentWidth: 100, drawnStart: 0,
                                        volume: VolumeEnvelope(), duration: 10, gainDB: 0)
        #expect(plain.allSatisfy { abs($0 - 0.9) < 1e-6 })

        // The second half turned down 12 dB drops under the warning line.
        var volume = VolumeEnvelope()
        let a = volume.addKeyframe(at: 4.9, smooth: false), b = volume.addKeyframe(at: 5.1, smooth: false)
        volume.move(a, to: 4.9, gainDB: 0)
        volume.move(b, to: 5.1, gainDB: -12)
        let turnedDown = WaveformView.levels(waveform, columns: 100, contentWidth: 100, drawnStart: 0,
                                             volume: volume, duration: 10, gainDB: 0)
        #expect(turnedDown[10] > WaveformView.warningHeight)
        #expect(turnedDown[90] < WaveformView.warningHeight)
        #expect(abs(turnedDown[90] - 0.7) < 1e-4)

        // The timeline turning it up 5 dB pushes it past the danger line.
        let turnedUp = WaveformView.levels(waveform, columns: 100, contentWidth: 100, drawnStart: 0,
                                           volume: VolumeEnvelope(), duration: 10, gainDB: 5)
        #expect(turnedUp.allSatisfy { $0 > WaveformView.dangerHeight })

        // Silence stays silent, and nothing goes past the edge.
        let silent = WaveformView.levels(Waveform(peaks: Array(repeating: -60, count: 2000)), columns: 10, contentWidth: 10,
                                         drawnStart: 0, volume: VolumeEnvelope(), duration: 10, gainDB: 30)
        #expect(silent.allSatisfy { $0 == 0 })
        let clipped = WaveformView.levels(waveform, columns: 10, contentWidth: 10, drawnStart: 0,
                                          volume: VolumeEnvelope(), duration: 10, gainDB: 20)
        #expect(clipped.allSatisfy { $0 == 1 })
    }
}
