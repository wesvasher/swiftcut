import Foundation
import Observation

/// One effect in the Effects section. Each has its own accordion, whose header shows `status`,
/// and a menu to clear it or save and load presets of just that effect.
enum EffectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case reduceNoise, enhance, sharpen, filmGrain

    var id: Self { self }

    var title: String {
        switch self {
        case .reduceNoise: "Reduce Noise"
        case .enhance: "Enhance"
        case .sharpen: "Sharpen"
        case .filmGrain: "Film Grain"
        }
    }

    var systemImage: String {
        switch self {
        case .reduceNoise: "wand.and.rays"
        case .enhance: "arrow.up.left.and.arrow.down.right"
        case .sharpen: "triangle"
        case .filmGrain: "circle.dotted"
        }
    }

    @MainActor func isActive(on clip: Clip) -> Bool {
        switch self {
        case .reduceNoise: clip.denoise
        case .enhance: clip.upscale != .off
        case .sharpen: clip.sharpenPercent > 0
        case .filmGrain: clip.filmGrainPercent > 0
        }
    }

    /// Shown in the header: "Off", or what it's set to.
    @MainActor func status(of clip: Clip) -> String {
        guard isActive(on: clip) else { return "Off" }
        switch self {
        case .reduceNoise: return "\(Int((clip.denoiseStrength * 100).rounded()))%"
        case .enhance: return clip.upscale.title
        case .sharpen: return "\(clip.sharpenPercent)%"
        case .filmGrain: return "\(clip.filmGrainPercent)% · \(Clip.grainSizeTitle(clip.filmGrainSize))"
        }
    }

    /// Turns the effect off and puts its settings back to their defaults.
    @MainActor func clear(on clip: Clip) {
        switch self {
        case .reduceNoise:
            clip.denoise = false
            clip.denoiseStrength = 0.5
        case .enhance:
            clip.upscale = .off
        case .sharpen:
            clip.sharpen = 0
        case .filmGrain:
            clip.filmGrain = 0
            clip.filmGrainSize = 1
        }
    }

    /// The effect's settings, to save as a preset.
    @MainActor func values(of clip: Clip) -> [String: Double] {
        switch self {
        case .reduceNoise: ["on": clip.denoise ? 1 : 0, "strength": clip.denoiseStrength]
        case .enhance: ["factor": Double(clip.upscale.factor)]
        case .sharpen: ["amount": clip.sharpen]
        case .filmGrain: ["amount": clip.filmGrain, "size": clip.filmGrainSize]
        }
    }

    /// Sets the effect from saved `values`. Missing values use the defaults.
    @MainActor func apply(_ values: [String: Double], to clip: Clip) {
        switch self {
        case .reduceNoise:
            clip.denoise = (values["on"] ?? 0) > 0
            clip.denoiseStrength = min(1, max(0.1, values["strength"] ?? 0.5))
        case .enhance:
            let factor = Int(values["factor"] ?? 1)
            clip.upscale = UpscaleMode.allCases.first { $0.factor == factor } ?? .off
        case .sharpen:
            clip.sharpen = min(1, max(0, values["amount"] ?? 0))
        case .filmGrain:
            clip.filmGrain = min(1, max(0, values["amount"] ?? 0))
            clip.filmGrainSize = min(Double(FilmGrain.maxSize), max(Double(FilmGrain.minSize), values["size"] ?? 1))
        }
    }

    /// Whether `values` are what the clip has now (for the menu's checkmark).
    @MainActor func matches(_ values: [String: Double], on clip: Clip) -> Bool {
        let current = self.values(of: clip)
        return current.keys.allSatisfy { key in abs((current[key] ?? 0) - (values[key] ?? 0)) < 0.005 }
    }
}

/// A saved setting for one effect, like "Light Grain" for Film Grain.
struct EffectPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: EffectKind
    var name: String
    var values: [String: Double]
}

/// Presets for single effects, shared by all clips and kept between launches. (Whole sets of
/// effects are saved separately, in `EffectsPresetStore`.)
@Observable
final class EffectPresetStore {
    static let shared = EffectPresetStore()

    private let defaults: UserDefaults
    private let key = "effectPresets"
    private(set) var presets: [EffectPreset] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([EffectPreset].self, from: data) {
            presets = saved
        }
    }

    func presets(for kind: EffectKind) -> [EffectPreset] {
        presets.filter { $0.kind == kind }
    }

    /// Saves the clip's setting for `kind` under `name`, replacing that effect's preset with the same name.
    @MainActor func save(_ kind: EffectKind, name: String, from clip: Clip) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let values = kind.values(of: clip)
        if let index = presets.firstIndex(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            presets[index].name = trimmed
            presets[index].values = values
        } else {
            presets.append(EffectPreset(kind: kind, name: trimmed, values: values))
            presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        persist()
    }

    func delete(_ preset: EffectPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }
}
