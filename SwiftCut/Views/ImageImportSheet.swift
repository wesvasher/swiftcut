import SwiftUI

/// Asks how to import images dropped on the window: as one image sequence or as separate
/// still images, and in what order.
struct ImageImportSheet: View {
    @Environment(ProjectStore.self) private var store
    let pending: PendingImageImport
    @State private var order = ImageSequence.Order.saved
    @State private var frameRate = ImageSequence.savedFrameRate
    @State private var isCustomRate = !ImageSequence.frameRates.contains(ImageSequence.savedFrameRate)
    @State private var count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Order:")
                        .gridColumnAlignment(.trailing)
                    orderPicker
                }
                GridRow {
                    Text("Frame Rate:")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Picker("Frame Rate", selection: rateChoice) {
                            ForEach(ImageSequence.frameRates, id: \.self) { fps in
                                Text(ImageSequence.frameRateTitle(fps)).tag(Optional(fps))
                            }
                            Divider()
                            Text("Custom…").tag(Double?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if isCustomRate {
                            TextField("fps", value: $frameRate, format: .number.precision(.fractionLength(0...3)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .help("Any rate from \(ImageSequence.minFrameRate.formatted()) to \(ImageSequence.maxFrameRate.formatted()) frames per second")
                            Text("fps")
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    .fixedSize()
                    .help("How many images play each second. You can change it later in the inspector.")
                }
            }
            .padding(.leading, 58)

            HStack {
                Button("Cancel", role: .cancel) { store.cancelImageImport() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Individual Images") { finish(asSequence: false) }
                Button("Image Sequence") { finish(asSequence: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            let pending = pending
            count = await Task.detached { pending.imageCount }.value
        }
    }

    /// A rate from the menu, or `nil` for Custom.
    private var rateChoice: Binding<Double?> {
        Binding(
            get: { isCustomRate ? nil : frameRate },
            set: { choice in
                if let choice {
                    frameRate = choice
                    isCustomRate = false
                } else {
                    isCustomRate = true
                }
            }
        )
    }

    private var orderPicker: some View {
                Picker("Order", selection: $order) {
                    ForEach(Array(ImageSequence.Order.groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        ForEach(group) { order in
                            Text(order.title).tag(order)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The order the images play in a sequence, or are added as separate images. Date Taken comes from the camera's details, or the date the file was made when there are none.")
    }

    private var title: String {
        guard let count else { return "Import images?" }
        return count == 1 ? "Import 1 image?" : "Import \(count.formatted()) images?"
    }

    private var message: String {
        let sequence = pending.folders.count > 1
            ? "Image Sequence makes each folder one video, one image per frame."
            : "Image Sequence makes them one video, one image per frame."
        return sequence + " Individual Images makes each image its own still clip. You can change the frame size, frame rate, and length later in the inspector."
    }

    private func finish(asSequence: Bool) {
        let fps = ImageSequence.clampedFrameRate(frameRate)
        ImageSequence.Order.saved = order
        ImageSequence.savedFrameRate = fps
        store.finishImageImport(asSequence: asSequence, order: order, frameRate: fps)
    }
}
