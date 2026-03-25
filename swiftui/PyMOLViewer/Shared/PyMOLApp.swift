// PyMOLApp.swift — Cross-platform SwiftUI entry point for macOS and iPadOS

import SwiftUI

@main
struct PyMOLApp: App {
    @StateObject private var engine = PyMOLEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
