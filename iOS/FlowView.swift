import SwiftUI

/// Almost nothing, on purpose.
///
/// The Mac app is 1,100 lines of interface because it is an instrument you play.
/// This is the same engine playing itself, so the only controls that survive are
/// the ones a listener could actually want: start, stop, and how loud. Everything
/// else Flow decides.
///
/// The controls fade out with the field and come back on a tap, which means the
/// steady state of this app is a black screen with a slow drifting picture on it
/// — and that is also the cheapest thing it can be doing.
struct FlowView: View {
    @ObservedObject var host: FlowHost
    /// Held as their own `@ObservedObject`s, and that is load-bearing rather than
    /// tidy: SwiftUI does not observe an ObservableObject nested inside another
    /// one. Reading `host.model.harmony` would compile, look right at launch, and
    /// then never update again — so the mode name would silently freeze on
    /// whatever Flow happened to start with, which is the one piece of text in
    /// this app whose whole job is to change. The Mac app hit the same thing in
    /// its menu bar; same fix.
    @ObservedObject var model: ThrumModel
    @ObservedObject var route: AudioRoute
    /// Same reasoning again, one level deeper: the head tracker's status is the
    /// only way to find out that Motion permission was refused, and a field that
    /// silently stopped following your head is indistinguishable from a field that
    /// was never very good.
    @ObservedObject var head: HeadTracker
    /// Briefly shown after an "I heard it" mark lands — see the two-finger tap.
    @State private var marked = false
    /// And again, for the same documented reason: what the thumbs have taught is
    /// the one line on this screen that is supposed to change slowly over weeks,
    /// and nested inside `model` it would never change at all.
    @ObservedObject var taste: Taste

    @State private var showControls = true
    @State private var hideWork: DispatchWorkItem?
    /// Flow's answer to a vote, shown for a few seconds. Without it a thumbs press
    /// is a button with no output — the audible consequence of a thumbs-up is
    /// something *not* happening for a while, which is by nature invisible.
    @State private var note: String?
    @State private var noteWork: DispatchWorkItem?
    @State private var askingToForget = false
    /// The semi-secret reset — see the long press on ⏯ in `controls`.
    @State private var askingToReset = false
    @State private var holdFired = false

