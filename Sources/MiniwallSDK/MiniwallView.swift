#if os(iOS)
import MiniwallCore
import SwiftUI

/// A screen inside your own UI (onboarding step, pricing section), like the Web SDK's
/// `mountPaywall`. Purchases, restores and actions go through `options`; `onFinish` reports
/// how it ended (purchased, closed, action...).
///
/// ```swift
/// MiniwallView(.placement("onboarding"), options: options) { result in ... }
/// ```
public struct MiniwallView: View {
    private let source: ScreenSource
    private let options: PresentOptions
    private let onFinish: (PurchaseResult) -> Void
    @StateObject private var loader = InlineLoader()

    public init(_ source: ScreenSource, options: PresentOptions = PresentOptions(), onFinish: @escaping (PurchaseResult) -> Void = { _ in }) {
        self.source = source
        self.options = options
        self.onFinish = onFinish
    }

    /// A local screen JSON (no analytics).
    public init(json: Data, options: PresentOptions = PresentOptions(), onFinish: @escaping (PurchaseResult) -> Void = { _ in }) throws {
        self.init(.json(try JSONValue.parse(json)), options: options, onFinish: onFinish)
    }

    public var body: some View {
        ZStack {
            if let coordinator = loader.coordinator {
                PresentedScreen(coordinator: coordinator)
            } else if loader.failed {
                Color.clear
            } else {
                ProgressView()
            }
        }
        .task { await loader.load(source, options: options, onFinish: onFinish) }
    }
}

/// Not `@MainActor` as a class, so `@StateObject` can create it from a view's property initializer; the only
/// method that changes its state is.
final class InlineLoader: ObservableObject {
    @Published var coordinator: PresentationCoordinator?
    @Published var failed = false
    private var started = false

    @MainActor
    func load(_ source: ScreenSource, options: PresentOptions, onFinish: @escaping (PurchaseResult) -> Void) async {
        guard !started else { return }
        started = true
        do {
            let resolved = try await Miniwall.resolve(source, options: options)
            if resolved.skip != nil {
                failed = true
                let result = PaywallSession.skipped(resolved, memory: Miniwall.memory, enqueue: Miniwall.client.enqueue, client: Miniwall.eventClient)
                Miniwall.notify(options, result)
                onFinish(result)
                return
            }
            let coordinator = PresentationCoordinator(options: options)
            coordinator.start(resolved) { Miniwall.notify(options, $0); onFinish($0) }
            self.coordinator = coordinator
        } catch {
            failed = true
            options.onError?(error)
        }
    }
}
#endif
