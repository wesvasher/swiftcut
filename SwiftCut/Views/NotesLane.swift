import SwiftUI

/// The row above the clip's filmstrip with its text notes: a bar from each note's in point to its
/// out point. Drag a bar to move it, drag its ends to change the in and out points, click it to
/// edit it in the inspector, and double-click the row to add a note there.
struct NotesLane: View {
    @Bindable var clip: Clip
    let controller: ClipPlayerController
    let contentWidth: CGFloat
    let duration: Double

    static let height: CGFloat = 20

    /// The note being dragged, and its times when the drag began.
    @State private var drag: (id: UUID, start: Double, end: Double, part: Part)?

    private enum Part { case body, start, end }
    private let handleWidth: CGFloat = 6

    private func x(_ seconds: Double) -> CGFloat { CGFloat(seconds / max(duration, 0.001)) * contentWidth }
    private func seconds(_ points: CGFloat) -> Double { Double(points / max(contentWidth, 1)) * duration }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.5))
            if clip.notes.isEmpty {
                Text("Notes · double-click to add one")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
                    .frame(height: Self.height)
                    .allowsHitTesting(false)
            }
            ForEach(clip.notes) { note in
                bar(note)
            }
        }
        .frame(width: contentWidth, height: Self.height, alignment: .topLeading)
        .coordinateSpace(.named("notesLane"))
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            controller.selectedNote = clip.addNote(at: seconds(value.location.x))
        })
        .help("Text notes over the picture. Double-click to add one; drag one to move it, or its ends to change where it starts and stops.")
    }

    private func bar(_ note: TextNote) -> some View {
        let left = x(note.start), width = max(handleWidth * 2 + 4, x(note.end) - x(note.start))
        let isSelected = controller.selectedNote == note.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.45))
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white.opacity(isSelected ? 0.9 : 0.25), lineWidth: 1)
            Text(note.text.isEmpty ? " " : note.text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, handleWidth + 2)
            // Grab the ends to change the in and out points.
            HStack(spacing: 0) {
                handle(note, .start)
                Spacer(minLength: 0)
                handle(note, .end)
            }
        }
        .frame(width: width, height: Self.height - 2)
        .offset(x: left, y: 1)
        .gesture(dragGesture(note, part: .body))
        .onTapGesture { controller.selectedNote = note.id }
        .contextMenu {
            Button("Set In to Playhead") { clip.updateNote(note.id) { $0.start = controller.currentTime } }
            Button("Set Out to Playhead") { clip.updateNote(note.id) { $0.end = controller.currentTime } }
            Divider()
            Button("Delete Note", role: .destructive) {
                clip.removeNote(note.id)
                if controller.selectedNote == note.id { controller.selectedNote = nil }
            }
        }
        .help("\(note.text) (\(controller.clock.timecode(seconds: note.start))–\(controller.clock.timecode(seconds: note.end)))")
    }

    private func handle(_ note: TextNote, _ part: Part) -> some View {
        Rectangle()
            .fill(.white.opacity(0.001))
            .frame(width: handleWidth)
            .overlay(Capsule().fill(.white.opacity(0.7)).frame(width: 2, height: 8))
            .contentShape(Rectangle())
            .gesture(dragGesture(note, part: part))
            .pointerStyle(.frameResize(position: part == .start ? .leading : .trailing))
    }

    private func dragGesture(_ note: TextNote, part: Part) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("notesLane"))
            .onChanged { value in
                if drag?.id != note.id {
                    drag = (note.id, note.start, note.end, part)
                    controller.selectedNote = note.id
                }
                guard let drag else { return }
                let delta = seconds(value.translation.width)
                clip.updateNote(note.id) { edited in
                    switch drag.part {
                    case .body:
                        // The whole note, keeping its length, inside the clip.
                        let length = drag.end - drag.start
                        let start = min(max(0, drag.start + delta), max(0, duration - length))
                        edited.start = start
                        edited.end = start + length
                    case .start:
                        edited.start = min(drag.start + delta, drag.end - 0.1)
                    case .end:
                        edited.end = max(drag.end + delta, drag.start + 0.1)
                    }
                }
            }
            .onEnded { _ in drag = nil }
    }
}
