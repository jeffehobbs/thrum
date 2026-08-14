import CarPlay
import UIKit
import Combine

/// Thrum as a CarPlay audio app.
///
/// CarPlay is template-only: you choose which of Apple's templates to show and
/// supply the data, and iOS does the drawing. No custom views, so the Metal field
/// cannot be put on a dashboard directly. What *can* go there is artwork — see
/// `FieldArtwork`, which renders the same blooms from the same voice data, so the
/// car shows the live field inside the Now Playing template rather than a logo.
/// Working within the constraint rather than against it.
///
/// The list is deliberately short and flat. Thrum has real content to browse — the
/// fifteen voicings, most of them borrowed from non-Western drone traditions — but
/// a car is not the place for fifteen items and a scroll, so it leads with the one
/// thing anyone wants while driving (start it) and keeps the voicings behind a
/// single push for when the car is stopped.
///
/// Requires `com.apple.developer.carplay-audio`, which Apple grants by review. The
/// scene below simply never activates without it, so this file is harmless in a
/// build that doesn't have it — and `build.sh` only attaches the entitlement when
/// `CARPLAY=1`, so the ordinary TestFlight path keeps working while the request is
/// outstanding.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    /// Held, rather than rebuilt — see `refreshRoot`.
    private var root: CPListTemplate?
    private var flowItem: CPListItem?
    private var transportWatch: AnyCancellable?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect controller: CPInterfaceController) {
        interfaceController = controller
        FlightRecorder.shared.note("CARPLAY connected — transport \(FlowHost.shared.transport)")
        controller.setRootTemplate(rootTemplate(), animated: false, completion: nil)
        // The label has to follow the transport wherever it is changed from — the
        // app's own screen, the lock screen, an AirPods squeeze — and not only from
        // the two handlers in this file. A car that has been reconnected after a
        // session was paused elsewhere was showing whatever the transport happened to
        // be when the template was last built, which is the wrong verb on the one
        // control the driver has.
        transportWatch = FlowHost.shared.$transport
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshRoot() } }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController controller: CPInterfaceController) {
        FlightRecorder.shared.note("CARPLAY disconnected")
        transportWatch = nil
        interfaceController = nil
        root = nil
        flowItem = nil
    }

    // MARK: Templates

    private var flowLabel: String {
        switch FlowHost.shared.transport {
        case .idle:    return "Start Flow"
        case .playing: return "Pause"
        case .paused:  return "Resume"
        }
    }

    private var flowDetail: String {
        let host = FlowHost.shared
        return host.hasStarted ? host.model.harmony.title : "The instrument plays itself"
    }

    private func rootTemplate() -> CPListTemplate {
        let flow = CPListItem(text: flowLabel, detailText: flowDetail)
        flow.handler = { [weak self] _, completion in
            MainActor.assumeIsolated {
                FlowHost.shared.toggle(from: "car list")
                if FlowHost.shared.running { self?.showNowPlaying() }
            }
            completion()
        }
        flowItem = flow

        let voicings = CPListItem(text: "Begin with…", detailText: "Choose a character")
        voicings.accessoryType = .disclosureIndicator
        voicings.handler = { [weak self] _, completion in
            MainActor.assumeIsolated { self?.pushVoicings() }
            completion()
        }

        let template = CPListTemplate(title: "Thrum", sections: [
            CPListSection(items: [flow, voicings]),
        ])
        template.tabTitle = "Thrum"
        root = template
        return template
    }

    /// The voicings, which are the app's actual catalogue.
    ///
    /// Each one starts Flow with that character rather than merely setting it, so a
    /// single tap in a car is a complete action — choosing a voicing and then having
    /// to find "start" would be two interactions at the wheel for no reason.
    private func pushVoicings() {
        let host = FlowHost.shared
        let items: [CPListItem] = ThrumModel.Voicing.allCases.map { voicing in
            let item = CPListItem(text: voicing.rawValue, detailText: nil)
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    FlightRecorder.shared.note("car voicing \(voicing.rawValue)")
                    host.startWith(voicing)
                    self?.showNowPlaying()
                }
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Begin with…",
                                      sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        // Already up: configure it, but do not push a second copy. `CPNowPlayingTemplate`
        // is a singleton, and pushing the same template object twice onto one stack is
        // not a duplicate screen — it is a stack whose two entries are the same object,
        // which is how a CarPlay interface stops responding to anything.
        guard interfaceController?.templates.contains(template) != true else {
            configure(template)
            return
        }
        configure(template)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func configure(_ template: CPNowPlayingTemplate) {
        // Nothing to queue and no artist page to visit — a drone has no "up next".
        // Leaving them on would put two dead buttons on a dashboard.
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false

        // The thumbs. `CPNowPlayingImageButton` rather than the feedback commands
        // alone, because a custom button is the one form of rating control CarPlay
        // documents for this template — and this is the app's *best* place for it:
        // a car is where Thrum runs for an hour with nobody looking, which is
        // exactly when "less like this" is the thing you want within reach.
        //
        // The car therefore has **two ways to say it**, and that is deliberate. This
        // row gives the real 👎 glyph, and the template's own ⏭ — drawn from
        // `MPRemoteCommandCenter.nextTrackCommand`, which `FlowHost` points at
        // `rate(.down)` — does the same thing. On the phone's lock screen ⏭ is the
        // *only* way to say it, since iOS gives `dislikeCommand` no slot; here it is
        // the one a driver's hand already knows where to find. Skipping a drone and
        // wanting less of it are the same wish.
        //
        // Rebuilt on every configure rather than held, since the buttons capture
        // nothing but the shared host and the template is a singleton either way.
        let down = CPNowPlayingImageButton(image: Self.thumb("hand.thumbsdown")) { _ in
            MainActor.assumeIsolated { FlowHost.shared.rate(.down, from: "car 👎") }
        }
        let up = CPNowPlayingImageButton(image: Self.thumb("hand.thumbsup")) { _ in
            MainActor.assumeIsolated { FlowHost.shared.rate(.up, from: "car 👍") }
        }
        template.updateNowPlayingButtons([down, up])
    }

    private static func thumb(_ name: String) -> UIImage {
        UIImage(systemName: name, withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
            ?? UIImage()
    }

    /// Keeps the root item's label honest after start/stop.
    ///
    /// **Updated in place, not rebuilt.** This used to call `setRootTemplate` with a
    /// freshly built list on every press — including immediately after
    /// `showNowPlaying()` had pushed a template on top of it. Replacing the root of a
    /// stack while something is pushed onto that root is how CarPlay ends up drawing a
    /// template that is no longer in its own hierarchy: the screen stays visible, and
    /// nothing on it does anything. Which is the reported symptom exactly — "pressing
    /// the play button in CarPlay did nothing" — and it would survive reconnecting,
    /// because the state that is wrong is the interface's and not the engine's.
    ///
    /// `CPListItem.setText` and `setDetailText` mutate a live item, so the row's verb
    /// can follow the transport without touching the stack at all.
    private func refreshRoot() {
        flowItem?.setText(flowLabel)
        flowItem?.setDetailText(flowDetail)
        // Only if the root was never built — reconnecting gives us a new controller.
        if root == nil, let interfaceController {
            interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)
        }
    }
}
