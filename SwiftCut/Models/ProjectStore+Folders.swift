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
        let mediaFolder = MediaFolder(name: folder.lastPathComponent, parentID: parentID, path: folder.path(percentEncoded: false))
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
}
