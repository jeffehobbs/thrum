import SwiftUI
import TipJar

/// Six coins, none of which buy anything.
///
/// The library ships its own `TipJarSection`, meant to be dropped into a stock
/// settings `Form` — and Thrum's settings screen is not one, so the six
/// buttons are drawn here in the same black-and-monospace idiom as
/// `SettingsView`, the way Field, Meter and Plasma all do it.
struct TipJarView: View {
    @ObservedObject var jar: TipJar
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(hue: 0.09, saturation: 0.7, brightness: 0.98)

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Said once, in the first person, and signed.
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Thrum is a drone that plays itself — Flow drifting the mode, the timbre and the field on its own, so there's always something moving and nothing that jumps.")
                            Text("I expect no payment for this app, it has been a project of curiosity, but if it has given you something, consider dropping a tip to pay for the next one.")
                            Text("Thanks, Jeff")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                        state

                        if jar.given > 0 { record }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Tip Jar")
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
        // Asked for on arrival rather than at launch: the six prices are a
        // round trip to the App Store, and somebody who never opens this
        // should never make it. `load()` answers instantly the second time.
        .task { await jar.load() }
    }

    // MARK: - What the jar is doing

    @ViewBuilder
    private var state: some View {
        switch jar.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                note("Asking the App Store…")
            }

        case .thanks:
            note("Thank you — that is more than enough.", color: accent)

        case .pending:
            // Ask to Buy, or a bank taking its time. The transaction arrives
            // later through the jar's own listener, so this is a real state
            // and not a failure.
            note("Waiting for approval — thank you either way.")

        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                ladder
                note(message, color: .orange.opacity(0.85))
            }

        default:
            if jar.isReady {
                ladder
            } else {
                // No products means no store access, or products that have
                // not been approved yet. Stated plainly rather than as an
                // error: it is not something the reader did or can fix.
                note("The tip jar isn't available right now.")
            }
        }
    }

    /// Six ruled boxes, small to large — a ladder, because the amount is the
    /// whole of what each one says.
    private var ladder: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(jar.tips) { tip in
                Button {
                    Task { await jar.tip(tip) }
                } label: {
                    Text(jar.label(for: tip))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            if case .buying(let id) = jar.state, id == tip.id {
                                ProgressView().tint(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isBusy ? 0.4 : 1)
            }
        }
    }

    /// Stated the way Thrum's own settings screen states any other fact.
    private var record: some View {
        VStack(spacing: 1) {
            statRow(label: "TIPS GIVEN", value: jar.given.formatted())
            if let last = jar.lastGiven {
                statRow(label: "LAST ONE", value: last.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private func note(_ text: String, color: Color = .white.opacity(0.5)) -> some View {
        Text(text)
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isBusy: Bool {
        switch jar.state {
        case .buying, .loading: return true
        default: return false
        }
    }
}

#Preview {
    TipJarView(jar: TipJar(prefix: "com.jeffhobbs.thrumflow.tip"))
}
