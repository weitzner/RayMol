// WhatsNewModel.swift — SwiftUI-facing controller for the "What's New" splash.
// Owns presentation state, persists the last-seen version, and loads the bundled
// catalog. The pure version logic it calls lives in WhatsNewLogic.swift; the
// carousel view + presenter modifier live in WhatsNewModal.swift.

import SwiftUI

@MainActor
final class WhatsNewModel: ObservableObject {
    /// Drives the `.sheet`. Set true to show the modal, false to dismiss.
    @Published var isPresented = false
    /// The pages currently being shown (auto-show set vs. manual set).
    @Published private(set) var pages: [WhatsNewPage] = []

    let releases: [WhatsNewRelease]
    let currentVersion: String

    private var didRunAutoCheck = false
    private let lastSeenKey = "whatsNewLastSeenVersion"
    private var lastSeenVersion: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    init(releases: [WhatsNewRelease]? = nil, currentVersion: String? = nil) {
        self.releases = releases ?? WhatsNewModel.loadBundledReleases()
        self.currentVersion = currentVersion ?? WhatsNewModel.appVersion()
    }

    /// Auto-show pass, run once per launch from the presenter's `onAppear`.
    /// Shows the modal when there's content newer than the last-seen version;
    /// otherwise just advances the baseline so it won't re-check every launch.
    func presentAutoIfNeeded() {
        guard !didRunAutoCheck else { return }
        didRunAutoCheck = true

        // Test/headless suppression (mirrors PYMOL_SKIP_GESTURE_HELP). Still
        // baseline the version so it can't fire on a later, un-suppressed launch.
        if ProcessInfo.processInfo.environment["PYMOL_SKIP_WHATS_NEW"] != nil {
            baselineToCurrent(); return
        }
        // Fresh install, or an install that predates this feature: no baseline to
        // compare against, so set it and don't show (we can't know what they last
        // saw, and blasting the full history would be worse). Auto-show begins
        // working from the next release onward.
        guard !lastSeenVersion.isEmpty else { baselineToCurrent(); return }

        let toShow = WhatsNewCatalog.pagesToShow(current: currentVersion,
                                                 lastSeen: lastSeenVersion,
                                                 releases: releases)
        guard !toShow.isEmpty else { baselineToCurrent(); return }
        pages = toShow
        isPresented = true
    }

    /// Manual open (app menu / Settings). Ignores the last-seen version and shows
    /// the current release's pages, or an "up to date" card if there's none.
    func presentManually() {
        let p = WhatsNewCatalog.manualPages(current: currentVersion, releases: releases)
        pages = p.isEmpty ? [.upToDate] : p
        isPresented = true
    }

    /// Called from the sheet's `onDismiss` (covers ✕, "Get Started", and swipe).
    func didDismiss() { baselineToCurrent() }

    /// Advance the baseline to the running version if it's behind (never rewind).
    private func baselineToCurrent() {
        if lastSeenVersion.isEmpty
            || WhatsNewCatalog.compareVersions(currentVersion, lastSeenVersion) == .orderedDescending {
            lastSeenVersion = currentVersion
        }
    }

    // MARK: - Bundled content

    static func loadBundledReleases() -> [WhatsNewRelease] {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let releases = try? JSONDecoder().decode([WhatsNewRelease].self, from: data)
        else { return [] }
        return releases
    }

    static func appVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}
