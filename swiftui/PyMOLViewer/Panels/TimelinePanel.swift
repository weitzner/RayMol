// TimelinePanel.swift — the docked "movie studio" (Timeline mode).
//
// Promotes RayMol's linear frame transport into a composition editor (the PyMOL
// Timeline, adapted to touch + pointer). On iPhone it IS the Movie tab's content
// (the tab bar stays visible — switch tabs to leave, no Done needed); on iPad /
// macOS it docks below the viewport as an explicit mode (with a Done button).
// Reuses TransportBar for playback so the playhead IS the core frame.
//
// ONE unified lane holds both object kinds — camera keyframes (diamonds) and
// scene markers (chips) — on a FIXED-SCALE time ruler (default ~10 s across the
// viewport, zoomable with +/-, and horizontally SCROLLABLE for longer movies).
// Objects are joined by TRANSITIONS (duration + easing) drawn as labeled
// connectors. Editing is item-centric:
//   • ◆ / palette  → append a camera keyframe / scene marker to the end.
//   • tap the ruler → seek to that time;  tap an item → seek to it.
//   • long-press an item → recall / delete;  drag an item past a neighbor →
//     reorder (ripples the timing).
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
    /// Whether to show the Done button. False on iPhone, where the timeline is
    /// the Movie tab and the tab bar handles navigation.
    var showsDone: Bool = true
    /// When set, the header shows an Expand button that opens/collapses the
    /// full-width bottom dock (macOS / iPad right-panel compact view). The button
    /// reflects `engine.timelineMode` (dock open) as its active state.
    var onExpand: (() -> Void)? = nil
    /// Force the narrow (iPhone-style) layout even on macOS/iPad — used for the
    /// right-inspector instance so it fits the ~400pt column instead of rendering
    /// the wide desktop transport that overflows.
    var forceCompact: Bool = false

    @State private var showClearConfirm = false

    // Horizontal zoom: pixels-per-second = (viewportWidth / 10) * zoom, so zoom
    // 1 fits ~10 s across the lane. +/- steps; the lane scrolls when the movie is
    // longer than the viewport.
    @State private var zoom: CGFloat = 1.0

    // Drag-to-reorder: while dragging an item we render it at `dragX` (live) and
    // commit the reorder on release.
    @State private var dragItemID: UUID? = nil
    @State private var dragX: CGFloat = 0

    // Long-press scene management (rename needs a text-entry alert).
    @State private var sceneRenameTarget: String? = nil
    @State private var sceneRenameText: String = ""

    // Template composer (preset builders, folded into the dock).
    @State private var composerKind = "roll"
    @State private var composerAxis = "y"
    @State private var composerDuration: Double = 8
    @State private var composerAngle: Double = 30
    @State private var composerSecPerScene: Double = 3

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { forceCompact || hSize == .compact }
    #else
    private var isCompact: Bool { forceCompact }
    #endif

    private let laneH: CGFloat = 56
    private let rulerH: CGFloat = 28
    private var labelW: CGFloat { isCompact ? 34 : 72 }
    private let laneSpace = "timelineLane"   // coord space for drag/tap -> frame
    private let minZoom: CGFloat = 0.05
    private let maxZoom: CGFloat = 8.0

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
            TransportBar(forceCompact: isCompact, inTimeline: true)
            Divider().opacity(0.5)
            composer
        }
        .background(TimelineTheme.bar)
        .confirmationDialog("Clear the timeline?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear timeline", role: .destructive) { engine.clearMovieItems() }
            Button("Cancel", role: .cancel) {}
        }
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
        HStack(spacing: isCompact ? 5 : 10) {
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

            addCameraButton
            zoomControl
            trashButton
            if onExpand != nil { expandButton }
            if showsDone { doneButton }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .frame(height: 44)
    }

    // Add a camera keyframe of the current view — a plain accent diamond.
    private var addCameraButton: some View {
        Button(action: { engine.captureCameraItem() }) {
            Image(systemName: "plus.diamond.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.accent)
        .accessibilityLabel("Add a camera keyframe of the current view")
        .help("Add a camera keyframe of the current view to the end")
    }

    // Joined -/+ zoom stepper for the time ruler.
    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { setZoom(zoom / 1.6) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 30).contentShape(Rectangle())
            }
            .disabled(zoom <= minZoom * 1.001)
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18)
            Button { setZoom(zoom * 1.6) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 30).contentShape(Rectangle())
            }
            .disabled(zoom >= maxZoom * 0.999)
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.text)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityLabel("Zoom timeline")
        .help("Zoom the time ruler in / out")
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.easeInOut(duration: 0.15)) {
            zoom = min(max(z, minZoom), maxZoom)
        }
    }

    // Clear the whole timeline (confirmed). Replaces the old overflow menu.
    private var trashButton: some View {
        Button { showClearConfirm = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 15))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(engine.timelineItems.isEmpty ? TimelineTheme.dim : TimelineTheme.text)
        .disabled(engine.timelineItems.isEmpty)
        .help("Clear the timeline")
        .accessibilityLabel("Clear timeline")
    }

    // Open / collapse the full-width bottom dock (compact right-panel view only).
    // Active (accent) while the dock is open (engine.timelineMode).
    private var expandButton: some View {
        let open = engine.timelineMode
        return Button { onExpand?() } label: {
            Image(systemName: open ? "arrow.down.right.and.arrow.up.left"
                                   : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Capsule().fill(open ? TimelineTheme.accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(open ? .white : TimelineTheme.text)
        .help(open ? "Collapse the full editor" : "Expand into a full editor at the bottom")
        .accessibilityLabel(open ? "Collapse timeline editor" : "Expand timeline editor")
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

    // MARK: - The unified lane (fixed-scale, scrollable)

    private var tracksSection: some View {
        HStack(spacing: 0) {
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
                let pps = ppsFor(w)
                let cW = contentWidth(w, pps: pps)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ruler(contentW: cW, pps: pps)
                                itemLane(contentW: cW, pps: pps)
                            }
                            playhead(pps: pps)
                            // Invisible follow-anchor centered on the playhead.
                            Color.clear
                                .frame(width: 1, height: rulerH + laneH)
                                .position(x: xFor(playback.currentFrame, pps: pps), y: (rulerH + laneH) / 2)
                                .id("playhead")
                        }
                        .frame(width: cW, height: rulerH + laneH, alignment: .topLeading)
                        .coordinateSpace(name: laneSpace)
                    }
                    // Bound the scroll view's own height — a horizontal ScrollView is
                    // otherwise vertically greedy and would absorb the panel's slack,
                    // opening gaps above the ruler / below the lane.
                    .frame(height: rulerH + laneH)
                    // Follow the playhead during playback (don't fight manual scroll).
                    .onChange(of: playback.currentFrame) { _ in
                        if playback.isPlaying {
                            withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("playhead", anchor: .center) }
                        }
                    }
                }
            }
            .frame(height: rulerH + laneH)
        }
        // Bound the whole track row — the gutter VStack + divider are otherwise
        // vertically greedy and, in a taller pane, would center the ruler/lane
        // inside an over-tall region (empty bands above/below).
        .frame(height: rulerH + laneH)
    }

    // Tick ruler across the whole (scrollable) content width. Tap to seek.
    private func ruler(contentW: CGFloat, pps: CGFloat) -> some View {
        let step = tickStep(pps: pps)
        let count = max(1, Int((Double(contentW / pps) / step).rounded(.up)))
        return ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.03))
            ForEach(0...count, id: \.self) { i in
                let t = Double(i) * step
                let x = CGFloat(t) * pps
                if x <= contentW + 1 {
                    Rectangle().fill(TimelineTheme.dim.opacity(0.5))
                        .frame(width: 1, height: 5)
                        .position(x: x, y: rulerH - 3)
                    Text(tickLabel(t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TimelineTheme.dim)
                        .fixedSize()
                        .position(x: x + (i == 0 ? 12 : 0), y: rulerH - 14)
                }
            }
        }
        .frame(width: contentW, height: rulerH)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(coordinateSpace: .named(laneSpace))
                .onEnded { e in engine.seek(to: frame(atX: e.location.x, pps: pps)) }
        )
    }

    @ViewBuilder
    private func itemLane(contentW: CGFloat, pps: CGFloat) -> some View {
        let items = laidOut
        ZStack(alignment: .topLeading) {
            Rectangle().fill(TimelineTheme.accent.opacity(0.05))
            if items.isEmpty {
                Text("Tap ◆ to add a camera keyframe, or a scene below")
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .padding(.leading, 10)
                    .frame(height: laneH, alignment: .leading)
            } else {
                ForEach(items.dropFirst()) { laid in
                    connector(laid,
                              prevX: xFor(items[laid.index - 1].frame, pps: pps),
                              curX: xFor(laid.frame, pps: pps))
                }
                ForEach(items) { laid in
                    itemNode(laid, pps: pps)
                }
            }
        }
        .frame(width: contentW, height: laneH)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
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
    private func itemNode(_ laid: Laid, pps: CGFloat) -> some View {
        let dragging = dragItemID == laid.item.id
        let x = dragging ? dragX : xFor(laid.frame, pps: pps)
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
        .position(x: max(x, 7), y: laneH / 2)
        // highPriority so a drag on an item reorders instead of scrolling the lane.
        .highPriorityGesture(reorderDrag(laid, pps: pps))
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
    private func reorderDrag(_ laid: Laid, pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(laneSpace))
            .onChanged { g in
                if dragItemID == nil { dragItemID = laid.item.id }
                dragX = g.location.x
            }
            .onEnded { _ in
                let dropX = dragX
                dragItemID = nil
                let others = engine.itemFrames().enumerated().filter { $0.offset != laid.index }
                let target = others.filter { xFor($0.element, pps: pps) < dropX }.count
                engine.moveItem(from: laid.index, to: target)
            }
    }

    // MARK: - Scene palette (source)

    // Always on screen (even with no saved scenes) so the "drop a scene" affordance
    // is discoverable; shows a hint until scenes exist.
    private var scenePaletteStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack").font(.system(size: 13)).foregroundColor(TimelineTheme.dim)
                if !isCompact {
                    Text("Scenes").font(.system(size: 11)).foregroundColor(TimelineTheme.text)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: labelW)   // match the track gutter (padding INSIDE) so the divider lines align
            .help("Saved scenes — tap to append to the timeline")
            .accessibilityLabel("Saved scenes")

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)

            if engine.sceneNames.isEmpty {
                Text("Store a scene to drop it onto the timeline")
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(engine.sceneNames, id: \.self) { name in
                            paletteChip(name)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                }
            }
        }
        .frame(height: 40)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
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
    //
    // The parameter chips scroll horizontally so their labels never wrap; Append
    // stays pinned on the right.

    private var composer: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
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
                }
                .padding(.vertical, 1)
            }

            Button(action: appendComposer) {
                Label("Append", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
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
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .font(.system(size: 12))
        .fixedSize()
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

    private func playhead(pps: CGFloat) -> some View {
        let x = xFor(playback.currentFrame, pps: pps)
        return ZStack(alignment: .top) {
            Rectangle().fill(TimelineTheme.accent).frame(width: 2)
            Triangle().fill(TimelineTheme.accent).frame(width: 10, height: 7).offset(y: -1)
        }
        .frame(width: 10, height: rulerH + laneH, alignment: .top)
        .position(x: max(x, 1), y: (rulerH + laneH) / 2)
        .allowsHitTesting(false)
    }

    // pixels-per-second: zoom 1 fits ~10 s across the viewport.
    private func ppsFor(_ w: CGFloat) -> CGFloat { max(w, 1) / 10 * zoom }

    private var durationSeconds: Double {
        Double(max(engine.timelineTotalFrames - 1, 0)) / max(playback.movieFPS, 1)
    }

    // Content spans the movie, but never less than the viewport (so a short movie
    // still shows a full ruler); a little end pad keeps the last item off the edge.
    private func contentWidth(_ w: CGFloat, pps: CGFloat) -> CGFloat {
        max(w, CGFloat(durationSeconds) * pps + 24)
    }

    private func xFor(_ frame: Int, pps: CGFloat) -> CGFloat {
        let fps = max(playback.movieFPS, 1)
        return CGFloat(max(frame - 1, 0)) / CGFloat(fps) * pps
    }

    private func frame(atX x: CGFloat, pps: CGFloat) -> Int {
        let fps = max(playback.movieFPS, 1)
        let total = max(playback.frameCount, 1)
        let f = 1 + Int((max(x, 0) / pps * CGFloat(fps)).rounded())
        return min(max(f, 1), total)
    }

    // Tick spacing: smallest "nice" step whose on-screen width is >= ~55pt.
    private func tickStep(pps: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        for c in candidates where CGFloat(c) * pps >= 55 { return c }
        return candidates.last!
    }

    private func tickLabel(_ t: Double) -> String {
        if t < 1 && t > 0 { return String(format: "%.1fs", t) }
        return "\(Int(t))s"
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
