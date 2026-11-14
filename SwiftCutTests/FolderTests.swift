import Foundation
import Testing
@testable import SwiftCut

/// Dropped folders stay as folders in Source Videos.
struct FolderTests {
    /// "Trip/" with two videos, a "Day 2/" subfolder with one, and an "Empty/" folder.
    static func tripFolder() async throws -> URL {
        let root = try TestVideo.tempDirectory().appending(path: "Trip", directoryHint: .isDirectory)
        let day2 = root.appending(path: "Day 2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Empty"), withIntermediateDirectories: true)
        for name in ["b", "a"] {
            _ = try await TestVideo.make(in: root, name: name, seconds: 1, size: CGSize(width: 160, height: 120))
        }
        _ = try await TestVideo.make(in: day2, name: "c", seconds: 1, size: CGSize(width: 160, height: 120))
        try Data("notes".utf8).write(to: root.appending(path: "notes.txt"))
        return root
    }

    @Test @MainActor func droppedFoldersKeepTheirShape() async throws {
        let root = try await Self.tripFolder()
        let store = ProjectStore(exporter: ExportManager.test("FolderTests"))
        #expect(store.handleDrop([root]))

        let trip = try #require(store.folders(in: nil).first)
        #expect(trip.name == "Trip" && store.folders(in: nil).count == 1)
        // Videos in name order; the empty folder and the text file are left out.
        #expect(store.clips(inFolder: trip.id).map(\.name) == ["a", "b"])
        let day2 = try #require(store.folders(in: trip.id).first)
        #expect(day2.name == "Day 2" && store.folders(in: trip.id).count == 1)
        #expect(store.clips(inFolder: day2.id).map(\.name) == ["c"])
        #expect(store.allClips(inFolder: trip.id).count == 3)
        #expect(store.clips(inFolder: nil).isEmpty)
        // The new clips are selected, as with any drop.
        #expect(store.selection.count == 3)
    }

    @Test @MainActor func foldersAreSavedAndReopened() async throws {
        let root = try await Self.tripFolder()
        let store = ProjectStore(exporter: ExportManager.test("FolderTests"))
        store.handleDrop([root])
        let data = try JSONEncoder().encode(store.projectFile)

        let reopened = ProjectStore(exporter: ExportManager.test("FolderTests"))
        reopened.apply(try JSONDecoder().decode(ProjectFile.self, from: data))
        #expect(reopened.folders == store.folders)
        let trip = try #require(reopened.folders(in: nil).first)
        #expect(reopened.allClips(inFolder: trip.id).map(\.name).sorted() == ["a", "b", "c"])

        // Projects from before folders open with none.
        let old = try JSONDecoder().decode(ProjectFile.self, from: Data(#"{"clips":[],"timeline":[]}"#.utf8))
        #expect(old.folders.isEmpty)
    }

    @Test @MainActor func removingAFolderTakesItsClips() async throws {
        let root = try await Self.tripFolder()
        let store = ProjectStore(exporter: ExportManager.test("FolderTests"))
        store.handleDrop([root])
        let loose = try await TestVideo.make(in: root.deletingLastPathComponent(), name: "loose", seconds: 1, size: CGSize(width: 160, height: 120))
        store.handleDrop([loose])
        let trip = try #require(store.folders(in: nil).first)
        store.removeFolder(trip.id)
        #expect(store.folders.isEmpty)
        #expect(store.clips.map(\.name) == ["loose"])
        // The files are still there.
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "a.mov").path(percentEncoded: false)))
    }

    @Test @MainActor func imagesInFoldersLandInTheirFolders() async throws {
        let (shots, _) = try ImageSequenceTests.folder(count: 3)
        _ = try await TestVideo.make(in: shots, name: "behind the scenes", seconds: 1, size: CGSize(width: 160, height: 120))
        let store = ProjectStore(exporter: ExportManager.test("FolderTests"))
        store.handleDrop([shots])
        let folder = try #require(store.folders(in: nil).first)
        // The video is in now; the images wait for the dialog.
        #expect(store.clips(inFolder: folder.id).map(\.name) == ["behind the scenes"])
        #expect(store.pendingImageImport?.imageCount == 3)
        store.finishImageImport(asSequence: true)
        let names = store.clips(inFolder: folder.id).map(\.name)
        #expect(names.contains("Shots") && names.count == 2)
        store.removeClips(Set(store.clips.map(\.id)))
    }

    @Test @MainActor func cancellingImagesRemovesAnEmptyFolder() throws {
        let (shots, _) = try ImageSequenceTests.folder(count: 2)
        let store = ProjectStore(exporter: ExportManager.test("FolderTests"))
        store.handleDrop([shots])
        #expect(store.folders.count == 1)
        store.cancelImageImport()
        #expect(store.folders.isEmpty && store.clips.isEmpty)
    }

    @Test @MainActor func rawPhotosInAFolderLandThereAfterDeveloping() async throws {
        let dir = try TestVideo.tempDirectory().appending(path: "Timelapse", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["DSC0001.ARW", "DSC0002.ARW"] { try Data().write(to: dir.appending(path: name)) }
        let store = ProjectStore(exporter: ExportManager.test("FolderTests"))
        store.handleDrop([dir])
        store.finishImageImport(asSequence: true)
        try await ImageSequenceTests.waitUntil(seconds: 3) { store.rawDevelopRequest != nil }
        let request = try #require(store.rawDevelopRequest)
        let folder = try #require(store.folders(in: nil).first)
        // Kept while the dialog is open…
        store.removeEmptyFolders()
        #expect(store.folders.count == 1)
        let clips = store.finishRawDevelop(request, settings: RawDevelopSettings(from: request.sequences[0]))
        // …and the clip goes into it.
        #expect(clips.first?.folderID == folder.id)
        store.removeClips(Set(store.clips.map(\.id)))
    }
}
