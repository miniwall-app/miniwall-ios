#if os(iOS)
import MiniwallCore
import SwiftUI
import UIKit

var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

/// Where a screen comes from.
public enum ScreenSource: Sendable {
    /// A placement set up in the dashboard (targeting, A/B test, display, schedule).
    case placement(String)
    /// A published screen by its id.
    case paywallId(String)
    /// A screen JSON you hold (e.g. bundled for offline use). No analytics.
    case json(JSONValue)
}

/// How a screen shows. Default: the placement's display from the dashboard, else `fullscreen`.
public enum PresentationStyle: Equatable, Sendable {
    case fullscreen
    /// Page sheet (form sheet on iPad); swipe down closes it.
    case modal
    /// Bottom sheet as tall as the screen's content (at most the large detent).
    case sheet
    /// Pinned to the top or bottom safe area; the app stays usable around it.
    case banner(top: Bool)
    /// A small card at the bottom (or top) that closes itself after `seconds`.
    case toast(seconds: Double, top: Bool = false)

    /// The placement's `display` mapped to iOS.
    static func from(display: JSONValue?) -> PresentationStyle {
        switch display?.str("format") {
        case "modal", "drawer", "launcher": return .modal
        case "slide_in": return .sheet
        case "banner": return .banner(top: display?.str("position") != "bottom")
        case "toast": return .toast(seconds: min(max(display?.num("duration") ?? 6, 3), 60), top: display?.str("position") == "top")
        default: return .fullscreen
        }
    }
}

/// Width of a presented screen on wide screens (modal, sheet, toast), like the Web SDK's `size`. Phones are narrower than all of them.
public enum PresentationSize: String, Sendable { case small, medium, large }

/// Where a banner or toast sits.
public enum PresentationPosition: Sendable { case top, bottom }

extension PresentationStyle {
    /// This style at `position`; styles without a position (fullscreen, modal, sheet) stay as they are.
    func positioned(_ position: PresentationPosition?) -> PresentationStyle {
        guard let position else { return self }
        switch self {
        case .banner: return .banner(top: position == .top)
        case let .toast(seconds, _): return .toast(seconds: seconds, top: position == .top)
        default: return self
        }
    }
}

/// What your app gets when a purchase button is tapped.
public struct PurchaseRequest: Sendable {
    public let packageId: String
    /// The price info you passed for this package, if any.
    public let product: ProductInfo?
    public let answers: [String: Flow.Answer]
}

/// Per-call options of ``Miniwall/present(_:options:from:)``.
public struct PresentOptions {
    /// Prices per package id, to fill `{{ product.* }}` texts. Build them with ``Miniwall/products(from:)``.
    public var products: [String: ProductInfo] = [:]
    /// Extra `{{ product.* }}` values per package, over the computed ones.
    public var variablesPerPackage: [String: [String: String]] = [:]
    /// Values for `{{ custom.name }}`.
    public var customVariables: [String: AttributeValue] = [:]
    /// Audience attributes for this call, over ``Miniwall/setAttributes(_:)``.
    public var attributes: [String: AttributeValue] = [:]
    public var locale: String?
    public var colorMode: ColorMode?
    /// Overrides the placement's display.
    public var style: PresentationStyle?
    /// Screens a "Go to screen" button may open, by paywall id (for `.json` sources).
    public var screens: [String: JSONValue] = [:]
    /// Run your purchase (StoreKit, your billing library). Return true when bought, false when
    /// cancelled; throw on failure. The screen shows a spinner meanwhile. Required when the screen has a buy button.
    public var onPurchase: ((PurchaseRequest) async throws -> Bool)?
    /// "Restore purchases"; return true when something was restored. Without it the button is hidden.
    public var onRestore: (() async throws -> Bool)?
    /// A "Run your code" button. Return false to keep the screen open.
    public var onAction: ((String, [String: Flow.Answer]) async -> Bool)?
    /// A question's answer changed.
    public var onAnswer: ((String, Flow.Answer?, [String: Flow.Answer]) -> Void)?
    /// Links in the screen. Default: open in Safari.
    public var onOpenURL: ((URL) -> Void)?
    public var onError: ((Error) -> Void)?
    /// The user closed the screen (close button, swipe down): the outcome is `.closed`. Not called for a purchase, restore or action.
    public var onClose: (() -> Void)?
    /// The placement's targeting chose to show nothing (frequency cap, audience, holdout): no screen was opened.
    public var onSkip: ((SkipReason) -> Void)?
    /// Widest the content gets, in pt; centered on wide screens (iPad, landscape). Wins over `size`. Default: no limit.
    public var maxContentWidth: Double?
    /// Close a `.modal` or `.sheet` by swiping it down or tapping outside it. Default true. `false` makes the sheet non-dismissible
    /// by gesture (`isModalInPresentation`): only the screen's own close button closes it.
    public var closeOnBackdrop: Bool = true
    /// Width of a modal, sheet or toast on wide screens (small 360/320/280, medium 440/380/360, large 560/440/440 pt). Overrides the placement's display.
    public var size: PresentationSize?
    /// Where a banner or toast sits. Overrides the placement's display.
    public var position: PresentationPosition?

