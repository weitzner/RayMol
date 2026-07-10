// TransportBar.swift — the unified Timeline transport for states, NMR models,
// trajectory frames and movie frames (all one cmd.frame index in PyMOL).
//
// Familiar desktop VCR transport (|< < play/pause > >|) + a scrubber bound to
// the core frame, a frame counter, a loop toggle, and an overflow menu (FPS,
// show frame rate, Make Movie…, Export Movie…). Playback is core-driven
// (engine.play()/pause() → cmd.mplay/mstop, advanced by the renderer idle tick);
// the bar only scrubs and reflects state. Auto-hidden when there is nothing to
// play (frameCount <= 1) — the caller gates that.
//
// Adaptive: one row on macOS / regular-width iPad; a 1-line "peek" that expands
// to a multi-row control on compact-width iPhone.

import SwiftUI

enum TimelineTheme {
    // Accent for transport / movie / scene controls — follows the ACTIVE THEME's
    // accent (so Build & Play, scene icons, chips, etc. match the rest of the app)
    // rather than a fixed teal. Mirrors SequencePanel's `ThemeManager.shared.active`
    // read. Views that should recolor live on a theme switch already observe
    // ThemeManager; others pick it up on their next render.
    static var accent: Color { ThemeManager.shared.active.accent.color }
    // Timeline / transport surface — follows the ACTIVE THEME's panel background
    // (like the Objects panel) so the Movie tab and docked timeline chrome match
    // the rest of the inspector rather than a fixed dark gray. Kept slightly
    // translucent (0.96) since the docked timeline floats over the viewport.
    static var bar: Color { ThemeManager.shared.active.panelBackground.color.opacity(0.96) }
    // Foreground text / dimmed labels FOLLOW the active theme's panel text color
    // (like the rest of the inspector) instead of a fixed near-white — otherwise
    // ruler ticks, the header, row labels, the counter and scene chips wash out on
    // a light theme (issue #133). `dim` is the same hue at reduced opacity so it
    // stays legible on both light and dark palettes.
    static var text: Color { ThemeManager.shared.active.panelText.color }
    static var dim: Color { ThemeManager.shared.active.panelText.color.opacity(0.6) }
    // Subtle fill for neutral chips / hairline separators, derived from the text
    // color so it contrasts against the panel background on any theme.
    static var subtleFill: Color { ThemeManager.shared.active.panelText.color.opacity(0.12) }
}

// Transport control sizing. The transport is embedded in the timeline, which on
// macOS lives in the narrow (~340pt) right inspector. macOS is pointer-driven and
// its native controls render denser, so it uses smaller buttons + tighter spacing
// so the single compact row (cluster + loop + fps + counter) fits 340 without
// clipping. iOS keeps larger touch targets (iPhone/iPad transports are unchanged).
#if os(iOS)
private let kTBtnW: CGFloat = 40
private let kTPlayW: CGFloat = 44
private let kTBtnH: CGFloat = 36
private let kTRowSpacing: CGFloat = 6
private let kTRowHPad: CGFloat = 12
#else
private let kTBtnW: CGFloat = 30
private let kTPlayW: CGFloat = 34
private let kTBtnH: CGFloat = 30
private let kTRowSpacing: CGFloat = 4
private let kTRowHPad: CGFloat = 8
#endif

struct TransportBar: View {
    @EnvironmentObject var engine: PyMOLEngine
    // Observe the isolated playback object so frame ticks re-render ONLY this
    // bar (not the inspector/menus, which observe `engine`).
    @EnvironmentObject var playback: PlaybackState

    /// iPhone collapsed state: render the 1-line peek instead of the full bar.
    var compactPeek: Bool = false
    /// Called when the user taps the expand/collapse chevron (iPhone only).
    var onToggleExpand: (() -> Void)? = nil
    /// Force the narrow (compact) layout regardless of size class — used when the
    /// bar is embedded in a narrow column (the macOS/iPad right-inspector timeline)
    /// where the wide `regularRow` would overflow.
    var forceCompact: Bool = false
    /// True when embedded in a TimelinePanel: the ruler is the scrubber, so this
    /// bar always uses the clean timeline layout (no redundant slider, no
    /// Make/Export — those live in the top Export menu), regardless of whether the
    /// bottom dock (engine.timelineMode) is open.
    var inTimeline: Bool = false
    /// When set (movie/timeline transport), the counter + scrubber reflect the
    /// AUTHORED movie length instead of the core frame count — so the movie
    /// transport stays decoupled from multi-state model inspection.
    var movieFrames: Int? = nil

