import Foundation
import Testing
@testable import SwiftCut

/// Watched folders: keeping them in step with the folder on disk.
struct FolderSyncTests {
    /// Dates a file a minute back, as if it finished copying a while ago.
    static func settle(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-60)],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    static func video(_ name: String, in dir: URL, settled: Bool = true) async throws -> URL {
        let url = try await TestVideo.make(in: dir, name: name, seconds: 1, size: CGSize(width: 160, height: 120))
        if settled { try settle(url) }
        return url
    }

    /// A store with "Trip" dropped in (videos a and b, and Day 2/c).
    @MainActor static func storeWithTrip() async throws -> (ProjectStore, URL, MediaFolder) {
        let root = try await FolderTests.tripFolder()
        let store = ProjectStore(exporter: ExportManager.test("FolderSyncTests"))
        store.handleDrop([root])
        let trip = try #require(store.folders(in: nil).first)
        return (store, root, trip)
    }

    @Test @MainActor func droppedFoldersAreWatched() async throws {
        let (store, _, trip) = try await Self.storeWithTrip()
        #expect(store.folderWatchers[trip.id] != nil)
        #expect(trip.bookmark != nil)
        guard case .upToDate = store.folderSync[trip.id] else {
            Issue.record("\(String(describing: store.folderSync[trip.id]))"); return
        }
    }

    @Test @MainActor func newVideosAreAdded() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        _ = try await Self.video("d", in: root)
        store.syncFolder(trip.id)
        #expect(store.clips(inFolder: trip.id).map(\.name).contains("d"))
        guard case .upToDate = store.folderSync[trip.id] else { Issue.record("not up to date"); return }
    }

    @Test @MainActor func filesStillBeingWrittenWait() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        let fresh = try await Self.video("e", in: root, settled: false)
        store.syncFolder(trip.id)
        #expect(!store.clips.contains { $0.name == "e" }, "too new: may still be copying")
        #expect(store.folderRechecks[trip.id] != nil, "another sync is on its way")
        try Self.settle(fresh)
        store.syncFolder(trip.id)
        #expect(store.clips.contains { $0.name == "e" })
    }

    @Test @MainActor func theWatcherOnlyMarksChanges() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        let before = store.allClips(inFolder: trip.id).count
        // As if copied in from Finder: the folder is marked, but nothing is brought in yet.
        _ = try await Self.video("from finder", in: root)
        try await ImageSequenceTests.waitUntil(seconds: 15) { store.folderSync[trip.id] == .changed }
        #expect(store.allClips(inFolder: trip.id).count == before)
        // The sync button brings it in.
        store.syncFolder(trip.id, interactive: true)
        #expect(store.clips(inFolder: trip.id).contains { $0.name == "from finder" })
        guard case .upToDate = store.folderSync[trip.id] else { Issue.record("not up to date"); return }
    }

    @Test @MainActor func newSubfoldersAndMissingFiles() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        let day3 = root.appending(path: "Day 3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: day3, withIntermediateDirectories: true)
        _ = try await Self.video("f", in: day3)
        try FileManager.default.removeItem(at: root.appending(path: "a.mov"))
        store.syncFolder(trip.id)

        let child = try #require(store.folders(in: trip.id).first { $0.name == "Day 3" })
        #expect(store.clips(inFolder: child.id).map(\.name) == ["f"])
        // The missing file's clip stays (it may be on the timeline); the folder says so.
        #expect(store.clips.contains { $0.name == "a" })
        guard case .attention(let message) = store.folderSync[trip.id] else { Issue.record("no warning"); return }
        #expect(message.contains("1 file is missing"))
    }

    @Test @MainActor func aDeletedFolderSaysSo() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        try FileManager.default.removeItem(at: root)
        store.syncFolder(trip.id)
        guard case .unavailable = store.folderSync[trip.id] else { Issue.record("\(String(describing: store.folderSync[trip.id]))"); return }
    }

    @Test @MainActor func aMovedFolderIsFollowed() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        let moved = root.deletingLastPathComponent().appending(path: "Moved", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: root, to: moved)
        store.syncFolder(trip.id)
        // It keeps watching it where it went (folders inside too).
        #expect(store.folder(for: trip.id)?.url?.standardizedFileURL.path == moved.standardizedFileURL.path)
        let day2 = try #require(store.folders(in: trip.id).first)
        #expect(day2.path?.contains("/Moved/Day 2") == true)
    }

    @Test @MainActor func sequencesGainNewFrames() async throws {
        let (dir, urls) = try ImageSequenceTests.folder(count: 3)
        try urls.forEach(Self.settle)
        let store = ProjectStore(exporter: ExportManager.test("FolderSyncTests"))
        store.handleDrop([dir])
        store.finishImageImport(asSequence: true)
        let folder = try #require(store.folders(in: nil).first)
        let sequenceClip = try #require(store.clips(inFolder: folder.id).first)

        let added = try ImageSequenceTests.png(in: dir, name: "frame4.png")
        try Self.settle(added)
        store.syncFolder(folder.id)
        let paths = try #require(store.clip(for: sequenceClip.id)?.imageSequence?.imagePaths)
        #expect(paths.count == 4 && paths.last == added.path(percentEncoded: false))
        // Still one clip: the sequence grew, its video is made again.
        #expect(store.clips(inFolder: folder.id).count == 1)
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test @MainActor func stillsGainNewStillsMadeLikeTheOthers() async throws {
        let (dir, urls) = try ImageSequenceTests.folder(count: 2)
        try urls.forEach(Self.settle)
        let store = ProjectStore(exporter: ExportManager.test("FolderSyncTests"))
        store.handleDrop([dir])
        store.finishImageImport(asSequence: false, frameRate: 12)
        let folder = try #require(store.folders(in: nil).first)
        store.clips(inFolder: folder.id).first?.imageSequence?.stillDuration = 3

        let added = try ImageSequenceTests.png(in: dir, name: "frame3.png")
        try Self.settle(added)
        store.syncFolder(folder.id)
        let stills = store.clips(inFolder: folder.id)
        #expect(stills.count == 3)
        let new = try #require(stills.first { $0.name == "frame3" }?.imageSequence)
        #expect(new.isStill && new.frameRate == 12 && new.stillDuration == 3)
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test @MainActor func newImagesWithoutClipsAskOnSync() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        let image = try ImageSequenceTests.png(in: root, name: "poster.png")
        try Self.settle(image)
        // On its own, it waits and says so…
        store.syncFolder(trip.id)
        #expect(store.pendingImageImport == nil)
        guard case .attention(let message) = store.folderSync[trip.id] else { Issue.record("no note"); return }
        #expect(message.contains("Click Sync"))
        // …and the sync button asks how to import them, into this folder.
        store.syncFolder(trip.id, interactive: true)
        let pending = try #require(store.pendingImageImport)
        #expect(pending.destinations[root.standardizedFileURL] == trip.id)
        store.finishImageImport(asSequence: false)
        #expect(store.clips(inFolder: trip.id).contains { $0.name == "poster" })
    }

    @Test @MainActor func openingAProjectDoesNoFolderWork() async throws {
        let (store, root, trip) = try await Self.storeWithTrip()
        let saved = try JSONEncoder().encode(store.projectFile)
        // Something new while the project was closed.
        _ = try await Self.video("while closed", in: root)

        let reopened = ProjectStore(exporter: ExportManager.test("FolderSyncTests"))
        reopened.apply(try JSONDecoder().decode(ProjectFile.self, from: saved))
        // Watched again, but not synced: opening stays quick.
        #expect(reopened.folderWatchers[trip.id] != nil)
        #expect(reopened.folderSync[trip.id] == nil)
        #expect(!reopened.clips.contains { $0.name == "while closed" })
        // Until the sync button.
        reopened.syncFolder(trip.id, interactive: true)
        #expect(reopened.clips(inFolder: trip.id).contains { $0.name == "while closed" })
    }
}
