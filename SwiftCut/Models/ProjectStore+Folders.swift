import Foundation

/// Folders in Source Videos: made from dropped folders, holding what was in them.
extension ProjectStore {
    /// What a drop brought in.
    struct DropResult {
        /// Videos added right away.
        var clips: [Clip] = []
        /// Images are waiting for the Image Sequence / Individual Images dialog.
        var asksAboutImages = false
        /// Folders were made in the sidebar.
        var madeFolders = false
    }

    /// Imports dropped files and folders. Videos are added (into a sidebar folder when they came
    /// in one); each folder becomes a sidebar folder, with folders for its subfolders; images,
    /// loose or in folders, go to the import dialog, which puts them in their folders after.
    @discardableResult
    func importDropped(_ urls: [URL], timelineIndex: Int? = nil, securityScoped: Bool = false) -> DropResult {
        if securityScoped { urls.forEach { _ = $0.startAccessingSecurityScopedResource() } }
        var result = DropResult()
        var imageFolders: [URL] = []
        var destinations: [URL: UUID] = [:]

        for folder in urls where ImageSequence.isFolder(folder) {
            if importFolder(folder, parentID: nil, clips: &result.clips, imageFolders: &imageFolders,
                            destinations: &destinations) != nil {
                result.madeFolders = true
            }
        }
        // Watch the new folders from now on (they've just been brought in, so they're up to date).
        if result.madeFolders { watchFolders(justImported: true) }
        let files = urls.filter { !ImageSequence.isFolder($0) }
        result.clips += importFiles(files)
        let looseImages = files.filter(ImageSequence.isImage)
        if !imageFolders.isEmpty || !looseImages.isEmpty {
            pendingImageImport = PendingImageImport(folders: imageFolders, images: looseImages,
                                                    timelineIndex: timelineIndex, destinations: destinations)
            result.asksAboutImages = true
        }
        return result
    }

    /// Makes a sidebar folder for `folder` and brings in what's in it: its videos now, its
    /// images later (listed in `imageFolders`), and its subfolders as folders inside. Returns the
    /// new folder's id, or `nil` when there was nothing to bring in.
    private func importFolder(_ folder: URL, parentID: UUID?, clips: inout [Clip], imageFolders: inout [URL],
                              destinations: inout [URL: UUID]) -> UUID? {
        let contents = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // The top folder keeps permission to read it after relaunching, to keep watching it.
        let mediaFolder = MediaFolder(name: folder.lastPathComponent, parentID: parentID, path: folder.path(percentEncoded: false),
                                      bookmark: parentID == nil ? Clip.makeBookmark(for: folder) : nil)
        folders.append(mediaFolder)

        var hasContent = false
        let videos = contents.filter { !ImageSequence.isFolder($0) && MediaLoader.isSupported($0) }
        if !videos.isEmpty {
            clips += importFiles(videos, folderID: mediaFolder.id)
            hasContent = true
        }
        if contents.contains(where: ImageSequence.isImage) {
            imageFolders.append(folder)
            destinations[folder.standardizedFileURL] = mediaFolder.id
            hasContent = true
        }
        for subfolder in contents where ImageSequence.isFolder(subfolder) {
            if importFolder(subfolder, parentID: mediaFolder.id, clips: &clips, imageFolders: &imageFolders,
                            destinations: &destinations) != nil {
                hasContent = true
            }
        }
        guard hasContent else {
            folders.removeAll { $0.id == mediaFolder.id }
            return nil
        }
        return mediaFolder.id
    }

    // MARK: Looking up

    func folder(for id: UUID) -> MediaFolder? {
        folders.first { $0.id == id }
    }

    /// The folders directly inside `parentID` (`nil`: at the top), in the order they were made.
    func folders(in parentID: UUID?) -> [MediaFolder] {
        folders.filter { $0.parentID == parentID }
    }

    /// The source videos directly inside a folder (`nil`: not in any).
    func clips(inFolder folderID: UUID?) -> [Clip] {
        clips.filter { $0.folderID == folderID }
    }

    /// Every source video in a folder and the folders inside it, in sidebar order.
    func allClips(inFolder folderID: UUID) -> [Clip] {
        clips(inFolder: folderID) + folders(in: folderID).flatMap { allClips(inFolder: $0.id) }
    }

    /// A folder and every folder inside it.
    private func folderTree(_ id: UUID) -> Set<UUID> {
        folders(in: id).reduce(into: Set([id])) { $0.formUnion(folderTree($1.id)) }
    }

    // MARK: Changing

    /// Removes a folder, the folders inside it, and their clips from the project. Files aren't touched.
    func removeFolder(_ id: UUID) {
        let tree = folderTree(id)
        removeClips(Set(clips.filter { $0.folderID.map(tree.contains) ?? false }.map(\.id)))
        folders.removeAll { tree.contains($0.id) }
        watchFolders()
    }

