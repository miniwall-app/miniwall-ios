#if os(iOS)
import MiniwallCore
import UIKit

/// Dictionary-based API for the React Native and Flutter wrappers (they bridge plain maps).
/// The wrapper passes `handler`, which forwards the screen's requests to JavaScript / Dart:
/// `purchase` {packageId, answers} -> Bool, `restore` -> Bool, `action` {actionId, answers} -> Bool,
/// `answer` {fieldId, value, answers}, `openUrl` {url}, `error` {message}, `autoResult` {placement, result}.
/// `answer`, `openUrl`, `error` and `autoResult` are fire-and-forget: the wrapper sends them and does not wait for a reply.
/// A `purchase`/`restore` reply may be `{error: message}` (the screen's onError fires and nothing is credited); an `action`
/// reply of `{error: message}` keeps the screen open and fires onError.
public final class MiniwallBridge {
    public typealias Handler = (_ method: String, _ arguments: [String: Any], _ reply: @escaping (Any?) -> Void) -> Void
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public func configure(_ args: [String: Any]) {
        var options = Miniwall.Options()
        if let url = (args["apiUrl"] as? String).flatMap(URL.init(string:)) { options.apiURL = url }
        options.locale = args["locale"] as? String
        options.colorMode = Self.colorMode(args["colorMode"] as? String) ?? .system
        options.analytics = args["analytics"] as? Bool ?? true
        options.attributes = Self.attributes(args["attributes"])
        if let timeout = args["timeoutMs"] as? Double { options.timeout = timeout / 1000 }
        if let scale = args["maxFontScale"] as? Double { options.maxFontScale = scale }
        Miniwall.configure(apiKey: args["apiKey"] as? String ?? "", options: options)
    }

    public func setAttributes(_ args: [String: Any]) {
        var values: [String: AttributeValue?] = [:]
        // updateValue: `values[key] = nil` would drop the key instead of storing "remove this attribute".
        for (key, value) in args { values.updateValue(value is NSNull ? nil : Self.attribute(value), forKey: key) }
        Miniwall.setAttributes(values)
    }

    public func reportPurchase(_ args: [String: Any]) {
        Miniwall.reportPurchase(packageId: args["packageId"] as? String, paywallId: args["paywallId"] as? String)
    }

    public func reset(_ args: [String: Any]) {
        Miniwall.reset(placements: args["placements"] as? [String] ?? [])
    }

    public func preload(_ args: [String: Any], completion: @escaping () -> Void) {
        Task {
            await Miniwall.preload(placements: args["placements"] as? [String] ?? [])
            completion()
        }
    }

    /// Starts placements that show by themselves (app open, delay, events). `options` (same shape as
    /// ``present(_:completion:)``'s) applies to all of them; each outcome comes back to the handler as
    /// `autoResult` {placement, result}.
    public func startAutoPlacements(_ args: [String: Any]) {
        let o = args["options"] as? [String: Any] ?? [:]
        Task { @MainActor in
            Miniwall.startAutoPlacements(
                options: { [weak self] _ in self?.options(o) ?? PresentOptions() },
                onResult: { [weak self] placement, result in
                    self?.handler("autoResult", ["placement": placement, "result": Self.result(result)]) { _ in }
                }
            )
        }
    }

    /// Stops the placements started by ``startAutoPlacements(_:)`` (the wrapper's engine or context is going away).
    public func stopAutoPlacements(_ args: [String: Any] = [:]) {
        Task { @MainActor in Miniwall.stopAutoPlacements() }
    }

    /// `Miniwall.track(event)`: {event}.
    public func track(_ args: [String: Any]) {
        let event = args["event"] as? String ?? ""
        Task { @MainActor in Miniwall.track(event) }
    }

