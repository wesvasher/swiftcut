import Foundation
import Testing
@testable import SwiftCut

/// The Sharpen field, − and + buttons, and presets.
struct SharpenControlTests {
    @Test @MainActor func typedPercentStaysInRange() {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.sharpenPercent = 42
        #expect(abs(clip.sharpen - 0.42) < 1e-9)
        #expect(clip.sharpenPercent == 42)
        clip.sharpenPercent = 250
        #expect(clip.sharpen == 1)
        clip.sharpenPercent = -10
        #expect(clip.sharpen == 0)
    }

    @Test @MainActor func stepsLandOnTheGrid() {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.stepSharpen(1)
        #expect(clip.sharpenPercent == 5)
        clip.sharpenPercent = 12
        clip.stepSharpen(1)
        #expect(clip.sharpenPercent == 15)
        clip.sharpenPercent = 12
        clip.stepSharpen(-1)
        #expect(clip.sharpenPercent == 10)
        clip.stepSharpen(-1)
        #expect(clip.sharpenPercent == 5)
        // Held at the ends.
        clip.sharpenPercent = 0
        clip.stepSharpen(-1)
        #expect(clip.sharpenPercent == 0)
        clip.sharpenPercent = 98
        clip.stepSharpen(1)
        #expect(clip.sharpenPercent == 100)
        clip.stepSharpen(1)
        #expect(clip.sharpenPercent == 100)
    }

    @Test func presetsGoFromOffToMaximum() {
        let percents = Clip.sharpenPresets.map(\.percent)
        #expect(percents.first == 0 && percents.last == 100)
        #expect(percents == percents.sorted())
        #expect(Set(percents).count == percents.count)
    }
}