    init(host: FlowHost) {
        self.host = host
        self.model = host.model
        self.route = host.model.route
        self.head = host.model.head
        self.taste = host.model.taste
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            FieldView(host: host)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Tap anywhere: start it, or wake the controls.
            //
            // A sibling *underneath* the controls rather than, as before, a
            // `.contentShape(Rectangle()).onTapGesture` wrapped around the whole
            // ZStack. Same behaviour, but it stops the app relying on a race it
            // once lost: a gesture on the container competes with every control
            // inside it, which is why the ☯ had to stop being a `Button`. As a
            // layer below, SwiftUI's front-to-back hit testing settles it —
            // whatever is on top gets first refusal, and anything landing on empty
            // screen falls through to here.
            //
            // Worth knowing before touching any of this: **the controls fade out
            // after five seconds**, and while faded they are not hit-testable, so a
            // tap aimed at a button lands here instead and merely wakes them. That
            // is correct behaviour and it is also an excellent way to convince
            // yourself the buttons are broken when they are not — every automated
            // press has to arrive inside the window opened by the press before it.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                // "I heard it just now" — a triple tap anywhere on the field.
                //
                // Undiscoverable on purpose: this is a diagnostic, not a feature, and
                // a listener who finds it by accident learns nothing useful.
                //
                // **Three taps rather than two fingers**, and the distinction is a
                // correction rather than a preference. Two fingers is the gesture this
                // wants — nothing in ordinary use puts two fingers down at once, and a
                // pocket cannot — but SwiftUI's `onTapGesture(count:)` counts *taps*
                // and is single-finger only; there is no touch-count parameter, and
                // getting one means a `UIViewRepresentable` wrapping a
                // `UITapGestureRecognizer` with `numberOfTouchesRequired`. Not worth a
                // UIKit bridge here. A double tap was the first attempt and is wrong
                // for a different reason: this whole screen is already a one-tap
                // target, so a double tap is a thing a listener does by accident and
                // a false mark is a lie in the log. Three is not.
                //
                // Ordered *before* the single-tap modifier so SwiftUI offers it the
                // gesture first. The single tap may still fire alongside it, which is
                // harmless — it only wakes the controls.
                .onTapGesture(count: 3) {
                    guard host.hasStarted else { return }
                    host.markHeard()
                    marked = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    // The only acknowledgement: a haptic and a brief word. It must be
                    // unmistakable, because a mark you are not sure landed is a mark
                    // you press again and again, and the log then says nothing about
                    // when you actually heard it.
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.easeOut(duration: 0.5)) { marked = false }
                    }
                }
                .onTapGesture {
                    // A tap on empty screen never changes the transport — it only
                    // begins the very first session, or wakes the controls so the
                    // transport can be reached deliberately. Tapping anywhere to
                    // pause would make the whole screen a hair trigger for silence.
                    if host.hasStarted {
                        host.touched()
                        reveal()
                    } else {
                        begin()
                    }
                }

            // The receipt for a mark. Small, brief, and at the top where nothing
            // else lives — it has to be legible at arm's length in daylight without
            // being something a listener has to dismiss.
            if marked {
                VStack {
                    Text("heard it — marked")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            // Both overlays are always mounted and merely faded, rather than being
            // inserted and removed by an `if` with a `.transition`.
            //
            // A conditional view can leave a departing copy of itself in the
            // hierarchy for the length of its transition, and a copy at zero opacity
            // still hit-tests — so a tap can be swallowed by controls that are no
            // longer there. Fading a permanently-mounted view has no insertion to go
            // wrong, and `allowsHitTesting` then says in one place what is touchable
            // instead of leaving it to be inferred from what is on screen. It costs
            // nothing: this is four text views and three glyphs.
            // Carries its own tap rather than deferring to the layer beneath, and
            // that is not redundancy: `allowsHitTesting(false)` would take it out of
            // VoiceOver too, leaving a blind user with a full-screen unlabelled tap
            // target and no "Start Flow" to activate. Sighted taps land on whichever
            // of the two is nearer; both do the same thing.
            // The ☯ is the invitation to begin, and it is shown exactly once in the
            // life of a launch. After the first tap the transport takes over and
            // there is nothing left for it to invite — pausing is not un-starting,
            // so putting the ☯ back would be offering to begin something that is
            // already under way.
            startPrompt
                .opacity(host.hasStarted ? 0 : 1)
                .allowsHitTesting(!host.hasStarted)

            controls
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.45), value: showControls)
        .animation(.easeInOut(duration: 0.3), value: note)
        .animation(.easeInOut(duration: 0.8), value: host.transport)
        // Keep the screen awake only while something is actually being watched.
        // Left on permanently this is the single most expensive line in the app.
        // Paused counts as "not being watched": the field is frozen, so there is
        // nothing for the screen to stay awake for.
        .onChange(of: host.transport) { _, _ in
            UIApplication.shared.isIdleTimerDisabled = host.running && !host.idle
        }
        .onChange(of: host.idle) { _, idle in
            UIApplication.shared.isIdleTimerDisabled = host.running && !idle
        }
        .onAppear {
            // Start without a tap, for driving the app from a script.
            //
            // Use it sparingly and never to sign off the UI: it skips the one path
            // a person actually takes, which is how the app once shipped unable to
            // start at all while every simulator run reported success. `simctl` has
            // no touch synthesis, but `Tools/click` posts real CGEvents at the
            // simulator window, and that does exercise the affordance — see the note
            // above about the five-second fade before trusting what it tells you.
            if ProcessInfo.processInfo.arguments.contains("-autostart") {
                host.start()
            }
        }
    }

    /// The affordance, and the only thing on screen before the drone starts.
    ///
    /// A tap gesture rather than a `Button` — this is the control that was a
    /// `Button` when the app shipped sitting on the ☯ forever, and the same
    /// primitive the three controls below use.
    private var startPrompt: some View {
        VStack(spacing: 26) {
            YinYang()
                .frame(width: 104, height: 104)

            if let error = host.lastError {
                // Surfaced rather than swallowed. `start()` used to catch and
                // silently `return`, which is indistinguishable from a dead
                // button — and on a device with no console to hand, invisible.
                Text(error)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            } else {
                Text("tap to begin")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: begin)
        .accessibilityElement()
        .accessibilityLabel("Start Flow")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, begin)
    }

    private func begin() {
        host.start()
        reveal()
    }

    private var controls: some View {
        VStack {
            Spacer()

            VStack(spacing: 18) {
                // What Flow is doing, which is the one thing worth reading.
                //
                // The labels opt out of hit testing throughout this stack. They sit
                // on top of the tap-anywhere layer and would otherwise absorb a tap
                // and do nothing with it — a dead patch of screen in the one region
                // a listener is most likely to touch.
                Text(model.harmony.title)
                    .font(.system(size: 26, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .allowsHitTesting(false)
                Text(model.harmony.subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .allowsHitTesting(false)

                // Flow's answer to a vote, directly above the thumb that caused it.
                //
                // It used to share the line *below* the row with the taste summary,
                // which was wrong twice over: the hand that just pressed a thumb is
                // covering that part of the screen, and a toast that replaces the
                // taste line means the one message you asked for hides the one
                // message that was already there.
                //
                // Always mounted at a fixed height and merely faded, for the reason
                // documented on the two overlays above — but here there is a second
                // reason that matters more: an appearing line of text would push the
                // buttons down by its own height, and these buttons get pressed
                // twice in a row. A control that moves between the two presses puts
                // the second one somewhere else.
                Text(note ?? " ")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 32)
                    .frame(height: 30)
                    .opacity(note == nil ? 0 : 1)
                    .allowsHitTesting(false)

                // Thumbs either side of stop, which puts the two things you do to a
                // drone you are enjoying and a drone you are not on the same row as
                // the one thing you do to a drone you are finished with.
                //
                // Thumbs-**up** on the left and down on the right, on the user's
                // spec (2026-08-10). It reads as the friendlier of the two coming
                // first, and the destructive one furthest from the thumb's resting
                // place — which is the same instinct as putting Cancel before
                // Delete.
                //
                // The explicit 56×52 frame and content shape are the tap targets. A
                // thin 24-point glyph is about 24×22 of touchable area otherwise,
                // which is half Apple's minimum and a quarter of what a thumb
                // actually lands on — and these get pressed in the dark, one-handed,
                // by someone who is not looking at the phone.
                HStack(spacing: 22) {
                    control("hand.thumbsup", 24, "More like this") { vote(.up) }
                    // **Hold ⏯ for five seconds to reset what Thrum has learned.**
                    //
                    // Deliberately undiscoverable. The taste line already carries the
                    // honest, findable way back (below), and it is only there once
                    // there is something to forget — which leaves no route at all for
                    // the case this exists to cover: a book that has gone somewhere
                    // the listener does not like, on a screen where the line
                    // describing it has scrolled off the bottom of their attention.
                    // Five seconds is long enough that nobody arrives here by
                    // fumbling ⏯ in a pocket, and the dialog is the second lock.
                    control(playing ? "pause.circle" : "play.circle", 34,
                            playing ? "Pause" : "Play") {
                        // A hold that has already fired swallows the tap that ends
                        // it, so the drone does not stop as a parting gift on the way
                        // into the dialog.
                        if holdFired { holdFired = false; return }
                        host.toggle()
                        reveal()
                    }
                    .onLongPressGesture(minimumDuration: 5, maximumDistance: 30) {
                        holdFired = true
                        askingToReset = true
                    } onPressingChanged: { pressing in
                        guard pressing else {
                            // Finger up: back to the ordinary five-second fade.
                            reveal()
                            return
                        }
                        holdFired = false
                        // The controls hide five seconds after the last tap and stop
                        // hit-testing when they do (see `controlsVisible`), so a
                        // five-second hold would otherwise race the very affordance
                        // it is being performed on and lose about half the time.
                        // Hold the fade off entirely while a finger is down.
                        hideWork?.cancel()
                        showControls = true
                        host.touched()
                    }
                    control("hand.thumbsdown", 24, "Less like this") { vote(.down) }
                }
                .foregroundStyle(.white.opacity(0.8))

                // What the thumbs have added up to. Empty on a fresh install, which
                // is the honest state — there is nothing to claim to have learned
                // yet. No longer doubles as the toast: that has its own line above
                // the row now, so this one keeps saying what has been learned even
                // in the five seconds after a vote.
                if !tasteLine.isEmpty {
                    Text(tasteLine)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                        // A short tap here has to do what a tap anywhere else does,
                        // because this line is on top of the layer that would
                        // otherwise handle it.
                        .onTapGesture {
                            host.touched()
                            reveal()
                        }
                        // The only way back. A system that quietly reshapes the
                        // music forever needs one, if only because a handful of
                        // votes cast while trying the buttons out are otherwise
                        // permanent. Hidden on the line that describes what would be
                        // forgotten, which is at least where you would look.
                        .onLongPressGesture { if !taste.isEmpty { askingToForget = true } }
                }

                // Route matters here in a way it doesn't on a Mac: spatial follows
                // it, so saying so explains why the sound changed when the AirPods
                // went in.
                Text(routeLine)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .allowsHitTesting(false)
            }
            .padding(.bottom, 54)
            .confirmationDialog("Forget what Thrum has learned?",
                                isPresented: $askingToForget, titleVisibility: .visible) {
                Button("Forget \(taste.ups + taste.downs) ratings", role: .destructive) {
                    taste.forget()
                    flash("Forgotten — back to no opinion")
                }
                Button("Keep them", role: .cancel) {}
            }
            // Attached out here rather than to ⏯ itself, because the control that
            // launches this is the one thing on screen that can be taken away while
            // the dialog is up — an alert owned by a disappearing view goes with it.
            .alert("Reset preferences?", isPresented: $askingToReset) {
                Button("Cancel", role: .cancel) {}
                Button("OK") {
                    taste.forget()
                    flash("Reset — back to no opinion")
                }
            }
        }
        .frame(maxWidth: 520)
    }

    /// Reads `route` (observed) rather than `engine.spatialEnabled` (not an
    /// ObservableObject at all), so this line actually changes when the AirPods
    /// go in. `isRoom` is the same test `FlowHost.routeChanged` switches on.
    private var routeLine: String {
        let name = route.name.isEmpty ? "Output" : route.name
        guard !route.isRoom else { return "\(name) · stereo" }
        // Head tracking is what makes the field a room rather than a filter, so
        // when it isn't happening the line says which kind of "isn't" it is.
        // Silence here is what let a denied Motion prompt read as a weak effect.
        switch head.status {
        case .tracking:        return "\(name) · spatial field · head-tracked"
        case .denied:          return "\(name) · spatial field · head-locked (Motion access off)"
        case .unsupported:     return "\(name) · spatial field · head-locked"
        case .needsPermission, .idle: return "\(name) · spatial field"
        }
    }

    private var playing: Bool { host.transport == .playing }

    /// Paused, the controls stay put. Auto-hiding them is right while the field is
    /// the thing being watched; with the sound held there is nothing else on screen
    /// and no way back except a tap in the dark.
    private var controlsVisible: Bool {
        host.hasStarted && (showControls || host.transport == .paused)
    }

    /// One of the three controls: a glyph, a generous tap target, and a tap
    /// gesture rather than a `Button`.
    ///
    /// `.onTapGesture` on an explicitly shaped view is the same primitive the ☯
    /// was moved to, and for the same reason — it is the one thing in this view
    /// that has never been ambiguous about who receives a touch. A `Button` brings
    /// `_ButtonGesture`'s press-state machinery, which is exactly what lost to the
    /// container gesture before, and it buys nothing here: there is no pressed
    /// style to speak of on a thin white glyph over black.
    ///
    /// The accessibility traits are therefore set by hand, so VoiceOver still finds
    /// three buttons and can activate them — that is the one thing a real `Button`
    /// was giving us for free and it is not optional.
    private func control(_ symbol: String, _ size: CGFloat, _ label: String,
                         action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .thin))
            .frame(width: 56, height: 52)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }

    /// Either thumb. Reads the answer straight off `model.status`, which `rate` has
    /// already written synchronously — Flow decides what to say about a vote,
    /// because Flow is what acted on it.
    private func vote(_ vote: Taste.Vote) {
        host.rate(vote)
        flash(model.status)
    }

    /// Show one line above the thumbs, then take it away again — and keep the
    /// controls up for as long as it is there, so the message and the buttons it
    /// describes never fade at different moments.
    private func flash(_ message: String) {
        note = message
        reveal()
        noteWork?.cancel()
        let work = DispatchWorkItem { note = nil }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// What has been learned so far, or how far off that is. Saying "3 ratings so
    /// far" rather than nothing is what distinguishes a database that is filling up
    /// from a pair of buttons that don't work.
    private var tasteLine: String {
        if !taste.summary.isEmpty { return taste.summary }
        let total = taste.ups + taste.downs
        guard total > 0 else { return "" }
        return "learning — \(total) rating\(total == 1 ? "" : "s") so far"
    }

    /// Show the controls, then take them away again. Deliberately not a toggle —
    /// tapping to wake the field and tapping to hide the controls are the same
    /// gesture, and having it sometimes do nothing visible feels broken.
    private func reveal() {
        showControls = true
        hideWork?.cancel()
        let work = DispatchWorkItem { showControls = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

/// The ☯, drawn rather than typed.
///
/// `Text("☯")` is the obvious version and it is wrong on iOS: U+262F has emoji
/// presentation by default, so it arrives as a purple color glyph that ignores
/// both `.thin` and `foregroundStyle`. Drawing it also means it can be line art
/// to match the rest of the app, and can turn — a quarter revolution per minute,
/// slow enough that you notice it has moved rather than watching it move.
struct YinYang: View {
    @State private var spin = false

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            let ink = Color.white.opacity(0.82)

            ZStack {
                Circle()
                    .strokeBorder(ink, lineWidth: d * 0.012)

                // The S-curve: two half-circles of radius r/2, meeting at the
                // centre, which is the whole construction of the figure.
                Path { p in
                    p.addArc(center: CGPoint(x: r, y: r * 0.5), radius: r * 0.5,
                             startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                    p.addArc(center: CGPoint(x: r, y: r * 1.5), radius: r * 0.5,
                             startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
                }
                .stroke(ink, lineWidth: d * 0.012)

                Circle()
                    .fill(ink)
                    .frame(width: d * 0.10, height: d * 0.10)
                    .offset(y: -r * 0.5)

                Circle()
                    .strokeBorder(ink, lineWidth: d * 0.012)
                    .frame(width: d * 0.10, height: d * 0.10)
                    .offset(y: r * 0.5)
            }
            .frame(width: d, height: d)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 240).repeatForever(autoreverses: false), value: spin)
        }
        .onAppear { spin = true }
    }
}
