import SwiftUI
import PhonotropicWorkout

/// The gear, and everything behind it.
///
/// Thrum Flow has three controls on its own screen — start, stop, and two thumbs
/// — because the premise is that Flow decides and the listener listens. That
/// premise holds for anything the app can work out for itself, and it stops
/// holding at the two questions here: whether the tempo should come from the
/// listener's body, and whether the drone should stay put in the room when they
/// turn their head. Neither is knowable from the outside, both change the app
/// materially, and both touch a sensor a listener may simply not want read.
///
/// So they are preferences rather than gestures — set once, on purpose, out of
/// the way — which is why this is a sheet and not another glyph on the field.
///
/// Styled in the black-and-monospace idiom Plasma's settings screen uses, rather
/// than a stock system `Form`: this is a place to read carefully, and the
/// black-and-line-art language of the field is built for the opposite of that.
struct SettingsView: View {
    @ObservedObject var host: FlowHost
    /// Nested `ObservableObject`s are not observed through their parent — the same
    /// thing `FlowView` documents at length. The status line below is the only way
    /// to find out that Motion access was refused, so a copy that never updates
    /// would be worse than no line at all.
    @ObservedObject var head: HeadTracker
    /// Here for the tempo readout, which is the one number on this screen that
    /// moves while it is open — the heart rate rewrites it every second.
    @ObservedObject var model: ThrumModel
    @ObservedObject var route: AudioRoute
    @ObservedObject var workout: WorkoutLink
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(hue: 0.09, saturation: 0.7, brightness: 0.98)

    init(host: FlowHost) {
        self.host = host
        self.head = host.model.head
        self.model = host.model
        self.route = host.model.route
        self.workout = host.workout
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        tempoSection
                            .padding(.top, 24)

                        spatialSection
                            .padding(.top, 28)

                        aboutSection
                            .padding(.top, 28)

                        creditsView
                            .padding(.top, 40)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .preferredColorScheme(.dark)
        // Turning heart rate on asks first: is there a watch, is a workout
        // all right.
        .workoutSetupAlerts(workout)
        .task { await workout.checkSavedWorkouts() }
    }

    /// What the workout is filed as in Health. Locked while one is running:
    /// it applies from the next start.
    private var activityRow: some View {
        HStack {
            Text("ACTIVITY")
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(1)
            Spacer()
            Picker("Activity", selection: Binding(get: { workout.activity }, set: { workout.activity = $0 })) {
                ForEach(PhonotropicActivity.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .tint(.white.opacity(0.6))
            .disabled(workout.isWorkoutActive)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Tempo

    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("TEMPO")

            VStack(spacing: 1) {
                Toggle(isOn: $host.followsPulse) {
                    Text(WorkoutLink.title.uppercased())
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .kerning(1)
                }
                .tint(accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05))

                // The slider stays with the switch on: it's the tempo before the
                // first reading, and whenever the watch isn't in play. While a
                // heart rate is setting the tempo it's grayed out.
                tempoSlider
                    .disabled(host.isFollowingHeartRate)
                    .opacity(host.isFollowingHeartRate ? 0.4 : 1)

                if host.followsPulse {
                    activityRow
                    statRow(label: "TEMPO", value: "\(Int(model.tempo.rounded())) BPM")
                    statRow(label: "SOURCE", value: host.tempoSource)
                    statRow(label: "WORKOUT", value: workoutStatus)
                    if let route = workout.routeStatus {
                        statRow(label: "ROUTE", value: route)
                    }
                    ForEach(Array(workout.savedWorkouts.enumerated()), id: \.offset) { i, line in
                        statRow(label: i == 0 ? "IN HEALTH" : "", value: line)
                    }
                    if let problem = workout.problem {
                        permissionRow(problem)
                    }
                    if workout.isWorkoutActive {
                        Button(role: .destructive) {
                            workout.endWorkout()
                        } label: {
                            Text("END WORKOUT")
                                .font(.system(.caption2, design: .monospaced).weight(.medium))
                                .kerning(1)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.05))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Text(host.followsPulse
                 ? "Play starts a workout on your Apple Watch, and the arpeggios beat at your heart rate, folded into a drone's range. Stop ends the workout and saves it to Health."
                 : "The tempo is yours: set it with the slider and it stays there.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
    }

    // MARK: - Spatial

    private var spatialSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("SPATIAL")

            VStack(spacing: 1) {
                Toggle(isOn: $host.headTrackingEnabled) {
                    Text("HEAD TRACKING")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .kerning(1)
                }
                .tint(accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05))

                statRow(label: "OUTPUT", value: route.name.isEmpty ? "—" : route.name)
                statRow(label: "FIELD", value: fieldState)

                if head.status == .denied {
                    permissionRow("Motion access is off — the field stays welded to your ears.")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Text(host.headTrackingEnabled
                 ? "With headphones on, the drone is placed around you and stays where it is when you turn your head — which is the cue that makes it sit in the room rather than in your ears. Turn Spatial Audio off in the AirPods controls; two spatialisers fight. On speakers there is nothing to track and nothing is read."
                 : "The field is welded to your head: still sixteen positions around you, but they turn when you do. Nothing reads the motion sensor.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
    }

    /// What the spatial field is actually doing right now, which is a different
    /// question from what the switch says — a switch that is on while the phone is
    /// playing through its own speaker is not tracking anything, and saying so here
    /// is what stops that reading as a broken feature.
    private var fieldState: String {
        if route.isRoom { return "stereo — speakers" }
        guard host.headTrackingEnabled else { return "head-locked" }
        switch head.status {
        case .tracking:    return "head-tracked"
        case .denied:      return "head-locked — no Motion access"
        case .unsupported: return "head-locked — these headphones don't report motion"
        case .needsPermission, .idle: return host.running ? "starting" : "idle"
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("ABOUT")

            VStack(spacing: 1) {
                statRow(label: "VERSION", value: version)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Text("Nothing here leaves the phone. No account, no analytics, no network code in the app at all.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: - Credits

    private var creditsView: some View {
        VStack(spacing: 5) {
            Text("Designed by Jeff Hobbs")
            Text("2026 Phonotropic Music Company")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.18))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bits

    /// A refusal the listener can act on, rather than a refusal reported at them.
    /// Both of the permissions on this screen are revocable in Settings and neither
    /// can be asked for twice, so a line that only says "off" is a dead end.
    private func permissionRow(_ message: String) -> some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced).weight(.medium))
            .foregroundStyle(.white.opacity(0.3))
            .kerning(1.5)
            .padding(.horizontal, 28)
            .padding(.bottom, 4)
    }

    /// The tempo without a heart rate. Same range and default in every
    /// Phonotropic app.
    private var tempoSlider: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TEMPO")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .kerning(1)
                Spacer()
                Text("\(Int(host.manualTempo.rounded())) BPM")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: $host.manualTempo, in: FlowHost.manualTempoRange, step: 1)
                .tint(accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
    }

    private var workoutStatus: String {
        switch workout.phase {
        case .off: return "Starts with play"
        case .launching: return "Starting on watch…"
        case .running: return "Recording"
        case .paused: return "Waiting for watch"
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(1)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
    }
}
