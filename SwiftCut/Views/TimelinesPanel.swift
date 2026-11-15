import SwiftUI

/// The top of the left sidebar: the project's timelines, pinned so they stay in view while the
/// Source Videos list scrolls under them. Click one to open it; double-click its name to rename
/// it; drop clips on one to add them to its end.
struct TimelinesPanel: View {
    @Environment(ProjectStore.self) private var store
    @State private var renamingID: UUID?
    @AppStorage("inspectorCollapsed.Timelines") private var isCollapsed = false

    /// Taller than this, the list scrolls on its own.
    private static let maxListHeight: CGFloat = 200
    static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(store.timelines) { timeline in
                            TimelineRow(timeline: timeline, renamingID: $renamingID)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(Self.maxListHeight, CGFloat(store.timelines.count) * (Self.rowHeight + 1) + 8))
            }
            Divider()
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Timelines")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    if isCollapsed {
                        Text(store.timelines.count.formatted())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show the timelines" : "Hide the timelines")
            Spacer()
            Button("New Timeline", systemImage: "plus") {
                renamingID = store.newTimeline()
                if isCollapsed { isCollapsed = false }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("New Timeline (⌥⌘N): an empty timeline with this one's frame size, frame rate, and sound settings")
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// A timeline in the sidebar: its name, how many clips, and how long. Highlighted while open.
private struct TimelineRow: View {
    @Environment(ProjectStore.self) private var store
    let timeline: ProjectTimeline
    @Binding var renamingID: UUID?
    @State private var name = ""
    @State private var isTargeted = false
    @FocusState private var isNameFocused: Bool

    private var isOpen: Bool { store.isTimelineOpen(timeline.id) }
    private var isRenaming: Bool { renamingID == timeline.id }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(isOpen ? Color.white : Color.accentColor)
                .frame(width: 18)
            if isRenaming {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(finishRenaming)
                    .onExitCommand { renamingID = nil }
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused, isRenaming { finishRenaming() }
                    }
                    .onAppear {
                        name = timeline.name
                        DispatchQueue.main.async { isNameFocused = true }
                    }
            } else {
                Text(timeline.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOpen ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isOpen ? Color.white : .primary)
        .padding(.horizontal, 8)
        .frame(height: TimelinesPanel.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isOpen ? Color.accentColor : isTargeted ? Color.accentColor.opacity(0.2) : .clear)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2) { startRenaming() }
        .onTapGesture { store.openTimeline(timeline.id) }
        .dropDestination(for: URL.self) { urls, _ in
            store.handleDrop(urls, onTimeline: timeline.id)
        } isTargeted: { isTargeted = $0 }
        .contextMenu { menu }
        .help("\(timeline.name): \(timeline.items.count) clip\(timeline.items.count == 1 ? "" : "s"), \(store.duration(of: timeline).timecode). Double-click to rename; drop clips here to add them to the end.")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
    }

    private var summary: String {
        timeline.items.isEmpty ? "Empty" : "\(timeline.items.count) · \(store.duration(of: timeline).timecode)"
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open", systemImage: "play.rectangle") { store.openTimeline(timeline.id) }
        Button("Rename", systemImage: "pencil") { startRenaming() }
        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateTimeline(timeline.id) }
        Divider()
        Button("Delete Timeline", systemImage: "trash", role: .destructive) { store.deleteTimeline(timeline.id) }
            .disabled(store.timelines.count < 2)
            .help("Deletes the timeline. Its clips stay in the project. You can undo this with Edit › Undo.")
    }

    private func startRenaming() {
        name = timeline.name
        renamingID = timeline.id
    }

    private func finishRenaming() {
        store.renameTimeline(timeline.id, to: name)
        renamingID = nil
    }
}

/// "Add to Timeline": a button for the open timeline, or a menu of them when there are several.
struct AddToTimelineMenu: View {
    @Environment(ProjectStore.self) private var store
    let media: [SidebarItem]

    var body: some View {
        if store.timelines.count < 2 {
            Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                store.addToTimeline(media)
            }
        } else {
            Menu("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                ForEach(store.timelines) { timeline in
                    Button(timeline.id == store.activeTimeline.id ? "\(timeline.name) (Open)" : timeline.name) {
                        store.addToTimeline(media, timelineID: timeline.id)
                    }
                }
                Divider()
                Button("New Timeline") {
                    store.addToTimeline(media, timelineID: store.newTimeline())
                }
            }
        }
    }
}
