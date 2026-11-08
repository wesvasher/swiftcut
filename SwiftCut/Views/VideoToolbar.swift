import AppKit
import SwiftUI

/// The bar above a video viewer (clip viewer and timeline): the picture size, then Copy Frame,
/// Export Images, quality, zoom, and the master volume on the right. `leading` holds controls only one viewer has.
///
/// Text never wraps. When the viewer is too narrow for everything, controls move into a ⋯ menu
/// at the right end, one at a time from the right (`Overflow`): the volume, the picture size, zoom,
/// quality, then Export Images and Copy Frame. `leading` always stays. (The viewer itself can't
/// have a minimum width: beside the inspector that made the window re-layout in a loop until it locked up.)
struct VideoToolbar<Leading: View>: View {
    /// The picture's size in pixels, or `nil` if not known yet.
    let pictureSize: CGSize?
    @Binding var zoom: ViewerZoom
    @Binding var quality: PreviewQuality
    /// The Quality menu's tooltip.
    let qualityHelp: String
    let canCopy: Bool
    let isExporting: Bool
    let copyFrame: () -> Void
    let exportImages: () -> Void
    @ViewBuilder var leading: () -> Leading

    /// How many controls are in the ⋯ menu: each step moves one more there, from the right.
    enum Overflow: Int, CaseIterable, Comparable {
        case none, volume, pictureSize, zoom, quality, frameActions

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        /// Whether `part` is in the menu at this step.
        func contains(_ part: Overflow) -> Bool { part != .none && part <= self }
    }

    var body: some View {
        // The first that fits; the last is used (and clipped) when nothing does.
        ViewThatFits(in: .horizontal) {
            ForEach(Overflow.allCases, id: \.self) { overflow in
                bar(overflow)
            }
        }
        // Never asks the window for a minimum width; a bar too wide is clipped instead.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(.bar)
    }

    private var pictureSizeText: String? {
        guard let pictureSize, pictureSize != .zero else { return nil }
        return "\(Int(pictureSize.width)) × \(Int(pictureSize.height))"
    }

    private func bar(_ overflow: Overflow) -> some View {
        HStack(spacing: 12) {
            leading()
                .lineLimit(1)
                .fixedSize()
            if !overflow.contains(.pictureSize), let pictureSizeText {
                Text(pictureSizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if !overflow.contains(.frameActions) {
                Button("Copy Frame", systemImage: "doc.on.doc", action: copyFrame)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!canCopy)
                    .help("Copy the frame on screen to the clipboard, at full size")
                Button("Export Images", systemImage: "photo.badge.arrow.down", action: exportImages)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!canCopy || isExporting)
                    .help("Save the full frame, and the part in view, as PNG images in the project's folder")
            }
            if !overflow.contains(.quality) {
                PreviewQualityMenu(quality: $quality)
                    .help(qualityHelp)
            }
            if !overflow.contains(.zoom) {
                ViewerZoomControl(zoom: $zoom)
            }
            if !overflow.contains(.volume) {
                Divider().frame(height: 14)
                MonitorVolumeControl()
            }
            if overflow != .none {
                overflowMenu(overflow)
            }
        }
    }

