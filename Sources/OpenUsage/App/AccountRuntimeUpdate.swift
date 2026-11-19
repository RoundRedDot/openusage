import Foundation

/// What an explicit refresh must change in the already-running provider graph.
///
/// The menu-bar app discovers accounts at launch. A later Claude login change has to
/// reach the same stores without rebuilding telemetry, the status item, or the local API.
/// Codex account changes stay on the launch pass.
/// Providers whose account binding did not change keep their instances, so in-memory cooldown,
/// reset-claim ownership, Pi, and Oh My Pi stay put.
@MainActor
enum AccountRuntimeUpdate {
    struct Change {
        var providers: [ProviderRuntime]
        var added: [String]
        var removed: [String]
        var rebound: [String]
        /// Cards whose cached snapshot belongs to a different account than the one now bound there.
        var dropSnapshotIDs: [String]
    }

    static func change(
        current: [ProviderRuntime],
        from previous: ProviderAccountAssembly,
        to next: ProviderAccountAssembly
    ) -> Change? {
        guard previous.claudeCards != next.claudeCards
            || previous.codex != next.codex
            || previous.identityKeysByCard != next.identityKeysByCard
        else { return nil }

        let fresh = ProviderCatalog.make(
            claudeCards: next.claudeCards,
            codex: next.codex,
            claudeIdentityKeys: next.identityKeysByCard
        )
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.provider.id, $0) })
        let freshIDs = Set(fresh.map(\.provider.id))
        let removed = current.map(\.provider.id).filter { !freshIDs.contains($0) }
        var providers: [ProviderRuntime] = []
        providers.reserveCapacity(fresh.count)
        var added: [String] = []
        var rebound: [String] = []
        for provider in fresh {
            let id = provider.provider.id
            if let existing = currentByID[id], !shouldReplace(id, from: previous, to: next) {
                providers.append(existing)
            } else if currentByID[id] != nil {
                providers.append(provider)
                rebound.append(id)
            } else {
                providers.append(provider)
                added.append(id)
            }
        }
        let dropSnapshotIDs = removed + rebound.filter {
            previous.identityKeysByCard[$0] != next.identityKeysByCard[$0]
        }
        return Change(
            providers: providers,
            added: added,
            removed: removed,
            rebound: rebound,
            dropSnapshotIDs: dropSnapshotIDs
        )
    }

    /// Keeps the Codex discovery and Codex identity keys already applied to the running app.
    /// Explicit refresh reads Claude only, so the discovered assembly has an empty Codex side.
    /// Copying the applied side means a Claude change does not rebind Codex or drop its
    /// reset-claim service. `change(from:to:)` still reports a Codex difference when both
    /// assemblies carry the Codex values being compared.
    static func preservingCodex(
        discovered: ProviderAccountAssembly,
        applied: ProviderAccountAssembly
    ) -> ProviderAccountAssembly {
        var keys = discovered.identityKeysByCard.filter { ProviderAccountID.family(of: $0.key) != "codex" }
        for (id, key) in applied.identityKeysByCard where ProviderAccountID.family(of: id) == "codex" {
            keys[id] = key
        }
        return ProviderAccountAssembly(
            identityKeysByCard: keys,
            claudeCards: discovered.claudeCards,
            codex: applied.codex
        )
    }

    /// The local API may return the limits envelope only after every target finished a fetch.
    /// `.refreshed` and `.failed` both finished. A skip, including a force refresh that joined an
    /// in-flight fetch the owner then dropped, must not go out as a 200 of the previous cache.
    static func responseAfterLocalRefresh(
        outcomes: [WidgetDataStore.RefreshOutcome],
        limits: LocalUsageAPI.Response
    ) -> LocalUsageAPI.Response {
        let completed = outcomes.allSatisfy { $0 == .refreshed || $0 == .failed }
        guard completed else {
            return LocalUsageAPI.Response(
                status: 503,
                body: Data(#"{"error":"refresh_incomplete"}"#.utf8)
            )
        }
        return limits
    }

    /// A new account card turns on only when this install has never seen it and the user already
    /// left another card of that family on. A card they previously disabled stays off.
    static func idsToEnable(
        added: [String],
        unseen: Set<String>,
        providerIDs: [String],
        isEnabled: (String) -> Bool
    ) -> [String] {
        added.filter { id in
            guard unseen.contains(id) else { return false }
            let family = ProviderAccountID.family(of: id)
            return providerIDs.contains { other in
                other != id && ProviderAccountID.family(of: other) == family && isEnabled(other)
            }
        }
    }

    /// Cards `openusage --force` asks the running app to fetch.
    ///
    /// A named card is included even when that card is turned off, matching the one-shot reader.
    /// With no name, every enabled card is included. A card whose binding just changed is added only
    /// while it stays enabled, so discovery does not fetch a card the user turned off.
    static func localRefreshTargets(
        orderedIDs: [String],
        requested: Set<String>?,
        changed: Set<String>,
        isEnabled: (String) -> Bool
    ) -> [String] {
        orderedIDs.filter { id in
            let inRequest = requested?.contains(id) ?? isEnabled(id)
            return inRequest || changed.contains(id) && isEnabled(id)
        }
    }

    private static func shouldReplace(
        _ id: String,
        from previous: ProviderAccountAssembly,
        to next: ProviderAccountAssembly
    ) -> Bool {
        if previous.identityKeysByCard[id] != next.identityKeysByCard[id] { return true }
        switch ProviderAccountID.family(of: id) {
        case "claude":
            return claudeSignature(id, previous) != claudeSignature(id, next)
        case "codex":
            return codexSignature(id, previous) != codexSignature(id, next)
        default:
            return false
        }
    }

    private struct ClaudeSignature: Equatable {
        var card: ClaudeAccountCard?
        var cardCount: Int
        var usesPlainProvider: Bool
    }

    private static func claudeSignature(_ id: String, _ assembly: ProviderAccountAssembly) -> ClaudeSignature {
        ClaudeSignature(
            card: assembly.claudeCards.first { $0.id == id },
            cardCount: assembly.claudeCards.count,
            usesPlainProvider: assembly.claudeCards.isEmpty && id == "claude"
        )
    }

    private struct CodexSignature: Equatable {
        var card: CodexAccountCard?
        var plain: CodexAccountDiscovery?
    }

    private static func codexSignature(_ id: String, _ assembly: ProviderAccountAssembly) -> CodexSignature {
        if let card = assembly.codex.cards.first(where: { $0.id == id }) {
            return CodexSignature(card: card, plain: nil)
        }
        if assembly.codex.cards.isEmpty, id == "codex" {
            return CodexSignature(card: nil, plain: assembly.codex)
        }
        return CodexSignature(card: nil, plain: nil)
    }
}
