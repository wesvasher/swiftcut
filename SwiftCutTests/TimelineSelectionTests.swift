import Foundation
import Testing
@testable import SwiftCut

/// Selecting clips on the timeline: on their own, with Command, and with Shift.
struct TimelineSelectionTests {
    /// A store with five clips on the timeline.
    @MainActor static func store() -> (ProjectStore, [UUID]) {
        let store = ProjectStore(exporter: ExportManager.test("TimelineSelectionTests"))
        let clips = (0..<5).map { index -> Clip in
            let clip = Clip(url: URL(filePath: "/tmp/\(index).mov"))
            clip.duration = 2
            clip.isLoaded = true
            return clip
        }
        store.clips = clips
        store.addToTimeline(clips)
        return (store, store.timeline.map(\.id))
    }

    @Test @MainActor func clickSelectsOne() {
        let (store, ids) = Self.store()
        store.clickTimelineItem(ids[1])
        #expect(store.selectedTimelineItemIDs == [ids[1]])
        #expect(store.selectedTimelineItemID == ids[1])
        store.clickTimelineItem(ids[3])
        #expect(store.selectedTimelineItemIDs == [ids[3]])
    }

    @Test @MainActor func commandAddsAndRemoves() {
        let (store, ids) = Self.store()
        store.clickTimelineItem(ids[0])
        store.clickTimelineItem(ids[2], command: true)
        store.clickTimelineItem(ids[4], command: true)
        #expect(store.selectedTimelineItemIDs == [ids[0], ids[2], ids[4]])
        // More than one: no single selected item, so the inspector shows the group.
        #expect(store.selectedTimelineItemID == nil)
        #expect(store.selectedTimelineItems.map(\.id) == [ids[0], ids[2], ids[4]])
        store.clickTimelineItem(ids[2], command: true)
        #expect(store.selectedTimelineItemIDs == [ids[0], ids[4]])
    }

    @Test @MainActor func shiftSelectsARunEitherWay() {
        let (store, ids) = Self.store()
        store.clickTimelineItem(ids[1])
        store.clickTimelineItem(ids[3], shift: true)
        #expect(store.selectedTimelineItemIDs == Set(ids[1...3]))
        // Shift again from the same anchor replaces the run.
        store.clickTimelineItem(ids[0], shift: true)
        #expect(store.selectedTimelineItemIDs == Set(ids[0...1]))
    }

    @Test @MainActor func commandShiftAddsARun() {
        let (store, ids) = Self.store()
        store.clickTimelineItem(ids[0])
        store.clickTimelineItem(ids[3], command: true)
        store.clickTimelineItem(ids[4], command: true, shift: true)
        #expect(store.selectedTimelineItemIDs == [ids[0], ids[3], ids[4]])
    }

    @Test @MainActor func shiftWithNothingSelectedSelectsThatClip() {
        let (store, ids) = Self.store()
        store.selectedTimelineItemID = nil
        store.clickTimelineItem(ids[2], shift: true)
        #expect(store.selectedTimelineItemIDs == [ids[2]])
    }

    @Test @MainActor func removingAndSelectingAll() {
        let (store, ids) = Self.store()
        store.selectAllTimelineItems()
        #expect(store.selectedTimelineItemIDs == Set(ids))

        store.clickTimelineItem(ids[1])
        store.clickTimelineItem(ids[3], shift: true)
        store.removeSelectedTimelineItems()
        #expect(store.timeline.map(\.id) == [ids[0], ids[4]])
        #expect(store.selectedTimelineItemIDs.isEmpty)

        // Removing one clip drops it from the selection too.
        store.clickTimelineItem(ids[0])
        store.clickTimelineItem(ids[4], command: true)
        store.removeTimelineItem(ids[4])
        #expect(store.selectedTimelineItemIDs == [ids[0]])
    }

    @Test @MainActor func clipsLeavingTheTimelineLeaveTheSelection() {
        let (store, ids) = Self.store()
        store.selectAllTimelineItems()
        store.removeClips([store.timeline[0].clipID])
        #expect(store.selectedTimelineItemIDs == Set(ids[1...]))
    }
}