    /// Removes folders with nothing in them (after an import was cancelled).
    func removeEmptyFolders() {
        var changed = true
        while changed {
            changed = false
            for folder in folders where clips(inFolder: folder.id).isEmpty && folders(in: folder.id).isEmpty {
                // A folder still waiting for images in the import dialog stays.
                if pendingImageImport?.destinations.values.contains(folder.id) == true { continue }
                if rawDevelopRequest?.sequences.contains(where: { $0.folderID == folder.id }) == true { continue }
                folders.removeAll { $0.id == folder.id }
                changed = true
            }
        }
    }

    // MARK: Keeping folders in sync

    /// How long a file must go unchanged before it's brought in, so a video still being copied
    /// (or a photo still being written) isn't added half-finished.
    static var settleTime: TimeInterval { 2 }

    /// Watches every top-level folder that came from disk for changes, and stops watching removed
    /// ones. Watching only notes that something changed; syncing happens when asked (the sync
    /// button or Sync Now), so opening a big project or copying files in does no work on its own.
    /// `justImported` marks new folders up to date (they were just brought in).
    func watchFolders(justImported: Bool = false) {
        let watched = folders.filter { $0.parentID == nil && $0.path != nil }
        let ids = Set(watched.map(\.id))
        for (id, watcher) in folderWatchers where !ids.contains(id) {
            watcher.stop()
            folderWatchers[id] = nil
            folderSync[id] = nil
            folderRechecks[id]?.cancel()
            folderRechecks[id] = nil
        }
        for folder in watched where folderWatchers[folder.id] == nil {
            guard let url = accessibleURL(of: folder), ImageSequence.isFolder(url) else {
                folderSync[folder.id] = .unavailable("Can't find “\(folder.name)” at \((folder.path ?? "").abbreviatingWithTilde). It may have been moved, deleted, or be on a drive that isn't connected.")
                continue
            }
            let id = folder.id
            folderWatchers[id] = FolderWatcher(url: url) { [weak self] in self?.noteChange(in: id) }
            if justImported, folderSync[id] == nil {
                folderSync[id] = .upToDate(at: .now)
            }
        }
    }

    /// The folder's location, with permission to read it (from its saved permission when there is one).
    private func accessibleURL(of folder: MediaFolder) -> URL? {
        if let data = folder.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return folder.url
    }

    /// Something changed in a watched folder on disk: say so, and leave syncing to the button.
    private func noteChange(in id: UUID) {
        switch folderSync[id] {
        case .syncing, .unavailable: break
        default: folderSync[id] = .changed
        }
    }

    /// What a sync found, for the status.
    private struct SyncReport {
        var missing = 0
        /// Folders with images that have no clips yet (and their sidebar folders).
        var waitingImages: [(url: URL, folderID: UUID)] = []
        /// Some files were still being written; another sync is due.
        var unsettled = false
    }

