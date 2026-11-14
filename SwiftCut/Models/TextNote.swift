import AppKit
import CoreImage
import CoreText

/// A text note shown over a clip from its in point to its out point: white text on a soft,
/// see-through black rounded box, so it reads over any picture. Belongs to the source video
/// (its times are in the source), so subclips and the timeline show it too, and exports keep it.
nonisolated struct TextNote: Codable, Hashable, Identifiable, Sendable {
    enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottom, middle, top
        var id: Self { self }
        var title: String {
            switch self {
            case .bottom: "Bottom"
            case .middle: "Middle"
            case .top: "Top"
            }
        }
    }

    enum Weight: String, Codable, CaseIterable, Identifiable, Sendable {
        case regular, medium, semibold, bold
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    var id = UUID()
    var text: String
    /// Seconds into the source video.
    var start: Double
    var end: Double
    /// Fades in at the in point and out at the out point.
    var fades = true
    /// A font family, or `nil` for the system font (the most readable on screen).
    var fontFamily: String?
    var weight = Weight.semibold
    /// Text height as a percentage of the frame's height, so it looks the same at any size.
    var size = 4.5
    var position = Position.bottom

    static let defaultLength = 3.0
    static let sizeRange = 2.0...15.0
    /// The Size menu's choices.
    static let sizePresets: [(value: Double, title: String)] = [
        (3.5, "Small"), (4.5, "Medium"), (6, "Large"), (8, "Extra Large"),
    ]
    /// The Font menu's families, after System.
    static let fontFamilies = ["Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Georgia", "Baskerville", "Menlo"]

    init(id: UUID = UUID(), text: String = "Note", start: Double, end: Double) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        fades = (try? c.decodeIfPresent(Bool.self, forKey: .fades)) ?? true
        fontFamily = try? c.decodeIfPresent(String.self, forKey: .fontFamily)
        weight = (try? c.decodeIfPresent(Weight.self, forKey: .weight)) ?? .semibold
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 4.5
        position = (try? c.decodeIfPresent(Position.self, forKey: .position)) ?? .bottom
    }

    /// How long fading in (and out) takes: half a second, or less for a short note.
    var fadeDuration: Double { min(0.5, max(0, end - start) / 3) }

    /// How visible it is at `time` (source seconds), 0…1.
    func opacity(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        guard fades, fadeDuration > 0 else { return 1 }
        return min(1, (time - start) / fadeDuration, (end - time) / fadeDuration)
    }
}

/// The notes the preview shows, changed without rebuilding it while typing or dragging.
/// Exports and the timeline get one holding the clip's notes.
nonisolated final class LiveNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [TextNote]

    init(_ notes: [TextNote] = []) {
        self.notes = notes
    }

    var value: [TextNote] {
        get { lock.withLock { notes } }
        set { lock.withLock { notes = newValue } }
    }
}

/// Draws text notes over a frame with Core Text and Core Image.
nonisolated enum TextNoteStage {
    /// `image` covers `frame`; adds the notes showing at `time` (source seconds).
    static func apply(_ image: CIImage, notes: [TextNote], at time: Double, frame: CGRect) -> CIImage {
        var result = image
        for note in notes {
            let opacity = note.opacity(at: time)
            guard opacity > 0, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let box = box(for: note, frameSize: frame.size) else { continue }
            let size = CGSize(width: box.width, height: box.height)
            let margin = frame.height * 0.06
            let x = frame.minX + (frame.width - size.width) / 2
            let y: CGFloat = switch note.position {
            case .bottom: frame.minY + margin
            case .middle: frame.midY - size.height / 2
            case .top: frame.maxY - margin - size.height
            }
            var overlay = CIImage(cgImage: box).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
            if opacity < 1 {
                overlay = overlay.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
                ])
            }
            // Over the picture in gamma-encoded values, as design apps do, so the box's darkness
            // looks as intended.
            result = overlay.applyingFilter("CILinearToSRGBToneCurve")
                .composited(over: result.applyingFilter("CILinearToSRGBToneCurve"))
                .applyingFilter("CISRGBToneCurveToLinear")
                .cropped(to: frame)
        }
        return result
    }

    // MARK: Drawing the box

    private struct Key: Hashable {
        let text: String
        let fontFamily: String?
        let weight: TextNote.Weight
        let size: Double
        let frameSize: CGSize
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CGImage] = [:]

    /// The note's text in its box, drawn once and kept (frames reuse it).
    static func box(for note: TextNote, frameSize: CGSize) -> CGImage? {
        let key = Key(text: note.text, fontFamily: note.fontFamily, weight: note.weight, size: note.size, frameSize: frameSize)
        if let cached = lock.withLock({ cache[key] }) { return cached }
        guard let image = draw(note, frameSize: frameSize) else { return nil }
        lock.withLock {
            if cache.count > 64 { cache.removeAll() }
            cache[key] = image
        }
        return image
    }

    static func font(for note: TextNote, pointSize: CGFloat) -> CTFont {
        if let family = note.fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: weightNumber(note.weight), size: pointSize) {
            return font as CTFont
        }
        return NSFont.systemFont(ofSize: pointSize, weight: note.weight.nsWeight) as CTFont
    }

    /// NSFontManager's 0–15 weights.
    private static func weightNumber(_ weight: TextNote.Weight) -> Int {
        switch weight {
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        }
    }

    private static func draw(_ note: TextNote, frameSize: CGSize) -> CGImage? {
        let pointSize = max(6, frameSize.height * CGFloat(min(TextNote.sizeRange.upperBound, max(TextNote.sizeRange.lowerBound, note.size))) / 100)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: note.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: note, pointSize: pointSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        // Wraps at 80% of the frame's width.
        let padding = CGSize(width: pointSize * 0.75, height: pointSize * 0.4)
        let maxText = CGSize(width: frameSize.width * 0.8 - padding.width * 2, height: .greatestFiniteMagnitude)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, maxText, nil)
        let box = CGSize(width: ceil(textSize.width + padding.width * 2), height: ceil(textSize.height + padding.height * 2))
        guard box.width > 0, box.height > 0,
              let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The box: black, a little see-through, with smooth round corners.
        let radius = min(pointSize * 0.45, box.height / 2)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.6))
        context.fillPath()
        // The text, centered in it.
        let textRect = CGRect(x: padding.width, y: padding.height, width: box.width - padding.width * 2, height: ceil(textSize.height))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}

extension Clip {
    /// Adds a note at `time` (source seconds), `TextNote.defaultLength` long or to the end of the
    /// clip, moved earlier if it's too close to the end. Returns its id.
    @discardableResult
    func addNote(at time: Double, text: String = "Note") -> UUID {
        let length = min(TextNote.defaultLength, max(0.1, duration))
        let start = max(0, min(time, duration - length))
        let note = TextNote(text: text, start: start, end: min(duration, start + length))
        notes.append(note)
        notes.sort { $0.start < $1.start }
        return note.id
    }

    /// Changes one note, by id.
    func updateNote(_ id: UUID, _ change: (inout TextNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        change(&note)
        // In before out, inside the clip, at least a tenth of a second long.
        note.start = min(max(0, note.start), max(0, duration - 0.1))
        note.end = min(duration, max(note.start + 0.1, note.end))
        if notes[index] != note { notes[index] = note }
    }

    func removeNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
    }
}