    @State private var showBuilder = false
    @State private var showExport = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { forceCompact || hSize == .compact }
    #else
    private var isCompact: Bool { forceCompact }
    #endif

    var body: some View {
        Group {
            if compactPeek {
                peekRow
            } else if isCompact {
                compactFull
            } else {
                regularRow
            }
        }
        .background(TimelineTheme.bar)
        .sheet(isPresented: $showBuilder) { MovieBuilderSheet() }
        .sheet(isPresented: $showExport) { MovieExportSheet() }
    }

    // MARK: - Layouts

    // macOS / regular-width iPad: everything on one line.
    private var regularRow: some View {
        HStack(spacing: 10) {
            transportCluster
            // In a timeline the ruler scrubs, so the slider is redundant here.
            if !inTimeline { scrubber }
            counter
            loopButton
            // In a timeline the frame rate lives inline on the transport row and
            // Export moved to the panel's top bar, so the ⋯ overflow menu is gone
            // (issue #142). The standalone (iPad floating) transport keeps it.
            if inTimeline {
                fpsMenu
            } else {
                overflowMenu
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // iPhone expanded. Two shapes:
    //  • Timeline mode: the ruler IS the scrubber, so everything — transport, loop,
    //    fps, counter — packs onto ONE row (Make/Export live in the top toolbar's
    //    Export menu).
    //  • Otherwise: cluster+counter row, a scrubber, and a loop/fps + Make/Export row.
    private var compactFull: some View {
        Group {
            if inTimeline {
                HStack(spacing: kTRowSpacing) {
                    transportCluster
                    Spacer(minLength: 4)
                    loopButton
                    fpsMenuTight
                    counter
                }
                .tint(TimelineTheme.accent)
                .padding(.horizontal, kTRowHPad).padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    HStack {
                        transportCluster
                        Spacer(minLength: 0)
                        counter
                        if let toggle = onToggleExpand {
                            iconButton("chevron.down", size: 16, action: toggle)
                                .accessibilityLabel("Collapse transport")
                        }
                    }
                    scrubber
                    HStack(spacing: 16) {
                        loopButton
                        fpsMenu
                        Spacer(minLength: 0)
                        Button { showBuilder = true } label: {
                            Label("Make", systemImage: "wand.and.stars").font(.system(size: 12))
                        }
                        Button { showExport = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 12))
                        }
                    }
                    .tint(TimelineTheme.accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    // iPhone collapsed peek: scrub + play in one line, plus an expand chevron.
    private var peekRow: some View {
        HStack(spacing: 10) {
            playPauseButton(size: 20)
            scrubber
            counter
            iconButton("chevron.up", size: 16) { onToggleExpand?() }
                .accessibilityLabel("Expand transport")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    // MARK: - Pieces

    private var transportCluster: some View {
        HStack(spacing: 2) {
            iconButton("backward.end.fill", size: 15) { engine.rewindMovie() }
                .accessibilityLabel("Rewind to start").help("Rewind to start")
            iconButton("backward.fill", size: 15) { engine.stepBackward() }
                .accessibilityLabel("Step back").help("Step back one frame")
            playPauseButton(size: 20)
            iconButton("forward.fill", size: 15) { engine.stepForward() }
                .accessibilityLabel("Step forward").help("Step forward one frame")
            iconButton("forward.end.fill", size: 15) { engine.endingMovie() }
                .accessibilityLabel("Go to end").help("Jump to end")
        }
    }

    private func playPauseButton(size: CGFloat) -> some View {
        Button(action: { engine.togglePlay() }) {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(TimelineTheme.accent)
                .frame(width: kTPlayW, height: kTBtnH)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        .help(playback.isPlaying ? "Pause" : "Play")
    }

    // Total frames shown/scrubbed: the authored movie length when provided
    // (timeline transport), else the core frame count.
    private var totalFrames: Int { max(movieFrames ?? playback.frameCount, 1) }
    private var shownFrame: Int { min(max(playback.currentFrame, 1), totalFrames) }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { Double(shownFrame) },
                set: { engine.scrub(to: Int($0.rounded())) }
            ),
            in: 1...Double(max(totalFrames, 2)),
            step: 1,
            onEditingChanged: { editing in if !editing { engine.endScrub() } }
        )
        .tint(TimelineTheme.accent)
        .frame(minWidth: 80)
    }

    private var counter: some View {
        // Reserve width for the movie's max digit count ("NNN / NNN") so the
        // current frame number growing (1 → N digits) never shifts neighbors.
        let digits = String(totalFrames).count
        return Text("\(shownFrame) / \(totalFrames)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(TimelineTheme.text)
            .lineLimit(1)
            .frame(minWidth: CGFloat(digits * 2 + 3) * 7.4, alignment: .trailing)
    }

    private var loopButton: some View {
        Button(action: { engine.setMovieLoop(!playback.movieLoop) }) {
            Image(systemName: "repeat")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(playback.movieLoop ? TimelineTheme.accent : TimelineTheme.dim)
                .frame(width: kTBtnW, height: kTBtnH)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.movieLoop ? "Looping on" : "Looping off")
        .help(playback.movieLoop ? "Looping on — tap to turn off" : "Loop the movie")
    }

    // Shared frame-rate picker + the "Show frame rate" HUD toggle. Folded into
    // every fps control so both actions stay reachable now that the ⋯ overflow
    // menu is gone (issue #142).
    @ViewBuilder private var fpsMenuContent: some View {
        Picker("Frame rate", selection: Binding(
            get: { playback.movieFPS },
            set: { engine.setMovieFPS($0) })) {
            Text("30 fps").tag(30.0)
            Text("15 fps").tag(15.0)
            Text("5 fps").tag(5.0)
            Text("1 fps").tag(1.0)
            Text("0.3 fps").tag(0.3)
        }
        Divider()
        Button { engine.setShowFrameRate(true) } label: {
            Label("Show frame rate", systemImage: "speedometer")
        }
    }

    private var fpsMenu: some View {
        Menu {
            fpsMenuContent
        } label: {
            Label("\(fpsLabel) fps", systemImage: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12))
        }
        .tint(TimelineTheme.accent)
        .help("Playback frame rate")
    }

    // Slim fps control for the packed timeline row (no gauge icon, "30fps").
    private var fpsMenuTight: some View {
        Menu {
            fpsMenuContent
        } label: {
            Text(fpsTightLabel)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(TimelineTheme.accent)
                .frame(height: kTBtnH)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // Chrome-free so the native pull-down border doesn't widen the narrow row.
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .help("Playback frame rate")
    }

    // The narrow row shows just the number on macOS ("30") to save width; iOS,
    // with room to spare, keeps the clearer "30 fps".
    private var fpsTightLabel: String {
        #if os(macOS)
        return fpsLabel
        #else
        return "\(fpsLabel) fps"
        #endif
    }

    private var overflowMenu: some View {
        Menu {
            Picker("Frame rate", selection: Binding(
                get: { playback.movieFPS },
                set: { engine.setMovieFPS($0) })) {
                Text("30 fps").tag(30.0)
                Text("15 fps").tag(15.0)
                Text("5 fps").tag(5.0)
                Text("1 fps").tag(1.0)
                Text("0.3 fps").tag(0.3)
            }
            Button { engine.setShowFrameRate(true) } label: {
                Label("Show frame rate", systemImage: "speedometer")
            }
            Divider()
            Button { showBuilder = true } label: {
                Label("Make Movie…", systemImage: "wand.and.stars")
            }
            Button { showExport = true } label: {
                Label("Export Movie…", systemImage: "square.and.arrow.up")
            }
            // Accelerator into the full timeline editor (proposal B). Hidden while
            // already in timeline mode (this bar is embedded there).
            if !engine.timelineMode {
                Divider()
                Button { withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = true } } label: {
                    Label("Edit in Timeline", systemImage: "clapperboard")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundColor(TimelineTheme.text)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
    }

    private var fpsLabel: String {
        let f = playback.movieFPS
        return f == f.rounded() ? String(Int(f)) : String(format: "%.1f", f)
    }

    private func iconButton(_ systemName: String, size: CGFloat,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(TimelineTheme.text)
                .frame(width: kTBtnW, height: kTBtnH)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
