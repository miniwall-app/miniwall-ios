import Foundation

/// Billing period of a product.
public enum Period: Equatable, Sendable {
    case lifetime
    case every(Unit, count: Int = 1)

    public enum Unit: String, CaseIterable, Sendable {
        case day, week, month, year

        var days: Double {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 365.0 / 12
            case .year: return 365
            }
        }

        var abbreviation: String {
            switch self {
            case .day: return "day"
            case .week: return "wk"
            case .month: return "mo"
            case .year: return "yr"
            }
        }

        var periodly: String {
            switch self {
            case .day: return "daily"
            case .week: return "weekly"
            case .month: return "monthly"
            case .year: return "yearly"
            }
        }
    }
}

/// A product's price as the app knows it (StoreKit, its server). Miniwall never charges (D-109):
/// this only fills `{{ product.* }}` texts.
public struct ProductInfo: Equatable, Sendable {
    public var price: Double
    /// ISO 4217 code, any case.
    public var currency: String
    public var period: Period?
    /// Shown by `{{ product.store_product_name }}`.
    public var title: String?
    /// Introductory or trial offer; a free trial has price 0.
    public var offer: Offer?

    public struct Offer: Equatable, Sendable {
        public var price: Double
        public var period: Period
        public init(price: Double, period: Period) {
            self.price = price
            self.period = period
        }
    }

    public init(price: Double, currency: String, period: Period? = nil, title: String? = nil, offer: Offer? = nil) {
        self.price = price
        self.currency = currency
        self.period = period
        self.title = title
        self.offer = offer
    }
}

/// `{{ product.* }}` values per package (Web SDK src/pricing.ts).
public enum Pricing {
    /// `en_US` (paywall JSON) -> Locale; nil -> en_US.
    public static func locale(_ code: String?) -> Locale {
        guard let code, !code.isEmpty else { return Locale(identifier: "en_US") }
        return Locale(identifier: code.replacingOccurrences(of: "-", with: "_"))
    }

    public static func money(_ amount: Double, currency: String, locale: Locale) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency.uppercased()
        f.roundingMode = .halfUp // Intl rounds half away from zero; NumberFormatter defaults to half-even
        return jaYen(f.string(from: NSNumber(value: amount)) ?? "\(amount)", currency: currency, locale: locale)
    }

    /// The web's Intl (and Java) write the yen in Japanese as the full-width sign ￥ (U+FFE5); Apple's data uses ¥ (U+00A5).
    private static func jaYen(_ s: String, currency: String, locale: Locale) -> String {
        guard currency.uppercased() == "JPY", locale.identifier.lowercased().hasPrefix("ja") else { return s }
        return s.replacingOccurrences(of: "\u{00A5}", with: "\u{FFE5}")
    }

    public static func currencySymbol(_ currency: String, locale: Locale) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency.uppercased()
        return jaYen(f.currencySymbol ?? currency, currency: currency, locale: locale)
    }

    private static func jsRound(_ v: Double) -> Int64 { (v + 0.5).rounded(.down).clampedInt64 }

    private static func periodVariables(_ prefix: String, _ period: Period?) -> [String: String] {
        let k = prefix == "product" ? "product." : "product.offer_"
        switch period {
        case nil: return [:]
        case .lifetime?: return ["\(k)period": "lifetime", "\(k)period_abbreviated": "lifetime", "\(k)period_with_unit": "lifetime"]
        case let .every(unit, count)?:
            let days = unit.days * Double(count)
            let plural = count == 1 ? unit.rawValue : "\(unit.rawValue)s"
            var vars = [
                "\(k)period": count == 1 ? unit.rawValue : "\(count) \(plural)",
                "\(k)period_abbreviated": count == 1 ? unit.abbreviation : "\(count) \(unit.abbreviation)",
                "\(k)period_with_unit": "\(count) \(plural)",
                "\(k)period_in_days": String(jsRound(days)),
                "\(k)period_in_weeks": String(jsRound(days / 7)),
                "\(k)period_in_months": String(jsRound(days / Period.Unit.month.days)),
                "\(k)period_in_years": String((days / Period.Unit.year.days).rounded(.down).clampedInt64),
            ]
            if prefix == "product" { vars["product.periodly"] = count == 1 ? unit.periodly : "every \(count) \(plural)" }
            return vars
        }
    }

    private static func pricePerVariables(_ prefix: String, _ price: Double, _ currency: String, _ period: Period?, _ locale: Locale) -> [String: String] {
        guard case let .every(unit, count)? = period else { return [:] }
        let days = unit.days * Double(count)
        let key = prefix == "product" ? "product.price_per_" : "product.offer_price_per_"
        var vars: [String: String] = [:]
        for u in Period.Unit.allCases { vars["\(key)\(u.rawValue)"] = money(price / days * u.days, currency: currency, locale: locale) }
        return vars
    }

    private static func monthlyPrice(_ p: ProductInfo) -> Double? {
        guard case let .every(unit, count)? = p.period else { return nil }
        return p.price / ((unit.days * Double(count)) / Period.Unit.month.days)
    }

    /// The `{{ product.* }}` values per package id. `relative_discount` compares each package's
    /// monthly price with the most expensive package's (annual vs monthly -> "33%").
    public static func productVariables(_ products: [String: ProductInfo], locale code: String?) -> [String: [String: String]] {
        let locale = locale(code)
        let monthly = products.values.compactMap(monthlyPrice)
        let highest = monthly.count > 1 ? monthly.max() : nil
        return products.mapValues { product in
            let price = money(product.price, currency: product.currency, locale: locale)
            let period = periodVariables("product", product.period)
            var vars = [
                "product.price": price,
                "product.currency_code": product.currency.uppercased(),
                "product.currency_symbol": currencySymbol(product.currency, locale: locale),
            ]
            vars.merge(period) { $1 }
            vars.merge(pricePerVariables("product", product.price, product.currency, product.period, locale)) { $1 }
            if let p = period["product.period"] {
                vars["product.price_per_period"] = product.period == .lifetime ? price : "\(price)/\(p)"
                vars["product.price_per_period_abbreviated"] = product.period == .lifetime ? price : "\(price)/\(period["product.period_abbreviated"] ?? p)"
            }
            if let title = product.title { vars["product.store_product_name"] = title }
            if let highest, let own = monthlyPrice(product), own < highest {
                vars["product.relative_discount"] = "\(jsRound((1 - own / highest) * 100))%"
            }
            if let offer = product.offer {
                vars["product.offer_price"] = money(offer.price, currency: product.currency, locale: locale)
                vars.merge(periodVariables("product.offer", offer.period)) { $1 }
                vars.merge(pricePerVariables("product.offer", offer.price, product.currency, offer.period, locale)) { $1 }
            }
            return vars
        }
    }
}
