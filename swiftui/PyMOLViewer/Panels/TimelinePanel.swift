// TimelinePanel.swift — the docked "movie studio" (Timeline mode).
//
// Promotes RayMol's linear frame transport into a composition editor (the PyMOL
// Timeline, adapted to touch + pointer). Shown only while engine.timelineMode is
// on; docks below the viewport on macOS and replaces the bottom panel on iOS.
// Reuses TransportBar for playback so the playhead IS the core frame.
//
// ONE unified lane holds both object kinds — camera keyframes (diamonds) and
// scene markers (chips) — laid out proportionally on a time ruler and joined by
// TRANSITIONS (duration + easing). Editing is item-centric:
//   • ◆ / palette  → append a camera keyframe / scene marker to the end.
//   • tap an item  → seek to it;  long-press → recall / delete.
//   • drag an item past a neighbor → reorder (ripples the timing).
//   • long-press a transition connector → set its duration (preset) + Smooth/
//     Linear easing. Duration drives timing: movie length = Σ transitions.
// Swift owns the ordered list (engine.timelineItems); every edit rebuilds the
// core movie. Produce hands the result to MovieExportSheet.

import SwiftUI

struct TimelinePanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject var playback: PlaybackState

    /// Called when the user exits the mode (Done / close). Defaults to flipping
    /// engine.timelineMode so the caller can just drop `TimelinePanel()` in.
    var onExit: (() -> Void)? = nil

    @State private var showExport = false

    // Drag-to-reorder: while dragging an item we render it at `dragX` (live) and
    // commit the reorder on release. A small minimumDistance keeps a stationary
    // tap (seek) from starting a drag.
    @State private var dragItemID: UUID? = nil
    @State private var dragX: CGFloat = 0

    // Long-press scene management (rename needs a text-entry alert).
    @State private var sceneRenameTarget: String? = nil
    @State private var sceneRenameText: String = ""

    // Template composer (preset builders, folded into the dock). Applying a
    // template APPENDS its items to the end of the lane.
    @State private var composerKind = "roll"
    @State private var composerAxis = "y"
    @State private var composerDuration: Double = 8
    @State private var composerAngle: Double = 30
    @State private var composerSecPerScene: Double = 3

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { hSize == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private let laneH: CGFloat = 44
    private let rulerH: CGFloat = 22
    private var labelW: CGFloat { isCompact ? 34 : 72 }
    private let laneSpace = "timelineLane"   // coord space for drag→x mapping

    static let durationPresets: [Double] = [0.5, 1, 2, 5, 8]

    // A laid-out item: its model, order index, and computed timeline frame.
    private struct Laid: Identifiable {
        let item: PyMOLEngine.TimelineItem
        let index: Int
        let frame: Int
        var id: UUID { item.id }
    }
    private var laidOut: [Laid] {
        let frames = engine.itemFrames()
        return engine.timelineItems.enumerated().compactMap { i, it in
            frames.indices.contains(i) ? Laid(item: it, index: i, frame: frames[i]) : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TimelineTheme.accent.opacity(0.35)).frame(height: 1)
            tracksSection
            scenePaletteStrip
            Divider()
            TransportBar()
            Divider().opacity(0.5)
            composer
        }
        .background(TimelineTheme.bar)
        .sheet(isPresented: $showExport) { MovieExportSheet() }
        .alert("Rename scene", isPresented: Binding(
            get: { sceneRenameTarget != nil },
            set: { if !$0 { sceneRenameTarget = nil } })) {
            TextField("Scene name", text: $sceneRenameText)
            Button("Rename") {
                if let t = sceneRenameTarget { engine.renameScene(t, to: sceneRenameText) }
                sceneRenameTarget = nil
            }
            Button("Cancel", role: .cancel) { sceneRenameTarget = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: isCompact ? 6 : 10) {
            Image(systemName: "clapperboard.fill")
                .font(.system(size: 14))
                .foregroundColor(TimelineTheme.accent)
            if !isCompact {
                Text("Timeline")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TimelineTheme.text)
            }
            Text(lengthLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TimelineTheme.dim)
                .lineLimit(1)

            Spacer(minLength: 4)

            addButton
            if !isCompact {
                textButton("Produce", "film") { showExport = true }
                    .disabled(engine.timelineItems.isEmpty)
            } else {
                iconButton("film", help: "Produce") { showExport = true }
                    .disabled(engine.timelineItems.isEmpty)
            }
            overflowMenu
            doneButton
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .frame(height: 44)
    }

    // Icon-only header button with a tooltip (macOS/pointer) + VoiceOver label.
    private func iconButton(_ systemName: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.text)
        .help(help)
        .accessibilityLabel(help)
    }

    private var addButton: some View {
        Button(action: { engine.captureCameraItem() }) {
            Label("Camera keyframe", systemImage: "plus.diamond.fill")
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.accent)
        .accessibilityLabel("Add a camera keyframe of the current view")
        .help("Add a camera keyframe of the current view to the end")
    }

    private var overflowMenu: some View {
        Menu {
            if !engine.timelineItems.isEmpty {
                Button(role: .destructive) { engine.clearMovieItems() } label: {
                    Label("Clear timeline", systemImage: "trash")
                }
            } else {
                Text("Timeline is empty")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(TimelineTheme.text)
        .help("Timeline options")
    }

    // The current movie length, from the sum of transition durations.
    private var lengthLabel: String {
        guard !engine.timelineItems.isEmpty else { return "Empty" }
        let secs = Double(engine.timelineTotalFrames) / max(playback.movieFPS, 1)
        return secs >= 10 ? String(format: "%.0fs", secs) : String(format: "%.1fs", secs)
    }

    private var doneButton: some View {
        Button { (onExit ?? { withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = false } })() } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                Text("Done")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(TimelineTheme.accent))
        }
        .buttonStyle(.plain)
        .help("Exit Timeline mode")
        .accessibilityLabel("Close timeline")
    }

    private func textButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.text)
    }

    // MARK: - The unified lane

    private var tracksSection: some View {
        HStack(spacing: 0) {
            // Slim left gutter (icon), aligned to the lane; ruler sits above it.
            VStack(spacing: 0) {
                Color.clear.frame(height: rulerH)
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 13)).foregroundColor(TimelineTheme.accent)
                    if !isCompact {
                        Text("Track").font(.system(size: 11)).foregroundColor(TimelineTheme.text)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: laneH)
                .help("Camera keyframes + scene markers")
                .accessibilityLabel("Timeline track")
            }
            .frame(width: labelW)

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ruler(width: w)
                        itemLane(width: w)
                    }
                    playhead(width: w)
                }
                .coordinateSpace(name: laneSpace)
            }
            .frame(height: rulerH + laneH)
        }
    }

    // Ruler doubles as the scrub strip: drag anywhere on it to move the playhead.
    private func ruler(width w: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.03))
            ForEach(0..<5) { i in
                let frac = CGFloat(i) / 4
                Text(timeLabel(frac))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TimelineTheme.dim)
                    .offset(x: min(frac * w + 3, w - 26), y: -4)
            }
        }
        .frame(height: rulerH)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in engine.scrub(to: frame(atX: g.location.x, width: w)) }
                .onEnded { _ in engine.endScrub() }
        )
    }

    @ViewBuilder
    private func itemLane(width w: CGFloat) -> some View {
        let items = laidOut
        ZStack(alignment: .topLeading) {
            Rectangle().fill(TimelineTheme.accent.opacity(0.05))
            if items.isEmpty {
                Text("Tap ◆ to add a camera keyframe, or a scene below — then set the gaps between them")
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .padding(.leading, 10)
                    .frame(height: laneH, alignment: .leading)
            } else {
                // Connectors first (behind the item nodes).
                ForEach(items.dropFirst()) { laid in
                    connector(laid,
                              prevX: clampX(xFor(items[laid.index - 1].frame, width: w), width: w),
                              curX: clampX(xFor(laid.frame, width: w), width: w))
                }
                ForEach(items) { laid in
                    itemNode(laid, width: w)
                }
            }
        }
        .frame(height: laneH)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
        .clipped()
    }

    // The transition INTO `laid.item` (the gap from the previous item), shown as
    // a bar with its duration; long-press to reconfigure duration + easing.
    private func connector(_ laid: Laid, prevX: CGFloat, curX: CGFloat) -> some View {
        let midX = (prevX + curX) / 2
        let wid = max(curX - prevX, 1)
        let linear = laid.item.transition.linear
        return ZStack {
            Capsule()
                .fill(TimelineTheme.accent.opacity(linear ? 0.18 : 0.28))
                .frame(width: wid, height: 3)
            Text(fmtSeconds(laid.item.transition.seconds))
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(TimelineTheme.bar))
                .overlay(Capsule().stroke(TimelineTheme.accent.opacity(linear ? 0.3 : 0.6),
                                          style: StrokeStyle(lineWidth: 0.75, dash: linear ? [2, 2] : [])))
                .foregroundColor(linear ? TimelineTheme.dim : TimelineTheme.accent)
        }
        .frame(width: max(wid, 34), height: laneH)
        .contentShape(Rectangle())
        .position(x: midX, y: laneH / 2)
        .contextMenu { transitionMenu(laid.item) }
        .help("Transition · \(fmtSeconds(laid.item.transition.seconds)) · \(linear ? "Linear" : "Smooth") — long-press to change")
        .accessibilityLabel("Transition \(fmtSeconds(laid.item.transition.seconds)) \(linear ? "linear" : "smooth")")
    }

    @ViewBuilder
    private func transitionMenu(_ item: PyMOLEngine.TimelineItem) -> some View {
        Text("Transition · \(fmtSeconds(item.transition.seconds)) · \(item.transition.linear ? "Linear" : "Smooth")")
        Menu("Duration") {
            ForEach(TimelinePanel.durationPresets, id: \.self) { d in
                Button {
                    engine.setTransition(item.id, seconds: d, linear: item.transition.linear)
                } label: {
                    Label(fmtSeconds(d), systemImage: item.transition.seconds == d ? "checkmark" : "clock")
                }
            }
        }
        Button {
            engine.setTransition(item.id, seconds: item.transition.seconds, linear: false)
        } label: { Label("Smooth", systemImage: item.transition.linear ? "circle" : "checkmark") }
        Button {
            engine.setTransition(item.id, seconds: item.transition.seconds, linear: true)
        } label: { Label("Linear", systemImage: item.transition.linear ? "checkmark" : "circle") }
    }

    // A camera keyframe (diamond) or scene marker (chip) at its timeline frame.
    private func itemNode(_ laid: Laid, width w: CGFloat) -> some View {
        let dragging = dragItemID == laid.item.id
        let x = dragging ? clampX(dragX, width: w) : clampX(xFor(laid.frame, width: w), width: w)
        return Group {
            switch laid.item.kind {
            case .camera:
                cameraNode(laid, current: laid.frame == playback.currentFrame)
            case .scene(let name):
                sceneNode(name)
            }
        }
        .scaleEffect(dragging ? 1.25 : 1)
        .frame(width: nodeHitWidth(laid), height: laneH)
        .contentShape(Rectangle())
        .position(x: x, y: laneH / 2)
        .gesture(reorderDrag(laid, width: w))
        .onTapGesture { engine.seekToItem(laid.item.id) }
        .contextMenu { itemMenu(laid) }
    }

    private func cameraNode(_ laid: Laid, current: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(current ? TimelineTheme.text : TimelineTheme.accent)
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(45))
            .shadow(color: .black.opacity(0.4), radius: 0.5)
            .accessibilityLabel("Camera keyframe \(laid.index + 1)")
    }

    private func sceneNode(_ name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "photo.fill").font(.system(size: 7))
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(TimelineTheme.accent.opacity(0.75)))
        .foregroundColor(.black)
        .fixedSize()
        .accessibilityLabel("Scene marker \(name)")
    }

    // Wider hit target for scene chips (variable width) than for diamonds.
    private func nodeHitWidth(_ laid: Laid) -> CGFloat {
        if case .scene = laid.item.kind { return 88 }
        return 30
    }

    private func itemMenu(_ laid: Laid) -> some View {
        Group {
            switch laid.item.kind {
            case .camera:
                Text("Camera keyframe \(laid.index + 1) · frame \(laid.frame)")
                Button { engine.seekToItem(laid.item.id) } label: { Label("Go to", systemImage: "arrow.right.to.line") }
                Button(role: .destructive) { engine.deleteItem(laid.item.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            case .scene(let name):
                Text("Scene · \(name) · frame \(laid.frame)")
                Button { engine.recallScene(name) } label: { Label("Recall (preview)", systemImage: "eye") }
                Button(role: .destructive) { engine.deleteItem(laid.item.id) } label: {
                    Label("Remove from timeline", systemImage: "trash")
                }
            }
        }
    }

    // Drag an item past a neighbor to reorder. Live x tracked in the lane space;
    // on release the target index = # of other items sitting left of the drop.
    private func reorderDrag(_ laid: Laid, width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(laneSpace))
            .onChanged { g in
                if dragItemID == nil { dragItemID = laid.item.id }
                dragX = g.location.x
            }
            .onEnded { _ in
                let dropX = dragX
                dragItemID = nil
                let others = engine.itemFrames().enumerated()
                    .filter { $0.offset != laid.index }
                let target = others.filter { xFor($0.element, width: w) < dropX }.count
                engine.moveItem(from: laid.index, to: target)
            }
    }

    // MARK: - Scene palette (source)

    // Saved scenes. Tap (or "Add") appends a scene marker to the end of the lane.
    @ViewBuilder private var scenePaletteStrip: some View {
        if !engine.sceneNames.isEmpty {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "photo.stack").font(.system(size: 13)).foregroundColor(TimelineTheme.dim)
                    if !isCompact {
                        Text("Scenes").font(.system(size: 11)).foregroundColor(TimelineTheme.text)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: labelW)
                .padding(.horizontal, 8)
                .help("Saved scenes — tap to append to the timeline")
                .accessibilityLabel("Saved scenes")

                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(engine.sceneNames, id: \.self) { name in
                            paletteChip(name)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .frame(height: 34)
            .overlay(alignment: .top) { Divider().opacity(0.4) }
        }
    }

    private func paletteChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(engine.currentScene == name
                                       ? TimelineTheme.accent : Color.white.opacity(0.12)))
            .foregroundColor(engine.currentScene == name ? .black : TimelineTheme.text)
            .contentShape(Capsule())
            .onTapGesture { engine.appendSceneItem(name) }
            .contextMenu {
                Text(name)
                Button { engine.recallScene(name) } label: { Label("Recall (preview)", systemImage: "eye") }
                Button { engine.appendSceneItem(name) } label: { Label("Add to timeline", systemImage: "plus") }
                Divider()
                Button { engine.updateScene(name) } label: { Label("Reset to current view", systemImage: "arrow.clockwise") }
                Button { sceneRenameText = name; sceneRenameTarget = name } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { engine.deleteScene(name) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    // MARK: - Template composer (folded-in preset builders → Append)

    private var composer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Camera Roll") { composerKind = "roll" }
                Button("Camera Rock") { composerKind = "rock" }
                Button("Scene loop")  { composerKind = "scenes" }
            } label: { composerChip(composerLabel, composerIcon) }

            if composerKind == "roll" || composerKind == "rock" {
                Menu {
                    ForEach(["x", "y", "z"], id: \.self) { a in
                        Button(a.uppercased()) { composerAxis = a }
                    }
                } label: { composerChip(composerAxis.uppercased(), "arrow.triangle.2.circlepath") }
                Menu {
                    ForEach([4, 8, 16], id: \.self) { s in Button("\(s) s") { composerDuration = Double(s) } }
                } label: { composerChip("\(Int(composerDuration))s", "clock") }
                if composerKind == "rock" {
                    Menu {
                        ForEach([30, 60, 90], id: \.self) { a in Button("\(a)°") { composerAngle = Double(a) } }
                    } label: { composerChip("\(Int(composerAngle))°", "angle") }
                }
            } else if composerKind == "scenes" {
                Menu {
                    ForEach([2, 3, 5], id: \.self) { s in Button("\(s) s / scene") { composerSecPerScene = Double(s) } }
                } label: { composerChip("\(Int(composerSecPerScene))s", "clock") }
            }

            Spacer(minLength: 0)

            Button(action: appendComposer) {
                Label("Append", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(TimelineTheme.accent)
            .disabled(composerKind == "scenes" && engine.sceneNames.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func composerChip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .foregroundColor(TimelineTheme.text)
    }

    private var composerLabel: String {
        switch composerKind {
        case "rock": return "Camera Rock"
        case "scenes": return "Scene loop"
        default: return "Camera Roll"
        }
    }

    private var composerIcon: String {
        switch composerKind {
        case "scenes": return "photo.stack"
        default: return "video"
        }
    }

    private func appendComposer() {
        switch composerKind {
        case "roll", "rock":
            engine.appendCameraTemplate(kind: composerKind, duration: composerDuration,
                                        axis: composerAxis, angle: composerAngle)
        case "scenes":
            engine.appendScenesTemplate(secondsPerScene: composerSecPerScene)
        default: break
        }
    }

    // MARK: - Playhead / geometry helpers

    private func playhead(width w: CGFloat) -> some View {
        let x = clampX(xFor(playback.currentFrame, width: w), width: w)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(TimelineTheme.accent)
                .frame(width: 2)
            Triangle()
                .fill(TimelineTheme.accent)
                .frame(width: 10, height: 7)
                .offset(y: -1)
        }
        .frame(width: 10, height: rulerH + laneH, alignment: .top)
        .offset(x: x - 5)
        .allowsHitTesting(false)
    }

    private func xFor(_ frame: Int, width w: CGFloat) -> CGFloat {
        let count = max(playback.frameCount, 1)
        guard count > 1 else { return 0 }
        let f = min(max(frame, 1), count)
        return CGFloat(f - 1) / CGFloat(count - 1) * w
    }

    private func frame(atX x: CGFloat, width w: CGFloat) -> Int {
        let count = max(playback.frameCount, 1)
        guard w > 0, count > 1 else { return 1 }
        let frac = min(max(x / w, 0), 1)
        return Int((frac * CGFloat(count - 1)).rounded()) + 1
    }

    private func clampX(_ x: CGFloat, width w: CGFloat) -> CGFloat {
        min(max(x, 7), max(w - 7, 7))
    }

    private func timeLabel(_ frac: CGFloat) -> String {
        let fps = max(playback.movieFPS, 0.1)
        let secs = Double(max(playback.frameCount, 1) - 1) / fps * Double(frac)
        return secs >= 10 ? String(format: "%.0fs", secs) : String(format: "%.1fs", secs)
    }

    private func fmtSeconds(_ s: Double) -> String {
        if s < 1 { return String(format: "%.1fs", s) }
        return s.rounded() == s ? "\(Int(s))s" : String(format: "%.1fs", s)
    }
}

// Small downward-pointing triangle for the playhead head.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
