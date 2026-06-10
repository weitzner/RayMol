// PyMOLApp.swift — Cross-platform SwiftUI entry point for macOS and iPadOS

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PyMOLApp: App {
    @StateObject private var engine = PyMOLEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
            #if os(macOS)
                // Bring the app/window to the front on launch (a GUI app should
                // foreground itself; also lets it be launched from a terminal).
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
            #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
