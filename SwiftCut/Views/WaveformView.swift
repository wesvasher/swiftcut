import SwiftUI

/// The clip's sound under the filmstrip: each column's loudest moment, mirrored around the middle.
/// Only the drawn part of the strip (`drawn`, out of `contentWidth`) is drawn.
///
/// Lines mark where the level meters turn yellow (−12 dB) and red (−3 dB), and the waveform is
/// colored past them, so loud passages show at a glance. It's drawn after the volume changes, so
/// it follows the keyframes as they're dragged.
struct WaveformView: View {
    let waveform: Waveform?
    let isReading: Bool
    let contentWidth: CGFloat
    let drawn: ClosedRange<CGFloat>
    /// The volume keyframes: the waveform shows the sound after them.
    var volume = VolumeEnvelope()
    var duration: Double = 0
    /// A fixed change on top of the keyframes, in dB (a timeline clip's loudness matching).
    var gainDB = 0.0
    /// Draws the sound after Cinematic Sound evens it out.
    var isCinematic = false
    /// 0 draws it square and unframed, to sit inside something else's frame (a timeline clip).
    var cornerRadius: CGFloat = 6

    /// Heights (0 at the middle, 1 at the edge) where the meters' yellow and red zones start.
    static let warningHeight = height(forDB: OutputLevelMeter.warning)
    static let dangerHeight = height(forDB: OutputLevelMeter.danger)

    /// Where a level in dB is drawn, on the waveform's scale (`Waveform.floorDB` at the middle, 0 dB at the edge).
    static func height(forDB db: Double) -> Float {
        max(0, 1 - Float(db) / Waveform.floorDB)
    }

    /// The column heights after the volume changes, 0…1.
    static func levels(_ waveform: Waveform, columns: Int, contentWidth: CGFloat, drawnStart: CGFloat,
                       volume: VolumeEnvelope, duration: Double, gainDB: Double, isCinematic: Bool = false) -> [Float] {
        let count = waveform.peaks.count
        guard count > 0, contentWidth > 0 else { return [] }
        let perPoint = Double(count) / Double(contentWidth)
        return (0..<max(0, columns)).map { column in
            let x = Double(drawnStart) + Double(column)
            let first = min(count - 1, Int(x * perPoint))
            let last = max(first + 1, min(count, Int((x + 1) * perPoint)))
            var level: Float = 0
            for index in first..<last { level = max(level, waveform.height(at: index)) }
            guard level > 0 else { return 0 }
            var gain = gainDB
            if !volume.isEmpty, duration > 0 {
                gain += volume.gainDB(at: (x + 0.5) / Double(contentWidth) * duration)
            }
            guard gain.isFinite else { return 0 }
            // Heights are in decibels above the floor, so a volume change shifts them evenly.
            let shifted = min(1, max(0, level - Float(gain) / Waveform.floorDB))
            guard isCinematic, shifted > 0 else { return shifted }
            let db = Double((1 - shifted) * Waveform.floorDB)
            return height(forDB: CinematicDynamics.outputDB(forLevel: db))
        }
    }

    var body: some View {
        Canvas { context, size in
            guard let waveform, !waveform.peaks.isEmpty, size.width > 0, contentWidth > 0 else { return }
            let middle = size.height / 2
            let reach = middle - 1
            let levels = Self.levels(waveform, columns: Int(size.width.rounded(.up)), contentWidth: contentWidth,
                                     drawnStart: drawn.lowerBound, volume: volume, duration: duration, gainDB: gainDB,
                                     isCinematic: isCinematic)
            let warning = Self.warningHeight, danger = Self.dangerHeight

            // Each column in up to three parts: normal up to the warning line, yellow to the danger line, red above.
            var normal = Path(), loud = Path(), tooLoud = Path()
            func band(_ path: inout Path, _ x: CGFloat, from low: Float, to high: Float) {
                guard high > low else { return }
                let top = CGFloat(high) * reach, bottom = CGFloat(low) * reach
                path.addRect(CGRect(x: x, y: middle - top, width: 1, height: top - bottom))
                path.addRect(CGRect(x: x, y: middle + bottom, width: 1, height: top - bottom))
            }
            for (column, level) in levels.enumerated() {
                let x = CGFloat(column)
                let half = max(0.5, CGFloat(min(level, warning)) * reach)
                normal.addRect(CGRect(x: x, y: middle - half, width: 1, height: half * 2))
                band(&loud, x, from: warning, to: min(level, danger))
                band(&tooLoud, x, from: danger, to: level)
            }
            // Strongest at the middle line, fading toward the peaks, so it reads lighter than a solid block.
            let shading = Gradient(stops: [
                .init(color: .accentColor.opacity(0.2), location: 0),
                .init(color: .accentColor.opacity(0.65), location: 0.5),
                .init(color: .accentColor.opacity(0.2), location: 1),
            ])
            context.fill(normal, with: .linearGradient(shading, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.fill(loud, with: .color(.yellow.opacity(0.85)))
            context.fill(tooLoud, with: .color(.red.opacity(0.9)))

            // The warning (−12 dB) and danger (−3 dB) lines, above and below the middle.
            for (height, color) in [(warning, Color.yellow), (danger, Color.red)] {
                var line = Path()
                for y in [middle - CGFloat(height) * reach, middle + CGFloat(height) * reach] {
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(line, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if cornerRadius > 0 {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.15))
            }
            if isReading { ProgressView().controlSize(.mini) }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

extension Clip {
    /// Reads the waveform the first time it's needed (it's kept on the clip after that).
    func readWaveform() async {
        guard hasAudio, !isWaveformRead, isLoaded else { return }
        if waveformRead == nil {
            let url = url, duration = duration
            waveformRead = Task.detached(priority: .utility) {
                try? await Waveform.read(url: url, duration: duration)
            }
        }
        let waveform = await waveformRead?.value
        // Kept even if this view went away meanwhile, so the clip isn't read again.
        guard !isWaveformRead else { return }
        self.waveform = waveform
        isWaveformRead = true
        waveformRead = nil
    }
}
