import PhonotropicWorkoutWatch
import SwiftUI

/// Thrum on the wrist: the workout that "Music Accompanies Heart Rate" starts
/// when play is pressed on the phone. Mind and Body, with a route, elevation
/// and heart rate; the heart rate goes back to the phone, live, and sets the
/// drone's pulse. Everything but the name, color and icon is the shared
/// Phonotropic watch app (PhonotropicWorkoutWatch).
@main
struct ThrumWatchApp: App {
    @WKApplicationDelegateAdaptor(PhonotropicWorkoutAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            PhonotropicWorkoutView(appearance: WorkoutAppearance(
                name: "Thrum",
                tint: Color(red: 0.98, green: 0.66, blue: 0.29),
                glyph: Image("WorkoutGlyph")))
        }
    }
}
