// WhatsNewModal.swift — the paginated "What's New" carousel and the presenter
// modifier that hosts it. One feature per page (hero image + title + body), with
// Back / Next + tappable dots (index-based, so it works identically on macOS and
// iOS — SwiftUI's `.page` TabView style is iOS-only). Swipe is added on iOS.
//
// Presentation, version gating, and content loading live in WhatsNewModel.swift;
// the pure logic lives in WhatsNewLogic.swift.

import SwiftUI
import AVKit

// The presenter (auto-show trigger, manual-open notification, and the `.sheet`
// itself) is inlined into ContentView.body so it uses ContentView's own
// @StateObject binding — the same shape as the other working sheets. A
// ViewModifier that owned the sheet via a separate @ObservedObject didn't
// present reliably under XCUITest.

// MARK: - Carousel

struct WhatsNewModal: View {
    let pages: [WhatsNewPage]
    /// e.g. "1.6.0" — shown as the "New in RayMol …" eyebrow.
    let versionLabel: String
    let onFinish: () -> Void

    @State private var index = 0

    private var safePages: [WhatsNewPage] { pages.isEmpty ? [.upToDate] : pages }
    private var isLast: Bool { index >= safePages.count - 1 }

    #if os(macOS)
    private let heroHeight: CGFloat = 238   // 25% larger than the prior 190
    #else
    private let heroHeight: CGFloat = 220   // 25% larger than the prior 176
    #endif

    var body: some View {
        VStack(spacing: 0) {
            page(safePages[min(index, safePages.count - 1)])
                .id(index)   // fresh identity per page → cross-fade on change
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            footer
        }
        .frame(maxWidth: .infinity)
        .background(background)
        .overlay(alignment: .topTrailing) { closeButton }
        #if os(macOS)
        .frame(width: 420, height: 392)   // hug content (removes the dead vertical span) w/ the taller hero
        #else
        // Standard detents (not a custom .height) — custom-height detents aren't
        // reliably traversable by XCUITest on newer iOS. Opens at medium.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Horizontal swipe to page (iOS only; macOS uses the buttons).
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    if v.translation.width < -40, !isLast {
                        withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
                    } else if v.translation.width > 40, index > 0 {
                        withAnimation(.easeInOut(duration: 0.25)) { index -= 1 }
                    }
                }
        )
        #endif
        // NOTE: do NOT put an .accessibilityIdentifier on this container — SwiftUI
        // propagates a container identifier to every descendant, which would
        // shadow the per-button ids (whatsNewPrimary / whatsNewClose) the tests
        // rely on.
    }

    // A single carousel page: hero on top, title + body beneath.
    @ViewBuilder
    private func page(_ p: WhatsNewPage) -> some View {
        VStack(spacing: 0) {
            hero(p)
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topLeading) {
                    Text("New in RayMol \(versionLabel)")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(14)
                }

            VStack(spacing: 10) {
                Text(p.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(p.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // Hero: bundled video if present, else a bundled image, else an SF Symbol on a
    // gradient, else just the gradient. Always renders — a page never fails for
    // want of media.
    @ViewBuilder
    private func hero(_ p: WhatsNewPage) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.23, green: 0.36, blue: 0.56),
                         Color(red: 0.06, green: 0.09, blue: 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            if let videoURL = Self.loadedVideoURL(p.videoName) {
                LoopingVideoView(url: videoURL)
            } else if let img = Self.loadedImage(p.imageName) {
                img.resizable().scaledToFill()
            } else if let symbol = p.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") {
                withAnimation(.easeInOut(duration: 0.25)) { index -= 1 }
            }
            .buttonStyle(.borderless)
            .opacity(index > 0 ? 1 : 0)
            .disabled(index == 0)
            .accessibilityHidden(index == 0)

            Spacer(minLength: 4)

            if safePages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<safePages.count, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == index ? 18 : 7, height: 7)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) { index = i }
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: index)
            }

            Spacer(minLength: 4)

            Button(isLast ? "Get Started" : "Next") {
                if isLast {
                    onFinish()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("whatsNewPrimary")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var closeButton: some View {
        Button(action: onFinish) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7), .black.opacity(0.25))
                .padding(10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("whatsNewClose")
    }

    private var background: some View {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Resolve a hero image by name. Prefers an asset-catalog image set; falls back
    /// to a bundled image FILE (png/jpg/jpeg/heic in the app bundle) so media can be
    /// dropped into Resources/ the same way videos are. Returns nil when neither
    /// resolves, so the caller can fall back to a symbol/gradient.
    static func loadedImage(_ name: String?) -> Image? {
        guard let name, !name.isEmpty else { return nil }
        let stem = (name as NSString).deletingPathExtension
        // 1) Asset catalog (asset names carry no extension). Build the SwiftUI
        // Image from the resolved platform image rather than Image(name:): on
        // iOS `UIImage(named:)` also finds LOOSE bundle files, so returning
        // Image(name:) — which only searches the asset catalog — would render a
        // blank hero for a Resources/ file. Image(uiImage:)/Image(nsImage:)
        // works for both an asset set and a loose file.
        #if os(macOS)
        if let img = NSImage(named: stem) { return Image(nsImage: img) }
        #else
        if let img = UIImage(named: stem) { return Image(uiImage: img) }
        #endif
        // 2) Bundled image file (with or without an explicit extension).
        let givenExt = (name as NSString).pathExtension
        let exts = givenExt.isEmpty ? ["png", "jpg", "jpeg", "heic"] : [givenExt]
        for ext in exts {
            guard let url = Bundle.main.url(forResource: stem, withExtension: ext) else { continue }
            #if os(macOS)
            if let img = NSImage(contentsOf: url) { return Image(nsImage: img) }
            #else
            if let img = UIImage(contentsOfFile: url.path) { return Image(uiImage: img) }
            #endif
        }
        return nil
    }

    /// Resolve a bundled .mp4 by name (with or without the extension), returning
    /// nil when it's absent so the caller can fall back to image/symbol/gradient.
    static func loadedVideoURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let extn = (name as NSString).pathExtension.isEmpty ? "mp4" : (name as NSString).pathExtension
        return Bundle.main.url(forResource: stem, withExtension: extn)
    }
}

