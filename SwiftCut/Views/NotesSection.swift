import SwiftUI

/// The clip inspector's text notes: add one at the playhead, pick one, and edit it (text, in
/// and out points, fade, font, weight, size, and where it sits). Notes show over the picture
/// in the viewer, on the timeline, and in exports.
struct NotesSection: View {
    @Bindable var clip: Clip
    @Bindable var controller: ClipPlayerController
    /// The note whose text is being typed. Otherwise the text just shows, so the keyboard is free
    /// for playback (Space plays and pauses).
    @State private var editingNoteID: UUID?
    @FocusState private var isTextFocused: Bool

    var body: some View {
        InspectorSection("Notes") {
            Button("Add Note", systemImage: "plus") { add() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Add a note at the playhead")
        } content: {
            if clip.notes.isEmpty {
                GridRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text over the picture between an in and an out point, white on a soft dark box so it reads over anything. Double-click the row above the filmstrip, or:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add Note at Playhead", systemImage: "text.bubble") { add() }
                    }
                    .gridCellColumns(2)
                }
            } else {
                ForEach(clip.notes) { note in
                    noteRow(note)
                }
                if let id = controller.selectedNote, let note = clip.notes.first(where: { $0.id == id }) {
                    editor(note)
                        // Picking another note finishes typing in this one.
                        .onChange(of: controller.selectedNote) { _, selected in
                            if editingNoteID != nil, editingNoteID != selected { endEditing() }
                        }
                } else {
                    GridRow {
                        Text("Click a note to edit it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(2)
                    }
                }
            }
        }
    }

    private func add() {
        let id = clip.addNote(at: controller.currentTime)
        controller.selectedNote = id
        // A new note starts with its text ready to type.
        beginEditing(id)
    }

    private func beginEditing(_ id: UUID) {
        editingNoteID = id
        DispatchQueue.main.async { isTextFocused = true }
    }

    /// Done: stop typing and give the keyboard back to playback.
    private func endEditing() {
        editingNoteID = nil
        isTextFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// A note in the list: its times and text. Click to edit it; the playhead goes to its start.
    private func noteRow(_ note: TextNote) -> some View {
        let isSelected = controller.selectedNote == note.id
        return GridRow {
            Button {
                controller.selectedNote = note.id
                controller.seek(to: note.start)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(controller.clock.timecode(seconds: note.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(note.text.isEmpty ? "(empty)" : note.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gridCellColumns(2)
        }
    }

    // MARK: Editing

    @ViewBuilder
    private func editor(_ note: TextNote) -> some View {
        let id = note.id
        GridRow {
            Divider().gridCellColumns(2)
        }
        GridRow {
            InspectorLabel("Text")
            if editingNoteID == id {
                HStack(alignment: .top, spacing: 6) {
                    TextField("Note", text: binding(id, \.text), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($isTextFocused)
                        .onSubmit(endEditing)
                        .onExitCommand(perform: endEditing)
                    Button("Done", action: endEditing)
                        .buttonStyle(.borderedProminent)
                        .help("Finish typing (or press Return or Esc). Space plays and pauses again.")
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text(note.text.isEmpty ? "Empty note" : note.text)
                        .foregroundStyle(note.text.isEmpty ? .secondary : .primary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditing(id) }
                        .help("Click to edit the text")
                    Button("Edit", systemImage: "pencil") { beginEditing(id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Edit the text")
                }
            }
        }
        timeRow("In", note.start, id: id) { $0.start = controller.currentTime }
        timeRow("Out", note.end, id: id) { $0.end = controller.currentTime }
        GridRow {
            InspectorLabel("Fade")
            Toggle("Fade in and out", isOn: binding(id, \.fades))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Fades in at the in point and out at the out point")
        }
        GridRow {
            InspectorLabel("Font")
            Picker("Font", selection: binding(id, \.fontFamily)) {
                Text("System").tag(String?.none)
                Divider()
                ForEach(TextNote.fontFamilies, id: \.self) { family in
                    Text(family).tag(String?.some(family))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("System is the most readable on screen")
        }
        GridRow {
            InspectorLabel("Weight")
            Picker("Weight", selection: binding(id, \.weight)) {
                ForEach(TextNote.Weight.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        GridRow {
            InspectorLabel("Size")
            NumberStepper(value: binding(id, \.size), range: TextNote.sizeRange, step: 0.5, unit: "%", fractionDigits: 1,
                          presets: TextNote.sizePresets)
                .help("How tall the text is, as a share of the picture's height, so it looks the same at any size")
        }
        GridRow {
            InspectorLabel("Position")
            Picker("Position", selection: binding(id, \.position)) {
                ForEach(TextNote.Position.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Button("Delete Note", systemImage: "trash", role: .destructive) {
                endEditing()
                clip.removeNote(id)
                controller.selectedNote = nil
            }
        }
    }

    private func timeRow(_ title: String, _ seconds: Double, id: UUID, setToPlayhead: @escaping (inout TextNote) -> Void) -> some View {
        GridRow {
            InspectorLabel(title)
            HStack(spacing: 6) {
                Button(controller.clock.timecode(seconds: seconds)) { controller.seek(to: seconds) }
                    .buttonStyle(.link)
                    .monospacedDigit()
                    .help("Go there")
                Spacer(minLength: 0)
                Button("Set to Playhead") { clip.updateNote(id, setToPlayhead) }
                    .controlSize(.mini)
                    .help("Make the note \(title == "In" ? "start" : "end") at the playhead")
            }
        }
    }

    private func binding<Value: Equatable>(_ id: UUID, _ keyPath: WritableKeyPath<TextNote, Value>) -> Binding<Value> {
        Binding(
            get: { clip.notes.first { $0.id == id }?[keyPath: keyPath] ?? TextNote(start: 0, end: 0)[keyPath: keyPath] },
            set: { value in clip.updateNote(id) { $0[keyPath: keyPath] = value } }
        )
    }
}
