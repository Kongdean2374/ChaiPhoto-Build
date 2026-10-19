import SwiftUI

@main
struct ChaiPhotoApp: App {
    init() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "analysis.enabled")
        if !defaults.bool(forKey: "analysis.retired.v1") {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            DispatchQueue.global(qos: .utility).async {
                do {
                    try RetiredAnalysisMigration.removeCache(in: support)
                    defaults.set(true, forKey: "analysis.retired.v1")
                } catch { /* Retry only this retired cache cleanup on a later launch. */ }
            }
        }
    }

    @StateObject private var settings = AppSettings()
    @StateObject private var library = PhotoLibraryStore()
    @StateObject private var mediaPreloader = MediaPreloader()
    @StateObject private var updateManager = AppUpdateManager()
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            ContentView()
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