    /// Brings a top-level folder (and the folders inside it) in line with the folder on disk:
    /// new videos and subfolders are added, image sequences and stills from it gain the new
    /// images, and what's gone is reported. `interactive` (the sync button) also asks how to
    /// import images the folder didn't have clips for.
    func syncFolder(_ id: UUID, interactive: Bool = false) {
        guard let folder = folder(for: id), let url = accessibleURL(of: folder) else { return }
        guard ImageSequence.isFolder(url) else {
            folderSync[id] = .unavailable("Can't find “\(folder.name)” at \((folder.path ?? "").abbreviatingWithTilde). It may have been moved, deleted, or be on a drive that isn't connected.")
            return
        }
        folderSync[id] = .syncing
        // Moved on disk (its saved permission follows it): note where it is now.
        if let old = folder.path, url.standardizedFileURL != folder.url?.standardizedFileURL {
            relocate(id, from: old, to: url.path(percentEncoded: false))
        }
        guard let folder = self.folder(for: id) else { return }
        var report = SyncReport()
        sync(folder, at: url, report: &report)
        refreshImageSequences()

        if report.unsettled {
            folderRechecks[id]?.cancel()
            folderRechecks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.settleTime + 1))
                guard !Task.isCancelled else { return }
                self?.syncFolder(id)
            }
        }
        if interactive, !report.waitingImages.isEmpty, pendingImageImport == nil {
            pendingImageImport = PendingImageImport(
                folders: report.waitingImages.map(\.url), images: [], timelineIndex: nil,
                destinations: Dictionary(report.waitingImages.map { ($0.url.standardizedFileURL, $0.folderID) },
                                         uniquingKeysWith: { first, _ in first }))
        }

        var notes: [String] = []
        if report.missing > 0 {
            notes.append(report.missing == 1 ? "1 file is missing from the folder on disk."
                         : "\(report.missing) files are missing from the folder on disk.")
        }
        if !report.waitingImages.isEmpty, !interactive {
            notes.append("New images haven't been imported yet. Click Sync to choose how.")
        }
        folderSync[id] = notes.isEmpty ? .upToDate(at: .now) : .attention(notes.joined(separator: " "))
    }

    /// Points a folder (and the folders inside it) at where it now is on disk.
    private func relocate(_ id: UUID, from old: String, to new: String) {
        let tree = folderTree(id)
        let oldPrefix = old.hasSuffix("/") ? old : old + "/", newPrefix = new.hasSuffix("/") ? new : new + "/"
        for index in folders.indices where tree.contains(folders[index].id) {
            guard let path = folders[index].path else { continue }
            if path == old || path == oldPrefix {
                folders[index].path = new
            } else if path.hasPrefix(oldPrefix) {
                folders[index].path = newPrefix + path.dropFirst(oldPrefix.count)
            }
        }
    }

    /// Syncs one folder's own files, then the folders inside it.
    private func sync(_ folder: MediaFolder, at url: URL, report: inout SyncReport) {
        let contents = ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let settledBefore = Date.now.addingTimeInterval(-Self.settleTime)
        func isSettled(_ file: URL) -> Bool {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified < settledBefore
        }
        let here = url.standardizedFileURL

        // New videos.
        let known = Set(clips.map { $0.url.standardizedFileURL })
        let videos = contents.filter { !ImageSequence.isFolder($0) && MediaLoader.isSupported($0) && !known.contains($0.standardizedFileURL) }
        let readyVideos = videos.filter(isSettled)
        if readyVideos.count < videos.count { report.unsettled = true }
        if !readyVideos.isEmpty { importFiles(readyVideos, folderID: folder.id) }

        // Images: into the sequences and stills already made from this folder.
        let images = contents.filter(ImageSequence.isImage)
        let readyImages = images.filter(isSettled)
        if readyImages.count < images.count { report.unsettled = true }
        let fromHere = clips.filter { clip in
            clip.imageSequence?.imageURLs.first.map { $0.deletingLastPathComponent().standardizedFileURL == here } ?? false
        }
        let sequences = fromHere.filter { $0.imageSequence?.isStill == false }
        let stills = fromHere.filter { $0.imageSequence?.isStill == true }
        let readyPaths = readyImages.map { $0.path(percentEncoded: false) }
        for clip in sequences {
            guard !readyPaths.isEmpty, clip.imageSequence?.imagePaths != readyPaths else { continue }
            // The sequence follows the folder: new frames join, deleted ones drop out. Its video is made again.
            clip.imageSequence?.imagePaths = readyPaths
        }
        if !stills.isEmpty, sequences.isEmpty, let template = stills.first?.imageSequence {
            let have = Set(stills.compactMap { $0.imageSequence?.imagePaths.first })
            let new = readyImages.filter { !have.contains($0.path(percentEncoded: false)) }.map { image in
                // A new still made like the others (frame size, rate, length, RAW development).
                var still = template
                still.name = image.deletingPathExtension().lastPathComponent
                still.imagePaths = [image.path(percentEncoded: false)]
                still.folderID = folder.id
                return still
            }
            if !new.isEmpty { addSequences(new) }
        }
        if fromHere.isEmpty, !readyImages.isEmpty,
           pendingImageImport?.destinations[here] == nil, !(rawDevelopRequest?.sequences.contains { $0.folderID == folder.id } ?? false) {
            report.waitingImages.append((url, folder.id))
        }

        // What's gone.
        report.missing += clips.filter {
            $0.folderID == folder.id && $0.imageSequence == nil
                && !FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false))
        }.count

        // Folders inside: new ones are added, and every one is synced.
        for subfolder in contents where ImageSequence.isFolder(subfolder) {
            let path = subfolder.standardizedFileURL
            if let existing = folders.first(where: { $0.parentID == folder.id && $0.url?.standardizedFileURL == path }) {
                sync(existing, at: subfolder, report: &report)
            } else {
                let child = MediaFolder(name: subfolder.lastPathComponent, parentID: folder.id, path: subfolder.path(percentEncoded: false))
                folders.append(child)
                let waitingBefore = report.waitingImages.count
                sync(child, at: subfolder, report: &report)
                // Nothing to show for it (yet): leave it out until there is.
                if clips(inFolder: child.id).isEmpty, folders(in: child.id).isEmpty, report.waitingImages.count == waitingBefore {
                    folders.removeAll { $0.id == child.id }
                }
            }
        }
    }
}