    public init() {}
}

extension Miniwall {
    /// Shows a screen and waits until it closes. A placement may decide to show nothing
    /// (`.skipped`: frequency cap, audience, holdout). Throws when the screen cannot be loaded.
    @MainActor
    @discardableResult
    public static func present(_ source: ScreenSource, options: PresentOptions = PresentOptions(), from presenter: UIViewController? = nil) async throws -> PurchaseResult {
        let resolved = try await resolve(source, options: options)
        if resolved.skip != nil {
            let result = PaywallSession.skipped(resolved, memory: memory, enqueue: client.enqueue, client: eventClient)
            notify(options, result)
            return result
        }
        presenting += 1
        defer {
            presenting -= 1
            // Events the app reported while this screen was open are replayed now (AutoPlacements).
            AutoPlacements.drainQueue()
        }
        await FontRegistry.shared.load(resolved.paywall)
        let style = (options.style ?? PresentationStyle.from(display: resolved.display)).positioned(options.position)
        let coordinator = PresentationCoordinator(options: options)
        let result = await withCheckedContinuation { continuation in
            coordinator.start(resolved) { continuation.resume(returning: $0) }
            coordinator.present(style: style, size: DisplayWidth.resolveSize(explicit: options.size?.rawValue, display: resolved.display, styleOverridden: options.style != nil), from: presenter)
        }
        notify(options, result)
        return result
    }

    /// `onClose` / `onSkip` as the Web SDK fires them: on a close by the user, and when targeting showed nothing.
    static func notify(_ options: PresentOptions, _ result: PurchaseResult) {
        switch result {
        case .closed: options.onClose?()
        case let .skipped(reason): options.onSkip?(reason)
        default: break
        }
    }

    /// `present(.placement(name))`.
    @MainActor
    @discardableResult
    public static func present(placement: String, options: PresentOptions = PresentOptions()) async throws -> PurchaseResult {
        try await present(.placement(placement), options: options)
    }

    /// Screens open now (yours and automatic ones): an app-open or delay trigger that fires meanwhile is dropped,
    /// events from ``Miniwall/track(_:)`` wait (up to 5) and play when the screen closes.
    @MainActor static var presenting = 0

    static func resolve(_ source: ScreenSource, options: PresentOptions) async throws -> Resolved {
        switch source {
        case let .placement(name):
            let body = try await client.fetch("/placements/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)")
            return Delivery.decide(body, input: targeting(options.attributes), memory: memory)
        case let .paywallId(id):
            return try await loadScreen(id, screens: [:])
        case let .json(json):
            guard let paywall = Delivery.asPaywall(json) else { throw MiniwallError("Miniwall: not a screen JSON (expected components_config.base.stack)") }
            return Resolved(paywall: paywall, context: nil)
        }
    }

    /// Images of a screen, fetched ahead (preload).
    static func preloadImages(in paywall: JSONValue?) async {
        var urls: [URL] = []
        var icons: [URL] = []
        Flow.walk(paywall?["components_config"]) { node in
            for key in ["source", "value", "fallback_source"] {
                if let files = node.obj(key)?.obj("light"), let u = files.str("original") ?? files.str("webp"), let url = URL(string: u) { urls.append(url) }
            }
            if node.str("type") == "icon", let base = node.str("base_url"), let file = node.obj("formats")?.str("webp"), let url = URL(string: "\(base)/\(file)") {
                if url.pathExtension.lowercased() == "svg" { icons.append(url) } else { urls.append(url) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { _ = await ImageLoader.shared.load(url) } }
            for url in Set(icons) { group.addTask { await withCheckedContinuation { continuation in IconLoader.shared.load(url) { _ in continuation.resume() } } } }
        }
    }
}

/// Runs one presentation: the session, the hosting controller and the host callbacks.
/// Everything here runs on the main thread (taps, and completions hop back with `@MainActor`).
final class PresentationCoordinator: ObservableObject, SessionHost {
    let options: PresentOptions
    @Published var model: ScreenModel?
    private var session: PaywallSession?
    private var completion: ((PurchaseResult) -> Void)?
    private weak var hosting: UIViewController?
    /// Banner and toast only: the full-window view that holds the card (see ``OverlayContainerView``).
    private var overlay: UIView?
    private var overlayHeight: NSLayoutConstraint?
    private var overlayKey: OverlayKey?
    /// Widest the content gets (pt) on this presentation, from `maxContentWidth` or `size`; nil = no limit.
    private(set) var widthCap: Double?
    /// Banners and toasts have no presenter to keep their hosting controller alive: hold it here.
    private var overlayHost: UIViewController?

