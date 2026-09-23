import SwiftUI

/// Keeps tvOS from sliding its own screensaver over this one.
///
/// Lifted from Chronological, where it was found the hard way:
/// `UIApplication.isIdleTimerDisabled` is the documented way to hold the
/// screensaver off and on tvOS setting it once does not reliably work — it
/// reads back `true` and the screensaver comes up anyway, across several
/// releases. What holds is re-arming it: `false` then straight back to `true`
/// restarts the system's idle countdown, so on a thirty-second timer it never
/// reaches the shortest delay tvOS offers (two minutes).
///
/// A drone that plays for an hour with no button pressed is, as far as tvOS is
/// concerned, an idle app. Pair every `hold()` with a `release()` or the Apple
/// TV can never sleep again.
@MainActor
final class IdleGuard {
    private static let interval = Duration.seconds(30)
    private var task: Task<Void, Never>?

    func hold() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { break }
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    func release() {
        task?.cancel()
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
