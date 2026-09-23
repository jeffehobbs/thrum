import SwiftUI

@main
struct ThrumTVApp: App {
    @StateObject private var host = TVHost()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVRootView(host: host)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                host.sceneBecameActive()
            case .background:
                host.sceneWentBackground()
            default:
                break
            }
        }
    }
}

/// The whole screen. The field, the wordmark while nothing plays, one caption
/// line for a few seconds after a start, and nothing else — no settings, no
/// menu, no thumbs. Select and play/pause both toggle; Menu leaves, as it does
/// everywhere on the platform.
struct TVRootView: View {
    @ObservedObject var host: TVHost
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WashView(host: host)
                .ignoresSafeArea()

            // The remote, caught in UIKit. A SwiftUI `Button` was the first
            // attempt and Select did not reliably reach it on the device while
            // play/pause did — so the two buttons that must do the same thing
            // did not. `UIPress` types are unambiguous: Select and play/pause
            // both toggle, down shows the caption (Aerial's gesture), and Menu
            // is left to the system so it still leaves the app.
            RemotePresses(
                onToggle: { source in host.toggle(from: source) },
                onDown: { host.showCaption() })
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                if !host.running {
                    HStack(spacing: 18) {
                        Text("Thrum")
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .opacity(pulse ? 0.9 : 0.45)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                                    pulse = true
                                }
                            }
                    }
                }
                if host.captionVisible {
                    Text(host.caption)
                        .transition(.opacity)
                }
                if let error = host.lastError {
                    Text(error)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.58))
                }
            }
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 3)
            .padding(.leading, 90)
            .padding(.bottom, 80)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.9), value: host.captionVisible)
            .animation(.easeInOut(duration: 0.9), value: host.running)
        }
        .background(Color.black)
    }
}

/// A focusable, invisible UIKit view that owns the remote. Select and
/// play/pause call `onToggle` with a name for the log; down calls `onDown`;
/// everything else (Menu above all) goes to the system.
struct RemotePresses: UIViewRepresentable {
    var onToggle: (String) -> Void
    var onDown: () -> Void

    func makeUIView(context: Context) -> PressView {
        let view = PressView()
        view.backgroundColor = .clear
        view.onToggle = onToggle
        view.onDown = onDown
        return view
    }

    func updateUIView(_ view: PressView, context: Context) {
        view.onToggle = onToggle
        view.onDown = onDown
        // SwiftUI re-runs this when the screen changes state — the wordmark
        // appearing on stop, the caption coming and going — and a focus update
        // can ride along with that and leave nothing focused, after which no
        // press reaches anyone. Take focus back every time.
        view.reclaimFocus()
    }

    final class PressView: UIView {
        var onToggle: ((String) -> Void)?
        var onDown: (() -> Void)?

        override var canBecomeFocused: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reclaimFocus()
        }

        /// There is nothing else on the screen to hold focus; if this view has
        /// lost it, the remote is dead. Asked for on every update and logged
        /// when it was actually missing, so the log can say whether that is
        /// what happened.
        func reclaimFocus() {
            guard window != nil else { return }
            if !isFocused {
                TVLog.note("remote: press view had lost focus — reclaiming")
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            for press in presses {
                switch press.type {
                case .select:    onToggle?("select")
                case .playPause: onToggle?("play/pause")
                case .downArrow: onDown?()
                default:         unhandled.insert(press)
                }
            }
            if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
        }
    }
}