    /// What the last overlay measurement was made for: the height is measured again only when one of these changes.
    private struct OverlayKey: Equatable {
        var width: CGFloat
        var maxHeight: CGFloat
        var model: ObjectIdentifier?
        var version: Int
    }

    init(options: PresentOptions) { self.options = options }

    var dark: Bool {
        switch options.colorMode ?? Miniwall.currentOptions.colorMode {
        case .dark: return true
        case .light: return false
        case .system: return (Self.keyWindow()?.traitCollection.userInterfaceStyle ?? .light) == .dark
        }
    }

    func start(_ resolved: Resolved, completion: @escaping (PurchaseResult) -> Void) {
        self.completion = completion
        let options = self.options
        let locale = options.locale ?? Miniwall.currentOptions.locale ?? Locale.current.identifier
        // Prices are formatted in the language the screen is drawn in (as the Web SDK does), not in the device language.
        func variables(for screen: JSONValue) -> [String: [String: String]] {
            Pricing.productVariables(options.products, locale: Localization.forPaywall(screen, requested: locale))
                .merging(options.variablesPerPackage) { $0.merging($1) { $1 } }
        }
        let custom = options.customVariables.mapValues { value -> String in
            switch value {
            case let .string(s): return s
            case let .number(n): return JsNumber.format(n)
            case let .bool(b): return b ? "true" : "false"
            }
        }
        let info = options.products.mapValues { p in
            PackageInfo(hasIntroOffer: (p.offer?.price ?? 0) > 0, hasTrial: p.offer?.price == 0, hasPromoOffer: false)
        }
        let dark = self.dark
        let showRestore = options.onRestore != nil
        session = PaywallSession(
            first: resolved,
            memory: Miniwall.memory,
            enqueue: Miniwall.client.enqueue,
            loadScreen: { id, done in
                Task { @MainActor in
                    do { done(.success(try await Miniwall.loadScreen(id, screens: options.screens))) } catch { done(.failure(error)) }
                }
            },
            controllerFactory: { json, answers, onEvent in
                ScreenController(paywall: json, locale: locale, dark: dark, variablesPerPackage: variables(for: json), baseVariables: custom,
                                 infoPerPackage: info, showRestoreButton: showRestore, initialAnswers: answers, onEvent: onEvent)
            },
            host: self,
            client: Miniwall.eventClient
        )
    }

    // MARK: Presentation

    /// Nothing could be shown: tell the app and end the presentation, so `present` does not wait forever.
    private func failToPresent(_ message: String) {
        options.onError?(MiniwallError(message))
        session?.close()
    }

    func present(style: PresentationStyle, size: String?, from presenter: UIViewController?) {
        let kind: String
        switch style {
        case .modal: kind = "modal"
        case .sheet: kind = "sheet"
        case .toast: kind = "toast"
        case .banner: kind = "banner"
        default: kind = "fullscreen"
        }
        widthCap = DisplayWidth.cap(kind: kind, size: size, maxContentWidth: options.maxContentWidth)
        let root = PresentedScreen(coordinator: self)
        switch style {
        case .banner, .toast:
            presentOverlay(root, style: style)
            return
        default:
            break
        }
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        switch style {
        case .fullscreen:
            hosting.modalPresentationStyle = .fullScreen
        case .modal:
            hosting.modalPresentationStyle = isPad ? .formSheet : .pageSheet
        case .sheet:
            // A form sheet on iPad is about 540 pt wide: measure the content at that width, not the screen's.
            let height = intrinsicHeight(width: sheetWidth(presenter: presenter))
            hosting.modalPresentationStyle = .pageSheet
            if isPad {
                hosting.modalPresentationStyle = .formSheet
                hosting.preferredContentSize = CGSize(width: CGFloat(sheetWidth(presenter: presenter)), height: CGFloat(height))
            }
            if let sheet = hosting.sheetPresentationController {
                sheet.detents = [.custom { context in min(CGFloat(height), context.maximumDetentValue) }]
                sheet.prefersGrabberVisible = true
            }
        default:
            break
        }
        hosting.isModalInPresentation = !options.closeOnBackdrop
        hosting.presentationController?.delegate = DismissDelegate.shared
        DismissDelegate.shared.onDismiss[ObjectIdentifier(hosting)] = { [weak self] in self?.session?.close() }
        self.hosting = hosting
        guard let top = presenter ?? Self.topViewController() else { return failToPresent("Miniwall: there is no view controller to present from") }
        top.present(hosting, animated: true)
        // UIKit ignores the call when the presenter is already presenting or being dismissed.
        if hosting.presentingViewController == nil { failToPresent("Miniwall: the screen could not be presented over the current view controller") }
    }