// MARK: - Looping video hero

/// A muted, looping, aspect-fill video with no transport controls, backed by an
/// AVPlayerLayer. Autoplays on appear and pauses/cleans up when its page leaves
/// the carousel (each page has a distinct `.id`, so paging tears the old one
/// down). Cross-platform (UIView on iOS, NSView on macOS).
struct LoopingVideoView {
    let url: URL

    final class Coordinator {
        let player: AVPlayer
        private var endObserver: NSObjectProtocol?
        init(url: URL) {
            player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem, queue: .main) { [weak player] _ in
                    player?.seek(to: .zero)
                    player?.play()
                }
        }
        func play() { player.play() }
        func pause() { player.pause() }
        deinit { if let o = endObserver { NotificationCenter.default.removeObserver(o) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
}

#if os(iOS)
extension LoopingVideoView: UIViewRepresentable {
    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = context.coordinator.player
        v.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.play()
        return v
    }
    func updateUIView(_ uiView: PlayerHostView, context: Context) {}
    static func dismantleUIView(_ uiView: PlayerHostView, coordinator: Coordinator) {
        coordinator.pause()
    }
}
#else
extension LoopingVideoView: NSViewRepresentable {
    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.frame = bounds
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() { super.layout(); playerLayer.frame = bounds }
    }
    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = context.coordinator.player
        context.coordinator.play()
        return v
    }
    func updateNSView(_ nsView: PlayerHostView, context: Context) {}
    static func dismantleNSView(_ nsView: PlayerHostView, coordinator: Coordinator) {
        coordinator.pause()
    }
}
#endif
