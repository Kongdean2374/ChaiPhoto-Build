import SwiftUI

@main
struct ChaiPhotoApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var library = PhotoLibraryStore()
    @StateObject private var mediaPreloader = MediaPreloader()
    @StateObject private var analysis = MediaAnalysis()
    @StateObject private var updateManager = AppUpdateManager()
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AnalysisLifecycle())
                .environmentObject(analysis)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(mediaPreloader)
                .environmentObject(updateManager)
                .preferredColorScheme(settings.colorScheme)
                .dynamicTypeSize(settings.textSize == "system" ? systemTextSize : settings.textSize == "large" ? .xLarge : settings.textSize == "extra" ? .xxxLarge : .large)
                .environment(\.locale, Locale(identifier: settings.language))
                .task { settings.startResourceMonitoring(); await library.requestCurrentStatus() }
                .onChange(of: scenePhase) { _, value in
                    if value == .active && wasInBackground {
                        wasInBackground = false
                        Task { await library.requestCurrentStatus() }
                    } else if value == .background {
                        wasInBackground = true
                        mediaPreloader.clear()
                        Task {
                            let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save sorting progress", expirationHandler: nil)
                            await library.flushPendingWrites()
                            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
                        }
                    }
                }
        }
    }
}

