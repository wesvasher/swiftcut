import SwiftUI

/// The loudness meter's scale: −40 to 0 LUFS. Both bars and the numbers under them share it,
/// and a line marks the timeline's target, so lining clips up is a matter of reaching it.
enum LoudnessMeter {
    static let range = -40.0...0.0

    static func fraction(_ lufs: Double) -> Double {
        min(1, max(0, (lufs - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
}

/// How loud the clip is right now, while it plays.
struct LiveLoudnessBar: View {
    let audio: TimelineAudio
    /// Where the clip plays on the timeline (seconds). Sound from elsewhere isn't shown.
    let span: Range<Double>
    let target: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let level = audio.level.flatMap { span.contains($0.time) ? $0 : nil }
            LoudnessBar(value: level?.momentary, original: nil, target: target, isLive: true)
        }
    }
}

/// The numbers under the bars.
struct LoudnessScale: View {
    var body: some View {
        GeometryReader { geometry in
            ForEach([-40, -30, -20, -10, 0], id: \.self) { mark in
                Text(mark == 0 ? "0" : "−\(-mark)")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: LoudnessMeter.fraction(Double(mark)) * geometry.size.width, y: geometry.size.height / 2)
            }
        }
        .frame(height: 10)
    }
}

/// One horizontal bar: filled up to `value` LUFS.
struct LoudnessBar: View {
    let value: Double?
    let original: Double?
    let target: Double?
    var isLive = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let value, value > LoudnessMeter.range.lowerBound {
                    Capsule()
                        .fill(color(for: value).gradient)
                        .frame(width: max(4, LoudnessMeter.fraction(value) * width))
                        .animation(isLive ? .linear(duration: 1.0 / 30) : .default, value: value)
                }
                if let original {
                    Rectangle()
                        .fill(.secondary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: LoudnessMeter.fraction(original) * width - 1)
                }
                if let target {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: geometry.size.height + 4)
                        .offset(x: LoudnessMeter.fraction(target) * width - 1)
                }
            }
        }
        .frame(height: 8)
    }

    /// Green near the target, yellow when well above it, red near full scale.
    private func color(for value: Double) -> Color {
        if value > -6 { return .red }
        if let target, value > target + 3 { return .yellow }
        return .green
    }
}

extension Double {
    /// "−16.0" with a real minus sign.
    var loudnessText: String {
        String(format: "%.1f", self).replacingOccurrences(of: "-", with: "−")
    }

    /// "+7.4 dB", "−3.0 dB", or "0 dB".
    var decibelChangeText: String {
        let rounded = (self * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return (rounded > 0 ? "+" : "") + rounded.loudnessText + " dB"
    }
}

/// A small stereo level meter for a viewer's output (timeline or clip): one thin bar per channel
/// showing the loudest sample of the last moment, −60 to 0 dB (green, yellow above −12, red above −3).
/// The track is tinted and ticked where those zones start, so the safe area shows even in silence.
struct OutputLevelMeter: View {
    let audio: TimelineAudio
    var help = "The timeline's sound level as it plays (left and right)"

    static let floor = -60.0
    /// Where yellow (getting loud) and red (close to clipping) start.
    static let warning = -12.0
    static let danger = -3.0
    /// Faint ticks below the warning zone, every 12 dB.
    static let minorTicks = [-48.0, -36.0, -24.0]

    /// How far along the bar `decibels` is, 0…1.
    static func fraction(_ decibels: Double) -> Double {
        decibels.isFinite ? min(1, max(0, 1 - decibels / floor)) : 0
    }

    private static let barHeight: CGFloat = 4
    private static let barSpacing: CGFloat = 2
    /// How far the zone ticks reach past the bars, above and below.
    private static let tickOverhang: CGFloat = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let peaks = channels(audio.level?.peaks ?? [])
            VStack(spacing: Self.barSpacing) {
                ForEach(peaks.indices, id: \.self) { index in
                    bar(peaks[index])
                }
            }
            .padding(.vertical, Self.tickOverhang)
            .overlay { ticks }
        }
        .frame(width: 80)
        .help(help + ". Green is a good level; yellow (above −12 dB) is getting loud; red (above −3 dB) is close to distorting.")
    }

    /// Always two bars: mono shows in both, more channels show the first two.
    private func channels(_ peaks: [Double]) -> [Double] {
        switch peaks.count {
        case 0: [-.infinity, -.infinity]
        case 1: [peaks[0], peaks[0]]
        default: Array(peaks.prefix(2))
        }
    }

    private func bar(_ decibels: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = Self.fraction(decibels)
            let warning = Self.fraction(Self.warning) * width, danger = Self.fraction(Self.danger) * width
            ZStack(alignment: .leading) {
                // The track, tinted where the zones are.
                Capsule().fill(.quaternary)
                Rectangle().fill(.yellow.opacity(0.22))
                    .frame(width: danger - warning)
                    .offset(x: warning)
                Rectangle().fill(.red.opacity(0.3))
                    .frame(width: width - danger)
                    .offset(x: danger)
                Capsule()
                    .fill(LinearGradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: Self.fraction(Self.warning) - 0.02),
                        .init(color: .yellow, location: Self.fraction(Self.warning)),
                        .init(color: .yellow, location: Self.fraction(Self.danger) - 0.02),
                        .init(color: .red, location: Self.fraction(Self.danger)),
                    ], startPoint: .leading, endPoint: .trailing))
                    // The gradient spans the whole bar; the mask shows the part up to the level.
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fraction * width)
                    }
                    .animation(.linear(duration: 1.0 / 30), value: fraction)
            }
            .clipShape(Capsule())
        }
        .frame(height: Self.barHeight)
    }

    /// Lines across both bars: faint ones every 12 dB, and stronger ones where yellow and red start.
    private var ticks: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            ForEach(Self.minorTicks, id: \.self) { db in
                Rectangle()
                    .fill(.primary.opacity(0.25))
                    .frame(width: 1, height: height - Self.tickOverhang * 2)
                    .position(x: Self.fraction(db) * width, y: height / 2)
            }
            ForEach([(Self.warning, Color.yellow), (Self.danger, Color.red)], id: \.0) { db, color in
                Rectangle()
                    .fill(color)
                    .frame(width: 1, height: height)
                    .position(x: Self.fraction(db) * width, y: height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
