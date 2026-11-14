import SwiftUI

/// The clip inspector's settings for a source video made from images: frame size, how images
/// fit it, frame rate, and (for a single image) how long it lasts. Changing one makes the video again.
struct ImageSequenceSection: View {
    @Environment(ProjectStore.self) private var store
    @Bindable var clip: Clip
    /// The first image's size, for Match Images.
    @State private var imageSize: CGSize?

    /// The Frame Size menu's choices.
    private enum SizeChoice: Hashable {
        case matchImages
        case preset(ImageSequence.FrameSize)
        case custom
    }

    /// The Frame Rate menu's choices.
    private enum RateChoice: Hashable {
        case rate(Double)
        case custom
    }

    var body: some View {
        if let sequence = clip.imageSequence {
            InspectorSection(sequence.isStill ? "Still Image" : "Image Sequence") {
                if !sequence.isStill {
                    InspectorRow("Images", sequence.imagePaths.count.formatted())
                }
                GridRow {
                    InspectorLabel("Frame Size")
                    Picker("Frame Size", selection: sizeChoice) {
                        Text(imageSize.map { "Match Images (\(Int(ImageSequence.even($0.width))) × \(Int(ImageSequence.even($0.height))))" }
                             ?? "Match Images")
                            .tag(SizeChoice.matchImages)
                        Divider()
                        ForEach(ImageSequence.frameSizes, id: \.size) { choice in
                            Text("\(choice.title) (\(choice.size.title))").tag(SizeChoice.preset(choice.size))
                        }
                        Divider()
                        Text("Custom…").tag(SizeChoice.custom)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("The video's frame size. Match Images uses the first image's size.")
                if sequence.isCustomSize {
                    GridRow {
                        InspectorLabel("Custom Size")
                        HStack(spacing: 4) {
                            dimensionField("Width", value: \.width)
                            Text("×").foregroundStyle(.secondary)
                            dimensionField("Height", value: \.height)
                            Text("px").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GridRow {
                    InspectorLabel("Fit")
                    Picker("Fit", selection: binding(\.fit)) {
                        ForEach(TimelineSettings.Fit.allCases) { fit in
                            Text(fit.title).tag(fit)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("How images of a different shape than the frame are placed")
                GridRow {
                    InspectorLabel("Frame Rate")
                    Picker("Frame Rate", selection: rateChoice) {
                        ForEach(ImageSequence.frameRates, id: \.self) { fps in
                            Text(ImageSequence.frameRateTitle(fps)).tag(RateChoice.rate(fps))
                        }
                        Divider()
                        Text(sequence.isCustomFrameRate ? "Custom (\(ImageSequence.frameRateTitle(sequence.frameRate)))" : "Custom…")
                            .tag(RateChoice.custom)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(sequence.isStill ? "Frames per second of the still's video"
                      : "How many images play each second")
                if sequence.isCustomFrameRate {
                    GridRow {
                        InspectorLabel("Custom Rate")
                        HStack(spacing: 4) {
                            TextField("fps", value: frameRate, format: .number.precision(.fractionLength(0...3)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                                .help("Any rate from \(ImageSequence.minFrameRate.formatted()) to \(ImageSequence.maxFrameRate.formatted()) frames per second. Press Return to use it.")
                            Text("fps").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if sequence.isStill {
                    GridRow {
                        InspectorLabel("Duration")
                        HStack(spacing: 4) {
                            TextField("Seconds", value: stillDuration, format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                                .help("How long the image shows, in seconds. Press Return to use it.")
                            Text("sec").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    InspectorRow("Length", "\(sequence.duration.preciseTimecode) (\(sequence.frameCount.formatted()) frames)")
                }
                if let raw = sequence.raw {
                    rawRows(raw, sequence: sequence)
                }
                status(sequence)
            }
            .task(id: sequence.imagePaths.first) {
                let first = sequence
                imageSize = await Task.detached { ImageSequenceWriter.firstImageInfo(first)?.size }.value
            }
        }
    }

    // MARK: RAW

    /// How the RAW photos were developed into this clip, and making a new clip with other settings.
    /// The settings can't change here: the clip is already made from them. The Develop RAW
    /// dialog makes a new one, with a preview and scopes.
    @ViewBuilder
    private func rawRows(_ raw: ImageSequence.RawDevelop, sequence: ImageSequence) -> some View {
        GridRow {
            Divider().gridCellColumns(2)
        }
        GridRow {
            Text("RAW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .gridCellColumns(2)
        }
        InspectorRow("Exposure", Self.exposureText(raw.exposure))
        InspectorRow("Highlights", "\(Int((raw.highlightRecovery * 100).rounded()))% recovered")
        InspectorRow("Shadows", "\(Int((raw.shadows * 100).rounded()))%")
        InspectorRow("Made As", "\(sequence.format(hasAlpha: false).title), \(sequence.format(hasAlpha: false).bitDepth)-bit")
        GridRow {
            Text("This clip was developed from the original RAW photos with these settings. To try other settings or another format, make a new clip from the same RAW files, with a preview and scopes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .gridCellColumns(2)
        }
        GridRow {
            Button("New Clip from RAW…", systemImage: "camera.aperture") { store.developNewClip(from: clip) }
                .disabled(clip.sequenceProgress != nil && !clip.isLoaded)
                .help("Open Develop RAW to make a new clip from these RAW photos: adjust exposure, highlights, and shadows with a preview and scopes, and pick the format. This clip stays as it is.")
                .gridCellColumns(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "+0.33 EV", "−1.00 EV", "0 EV".
    static func exposureText(_ stops: Double) -> String {
        guard abs(stops) > 0.004 else { return "0 EV" }
        return (stops > 0 ? "+" : "−") + String(format: "%.2f EV", abs(stops))
    }

    @ViewBuilder
    private func status(_ sequence: ImageSequence) -> some View {
        if let progress = clip.sequenceProgress {
            GridRow {
                InspectorLabel("Making Video")
                ProgressView(value: progress)
                    .frame(maxWidth: .infinity)
            }
        } else if let error = clip.sequenceError {
            GridRow {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(2)
            }
        }
        GridRow {
            Text("SwiftCut makes a ProRes video from the images and keeps it in its cache. Changing these settings makes it again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .gridCellColumns(2)
        }
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<ImageSequence, Value>) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { clip.imageSequence![keyPath: keyPath] },
            set: { value in
                guard clip.imageSequence?[keyPath: keyPath] != value else { return }
                clip.imageSequence?[keyPath: keyPath] = value
            }
        )
    }

    private var sizeChoice: Binding<SizeChoice> {
        Binding(
            get: {
                guard let sequence = clip.imageSequence else { return .matchImages }
                if sequence.isCustomSize { return .custom }
                return sequence.frameSize.map(SizeChoice.preset) ?? .matchImages
            },
            set: { choice in
                guard var sequence = clip.imageSequence else { return }
                switch choice {
                case .matchImages:
                    sequence.frameSize = nil
                    sequence.isCustomSize = false
                case .preset(let size):
                    sequence.frameSize = size
                    sequence.isCustomSize = false
                case .custom:
                    // Start from the size it has now.
                    let current = sequence.outputSize(firstImage: imageSize ?? CGSize(width: 1920, height: 1080))
                    sequence.frameSize = .init(width: Int(current.width), height: Int(current.height))
                    sequence.isCustomSize = true
                }
                if clip.imageSequence != sequence { clip.imageSequence = sequence }
            }
        )
    }

    private var rateChoice: Binding<RateChoice> {
        Binding(
            get: {
                guard let sequence = clip.imageSequence, !sequence.isCustomFrameRate else { return .custom }
                return .rate(sequence.frameRate)
            },
            set: { choice in
                guard var sequence = clip.imageSequence else { return }
                switch choice {
                case .rate(let fps):
                    sequence.frameRate = fps
                    sequence.isCustomFrameRate = false
                case .custom:
                    sequence.isCustomFrameRate = true
                }
                if clip.imageSequence != sequence { clip.imageSequence = sequence }
            }
        )
    }

    private var frameRate: Binding<Double> {
        Binding(
            get: { clip.imageSequence?.frameRate ?? 24 },
            set: { fps in
                let fps = min(ImageSequence.maxFrameRate, max(ImageSequence.minFrameRate, fps))
                if clip.imageSequence?.frameRate != fps { clip.imageSequence?.frameRate = fps }
            }
        )
    }

    private var stillDuration: Binding<Double> {
        Binding(
            get: { clip.imageSequence?.stillDuration ?? 5 },
            set: { seconds in
                let seconds = min(3600, max(0.1, seconds))
                if clip.imageSequence?.stillDuration != seconds { clip.imageSequence?.stillDuration = seconds }
            }
        )
    }

    private func dimensionField(_ title: String, value: WritableKeyPath<ImageSequence.FrameSize, Int>) -> some View {
        TextField(title, value: Binding(
            get: { clip.imageSequence?.frameSize?[keyPath: value] ?? 0 },
            set: { pixels in
                // Even sizes from 16 to 8K, as the video encoder needs.
                let pixels = Int(ImageSequence.even(CGFloat(min(8192, max(16, pixels)))))
                guard var size = clip.imageSequence?.frameSize, size[keyPath: value] != pixels else { return }
                size[keyPath: value] = pixels
                clip.imageSequence?.frameSize = size
            }
        ), format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder)
        .frame(width: 58)
        .help("\(title) in pixels. Press Return to use it.")
    }
}

/// Over the clip viewer while the video is made from the images.
struct SequenceProgressBadge: View {
    let progress: Double
    /// The first time, there's nothing to play yet; after a settings change the old video plays meanwhile.
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress)
                .frame(width: 120)
            Text(isFirst ? "Making video from images… \(percent)" : "Updating video… \(percent)")
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    private var percent: String { progress.formatted(.percent.precision(.fractionLength(0))) }
}

/// A number to type, − and + buttons, and a menu of common values. Changes only when a button
/// or menu item is clicked or Return is pressed, not while typing, since each change can mean
/// making a video again.
struct NumberStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var fractionDigits = 0
    let presets: [(value: Double, title: String)]

    var body: some View {
        HStack(spacing: 4) {
            Button("Less", systemImage: "minus") { set(Self.stepped(value, -1, by: step)) }
                .disabled(value <= range.lowerBound + 1e-9)
            TextField(unit, value: Binding(get: { value }, set: { set($0) }),
                      format: .number.precision(.fractionLength(0...fractionDigits)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
            Text(unit).foregroundStyle(.secondary)
            Button("More", systemImage: "plus") { set(Self.stepped(value, 1, by: step)) }
                .disabled(value >= range.upperBound - 1e-9)
            Menu {
                ForEach(presets, id: \.value) { preset in
                    Button {
                        set(preset.value)
                    } label: {
                        if abs(preset.value - value) < 1e-6 {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Common values")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One step down (−1) or up (1), landing on the step's grid: 1/3-stop steps go 0.33, 0.67, 1.
    static func stepped(_ value: Double, _ direction: Int, by step: Double) -> Double {
        var position = value / step
        // A value shown rounded (0.33 for a third) counts as on the grid, so steps don't stick.
        if abs(position - position.rounded()) < 0.05 { position = position.rounded() }
        let next = direction > 0 ? (position + 1e-6).rounded(.down) + 1 : (position - 1e-6).rounded(.up) - 1
        return next * step
    }

    /// Held to the range, and rounded to what's shown.
    private func set(_ newValue: Double) {
        let scale = pow(10, Double(fractionDigits))
        let clamped = min(range.upperBound, max(range.lowerBound, (newValue * scale).rounded() / scale))
        if abs(clamped - value) > 1e-9 { value = clamped }
    }
}
