// WhatsNewLogic.swift — pure, Foundation-only data model + version logic for the
// "What's New" splash. Kept free of SwiftUI so it compiles in a standalone
// `swiftc` test (see testing/tests/system/whats_new_logic_test.swift). The
// SwiftUI-facing pieces (ObservableObject, @AppStorage, bundle loading) live in
// WhatsNewModel.swift; the carousel view lives in WhatsNewModal.swift.

import Foundation

/// One page of the carousel: a single feature to showcase.
struct WhatsNewPage: Decodable, Hashable {
    let title: String
    let body: String
    /// Bundled .mp4 resource name (extension optional). When present it takes
    /// precedence over `imageName` and plays muted, looping, aspect-fill.
    let videoName: String?
    /// Asset-catalog image name. Optional — used when there's no `videoName`;
    /// falls back to `systemImage`, then a neutral gradient, so a page always renders.
    let imageName: String?
    /// SF Symbol fallback shown when neither `videoName` nor `imageName` resolves.
    let systemImage: String?

    init(title: String, body: String, imageName: String? = nil,
         videoName: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.body = body
        self.imageName = imageName
        self.videoName = videoName
        self.systemImage = systemImage
    }
}

extension WhatsNewPage {
    /// Shown when the user opens What's New manually but there's no content to
    /// display (empty/malformed catalog).
    static let upToDate = WhatsNewPage(
        title: "You're up to date",
        body: "There's nothing new to show right now.",
        imageName: nil,
        systemImage: "checkmark.seal")
}

/// All the pages introduced in one app release.
struct WhatsNewRelease: Decodable {
    let version: String
    let pages: [WhatsNewPage]
}

/// Pure functions over the bundled catalog. No SwiftUI, no I/O beyond an optional
/// Bundle read — everything here is deterministic and unit-tested.
enum WhatsNewCatalog {

    /// Compare two dotted version strings numerically, component-wise. Missing
    /// components count as 0, so "1.6" == "1.6.0". Non-numeric components read
    /// as 0 (defensive — versions are always numeric here).
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Pages to auto-show: every release strictly newer than `lastSeen` and not
    /// newer than `current` (defensive cap), flattened oldest→newest. Cumulative,
    /// so a user who skipped versions still sees everything they missed.
    ///
    /// Returns [] when `lastSeen` is empty — a fresh install (or an install that
    /// predates this feature) has no baseline, so the caller sets the baseline and
    /// suppresses the auto-show rather than blasting the full history.
    static func pagesToShow(current: String,
                            lastSeen: String,
                            releases: [WhatsNewRelease]) -> [WhatsNewPage] {
        guard !lastSeen.isEmpty else { return [] }
        return releases
            .filter { compareVersions($0.version, lastSeen) == .orderedDescending
                   && compareVersions($0.version, current) != .orderedDescending }
            .sorted { compareVersions($0.version, $1.version) == .orderedAscending }
            .flatMap { $0.pages }
    }

    /// Pages for a manual "What's New" open: the current release's pages. Falls
    /// back to the newest release at or below `current`, then to the newest
    /// release overall. Empty catalog → []. (Manual open ignores `lastSeen`.)
    static func manualPages(current: String,
                            releases: [WhatsNewRelease]) -> [WhatsNewPage] {
        guard !releases.isEmpty else { return [] }
        if let exact = releases.first(where: { compareVersions($0.version, current) == .orderedSame }) {
            return exact.pages
        }
        let atOrBelow = releases
            .filter { compareVersions($0.version, current) != .orderedDescending }
            .sorted { compareVersions($0.version, $1.version) == .orderedDescending }
        if let newestAtOrBelow = atOrBelow.first { return newestAtOrBelow.pages }
        // Everything in the catalog is newer than the running build (unusual):
        // show the newest available so a manual open is never empty.
        return releases
            .sorted { compareVersions($0.version, $1.version) == .orderedDescending }
            .first?.pages ?? []
    }
}
