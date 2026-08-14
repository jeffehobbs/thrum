import SwiftUI

@main
struct ThrumFlowApp: App {
    /// `FlowHost.shared`, not a fresh one: CarPlay connects as a separate UIScene
    /// with its own delegate, outside this hierarchy, and both have to drive the
    /// same engine and the same audio session.
    @StateObject private var host = FlowHost.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FlowView(host: host)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                host.sceneBecameActive()
            case .background, .inactive:
                // Only the drawing stops. The drone is the point of the app and
                // `UIBackgroundModes: audio` exists so it survives the lock
                // screen — this is the opposite of the Mac app's bug, where
                // tearing down on a view disappearing killed the sound with no
                // way back.
                host.sceneWentBackground()
            @unknown default:
                break
            }
        }
    }
}
