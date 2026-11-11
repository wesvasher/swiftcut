import Foundation

/// Cinematic Sound: evens out the loud and quiet parts, the way film and TV mixes do.
///
/// 1. A compressor turns down whatever goes above `threshold`, by `ratio` (3:1: 3 dB over
///    comes out 1 dB over), easing in over a soft `knee`.
/// 2. Make-up gain turns everything back up by `makeup`, so the quiet parts end up closer to
///    the loud ones. Near silence gets less of it, so background hiss isn't raised.
/// 3. A limiter holds the result under `ceiling`, so the boost never distorts.
///
/// Both channels are turned down together, so the stereo picture doesn't shift. Runs one frame
/// (a sample per channel) at a time, in the audio tap that also applies the volume.
nonisolated struct CinematicDynamics {
    static let threshold = -20.0
    static let ratio = 3.0
    static let knee = 10.0
    static let makeup = 6.0
    static let ceiling = -1.0
    /// Below this the make-up gain fades out, reaching none at `silence`.
    static let quiet = -50.0
    static let silence = -60.0

    /// The compressor's level follower, in dB.
    private var level = -120.0
    private var limiterGain = 1.0
    private let attack: Double
    private let release: Double
    private let limiterRelease: Double
    private static let ceilingLinear = pow(10, ceiling / 20)

    init(sampleRate: Double) {
        let rate = max(1, sampleRate)
        // Reacts to a rise in about 5 ms and lets go over about 200 ms: smooth, without pumping.
        attack = 1 - exp(-1 / (0.005 * rate))
        release = 1 - exp(-1 / (0.2 * rate))
        limiterRelease = 1 - exp(-1 / (0.05 * rate))
    }

    /// How much the compressor and make-up change a steady sound at `inputDB`, in dB
    /// (the limiter aside). Also used to draw the waveform after Cinematic Sound.
    static func gainDB(forLevel inputDB: Double) -> Double {
        let over = inputDB - threshold
        let reduction: Double
        if over <= -knee / 2 {
            reduction = 0
        } else if over < knee / 2 {
            // The knee: the ratio eases in over `knee` dB.
            reduction = (1 / ratio - 1) * pow(over + knee / 2, 2) / (2 * knee)
        } else {
            reduction = (1 / ratio - 1) * over
        }
        let makeupShare = min(1, max(0, (inputDB - silence) / (quiet - silence)))
        return reduction + makeup * makeupShare
    }

    /// The level of a steady sound at `inputDB` after Cinematic Sound, limiter included.
    static func outputDB(forLevel inputDB: Double) -> Double {
        guard inputDB.isFinite else { return inputDB }
        return min(ceiling, inputDB + gainDB(forLevel: inputDB))
    }

    /// The gain for one frame whose loudest channel is `peak` (0…1, after the volume changes).
    mutating func gain(forPeak peak: Float) -> Float {
        let input = Double(peak)
        let inputDB = input > 1e-6 ? 20 * log10(input) : -120
        level += (inputDB - level) * (inputDB > level ? attack : release)
        let compressed = pow(10, Self.gainDB(forLevel: level) / 20)

        // The limiter: straight down to the ceiling, then easing back up.
        let out = input * compressed
        let needed = out > Self.ceilingLinear ? Self.ceilingLinear / out : 1
        limiterGain = min(needed, limiterGain + (1 - limiterGain) * limiterRelease)
        return Float(compressed * limiterGain)
    }
}
