import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import SwiftCut

/// Film grain, and the Effects section's per-effect status, clearing, and presets.
struct FilmGrainTests {
    /// Renders a flat gray picture with grain, as 8-bit gray.
    static func render(amount: Float, size: Float = 1, frame: Int) -> [UInt8] {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let image = FilmGrainStage.apply(gray, grain: FilmGrain(amount: amount, size: size), frame: frame, scale: 1, extent: extent)
        var bytes = [UInt8](repeating: 0, count: 64 * 64)
        CIContext().render(image, toBitmap: &bytes, rowBytes: 64, bounds: extent, format: .L8,
                           colorSpace: CGColorSpaceCreateDeviceGray())
        return bytes
    }

    static func deviation(_ bytes: [UInt8]) -> Double {
        let values = bytes.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    @Test func grainChangesEveryFrameButIsRepeatable() {
        let off = Self.render(amount: 0, frame: 1)
        #expect(Self.deviation(off) < 0.5, "no grain at 0")

        let first = Self.render(amount: 0.5, frame: 1)
        #expect(Self.deviation(first) > 5)
        // The same frame always gets the same grain (so exports match the preview)…
        #expect(Self.render(amount: 0.5, frame: 1) == first)
        // …and the next frame gets different grain.
        #expect(Self.render(amount: 0.5, frame: 2) != first)
        // Stronger is grainier.
        #expect(Self.deviation(Self.render(amount: 1, frame: 1)) > Self.deviation(first))
    }

    @Test func grainKeepsTheBrightness() {
        let values = Self.render(amount: 0.6, frame: 7).map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        // Soft light around middle gray: lighter and darker evenly.
        #expect(abs(mean - 128) < 3, "\(mean)")
    }

    @Test func framesFarApart() {
        let a = FilmGrainStage.offset(forFrame: 1000), b = FilmGrainStage.offset(forFrame: 1001)
        #expect(hypot(a.x - b.x, a.y - b.y) > 100)
        #expect(FilmGrainStage.offset(forFrame: 1000) == a)
    }

    @Test func exportsHaveGrain() async throws {
        let dir = try TestVideo.tempDirectory()
        let source = try await TestVideo.make(in: dir, name: "gray", seconds: 1, size: CGSize(width: 320, height: 240), codec: .proRes422) { _, pixels in
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        let job = try await EnhanceTests.export(source, EnhanceSettings(grain: FilmGrain(amount: 0.5, size: 1)), to: dir, name: "grain")
        #expect(job.state == .finished, "\(job.state)")
        let before = try await EnhanceTests.stats(source, at: 0.5)
        let after = try await EnhanceTests.stats(job.outputURL, at: 0.5)
        #expect(after.deviation > before.deviation + 3, "\(before.deviation) → \(after.deviation)")
        #expect(abs(after.mean - before.mean) < 8, "\(before.mean) → \(after.mean)")
    }

    // MARK: The clip's settings

    @Test @MainActor func clipTurnsGrainIntoSettings() throws {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.displaySize = CGSize(width: 1920, height: 1080)
        #expect(clip.enhanceSettings.grain == nil)
        clip.filmGrainPercent = 30
        clip.filmGrainSize = 2.3
        #expect(clip.enhanceSettings.grain == FilmGrain(amount: 0.3, size: 2.3))
        #expect(clip.enhanceSettings.hasEffects)
        #expect(!clip.isAtDefaults)
        #expect(clip.exportNameSuffix == "Enhanced")

        // Saved and opened again.
        let decoded = try JSONDecoder().decode(ProjectFile.ClipRecord.self, from: JSONEncoder().encode(clip.record))
        let reopened = Clip(url: clip.url, id: clip.id)
        reopened.apply(decoded)
        #expect(reopened.filmGrain == 0.3 && reopened.filmGrainSize == 2.3)

        clip.resetEffects()
        #expect(clip.filmGrain == 0 && clip.filmGrainSize == 1)
        #expect(Clip.grainSizeTitle(2.2) == "Coarse")
    }

    @Test @MainActor func effectSetsSavedBeforeFilmGrainStillLoad() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"Old","denoise":false,"denoiseStrength":0.5,"upscale":"off","sharpen":0.2}]"#
        let presets = try JSONDecoder().decode([EffectsPreset].self, from: Data(json.utf8))
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.filmGrain = 0.4
        presets[0].apply(to: clip)
        #expect(clip.sharpen == 0.2 && clip.filmGrain == 0)
        #expect(presets[0].matches(clip))
    }

    // MARK: Each effect's accordion

    @Test @MainActor func statusAndClear() {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        for kind in EffectKind.allCases {
            #expect(!kind.isActive(on: clip))
            #expect(kind.status(of: clip) == "Off")
        }
        clip.denoise = true
        clip.denoiseStrength = 0.7
        clip.upscale = .fast
        clip.sharpenPercent = 35
        clip.filmGrainPercent = 20
        #expect(EffectKind.reduceNoise.status(of: clip) == "70%")
        #expect(EffectKind.enhance.status(of: clip) == "2× (Fast)")
        #expect(EffectKind.sharpen.status(of: clip) == "35%")
        #expect(EffectKind.filmGrain.status(of: clip) == "20% · Fine")

        // Clearing one leaves the others.
        EffectKind.sharpen.clear(on: clip)
        #expect(clip.sharpen == 0)
        #expect(EffectKind.filmGrain.isActive(on: clip) && EffectKind.enhance.isActive(on: clip))
        EffectKind.reduceNoise.clear(on: clip)
        #expect(!clip.denoise && clip.denoiseStrength == 0.5)
    }

    @Test @MainActor func presetsForOneEffect() throws {
        let suite = "FilmGrainTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EffectPresetStore(defaults: defaults)

        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.filmGrainPercent = 25
        clip.filmGrainSize = 1.6
        clip.sharpenPercent = 40
        store.save(.filmGrain, name: "Light 16mm", from: clip)
        #expect(store.presets(for: .filmGrain).map(\.name) == ["Light 16mm"])
        #expect(store.presets(for: .sharpen).isEmpty)

        // Applying it sets only that effect.
        let other = Clip(url: URL(filePath: "/tmp/b.mov"))
        other.sharpenPercent = 10
        let preset = try #require(store.presets(for: .filmGrain).first)
        EffectKind.filmGrain.apply(preset.values, to: other)
        #expect(other.filmGrainPercent == 25 && other.filmGrainSize == 1.6)
        #expect(other.sharpenPercent == 10)
        #expect(EffectKind.filmGrain.matches(preset.values, on: other))

        // Same name replaces; kept between launches.
        clip.filmGrainPercent = 30
        store.save(.filmGrain, name: "light 16MM", from: clip)
        let reloaded = EffectPresetStore(defaults: defaults)
        #expect(reloaded.presets(for: .filmGrain).count == 1)
        #expect(reloaded.presets(for: .filmGrain).first?.values["amount"] == 0.3)

        reloaded.delete(try #require(reloaded.presets.first))
        #expect(EffectPresetStore(defaults: defaults).presets.isEmpty)
    }

    @Test @MainActor func enhancePresetRoundTrips() {
        let clip = Clip(url: URL(filePath: "/tmp/a.mov"))
        clip.upscale = .best
        let values = EffectKind.enhance.values(of: clip)
        let other = Clip(url: URL(filePath: "/tmp/b.mov"))
        EffectKind.enhance.apply(values, to: other)
        #expect(other.upscale == .best)
    }
}
