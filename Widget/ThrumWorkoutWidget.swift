import AppIntents
import PhonotropicWorkoutActivity
import SwiftUI
import WidgetKit

/// The workout on the lock screen and in the Dynamic Island. All of it is the
/// shared Phonotropic Live Activity; this extension contributes the icon
/// (`WorkoutGlyph` in its asset catalog).
@main
struct ThrumWorkoutWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}

/// So the extension knows the stop button's intent.
struct ThrumWorkoutWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [PhonotropicWorkoutIntents.self] }
}
