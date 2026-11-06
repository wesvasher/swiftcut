import AppKit
import UniformTypeIdentifiers

/// Importing images, and making (and remaking) the videos SwiftCut makes from them.
extension ProjectStore {
    // MARK: Dropping and choosing

    /// Handles files dropped on the window: videos are imported right away; for images (or
    /// folders of them) the user is asked whether they're one image sequence or separate images.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let images = askAboutImages(in: urls)
        let imported = importFiles(urls)
        if !imported.isEmpty { selection = Set(imported.map { .clip($0.id) }) }
        return images || !imported.isEmpty
    }

    /// Puts the images and image folders among `urls` up for the drop dialog.
    /// Returns whether there were any.
    @discardableResult
    func askAboutImages(in urls: [URL], timelineIndex: Int? = nil) -> Bool {
        let folders = urls.filter { ImageSequence.isFolder($0) && !ImageSequence.images(in: $0).isEmpty }
        let images = urls.filter(ImageSequence.isImage)
        guard !folders.isEmpty || !images.isEmpty else { return false }
        pendingImageImport = PendingImageImport(folders: folders, images: images, timelineIndex: timelineIndex)
        return true
    }

    /// The drop dialog's answer: `asSequence` makes each folder (and the loose images
    /// together) one video; otherwise each image becomes its own still clip.
    func finishImageImport(asSequence: Bool, order: ImageSequence.Order = .nameAscending, frameRate: Double? = nil) {
        guard let pending = pendingImageImport else { return }
        pendingImageImport = nil
        let clips = importImages(folders: pending.folders, images: pending.images, asSequence: asSequence,
                                 order: order, frameRate: frameRate)
        guard !clips.isEmpty else { return }
        if let index = pending.timelineIndex {
            addToTimeline(clips, at: index)
        } else {
            selection = Set(clips.map { .clip($0.id) })
        }
    }

    func cancelImageImport() {
        pendingImageImport = nil
    }

    /// File › Import Image Sequence: asks for a folder of images, or images, and makes each
    /// folder (and the chosen images together) one video.
    func chooseImageSequence() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Import"
        panel.message = "Choose a folder of images, or select the images, to make into a video."
        let options = ImportOptions()
        panel.accessoryView = options.view
        panel.isAccessoryViewDisclosed = true
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            let order = options.order, frameRate = options.frameRate
            ImageSequence.Order.saved = order
            ImageSequence.savedFrameRate = frameRate
            urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
            let clips = self.importImages(folders: urls.filter(ImageSequence.isFolder),
                                          images: urls.filter(ImageSequence.isImage), asSequence: true,
                                          order: order, frameRate: frameRate)
            if !clips.isEmpty { self.selection = Set(clips.map { .clip($0.id) }) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// The open panel's Order and Frame Rate menus (Custom shows a field for the rate).
    private final class ImportOptions: NSObject {
        let view: NSView
        private let orderPopUp = NSPopUpButton()
        private let ratePopUp = NSPopUpButton()
        private let customRate = NSTextField()
        private let fpsLabel = NSTextField(labelWithString: "fps")
        /// The Custom item's tag; the others are indexes into `ImageSequence.frameRates`.
        private static let customTag = -1

        override init() {
            let saved = ImageSequence.savedFrameRate
            let isCustom = !ImageSequence.frameRates.contains(saved)

            for (index, group) in ImageSequence.Order.groups.enumerated() {
                if index > 0 { orderPopUp.menu?.addItem(.separator()) }
                for order in group {
                    let item = NSMenuItem(title: order.title, action: nil, keyEquivalent: "")
                    item.representedObject = order.rawValue
                    orderPopUp.menu?.addItem(item)
                }
            }
            if let item = orderPopUp.itemArray.first(where: { $0.representedObject as? String == ImageSequence.Order.saved.rawValue }) {
                orderPopUp.select(item)
            }

            for (index, fps) in ImageSequence.frameRates.enumerated() {
                let item = NSMenuItem(title: ImageSequence.frameRateTitle(fps), action: nil, keyEquivalent: "")
                item.tag = index
                ratePopUp.menu?.addItem(item)
            }
            ratePopUp.menu?.addItem(.separator())
            let custom = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
            custom.tag = Self.customTag
            ratePopUp.menu?.addItem(custom)
            ratePopUp.selectItem(withTag: isCustom ? Self.customTag : ImageSequence.frameRates.firstIndex(of: saved) ?? 0)

            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 3
            formatter.minimum = NSNumber(value: ImageSequence.minFrameRate)
            formatter.maximum = NSNumber(value: ImageSequence.maxFrameRate)
            customRate.formatter = formatter
            customRate.doubleValue = saved
            customRate.widthAnchor.constraint(equalToConstant: 60).isActive = true

            let grid = NSGridView(views: [
                [NSTextField(labelWithString: "Order:"), orderPopUp],
                [NSTextField(labelWithString: "Frame Rate:"),
                 NSStackView(views: [ratePopUp, customRate, fpsLabel])],
            ])
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            let container = NSStackView(views: [grid])
            container.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
            view = container
            super.init()
            ratePopUp.target = self
            ratePopUp.action = #selector(rateChanged)
            rateChanged()
        }

        @objc private func rateChanged() {
            let isCustom = ratePopUp.selectedTag() == Self.customTag
            customRate.isHidden = !isCustom
            fpsLabel.isHidden = !isCustom
        }

        var order: ImageSequence.Order {
            (orderPopUp.selectedItem?.representedObject as? String).flatMap(ImageSequence.Order.init) ?? .nameAscending
        }

        var frameRate: Double {
            let tag = ratePopUp.selectedTag()
            if tag == Self.customTag {
                return ImageSequence.clampedFrameRate(customRate.doubleValue > 0 ? customRate.doubleValue : 24)
            }
            return ImageSequence.frameRates.indices.contains(tag) ? ImageSequence.frameRates[tag] : 24
        }
    }

    // MARK: Importing

    /// Adds source videos made from images. As a sequence, each folder becomes one video and
    /// the loose images another; otherwise every image is its own still. Returns the new clips.
    @discardableResult
    func importImages(folders: [URL], images: [URL], asSequence: Bool,
                      order: ImageSequence.Order = .nameAscending, frameRate: Double? = nil) -> [Clip] {
        var sequences: [ImageSequence] = []
        if asSequence {
            for folder in folders {
                let urls = ImageSequence.images(in: folder, order: order)
                guard !urls.isEmpty else { continue }
                sequences.append(ImageSequence(name: folder.lastPathComponent, imagePaths: urls.map(Self.path),
                                               access: [ImageSequence.access(to: folder)]))
            }
            let loose = ImageSequence.sorted(images, by: order)
            if !loose.isEmpty {
                sequences.append(ImageSequence(name: ImageSequence.name(forImages: loose), imagePaths: loose.map(Self.path),
                                               access: loose.map(ImageSequence.access(to:))))
            }
        } else {
            for folder in folders {
                let access = ImageSequence.access(to: folder)
                sequences += ImageSequence.images(in: folder, order: order).map {
                    ImageSequence(name: $0.deletingPathExtension().lastPathComponent, imagePaths: [Self.path($0)], access: [access])
                }
            }
            sequences += ImageSequence.sorted(images, by: order).map {
                ImageSequence(name: $0.deletingPathExtension().lastPathComponent, imagePaths: [Self.path($0)],
                              access: [ImageSequence.access(to: $0)])
            }
        }
        if let frameRate {
            for index in sequences.indices { sequences[index].setFrameRate(frameRate) }
        }
        let new = sequences.map { Clip(sequence: $0) }
        clips += new
        refreshImageSequences()
        return new
    }

    private static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    // MARK: Making the videos

    /// Makes sure every image sequence's video matches its settings: loads the video when it's
    /// there, and makes it when it isn't (after import, a settings change, Undo, or when the
    /// cache was cleared). A clip keeps playing its old video until the new one is ready.
    func refreshImageSequences() {
        for clip in clips {
            guard let sequence = clip.imageSequence else { continue }
            let target = sequence.videoURL
            let exists = FileManager.default.fileExists(atPath: target.path(percentEncoded: false))

            if clip.url == target {
                if exists {
                    // Already showing the right video.
                    if !clip.isLoaded, clip.loadError == nil, sequenceBuilds[clip.id] == nil, !clip.isLoading {
                        load(clip)
                    }
                    cancelBuild(for: clip, unless: target)
                    continue
                }
            } else if exists {
                cancelBuild(for: clip, unless: nil)
                swapVideo(of: clip, to: target)
                continue
            }
            guard sequenceBuilds[clip.id]?.url != target else { continue }
            build(sequence, for: clip, to: target)
        }
        // Clips that were removed stop their builds.
        let ids = Set(clips.map(\.id))
        for (id, build) in sequenceBuilds where !ids.contains(id) {
            build.task.cancel()
            sequenceBuilds[id] = nil
        }
    }

    private func cancelBuild(for clip: Clip, unless url: URL?) {
        guard let build = sequenceBuilds[clip.id], build.url != url else { return }
        build.task.cancel()
        sequenceBuilds[clip.id] = nil
        clip.sequenceProgress = nil
    }

    private func build(_ sequence: ImageSequence, for clip: Clip, to target: URL) {
        sequenceBuilds[clip.id]?.task.cancel()
        clip.sequenceProgress = 0
        clip.sequenceError = nil
        let id = clip.id
        let task = Task { [weak self] in
            do {
                try await BlockingWork.run { isCancelled in
                    try ImageSequenceWriter.write(sequence, to: target, progress: { value in
                        Task { @MainActor in
                            if let self, self.sequenceBuilds[id]?.url == target {
                                self.clip(for: id)?.sequenceProgress = value
                            }
                        }
                    }, isCancelled: isCancelled)
                }
                guard let self, !Task.isCancelled, self.sequenceBuilds[id]?.url == target else { return }
                self.sequenceBuilds[id] = nil
                guard let current = self.clip(for: id) else { return }
                current.sequenceProgress = nil
                if current.url == target {
                    self.load(current)
                } else {
                    self.swapVideo(of: current, to: target)
                }
            } catch {
                guard let self, !(error is CancellationError), self.sequenceBuilds[id]?.url == target else { return }
                self.sequenceBuilds[id] = nil
                guard let current = self.clip(for: id) else { return }
                current.sequenceProgress = nil
                current.sequenceError = error.localizedDescription
                // Nothing to show yet: say why in the sidebar too.
                if !current.isLoaded { current.loadError = error.localizedDescription }
            }
        }
        sequenceBuilds[id] = (target, task)
    }

    /// Replaces a clip with one showing its new video, keeping its id, marks, and settings
    /// (the way relinking does), then removes the old video if nothing else uses it.
    private func swapVideo(of old: Clip, to target: URL) {
        guard let index = clips.firstIndex(where: { $0 === old }), let sequence = old.imageSequence else { return }
        let clip = Clip(sequence: sequence, id: old.id)
        clip.apply(old.record)
        clips[index] = clip
        load(clip)
        let previous = old.url
        if previous != target, !clips.contains(where: { $0.url == previous }) {
            try? FileManager.default.removeItem(at: previous)
        }
    }

    private func load(_ clip: Clip) {
        clip.isLoading = true
        clip.loadError = nil
        Task {
            await MediaLoader.load(clip)
            clip.isLoading = false
        }
    }
}

extension ImageSequence {
    /// Permission to read `url` (a folder or an image) again after relaunching.
    @MainActor static func access(to url: URL) -> Access {
        Access(path: url.path(percentEncoded: false), bookmark: Clip.makeBookmark(for: url))
    }

    /// Uses the saved permissions, so the images can be read (to make the video again).
    @MainActor func startAccess() {
        for access in access {
            guard let data = access.bookmark else { continue }
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
            }
        }
    }
}
