import AppKit
import SwiftUI
import Testing
@testable import SwiftCut

/// More than one timeline in a project: making, opening, renaming, deleting, saving, and
/// keeping them apart.
struct TimelinesTests {
    /// A store with three clips, all on the first timeline.
    @MainActor static func store() -> (ProjectStore, [Clip]) {
        let store = ProjectStore(exporter: ExportManager.test("TimelinesTests"))
        let clips = (0..<3).map { index -> Clip in
            let clip = Clip(url: URL(filePath: "/tmp/timelines-\(index).mov"))
            clip.duration = 4
            clip.isLoaded = true
            return clip
        }
        store.clips = clips
        store.addToTimeline(clips)
        return (store, clips)
    }

    @Test @MainActor func newTimelineIsEmptyOpenAndNamed() {
        let (store, _) = Self.store()
        store.timelineSettings.frameRate = .fps24
        let first = store.activeTimeline.id
        let id = store.newTimeline()
        #expect(store.timelines.count == 2)
        #expect(store.activeTimeline.id == id)
        #expect(store.isTimelineSelected)
        #expect(store.timeline.isEmpty)
        #expect(store.activeTimeline.name == "Timeline 2")
        // Starts with the open timeline's settings.
        #expect(store.timelineSettings.frameRate == .fps24)
        // The first keeps its clips.
        #expect(store.timeline(for: first)?.items.count == 3)
        #expect(store.newTimeline() != id)
        #expect(store.activeTimeline.name == "Timeline 3")
    }

    @Test @MainActor func editsGoToTheOpenTimeline() {
        let (store, clips) = Self.store()
        let first = store.activeTimeline.id
        store.newTimeline()
        store.addToTimeline([clips[1]])
        store.timelineSettings.matchLoudness = true
        #expect(store.timeline.map(\.clipID) == [clips[1].id])
        store.openTimeline(first)
        #expect(store.timeline.count == 3)
        #expect(!store.timelineSettings.matchLoudness)
        #expect(store.timelineDuration == 12)
    }

    @Test @MainActor func switchingClearsTheItemSelection() {
        let (store, _) = Self.store()
        let first = store.activeTimeline.id
        store.selectAllTimelineItems()
        store.newTimeline()
        #expect(store.selectedTimelineItemIDs.isEmpty)
        store.openTimeline(first)
        #expect(store.selectedTimelineItemIDs.isEmpty)
    }

    @Test @MainActor func addsToATimelineThatIsntOpen() {
        let (store, clips) = Self.store()
        let first = store.activeTimeline.id
        let second = store.newTimeline()
        store.openTimeline(first)
        store.addToTimeline([.clip(clips[2].id)], timelineID: second)
        #expect(store.activeTimeline.id == first)
        #expect(store.timeline.count == 3)
        #expect(store.timeline(for: second)?.items.map(\.clipID) == [clips[2].id])
    }

    @Test @MainActor func renameDuplicateAndDelete() {
        let (store, _) = Self.store()
        let first = store.activeTimeline.id
        store.renameTimeline(first, to: "  Rough Cut ")
        #expect(store.activeTimeline.name == "Rough Cut")
        store.renameTimeline(first, to: "   ")
        #expect(store.activeTimeline.name == "Rough Cut")

        let copy = store.duplicateTimeline(first)!
        #expect(store.timelines.map(\.name) == ["Rough Cut", "Rough Cut Copy"])
        #expect(store.activeTimeline.id == copy)
        #expect(store.timeline.map(\.clipID) == store.timeline(for: first)!.items.map(\.clipID))
        // Items of their own.
        #expect(Set(store.timeline.map(\.id)).isDisjoint(with: store.timeline(for: first)!.items.map(\.id)))

        // Deleting the open one opens its neighbor; the last one can't be deleted.
        store.deleteTimeline(copy)
        #expect(store.timelines.count == 1)
        #expect(store.activeTimeline.id == first)
        store.deleteTimeline(first)
        #expect(store.timelines.count == 1)
    }

    @Test @MainActor func removingAClipTakesItOffEveryTimeline() {
        let (store, clips) = Self.store()
        store.newTimeline()
        store.addToTimeline([clips[0], clips[1]])
        store.removeClips([clips[0].id])
        #expect(store.timelines.allSatisfy { !$0.items.contains { $0.clipID == clips[0].id } })
        #expect(store.timeline.count == 1)
        #expect(store.timelines[0].items.count == 2)
    }

