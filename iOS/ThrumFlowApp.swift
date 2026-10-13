import AppIntents
import PhonotropicWorkout
import PhonotropicWorkoutActivity
import SwiftUI

@main
struct ThrumFlowApp: App {
    @UIApplicationDelegateAdaptor(ThrumFlowAppDelegate.self) private var appDelegate
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

final class ThrumFlowAppDelegate: NSObject, UIApplicationDelegate {
    /// Up front, not on first view: when the watch starts a workout the system
    /// may launch this app in the background, with no window, just to hand it
    /// over — and the handler that receives it lives in `FlowHost.workout`.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { _ = FlowHost.shared }
        return true
    }

    /// The watch app asking for Health access is answered here, on the phone.
    func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {
        WorkoutLink.handleWatchAuthorizationRequest()
    }
}

/// The workout's stop intent (the Live Activity's button) lives in the
/// PhonotropicWorkout package; this is how the app picks it up.
struct ThrumWorkoutIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [PhonotropicWorkoutIntents.self] }
}
