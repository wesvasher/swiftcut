import SwiftUI

/// Develop RAW: turns camera RAW photos into a clip. A large preview of one photo, developed as
/// the video will be, with a filmstrip to pick which; Exposure, Highlights, and Shadows; the
/// Waveform, RGB Parade, and Histogram to check nothing clips; and the format to make the video
/// in, from compressed to the highest-quality ProRes. Create Clip makes it and adds it to the project.
struct RawDeveloperSheet: View {
    @Environment(ProjectStore.self) private var store
    let request: RawDevelopRequest
    @State private var settings: RawDevelopSettings
    @State private var frameIndex = 0
    @State private var preview: CGImage?
    @State private var scopes: ScopeData?
    @State private var previewError: String?
    @State private var isRendering = false
    @State private var thumbnails: [Int: CGImage] = [:]
    /// The first photo's size, for Match Images and the size estimate.
    @State private var photoSize: CGSize?

    init(request: RawDevelopRequest) {
        self.request = request
        _settings = State(initialValue: RawDevelopSettings(from: request.sequences.first ?? ImageSequence(name: "", imagePaths: [])))
    }

    private var urls: [URL] { request.imageURLs }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                previewArea
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        developControls
                        scopesBlock
                        outputControls
                    }
                    .padding(16)
                }
                .frame(width: 330)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1080, idealWidth: 1200, minHeight: 720, idealHeight: 800)
        .task(id: PreviewKey(index: frameIndex, develop: settings.develop)) { await renderPreview() }
        .task { await loadPhotoInfo() }
    }

    private struct PreviewKey: Hashable {
        let index: Int
        let develop: ImageSequence.RawDevelop
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.isNewVersion ? "Make a New Clip from the RAW Photos" : "Develop RAW Photos")
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let count = urls.count
        let clips = request.sequences.count
        let photos = count == 1 ? "1 RAW photo" : "\(count.formatted()) RAW photos"
        let what = clips == 1 ? "one clip" : "\(clips) clips"
        return "\(photos) from “\(request.sequences.first?.name ?? "")”, made into \(what). The RAW files aren't changed."
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Each RAW photo is developed with these settings and saved as \(settings.format.title) (\(settings.format.bitDepth)-bit). You can make another version later from the clip's Image Sequence section.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel", role: .cancel) { store.cancelRawDevelop() }
                .keyboardShortcut(.cancelAction)
            Button(request.sequences.count == 1 ? "Create Clip" : "Create \(request.sequences.count) Clips") {
                store.finishRawDevelop(request, settings: settings)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(urls.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Preview and filmstrip

    private var previewArea: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            filmstrip
        }
    }

    /// The photos side by side; click or drag to pick the one previewed.
    private var filmstrip: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let count = urls.count
                let shown = Self.shownIndexes(count: count, width: geometry.size.width)
                let cell = geometry.size.width / CGFloat(max(1, shown.count))
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(shown, id: \.self) { index in
                            ZStack {
                                Rectangle().fill(.quaternary)
                                if let image = thumbnails[index] {
                                    Image(decorative: image, scale: 1)
                                        .resizable()
                                        .scaledToFill()
                                }
                            }
                            .frame(width: cell, height: geometry.size.height)
                            .clipped()
                            .task { await loadThumbnail(index) }
                        }
                    }
                    // Where the previewed photo is.
                    let x = count > 1 ? CGFloat(frameIndex) / CGFloat(count - 1) * (geometry.size.width - 3) : 0
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: geometry.size.height)
                        .offset(x: x)
                        .shadow(radius: 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard count > 1 else { return }
                    let fraction = min(1, max(0, value.location.x / geometry.size.width))
                    frameIndex = Int((fraction * CGFloat(count - 1)).rounded())
                })
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 54)
            .help("Click or drag to preview another photo")

            HStack(spacing: 8) {
                Button("Previous Photo", systemImage: "chevron.left") { frameIndex = max(0, frameIndex - 1) }
                    .disabled(frameIndex == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Text(urls.isEmpty ? "" : "Photo \((frameIndex + 1).formatted()) of \(urls.count.formatted()) · \(urls[frameIndex].lastPathComponent)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Next Photo", systemImage: "chevron.right") { frameIndex = min(urls.count - 1, frameIndex + 1) }
                    .disabled(frameIndex >= urls.count - 1)
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Which photos the filmstrip shows: all of them, or evenly spaced ones when there are more
    /// than fit (about one every 56 points).
    static func shownIndexes(count: Int, width: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        let fits = max(1, Int(width / 56))
        guard count > fits else { return Array(0..<count) }
        return (0..<fits).map { Int((Double($0) + 0.5) / Double(fits) * Double(count)) }
    }

    // MARK: Develop

    private var developControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                groupTitle("Develop")
                Spacer()
                Button("Reset", systemImage: "arrow.counterclockwise") { settings.develop = ImageSequence.RawDevelop() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(settings.develop.isDefault)
                    .help("Put Exposure, Highlights, and Shadows back to their defaults")
            }
            control("Exposure", help: "Brighter or darker, in stops. The RAW has room to brighten shadows or darken highlights without losing detail.") {
                Slider(value: $settings.develop.exposure, in: ImageSequence.RawDevelop.exposureRange)
                NumberStepper(value: $settings.develop.exposure, range: ImageSequence.RawDevelop.exposureRange, step: 1.0 / 3,
                              unit: "EV", fractionDigits: 2,
                              presets: [(-2, "−2 stops"), (-1, "−1 stop"), (0, "Camera (0)"), (1, "+1 stop"), (2, "+2 stops")])
            }
            control("Highlights", help: "Highlight recovery: brings back the detail the camera's look clips to white (bright skies, lights), rolled off smoothly. 0% clips like the camera's own look.") {
                Slider(value: $settings.develop.highlightRecovery, in: 0...1)
                NumberStepper(value: percent(\.highlightRecovery), range: 0...100, step: 10, unit: "%",
                              presets: [(0, "Off (camera look)"), (50, "Some"), (100, "Full")])
            }
            control("Shadows", help: "How much the shadows are lifted. 100% is the camera's own amount.") {
                Slider(value: $settings.develop.shadows, in: ImageSequence.RawDevelop.shadowsRange)
                NumberStepper(value: percent(\.shadows), range: 0...200, step: 10, unit: "%",
                              presets: [(0, "No lift"), (50, "Less"), (100, "Camera (100%)"), (150, "More"), (200, "Most")])
            }
        }
    }

    private func control<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            content()
        }
        .controlSize(.small)
        .help(help)
    }

    private func percent(_ keyPath: WritableKeyPath<ImageSequence.RawDevelop, Double>) -> Binding<Double> {
        Binding(
            get: { (settings.develop[keyPath: keyPath] * 100).rounded() },
            set: { settings.develop[keyPath: keyPath] = $0 / 100 }
        )
    }

    // MARK: Scopes

    private var scopesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("Scopes")
            scope("Waveform") { LumaWaveformView(data: scopes) }
            scope("RGB Parade") { ParadeView(data: scopes) }
            scope("Histogram") { HistogramView(data: scopes) }
            ClippingReadout(data: scopes)
        }
    }

    private func scope<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    // MARK: Output

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupTitle("Output")
            VStack(alignment: .leading, spacing: 4) {
                Text("Format").font(.callout)
                Picker("Format", selection: $settings.format) {
                    Section("Compressed") {
                        ForEach([ImageSequence.OutputFormat.h264, .hevc10]) { Text($0.title).tag($0) }
                    }
                    Section("Apple ProRes") {
                        ForEach(ImageSequence.OutputFormat.allCases.filter { !$0.isCompressed }) { Text($0.title).tag($0) }
                    }
                }
                .labelsHidden()
                Text("\(settings.format.bitDepth)-bit. \(settings.format.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Frame Size").font(.callout)
                Picker("Frame Size", selection: $settings.frameSize) {
                    Text(photoSize.map { "Match Photos (\(Int(ImageSequence.even($0.width))) × \(Int(ImageSequence.even($0.height))))" } ?? "Match Photos")
                        .tag(ImageSequence.FrameSize?.none)
                    Divider()
                    ForEach(ImageSequence.frameSizes, id: \.size) { choice in
                        Text("\(choice.title) (\(choice.size.title))").tag(ImageSequence.FrameSize?.some(choice.size))
                    }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Frame Rate").font(.callout)
                Picker("Frame Rate", selection: $settings.frameRate) {
                    ForEach(rates, id: \.self) { Text(ImageSequence.frameRateTitle($0)).tag($0) }
                }
                .labelsHidden()
            }
            if let estimate {
                Text(estimate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    /// The menu's rates, plus the current one if it's a custom rate.
    private var rates: [Double] {
        ImageSequence.frameRates.contains(settings.frameRate) ? ImageSequence.frameRates
            : (ImageSequence.frameRates + [settings.frameRate]).sorted()
    }

    /// "About 2.1 GB for 80 photos at 6000 × 4000, 3.3 seconds at 24 fps."
    private var estimate: String? {
        guard let size = outputSize else { return nil }
        let fps = settings.frameRate
        let seconds = request.sequences.reduce(0) { total, original in
            var each = original
            settings.apply(to: &each)
            return total + each.duration
        }
        let bytes = settings.format.estimatedBytes(frameSize: size, fps: fps, seconds: seconds)
        return "About \(Int64(bytes).formatted(.byteCount(style: .file))) at \(Int(size.width)) × \(Int(size.height)), \(seconds.preciseTimecode) long."
    }

    private var outputSize: CGSize? {
        if let size = settings.frameSize { return size.cgSize }
        return photoSize.map { CGSize(width: ImageSequence.even($0.width), height: ImageSequence.even($0.height)) }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Loading

    private func renderPreview() async {
        guard urls.indices.contains(frameIndex) else { return }
        // Wait a moment so dragging a slider doesn't develop on every tick.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        isRendering = true
        defer { isRendering = false }
        let url = urls[frameIndex], develop = settings.develop
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ImageSequenceWriter.preview(url, develop: develop, longSide: 1800)
            }.value
            guard !Task.isCancelled else { return }
            preview = result.image
            scopes = result.scopes
            previewError = nil
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }

    private func loadPhotoInfo() async {
        guard let first = request.sequences.first else { return }
        photoSize = await Task.detached { ImageSequenceWriter.firstImageInfo(first)?.size }.value
    }

    private func loadThumbnail(_ index: Int) async {
        guard thumbnails[index] == nil, urls.indices.contains(index) else { return }
        let url = urls[index]
        if let image = await Task.detached(priority: .utility, operation: { ImageSequenceWriter.thumbnail(url) }).value {
            thumbnails[index] = image
        }
    }
}