    /// Trimming on one timeline doesn't change a subclip another timeline uses.
    @Test @MainActor func trimmingDoesntChangeAnotherTimeline() {
        let (store, clips) = Self.store()
        let first = store.activeTimeline.id
        let item = store.timeline[0].id
        store.setTrimStart(1, for: item)
        let subclip = store.timeline[0].subclipID!
        store.newTimeline()
        store.addToTimeline([.subclip(subclip)])
        store.setTrimStart(2, for: store.timeline[0].id)
        #expect(store.timeline[0].subclipID != subclip)
        #expect(store.subclip(for: subclip)?.start == 1)
        store.openTimeline(first)
        #expect(store.trimRange(of: store.timeline[0]) == 1...clips[0].duration)
    }

    @Test @MainActor func savesAndReopensEveryTimeline() throws {
        let (store, clips) = Self.store()
        store.renameTimeline(store.activeTimeline.id, to: "Long")
        store.newTimeline()
        store.renameTimeline(store.activeTimeline.id, to: "Short")
        store.addToTimeline([clips[2]])
        store.timelineSettings.cinematicSound = true

        let data = try JSONEncoder().encode(store.projectFile)
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        #expect(file == store.projectFile)
        let reopened = ProjectStore(exporter: ExportManager.test("TimelinesTests"))
        reopened.apply(file)
        #expect(reopened.timelines.map(\.name) == ["Long", "Short"])
        #expect(reopened.timelines[1].items.map(\.clipID) == [clips[2].id])
        #expect(reopened.timelines[1].settings.cinematicSound)
        #expect(reopened.timelines.map(\.id) == store.timelines.map(\.id))

        // Older versions read the first timeline from where they always did.
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["timeline"] as? [Any])?.count == 3)
        #expect(json["timelineSettings"] != nil)
    }

    /// A project saved before there could be more than one timeline opens with it as the only one.
    @Test @MainActor func opensAProjectWithOneTimeline() throws {
        let clipID = UUID(), itemID = UUID()
        let json = """
        {"version": 2, "clips": [{"id": "\(clipID)", "path": "/tmp/a.mov"}],
         "timeline": [{"id": "\(itemID)", "clipID": "\(clipID)"}],
         "timelineSettings": {"matchLoudness": true}}
        """
        let file = try JSONDecoder().decode(ProjectFile.self, from: Data(json.utf8))
        #expect(file.timelines.count == 1)
        #expect(file.timelines[0].name == "Timeline")
        #expect(file.timelines[0].items.map(\.id) == [itemID])
        #expect(file.timelines[0].settings.matchLoudness)
    }

    /// Undoing a new timeline while it's open goes back to the first.
    @Test @MainActor func undoingTheOpenTimelineOpensTheFirst() {
        let (store, _) = Self.store()
        let before = store.projectFile
        store.newTimeline()
        store.apply(before)
        #expect(store.timelines.count == 1)
        #expect(store.activeTimeline.id == before.timelines[0].id)
        #expect(store.timeline.count == 3)
    }

    @Test @MainActor func droppingClipsOnATimeline() {
        let (store, clips) = Self.store()
        let first = store.activeTimeline.id
        let second = store.newTimeline()
        store.openTimeline(first)
        #expect(store.handleDrop([clips[1].url], onTimeline: second))
        #expect(store.clips.count == 3)
        #expect(store.timeline(for: second)?.items.map(\.clipID) == [clips[1].id])
        // Items dragged off a timeline don't move to another this way.
        #expect(!store.handleDrop([store.timeline[0].dragURL], onTimeline: second))
    }

    /// Draws the sidebar with several timelines over a long clip list, so its look can be checked.
    @Test @MainActor func sidebarDraws() throws {
        let (store, clips) = Self.store()
        store.clips += (3..<14).map { index in
            let clip = Clip(url: URL(filePath: "/tmp/timelines-\(index).mov"))
            clip.duration = 4
            clip.isLoaded = true
            return clip
        }
        store.renameTimeline(store.activeTimeline.id, to: "Main Edit")
        store.newTimeline()
        store.addToTimeline([clips[0]])
        store.renameTimeline(store.activeTimeline.id, to: "Trailer")
        store.newTimeline()
        store.openTimeline(store.timelines[1].id)
        let host = NSHostingView(rootView: SidebarView().environment(store).frame(width: 280, height: 560))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 560)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
            .write(to: FileManager.default.temporaryDirectory.appending(path: "timelines-sidebar.png"))
    }
}
