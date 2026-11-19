import Foundation

enum ProviderAliasStore {
    static func key(for providerID: String) -> String {
        "openusage.providerAlias.\(providerID)"
    }

    static func alias(for providerID: String, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key(for: providerID)) ?? ""
    }

    static func editValue(for provider: Provider, defaults: UserDefaults = .standard) -> String {
        let saved = alias(for: provider.id, defaults: defaults)
        guard saved.isEmpty else { return saved }
        for separator in [": ", " — "] {
            if let range = provider.displayName.range(of: separator) {
                return String(provider.displayName[range.upperBound...])
            }
        }
        return provider.displayName
    }

    static func displayName(for provider: Provider, alias: String) -> String {
        guard !alias.isEmpty else { return provider.displayName }
        for separator in [": ", " — "] {
            if let range = provider.displayName.range(of: separator) {
                return "\(provider.displayName[..<range.lowerBound]): \(alias)"
            }
        }
        return alias == provider.displayName ? alias : "\(provider.displayName): \(alias)"
    }

    static func set(_ alias: String, for providerID: String, defaults: UserDefaults = .standard) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.removeObject(forKey: key(for: providerID))
        } else {
            defaults.set(value, forKey: key(for: providerID))
        }
    }
}
