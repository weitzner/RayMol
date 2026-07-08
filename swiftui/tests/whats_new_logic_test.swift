// whats_new_logic_test.swift — standalone unit test for the pure What's New
// version logic. Compiled together with the real source, so it tests the
// shipping code (no duplicated logic):
//
//   swiftc PyMOLViewer/Shared/WhatsNewLogic.swift tests/whats_new_logic_test.swift \
//          -o /tmp/wn_test && /tmp/wn_test
//
// (or just run tests/run_whats_new_logic_test.sh)

import Foundation

@main
struct WhatsNewLogicTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok: \(msg)") }
        else { print("  FAIL: \(msg)"); failures += 1 }
    }

    static func main() {
        // Sample catalog spanning three releases.
        let releases = [
            WhatsNewRelease(version: "1.4.0", pages: [
                WhatsNewPage(title: "1.4-a", body: "x"),
            ]),
            WhatsNewRelease(version: "1.5.0", pages: [
                WhatsNewPage(title: "1.5-a", body: "x"),
                WhatsNewPage(title: "1.5-b", body: "x"),
            ]),
            WhatsNewRelease(version: "1.6.0", pages: [
                WhatsNewPage(title: "1.6-a", body: "x"),
            ]),
        ]

        print("compareVersions:")
        check(WhatsNewCatalog.compareVersions("1.6.0", "1.5.2") == .orderedDescending, "1.6.0 > 1.5.2")
        check(WhatsNewCatalog.compareVersions("1.5.2", "1.6.0") == .orderedAscending, "1.5.2 < 1.6.0")
        check(WhatsNewCatalog.compareVersions("1.6", "1.6.0") == .orderedSame, "1.6 == 1.6.0 (padding)")
        check(WhatsNewCatalog.compareVersions("1.10.0", "1.9.0") == .orderedDescending, "1.10 > 1.9 (numeric, not lexical)")
        check(WhatsNewCatalog.compareVersions("2.0", "1.9.9") == .orderedDescending, "2.0 > 1.9.9")

        print("pagesToShow — cumulative across skipped versions:")
        let jump = WhatsNewCatalog.pagesToShow(current: "1.6.0", lastSeen: "1.4.0", releases: releases)
        check(jump.map { $0.title } == ["1.5-a", "1.5-b", "1.6-a"],
              "1.4 → 1.6 shows 1.5 + 1.6 pages, oldest→newest")

        print("pagesToShow — single-step update:")
        let step = WhatsNewCatalog.pagesToShow(current: "1.6.0", lastSeen: "1.5.0", releases: releases)
        check(step.map { $0.title } == ["1.6-a"], "1.5 → 1.6 shows only 1.6")

        print("pagesToShow — nothing newer:")
        let none = WhatsNewCatalog.pagesToShow(current: "1.6.0", lastSeen: "1.6.0", releases: releases)
        check(none.isEmpty, "already on latest → no pages")

        print("pagesToShow — fresh install (empty lastSeen):")
        let fresh = WhatsNewCatalog.pagesToShow(current: "1.6.0", lastSeen: "", releases: releases)
        check(fresh.isEmpty, "empty baseline → no auto-show")

        print("pagesToShow — downgrade:")
        let down = WhatsNewCatalog.pagesToShow(current: "1.4.0", lastSeen: "1.6.0", releases: releases)
        check(down.isEmpty, "lastSeen newer than current → no pages")

        print("pagesToShow — defensive cap at current:")
        let capped = WhatsNewCatalog.pagesToShow(current: "1.5.0", lastSeen: "1.4.0", releases: releases)
        check(capped.map { $0.title } == ["1.5-a", "1.5-b"], "future 1.6 pages not shown when running 1.5")

        print("manualPages — exact match:")
        check(WhatsNewCatalog.manualPages(current: "1.5.0", releases: releases).map { $0.title } == ["1.5-a", "1.5-b"],
              "manual open on 1.5 shows 1.5 pages")

        print("manualPages — no exact match, newest at-or-below:")
        check(WhatsNewCatalog.manualPages(current: "1.5.5", releases: releases).map { $0.title } == ["1.5-a", "1.5-b"],
              "manual open on 1.5.5 falls back to 1.5")

        print("manualPages — empty catalog:")
        check(WhatsNewCatalog.manualPages(current: "1.6.0", releases: []).isEmpty, "empty catalog → []")

        print("")
        if failures == 0 {
            print("ALL PASSED")
        } else {
            print("\(failures) FAILURE(S)")
            exit(1)
        }
    }
}
