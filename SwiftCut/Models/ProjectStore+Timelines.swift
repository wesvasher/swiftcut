import Foundation

/// One of the project's timelines: its name, the clips on it in order, and its settings.
struct ProjectTimeline: Identifiable, Equatable {
    var id = UUID()
    var name = "Timeline"
    var items: [TimelineItem] = []
    var settings = TimelineSettings()
}

/// Where a timeline's view was left: the playhead, the strip's zoom and scroll, and the viewer's
/// zoom. Kept while the project is open, not saved.
struct TimelineViewState: Equatable {
    var time: Double = 0
    /// The strip's zoom; `nil` until it's been shown.
    var pointsPerSecond: Double?
    var scrollX: CGFloat = 0
    var viewerZoom = ViewerZoom.fit
    var viewerPan = CGSize.zero
}

extension ProjectStore {
    func timeline(for id: UUID) -> ProjectTimeline? {
        timelines.first { $0.id == id }
    }

    /// Whether this timeline is the one showing.
    func isTimelineOpen(_ id: UUID) -> Bool {
        isTimelineSelected && activeTimeline.id == id
    }

    /// Shows a timeline in the viewer.
    func openTimeline(_ id: UUID) {
        guard timeline(for: id) != nil else { return }
        if activeTimeline.id != id {
            activeTimelineID = id
            selectedTimelineItemIDs = []
            timelineSelectionAnchor = nil
        }
        if selection != [.timeline] { selection = [.timeline] }
    }

    /// Makes an empty timeline with the open one's frame size, frame rate, and sound settings, and opens it.
    @discardableResult
    func newTimeline() -> UUID {
        var timeline = ProjectTimeline(name: nextTimelineName("Timeline"))
        timeline.settings = activeTimeline.settings
        timelines.append(timeline)
        openTimeline(timeline.id)
        return timeline.id
    }

    /// Copies a timeline (its clips and settings) under it, and opens the copy.
    @discardableResult
    func duplicateTimeline(_ id: UUID) -> UUID? {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return nil }
        let original = timelines[index]
        let copy = ProjectTimeline(
            name: nextTimelineName("\(original.name) Copy"),
            // New ids, so selecting on one doesn't select on the other. Subclips are shared until trimmed.
            items: original.items.map { TimelineItem(clipID: $0.clipID, subclipID: $0.subclipID, audio: $0.audio) },
            settings: original.settings)
        timelines.insert(copy, at: index + 1)
        openTimeline(copy.id)
        return copy.id
    }

    func renameTimeline(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = timelines.firstIndex(where: { $0.id == id }),
              timelines[index].name != trimmed else { return }
        timelines[index].name = trimmed
    }

    /// Deletes a timeline (not the last one). The clips it used stay in the project.
    func deleteTimeline(_ id: UUID) {
        guard timelines.count > 1, let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        let wasOpen = activeTimeline.id == id
        timelines.remove(at: index)
        timelineViewStates[id] = nil
        if wasOpen {
            // Open its neighbor instead.
            activeTimelineID = timelines[min(index, timelines.count - 1)].id
            selectedTimelineItemIDs = []
            timelineSelectionAnchor = nil
        }
    }

    /// Moves timelines in the sidebar's list.
    func moveTimelines(from offsets: IndexSet, to destination: Int) {
        timelines.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Adds source videos and subclips to the end of a timeline, which needn't be the open one.
    func addToTimeline(_ media: [SidebarItem], timelineID: UUID) {
        guard timelineID != activeTimeline.id else {
            addToTimeline(media)
            return
        }
        guard let index = timelines.firstIndex(where: { $0.id == timelineID }) else { return }
        let items: [TimelineItem] = media.compactMap { entry in
            switch entry {
            case .clip(let id): clip(for: id).map { TimelineItem(clipID: $0.id) }
            case .subclip(let id): subclip(for: id).map { TimelineItem(clipID: $0.sourceID, subclipID: $0.id) }
            case .timeline: nil
            }
        }
        guard !items.isEmpty else { return }
        timelines[index].items.append(contentsOf: items)
    }

    /// Media-list rows or files dropped on a timeline in the sidebar: added to its end.
    func handleDrop(_ urls: [URL], onTimeline timelineID: UUID) -> Bool {
        let subclipIDs = urls.compactMap(Subclip.id(fromDragURL:))
        if !subclipIDs.isEmpty {
            addToTimeline(subclipIDs.map { .subclip($0) }, timelineID: timelineID)
            return true
        }
        // Timeline items can't move between timelines this way.
        guard !urls.contains(where: { TimelineItem.id(fromDragURL: $0) != nil }) else { return false }
        let clips = importFiles(urls, securityScoped: true)
        guard !clips.isEmpty else { return false }
        addToTimeline(clips.map { .clip($0.id) }, timelineID: timelineID)
        return true
    }

    /// How long a timeline plays, in seconds.
    func duration(of timeline: ProjectTimeline) -> Double {
        timeline.items.map(duration(of:)).reduce(0, +)
    }

    /// "Timeline", or "Timeline 2" and up when that's taken.
    func nextTimelineName(_ base: String) -> String {
        let names = Set(timelines.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
