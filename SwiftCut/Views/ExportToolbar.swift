import SwiftUI

/// The Play Full Screen button and the Export menu (two clicks: open it, pick a format).
struct ExportToolbar: ToolbarContent {
    @Environment(ProjectStore.self) private var store
    @Environment(ExportManager.self) private var exporter

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            UndoRedoButtons()
        }
        ToolbarItem(placement: .primaryAction) {
            // ⌘F lives on View › Play Full Screen, which works wherever the focus is.
            Button("Play Full Screen", systemImage: "play.rectangle") { store.playFullScreen() }
                .disabled(store.fullScreenSource == nil)
                .help(store.isTimelineSelected ? "Play the timeline full screen (⌘F)" : "Play the clip full screen (⌘F)")
        }
        ToolbarItem(placement: .primaryAction) {
            ExportMenu()
        }
    }
}

/// The Export menu. Export progress pops up from it while exports run.
private struct ExportMenu: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ExportManager.self) private var exporter

    var body: some View {
        @Bindable var exporter = exporter

        Menu {
            ExportPresetMenuItems { preset in store.exportSelection(as: preset) }
                .disabled(!store.canExport)
            Divider()
            if let folder = shownFolder {
                Button("Show Export Folder", systemImage: "folder") { NSWorkspace.shared.open(folder) }
            }
            Button("Show Exports…", systemImage: "arrow.down.circle") { exporter.isShowingActivity = true }
                .disabled(exporter.jobs.isEmpty)
            Button("Export Settings…", systemImage: "gearshape") { store.openExportSettings?() }
        } label: {
            if exporter.runningJobs.isEmpty {
                Label("Export", systemImage: "square.and.arrow.up")
            } else {
                // Shows progress while exporting.
                Label {
                    Text("Export")
                } icon: {
                    ProgressView(value: exporter.overallProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
        }
        .menuIndicator(.hidden)
        .disabled(!store.canExport && exporter.jobs.isEmpty)
        .help(store.isTimelineSelected ? "Export the timeline" : "Export the selected clips")
        .popover(isPresented: $exporter.isShowingActivity, arrowEdge: .bottom) {
            ExportActivityView()
        }
    }

    /// The folder exports currently go to, when there is a fixed one.
    private var shownFolder: URL? {
        switch exporter.location {
        case .projectFolder: store.projectURL?.deletingLastPathComponent()
        case .folder: exporter.customFolderIsMissing ? nil : exporter.customFolder
        case .ask: exporter.lastChosenFolder
        }
    }
}

/// The export presets as menu items: video presets first, then audio-only ones.
struct ExportPresetMenuItems: View {
    @Environment(ExportManager.self) private var exporter
    let action: (ExportPreset) -> Void

    var body: some View {
        let video = exporter.presets.filter { !$0.isAudioOnly }
        let audio = exporter.presets.filter(\.isAudioOnly)
        if exporter.presets.isEmpty {
            Text("No Export Presets")
        }
        if !video.isEmpty {
            Section("Video") { buttons(video) }
        }
        if !audio.isEmpty {
            Section("Audio") { buttons(audio) }
        }
    }

    private func buttons(_ presets: [ExportPreset]) -> some View {
        ForEach(presets) { preset in
            Button(preset.name, systemImage: preset.systemImage) { action(preset) }
        }
    }
}

struct ExportActivityView: View {
    @Environment(ExportManager.self) private var exporter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Exports").font(.headline)
                Spacer()
                Button("Clear") { exporter.clearFinished() }
                    .disabled(exporter.jobs.allSatisfy(\.isRunning))
            }
            .padding(12)

            Divider()

            if exporter.jobs.isEmpty {
                Text("No exports yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(exporter.jobs) { job in
                            ExportJobRow(job: job)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Text(locationNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(12)
        }
        .frame(width: 360)
    }

    private var locationNote: String {
        switch exporter.location {
        case .projectFolder: "Exports are saved next to the project file"
        case .ask: "SwiftCut asks where to save each export"
        case .folder: "Exports are saved to \((exporter.customFolderPath ?? "").abbreviatingWithTilde)"
        }
    }
}

private struct ExportJobRow: View {
    let job: ExportJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.outputURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.state {
                case .running:
                    ProgressView(value: job.progress)
                case .finished:
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            switch job.state {
            case .running:
                Button("Cancel", systemImage: "xmark.circle.fill") { job.cancel() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            case .finished:
                Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") { job.revealInFinder() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}

/// Undo and Redo, as Edit › Undo and Redo (⌘Z, ⇧⌘Z) do. Their tooltips say what they'd undo or redo.
private struct UndoRedoButtons: View {
    @Environment(\.undoManager) private var undoManager
    @State private var history = UndoHistory()

    var body: some View {
        ControlGroup {
            Button("Undo", systemImage: "arrow.uturn.backward") { send("undo:") }
                .disabled(!history.state.canUndo)
                .help(history.state.undoTitle + " (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { send("redo:") }
                .disabled(!history.state.canRedo)
                .help(history.state.redoTitle + " (⇧⌘Z)")
        }
        .onAppear { history.follow(undoManager) }
        .onChange(of: undoManager) { history.follow(undoManager) }
    }

    /// Through the responder chain, like the Edit menu, so it undoes typing in a text field too.
    private func send(_ action: String) {
        NSApp.sendAction(Selector(action), to: nil, from: nil)
        history.refresh()
    }
}

/// Follows a window's undo history for the Undo and Redo buttons. Listens outside SwiftUI and
/// changes `state` only when it differs: undo managers post checkpoints on every pass of the
/// run loop, and handing each one to SwiftUI (with `onReceive`) made its graph grow until the
/// app crashed.
@MainActor
@Observable
private final class UndoHistory {
    struct State: Equatable {
        var canUndo = false
        var canRedo = false
        var undoTitle = "Undo"
        var redoTitle = "Redo"
    }

    private(set) var state = State()
    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func follow(_ undoManager: UndoManager?) {
        if undoManager === self.undoManager, !observers.isEmpty { return }
        stop()
        self.undoManager = undoManager
        if let undoManager {
            let names: [Notification.Name] = [.NSUndoManagerCheckpoint, .NSUndoManagerDidCloseUndoGroup,
                                              .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        refresh()
    }

    func refresh() {
        var new = State()
        if let undoManager {
            new.canUndo = undoManager.canUndo
            new.canRedo = undoManager.canRedo
            if !undoManager.undoMenuItemTitle.isEmpty { new.undoTitle = undoManager.undoMenuItemTitle }
            if !undoManager.redoMenuItemTitle.isEmpty { new.redoTitle = undoManager.redoMenuItemTitle }
        }
        if new != state { state = new }
    }

    private func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    isolated deinit {
        stop()
    }
}