    /// The ⋯ menu: whatever doesn't fit in the bar.
    private func overflowMenu(_ overflow: Overflow) -> some View {
        Menu {
            if overflow.contains(.pictureSize), let pictureSizeText {
                Text("Frame Size: \(pictureSizeText)")
                Divider()
            }
            if overflow.contains(.frameActions) {
                Button("Copy Frame", systemImage: "doc.on.doc", action: copyFrame)
                    .disabled(!canCopy)
                Button("Export Images", systemImage: "photo.badge.arrow.down", action: exportImages)
                    .disabled(!canCopy || isExporting)
                Divider()
            }
            if overflow.contains(.quality) {
                Picker("Preview Quality", systemImage: "sparkles.tv", selection: $quality) {
                    ForEach(PreviewQuality.allCases) { choice in
                        Text(choice.menuTitle).tag(choice)
                    }
                }
            }
            if overflow.contains(.zoom) {
                Picker("Zoom", systemImage: "plus.magnifyingglass", selection: $zoom) {
                    ForEach(Self.zoomChoices, id: \.self) { choice in
                        if let choice {
                            Text(choice.menuTitle).tag(choice)
                        } else {
                            Divider()
                        }
                    }
                }
            }
            if overflow.contains(.volume) {
                Divider()
                VolumeMenuItems()
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More controls")
    }

    /// The zoom choices, with dividers (`nil`) between groups.
    private static var zoomChoices: [ViewerZoom?] {
        [.fit, .actual, nil, .fitHeight, .fitWidth, nil] + ViewerZoom.menuPercents.map { .percent($0) }
    }
}

/// The master volume as menu items, for the ⋯ menu: mute, and a few levels.
private struct VolumeMenuItems: View {
    @Bindable private var volume = MonitorVolume.shared

    /// The levels offered, loudest first. The last is silence.
    private static let levels: [Double] = [0, -6, -12, -20, -30, -40, MonitorVolume.range.lowerBound]

    var body: some View {
        Toggle("Mute", systemImage: "speaker.slash", isOn: $volume.isMuted)
        Picker("Volume", systemImage: "speaker.wave.3", selection: Binding(
            get: { volume.decibels },
            set: { decibels in
                volume.decibels = decibels
                volume.isMuted = false
            }
        )) {
            ForEach(Self.levels, id: \.self) { level in
                Text(Self.title(level)).tag(level)
            }
            // The slider can be anywhere; show where it is when that's between the levels.
            if !Self.levels.contains(volume.decibels) {
                Divider()
                Text("\(Self.title(volume.decibels)) (Current)").tag(volume.decibels)
            }
        }
    }

    private static func title(_ decibels: Double) -> String {
        if decibels <= MonitorVolume.range.lowerBound { return "Off" }
        if decibels == MonitorVolume.monitoringLevel { return "0 dB (Monitoring Level)" }
        return "\(Int(decibels.rounded())) dB".replacingOccurrences(of: "-", with: "−")
    }
}

extension VideoToolbar where Leading == EmptyView {
    init(pictureSize: CGSize?, zoom: Binding<ViewerZoom>, quality: Binding<PreviewQuality>, qualityHelp: String,
         canCopy: Bool, isExporting: Bool, copyFrame: @escaping () -> Void, exportImages: @escaping () -> Void) {
        self.init(pictureSize: pictureSize, zoom: zoom, quality: quality, qualityHelp: qualityHelp,
                  canCopy: canCopy, isExporting: isExporting,
                  copyFrame: copyFrame, exportImages: exportImages, leading: { EmptyView() })
    }
}

/// Picks the preview quality: full, or a smaller picture that plays more easily.
private struct PreviewQualityMenu: View {
    @Binding var quality: PreviewQuality

    var body: some View {
        Menu {
            Picker("Preview Quality", selection: $quality) {
                ForEach(PreviewQuality.allCases) { choice in
                    Text(choice.menuTitle).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(quality.title, systemImage: quality == .full ? "sparkles.tv" : "gauge.with.dots.needle.33percent")
                .labelStyle(.titleAndIcon)
                .font(.callout.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Preview Quality: \(quality.menuTitle)")
    }
}

/// Copy Frame and Export Images, shared by the viewers. Each returns the toast to show.
enum VideoFrameActions {
    /// Copies the frame from `grab`. `describe` says which frame, e.g. "Frame 12 (00:00:00:11)".
    static func copy(grab: () async throws -> CGImage, describe: String, suffix: String = ", as shown in the viewer.") async -> Toast {
        do {
            let image = try await grab()
            try await FrameClipboard.copy(image)
            return Toast(systemImage: "doc.on.clipboard", title: "Frame Copied to Clipboard",
                         detail: "\(describe) at \(image.width) × \(image.height)\(suffix) Paste it into any app.")
        } catch {
            return Toast(systemImage: "exclamationmark.triangle.fill", title: "Couldn't Copy Frame",
                         detail: error.localizedDescription, isError: true)
        }
    }

    /// Saves two PNGs next to the project: the whole frame at full size, and the part in the
    /// viewer as it looks on screen (`view`: which part, and its on-screen size in pixels).
    /// `nil` when the user cancelled choosing a folder.
    static func exportImages(grab: () async throws -> CGImage, baseName: String,
                             view: (fraction: CGRect, pixels: CGSize), zoomTitle: String,
                             store: ProjectStore) async -> Toast? {
        do {
            // Grab the frame first, so it's the one on screen when the button was clicked.
            let image = try await grab()
            guard let folder = await store.projectFolderForImages() else { return nil }
            let pixels = view.pixels == .zero ? CGSize(width: image.width, height: image.height) : view.pixels
            let fraction = view.fraction
            let saved = try await Task.detached(priority: .userInitiated) {
                let viewImage = try FrameClipboard.crop(image, to: fraction, size: pixels)
                return (try FrameClipboard.savePNG(image, named: baseName, in: folder),
                        try FrameClipboard.savePNG(viewImage, named: "\(baseName) View \(zoomTitle)", in: folder))
            }.value
            return Toast(
                systemImage: "photo.on.rectangle",
                title: "Exported 2 Images",
                detail: "“\(saved.0.lastPathComponent)” (\(image.width) × \(image.height)) and “\(saved.1.lastPathComponent)” (the view) are in “\(folder.lastPathComponent)”.",
                action: ToastAction(title: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([saved.0, saved.1])
                }
            )
        } catch {
            return Toast(systemImage: "exclamationmark.triangle.fill", title: "Couldn't Export Images",
                         detail: error.localizedDescription, isError: true)
        }
    }
}