    /// The width a modal or sheet gets: a phone sheet is as wide as its presenter, a form sheet on iPad about 540 pt.
    private func sheetWidth(presenter: UIViewController?) -> Double {
        let full = Double((presenter ?? Self.topViewController())?.view.bounds.width ?? Self.keyWindow()?.bounds.width ?? 390)
        let width = isPad ? min(540, full) : full
        return widthCap.map { min(width, $0) } ?? width
    }

    private func intrinsicHeight(width: Double) -> Double {
        guard let controller = model?.controller else { return 400 }
        // Measured at the text size it will be drawn at: at a large Dynamic Type size a banner measured at 1.0 is clipped.
        controller.fontScale = ScreenView.currentFontScale
        return controller.intrinsicHeight(width: width, measurer: TextKitMeasurer())
    }

    /// Banners and toasts sit on top of the app without blocking it.
    private func presentOverlay(_ root: PresentedScreen, style: PresentationStyle) {
        guard let window = Self.keyWindow() else { return failToPresent("Miniwall: there is no window to show the screen in") }
        var top = false
        var seconds: Double?
        switch style {
        case let .banner(t): top = t
        case let .toast(s, t): seconds = s; top = t
        default: break
        }
        // A toast is a card inset from the edges; a banner spans the width. Auto Layout against the container's safe
        // area keeps it in place through rotation and window resizes; its height follows the width (see below).
        let inset: CGFloat = seconds == nil ? 0 : 16
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        if seconds != nil {
            hosting.view.layer.cornerRadius = 16
            hosting.view.clipsToBounds = true
        }
        let container = OverlayContainerView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .clear
        container.alpha = 0
        container.addSubview(hosting.view)
        let guide = container.safeAreaLayoutGuide
        let height = hosting.view.heightAnchor.constraint(equalToConstant: 0)
        // Wider than the cap: centered, at most `widthCap` wide; otherwise it spans the safe area minus the inset.
        let edges: [NSLayoutConstraint]
        if let cap = widthCap {
            let fill = hosting.view.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -inset * 2)
            fill.priority = .defaultHigh
            edges = [
                hosting.view.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
                hosting.view.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: inset),
                hosting.view.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -inset),
                hosting.view.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(cap)),
                fill,
            ]
        } else {
            edges = [
                hosting.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
                hosting.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            ]
        }
        NSLayoutConstraint.activate(edges + [
            top ? hosting.view.topAnchor.constraint(equalTo: guide.topAnchor, constant: inset)
                : hosting.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -inset),
            height,
        ])
        overlayHeight = height
        overlayKey = nil
        container.onLayout = { [weak self, weak container] in
            guard let self, let container else { return }
            self.updateOverlayHeight(in: container, inset: inset)
        }
        // The card sits on the window, above every screen of the app. It is not made a child of the root view
        // controller: UIKit (iOS 27) throws when a child's view is not inside its parent's view, and the card's
        // view lives in the window. The coordinator holds the hosting controller (`overlayHost`).
        window.addSubview(container)
        container.layoutIfNeeded()
        overlay = container
        overlayHost = hosting
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) { container.alpha = 1 }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.session?.close() }
        }
    }

    /// Measures the card again at the container's current width (rotation, Split View, safe-area change) and
    /// resizes it, at most 40% of the window's height.
    private func updateOverlayHeight(in container: UIView, inset: CGFloat) {
        let safe = container.safeAreaInsets
        var width = container.bounds.width - safe.left - safe.right - inset * 2
        if let cap = widthCap { width = min(width, CGFloat(cap)) }
        guard width > 0 else { return }
        let key = OverlayKey(width: width, maxHeight: container.bounds.height, model: model.map { ObjectIdentifier($0) }, version: model?.version ?? 0)
        guard key != overlayKey else { return }
        overlayKey = key
        let measured = intrinsicHeight(width: Double(width))
        overlayHeight?.constant = CGFloat(min(measured, Double(container.bounds.height) * 0.4))
    }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The scene the user is in, not one in the background (iPad can have several).
        let active = scenes.filter { $0.activationState == .foregroundActive }
        return (active.isEmpty ? scenes : active).flatMap(\.windows).first { $0.isKeyWindow }
    }

    static func topViewController(_ base: UIViewController? = keyWindow()?.rootViewController) -> UIViewController? {
        if let presented = base?.presentedViewController { return topViewController(presented) }
        if let nav = base as? UINavigationController { return topViewController(nav.visibleViewController) }
        if let tab = base as? UITabBarController { return topViewController(tab.selectedViewController) }
        return base
    }

    // MARK: SessionHost

    func purchase(packageId: String, answers: [String: Flow.Answer], done: @escaping (Result<Bool, Error>) -> Void) {
        guard let onPurchase = options.onPurchase else {
            done(.failure(MiniwallError("Miniwall: pass onPurchase in PresentOptions to handle purchase buttons")))
            return
        }
        let request = PurchaseRequest(packageId: packageId, product: options.products[packageId], answers: answers)
        Task { @MainActor in
            do { done(.success(try await onPurchase(request))) } catch { done(.failure(error)) }
        }
    }

    func restore(done: @escaping (Result<Bool, Error>) -> Void) {
        guard let onRestore = options.onRestore else { return done(.success(false)) }
        Task { @MainActor in
            do { done(.success(try await onRestore())) } catch { done(.failure(error)) }
        }
    }

    func action(actionId: String, answers: [String: Flow.Answer], done: @escaping (Bool) -> Void) {
        guard let onAction = options.onAction else { return done(true) }
        Task { @MainActor in done(await onAction(actionId, answers)) }
    }

    func openURL(_ url: String) {
        guard let u = URL(string: url) else { return }
        if let onOpenURL = options.onOpenURL { onOpenURL(u) } else { UIApplication.shared.open(u) }
    }

    func answer(fieldId: String, value: Flow.Answer?, answers: [String: Flow.Answer]) {
        options.onAnswer?(fieldId, value, answers)
    }

    func error(_ error: Error) {
        options.onError?(error)
    }

    func show(_ controller: ScreenController, animated: Bool) {
        let next = ScreenModel(controller: controller)
        if animated {
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2)) { model = next }
        } else {
            model = next
        }
        // The next screen of a flow can be taller or shorter: a banner or toast measures it again.
        overlay?.setNeedsLayout()
    }

    func finish(_ result: PurchaseResult) {
        if let hosting { DismissDelegate.shared.onDismiss.removeValue(forKey: ObjectIdentifier(hosting)) }
        let complete = { [weak self] in
            guard let self else { return }
            self.completion?(result)
            self.completion = nil
            self.session = nil
        }
        if let overlay {
            let host = overlayHost
            UIView.animate(withDuration: 0.2, animations: { overlay.alpha = 0 }) { _ in
                host?.willMove(toParent: nil)
                overlay.removeFromSuperview()
                host?.removeFromParent()
                complete()
            }
            self.overlay = nil
            self.overlayHost = nil
            self.overlayHeight = nil
        } else if let hosting, hosting.presentingViewController != nil {
            hosting.dismiss(animated: true, completion: complete)
        } else {
            complete()
        }
        Miniwall.client.flush()
    }

    func busy(_ isBusy: Bool) {
        model?.busy = isBusy
        // A swipe-down while a purchase runs would end the presentation before its result arrives.
        hosting?.isModalInPresentation = isBusy || !options.closeOnBackdrop
    }
}

/// Holds a banner or toast over the whole window: touches outside the card go to the app, and every layout pass
/// (rotation, window resize, safe-area change) lets the coordinator measure the card again at its new width.
final class OverlayContainerView: UIView {
    var onLayout: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        onLayout?()
        super.layoutSubviews()
    }
}

/// Swipe-down closes a sheet: report it as `closed`.
final class DismissDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = DismissDelegate()
    var onDismiss: [ObjectIdentifier: () -> Void] = [:]

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss.removeValue(forKey: ObjectIdentifier(presentationController.presentedViewController))?()
    }
}

/// The presented content: the current screen of the flow, with a short fade between screens.
struct PresentedScreen: View {
    @ObservedObject var coordinator: PresentationCoordinator

    var body: some View {
        ZStack {
            if let model = coordinator.model {
                ScreenView(model: model, openURL: coordinator.openURL, maxContentWidth: coordinator.widthCap)
                    .id(ObjectIdentifier(model))
                    .transition(.opacity)
            }
        }
    }
}
#endif