    /// `source`: {placement} | {paywallId} | {json}; `options`: products, variablesPerPackage,
    /// customVariables, attributes, locale, colorMode, style, screens, hasPurchase/hasRestore/hasAction/hasOpenUrl.
    public func present(_ args: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        let source: ScreenSource
        let s = args["source"] as? [String: Any] ?? [:]
        if let placement = s["placement"] as? String {
            source = .placement(placement)
        } else if let id = s["paywallId"] as? String {
            source = .paywallId(id)
        } else if let json = s["json"], let value = try? JSONValue(any: json) {
            source = .json(value)
        } else {
            return completion(nil, MiniwallError("Miniwall: present needs a source (placement, paywallId or json)"))
        }
        let options = self.options(args["options"] as? [String: Any] ?? [:])
        Task { @MainActor in
            do {
                completion(Self.result(try await Miniwall.present(source, options: options)), nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    // MARK: Conversions

    /// Asks JavaScript or Dart and waits for the answer. A purchase can take minutes on the store's payment sheet, so the
    /// limit is long (10 minutes): it only frees the screen when the wrapper was reloaded or never replies.
    private func ask(_ method: String, _ args: [String: Any]) async -> Any? {
        await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Any?) -> Void = { value in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
            DispatchQueue.main.async { self.handler(method, args, answer) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { answer(nil) }
        }
    }

    private func options(_ o: [String: Any]) -> PresentOptions {
        var options = PresentOptions()
        options.products = (o["products"] as? [String: Any] ?? [:]).compactMapValues { Self.product($0) }
        options.variablesPerPackage = o["variablesPerPackage"] as? [String: [String: String]] ?? [:]
        options.customVariables = (o["customVariables"] as? [String: Any] ?? [:]).compactMapValues(Self.attribute)
        options.attributes = Self.attributes(o["attributes"])
        options.locale = o["locale"] as? String
        options.colorMode = Self.colorMode(o["colorMode"] as? String)
        options.style = Self.style(o["style"] as? [String: Any])
        // onClose / onSkip are not bridged: the wrapper derives them from the result (`closed` / `skipped`).
        options.maxContentWidth = (o["maxContentWidth"] as? NSNumber)?.doubleValue
        options.closeOnBackdrop = o["closeOnBackdrop"] as? Bool ?? true
        options.size = (o["size"] as? String).flatMap(PresentationSize.init(rawValue:))
        options.position = Self.position(o["position"] as? String)
        options.screens = (o["screens"] as? [String: Any] ?? [:]).compactMapValues { try? JSONValue(any: $0) }
        if o["hasPurchase"] as? Bool ?? true {
            options.onPurchase = { [weak self] request in
                guard let self else { return false }
                let reply = await self.ask("purchase", ["packageId": request.packageId, "answers": Self.answers(request.answers)])
                if let error = (reply as? [String: Any])?["error"] as? String { throw MiniwallError(error) }
                return reply as? Bool ?? false
            }
        }
        if o["hasRestore"] as? Bool ?? false {
            options.onRestore = { [weak self] in
                let reply = await self?.ask("restore", [:])
                if let error = (reply as? [String: Any])?["error"] as? String { throw MiniwallError(error) }
                return reply as? Bool ?? false
            }
        }
        if o["hasAction"] as? Bool ?? false {
            options.onAction = { [weak self] actionId, answers in
                // A handler that failed: tell onError and keep the screen open instead of closing as if it had worked.
                let reply = await self?.ask("action", ["actionId": actionId, "answers": Self.answers(answers)])
                if let message = (reply as? [String: Any])?["error"] as? String {
                    self?.handler("error", ["message": message]) { _ in }
                    return false
                }
                return reply as? Bool ?? true
            }
        }
        options.onAnswer = { [weak self] fieldId, value, answers in
            self?.handler("answer", ["fieldId": fieldId, "value": value.map(Self.answer) ?? NSNull(), "answers": Self.answers(answers)]) { _ in }
        }
        if o["hasOpenUrl"] as? Bool ?? false {
            options.onOpenURL = { [weak self] url in self?.handler("openUrl", ["url": url.absoluteString]) { _ in } }
        }
        options.onError = { [weak self] error in self?.handler("error", ["message": error.localizedDescription]) { _ in } }
        return options
    }

    static func colorMode(_ s: String?) -> ColorMode? {
        switch s {
        case "light": return .light
        case "dark": return .dark
        case "system": return .system
        default: return nil
        }
    }

    static func attribute(_ v: Any) -> AttributeValue? {
        if let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { return .bool(b) }
        if let n = v as? NSNumber { return .number(n.doubleValue) }
        if let s = v as? String { return .string(s) }
        return nil
    }

    static func attributes(_ v: Any?) -> [String: AttributeValue] {
        (v as? [String: Any] ?? [:]).compactMapValues(attribute)
    }

    static func period(_ v: Any?) -> Period? {
        if let s = v as? String {
            if s == "lifetime" { return .lifetime }
            return Period.Unit(rawValue: s).map { .every($0) }
        }
        if let o = v as? [String: Any], let unit = (o["unit"] as? String).flatMap(Period.Unit.init(rawValue:)) {
            return .every(unit, count: (o["count"] as? NSNumber)?.intValue ?? 1)
        }
        return nil
    }

    static func product(_ v: Any) -> ProductInfo? {
        guard let o = v as? [String: Any], let price = (o["price"] as? NSNumber)?.doubleValue, let currency = o["currency"] as? String else { return nil }
        let offer = (o["offer"] as? [String: Any]).flatMap { offer -> ProductInfo.Offer? in
            guard let p = (offer["price"] as? NSNumber)?.doubleValue, let period = period(offer["period"]) else { return nil }
            return ProductInfo.Offer(price: p, period: period)
        }
        return ProductInfo(price: price, currency: currency, period: period(o["period"]), title: o["title"] as? String, offer: offer)
    }

    static func position(_ s: String?) -> PresentationPosition? {
        switch s {
        case "top": return .top
        case "bottom": return .bottom
        default: return nil
        }
    }

    static func style(_ o: [String: Any]?) -> PresentationStyle? {
        switch o?["type"] as? String {
        case "fullscreen": return .fullscreen
        case "modal": return .modal
        case "sheet": return .sheet
        case "banner": return .banner(top: (o?["position"] as? String) != "bottom")
        case "toast": return .toast(seconds: (o?["seconds"] as? NSNumber)?.doubleValue ?? 6, top: (o?["position"] as? String) == "top")
        default: return nil
        }
    }

    static func answer(_ a: Flow.Answer) -> Any {
        switch a {
        case let .one(v): return v
        case let .many(vs): return vs
        }
    }

    static func answers(_ a: [String: Flow.Answer]) -> [String: Any] { a.mapValues(answer) }

    static func result(_ r: PurchaseResult) -> [String: Any] {
        switch r {
        case let .purchased(id, a): return ["outcome": "purchased", "packageId": id, "answers": answers(a)]
        case let .restored(a): return ["outcome": "restored", "answers": answers(a)]
        case let .closed(a): return ["outcome": "closed", "answers": answers(a)]
        case let .action(id, a): return ["outcome": "action", "actionId": id, "answers": answers(a)]
        case let .skipped(reason): return ["outcome": "skipped", "reason": reason.rawValue]
        }
    }
}
#endif
