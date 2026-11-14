import SwiftUI

/// The bottom of the left sidebar: the Histogram and RGB Parade, shown and hidden together by
/// the Scopes button in the bar below them. They follow the viewer on screen.
struct ScopesArea: View {
    @Environment(ProjectStore.self) private var store
    @AppStorage("showScopes") private var showsScopes = false
    @State private var tap = ScopeTap()

    var body: some View {
        VStack(spacing: 0) {
            if showsScopes {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if store.scopeSource == nil {
                        Text("Open a clip or the timeline to see its scopes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        ScopePanel(title: "Histogram") { HistogramView(data: tap.data) }
                        ScopePanel(title: "RGB Parade") { ParadeView(data: tap.data) }
                        ClippingReadout(data: tap.data)
                    }
                }
                .padding(10)
                // Reads frames only while the scopes are showing.
                .task(id: store.scopeSource.map { ObjectIdentifier($0.player) }) {
                    tap.follow(store.scopeSource?.player)
                    while !Task.isCancelled {
                        tap.tick()
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                }
            }
            controlBar
        }
    }

    /// The button that shows and hides the scopes.
    private var controlBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsScopes.toggle() }
                } label: {
                    Label("Scopes", systemImage: "chart.bar.xaxis")
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(showsScopes ? Color.accentColor : .secondary)
                        .background(showsScopes ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help((showsScopes ? "Hide" : "Show") + " the Histogram and RGB Parade for the frame on screen, with how much of the picture is clipped")
                .accessibilityAddTraits(showsScopes ? .isSelected : [])
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

/// The colors for clipping marks: shadows crushed to black, highlights blown to white.
private enum ClipColor {
    static let shadows = Color(red: 0.35, green: 0.65, blue: 1)
    static let highlights = Color(red: 1, green: 0.35, blue: 0.3)
}

/// A scope with its name over it.
private struct ScopePanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// How much of the picture is clipped, in the shadows and highlights; red past a sliver.
private struct ClippingReadout: View {
    let data: ScopeData?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            item("Shadows clipped", data?.clippedShadows, color: ClipColor.shadows)
            item("Highlights clipped", data?.clippedHighlights, color: ClipColor.highlights)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption2.monospacedDigit())
        .help("How much of the picture is clipped: crushed to pure black (any color at 0) or blown to pure white (any color at 255). More than half a percent shows in red.")
    }

    private func item(_ title: String, _ value: Double?, color: Color) -> some View {
        let isWarning = (value ?? 0) > ScopeData.clipWarning
        return HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 8, height: 2)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value.map { Self.percent($0) } ?? "—")
                .fontWeight(isWarning ? .semibold : .regular)
                .foregroundStyle(isWarning ? Color.red : .primary)
        }
    }

    static func percent(_ value: Double) -> String {
        if value == 0 { return "0%" }
        if value < 0.001 { return "<0.1%" }
        return value.formatted(.percent.precision(.fractionLength(value < 0.1 ? 1 : 0)))
    }
}

/// Red, green, and blue histograms over each other, with brightness as a white line.
/// Dark on the left, light on the right; lines mark quarters, and the clipping points at the
/// very ends are marked (blue for crushed shadows, red for blown highlights).
struct HistogramView: View {
    let data: ScopeData?

    var body: some View {
        Canvas { context, size in
            Self.drawGrid(context, size: size, vertical: true)
            if let histogram = data?.histogram, histogram.count == 4 {
                let colors: [Color] = [.red, .green, .blue]
                context.blendMode = .plusLighter
                for channel in 0..<3 {
                    context.fill(Self.area(histogram[channel], size: size), with: .color(colors[channel].opacity(0.55)))
                }
                context.blendMode = .normal
                context.stroke(Self.outline(histogram[3], size: size), with: .color(.white.opacity(0.85)), lineWidth: 1)
            }
            // The clipping points: anything at the very left is pure black, at the very right pure white.
            let shadowsWarn = (data?.clippedShadows ?? 0) > ScopeData.clipWarning
            let highlightsWarn = (data?.clippedHighlights ?? 0) > ScopeData.clipWarning
            Self.mark(context, x: 1, size: size, color: ClipColor.shadows, strong: shadowsWarn)
            Self.mark(context, x: size.width - 1, size: size, color: ClipColor.highlights, strong: highlightsWarn)
        }
        .accessibilityLabel("Histogram")
    }

    /// A clipping mark up the scope; solid and brighter while that much is clipped.
    private static func mark(_ context: GraphicsContext, x: CGFloat, size: CGSize, color: Color, strong: Bool) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(color.opacity(strong ? 1 : 0.55)),
                       style: StrokeStyle(lineWidth: strong ? 2 : 1, dash: strong ? [] : [3, 2]))
    }

    static func area(_ bins: [Float], size: CGSize) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(index) / 255 * size.width, y: size.height * (1 - CGFloat(value))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }

    static func outline(_ bins: [Float], size: CGSize) -> Path {
        Path { path in
            for (index, value) in bins.enumerated() {
                let point = CGPoint(x: CGFloat(index) / 255 * size.width, y: size.height * (1 - CGFloat(value)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// Faint quarter lines: across the levels (`vertical`), or up them.
    static func drawGrid(_ context: GraphicsContext, size: CGSize, vertical: Bool, inset: CGFloat = 0) {
        var grid = Path()
        for quarter in 1...3 {
            let fraction = CGFloat(quarter) / 4
            if vertical {
                grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            } else {
                let y = inset + (size.height - inset * 2) * fraction
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
    }
}

/// The RGB parade, with quarter lines and the clipping lines: 100% (blown highlights) across the
/// top and 0% (crushed shadows) across the bottom.
struct ParadeView: View {
    let data: ScopeData?
    /// Room above 100% and below 0%, so the clipping lines and anything on them show.
    static let inset: CGFloat = 8

    var body: some View {
        ZStack {
            if let parade = data?.parade {
                Image(decorative: parade, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .padding(.vertical, Self.inset)
            }
            Canvas { context, size in
                HistogramView.drawGrid(context, size: size, vertical: false, inset: Self.inset)
                let shadowsWarn = (data?.clippedShadows ?? 0) > ScopeData.clipWarning
                let highlightsWarn = (data?.clippedHighlights ?? 0) > ScopeData.clipWarning
                Self.line(context, y: Self.inset, size: size, color: ClipColor.highlights, strong: highlightsWarn)
                Self.line(context, y: size.height - Self.inset, size: size, color: ClipColor.shadows, strong: shadowsWarn)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading) {
                Text("100")
                Spacer()
                Text("0")
            }
            .font(.system(size: 7).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
        }
        .accessibilityLabel("RGB Parade")
    }

    private static func line(_ context: GraphicsContext, y: CGFloat, size: CGSize, color: Color, strong: Bool) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(path, with: .color(color.opacity(strong ? 1 : 0.6)),
                       style: StrokeStyle(lineWidth: strong ? 1.5 : 1, dash: strong ? [] : [3, 2]))
    }
}
