import XCTest
@testable import OpenUsage

/// Explicit account refresh: the running menu-bar graph, identity isolation, layout, enablement,
/// and the CLI's route onto that graph. Fixtures only — these tests never refresh a real provider
/// and never open the loopback port.
@MainActor
final class AccountLiveRefreshTests: XCTestCase {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "AccountLiveRefresh.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func card(
        id: String,
        identity: String,
        name: String? = nil,
        desktop: Bool = false,
        pi: Bool = true
    ) -> ClaudeAccountCard {
        ClaudeAccountCard(
            id: id,
            identityKey: identity,
            organizationID: nil,
            displayName: name ?? identity,
            usesDesktopCredentials: desktop,
            allowsUnattributedPiUsage: pi
        )
    }

    private func assembly(
        cards: [ClaudeAccountCard] = [],
        identity: [String: String]? = nil,
        codex: CodexAccountDiscovery = CodexAccountDiscovery()
    ) -> ProviderAccountAssembly {
        var assembly = ProviderAccountAssembly(
            identityKeysByCard: identity ?? Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.identityKey) })
        )
        assembly.claudeCards = cards
        assembly.codex = codex
        return assembly
    }

    private func runtime(_ id: String, in providers: [ProviderRuntime]) -> ProviderRuntime? {
        providers.first { $0.provider.id == id }
    }

    func testNoOpDiscoveryDoesNotRebuildProviders() {
        let cards = [card(id: "claude", identity: "user-a|org")]
        let current = assembly(cards: cards)
        XCTAssertNil(AccountRuntimeUpdate.change(current: [], from: current, to: assembly(cards: cards)))
    }

    func testAddingASecondClaudeCardRebindsTheFirstAndKeepsOtherProviders() throws {
        let first = card(id: "claude", identity: "user-a|org-a", pi: true)
        let secondID = ProviderAccountID.make(family: "claude", identityKey: "user-b|org-b")
        let second = card(id: secondID, identity: "user-b|org-b", pi: false)
        let previous = assembly(cards: [first])
        let next = assembly(cards: [
            card(id: "claude", identity: "user-a|org-a", pi: false),
            second,
        ])
        let current = ProviderCatalog.make(claudeCards: previous.claudeCards, claudeIdentityKeys: previous.identityKeysByCard)
        let change = AccountRuntimeUpdate.change(current: current, from: previous, to: next)

        let update = try XCTUnwrap(change)
        XCTAssertEqual(update.added, [secondID])
        XCTAssertEqual(update.removed, [])
        XCTAssertEqual(update.rebound, ["claude"])
        XCTAssertFalse(update.dropSnapshotIDs.contains("claude"))
        XCTAssertFalse(update.dropSnapshotIDs.contains(secondID))
        XCTAssertTrue(runtime("pi", in: current) === runtime("pi", in: update.providers))
        XCTAssertTrue(runtime("omp", in: current) === runtime("omp", in: update.providers))
        XCTAssertFalse(runtime("claude", in: current) === runtime("claude", in: update.providers))
        XCTAssertNotNil(runtime(secondID, in: update.providers))
    }

    func testRemovingACardDropsThatSnapshotAndRebindsTheSurvivor() throws {
        let secondID = ProviderAccountID.make(family: "claude", identityKey: "user-b|org-b")
        let first = card(id: "claude", identity: "user-a|org-a", pi: false)
        let second = card(id: secondID, identity: "user-b|org-b", pi: false)
        let previous = assembly(cards: [first, second])
        let current = ProviderCatalog.make(
            claudeCards: previous.claudeCards,
            claudeIdentityKeys: previous.identityKeysByCard
        )
        // Card count still changes the first card's display and pi attribution, so it rebinds,
        // but the identity key is the same and its snapshot stays.
        let next = assembly(cards: [card(id: "claude", identity: "user-a|org-a", pi: true)])
        let update = try XCTUnwrap(AccountRuntimeUpdate.change(current: current, from: previous, to: next))

        XCTAssertEqual(update.removed, [secondID])
        XCTAssertEqual(update.added, [])
        XCTAssertEqual(update.rebound, ["claude"])
        XCTAssertEqual(update.dropSnapshotIDs, [secondID])
        XCTAssertTrue(runtime("pi", in: current) === runtime("pi", in: update.providers))
        XCTAssertFalse(runtime("claude", in: current) === runtime("claude", in: update.providers))
    }

    func testIdentityChangeDropsTheCardSnapshotAndADisplayNameChangeDoesNot() throws {
        let before = card(id: "claude", identity: "user-a|org", name: "Claude — A")
        let switched = card(id: "claude", identity: "user-b|org", name: "Claude — B")
        let current = ProviderCatalog.make(claudeCards: [before], claudeIdentityKeys: ["claude": before.identityKey])
        let identityChange = try XCTUnwrap(AccountRuntimeUpdate.change(
            current: current,
            from: assembly(cards: [before]),
            to: assembly(cards: [switched])
        ))
        XCTAssertEqual(identityChange.rebound, ["claude"])
        XCTAssertEqual(identityChange.dropSnapshotIDs, ["claude"])
        XCTAssertTrue(runtime("codex", in: current) === runtime("codex", in: identityChange.providers))

        let renamed = card(id: "claude", identity: "user-a|org", name: "Claude — Renamed")
        let sameAccount = try XCTUnwrap(AccountRuntimeUpdate.change(
            current: current,
            from: assembly(cards: [before]),
            to: assembly(cards: [renamed])
        ))
        XCTAssertEqual(sameAccount.rebound, ["claude"])
        XCTAssertTrue(sameAccount.dropSnapshotIDs.isEmpty)
    }

    func testCodexHomeChangeRebindsCodexOnly() throws {
        var codex = CodexAccountDiscovery()
        codex.plainAuthHomes = ["/tmp/openusage-account-live-refresh-fixture"]
        let current = ProviderCatalog.make()
        let update = try XCTUnwrap(AccountRuntimeUpdate.change(
            current: current,
            from: assembly(),
            to: assembly(codex: codex)
        ))

        XCTAssertEqual(update.rebound, ["codex"])
        XCTAssertTrue(update.added.isEmpty)
        XCTAssertTrue(update.removed.isEmpty)
        XCTAssertTrue(update.dropSnapshotIDs.isEmpty)
        XCTAssertFalse(runtime("codex", in: current) === runtime("codex", in: update.providers))
        XCTAssertTrue(runtime("claude", in: current) === runtime("claude", in: update.providers))
        XCTAssertTrue(runtime("pi", in: current) === runtime("pi", in: update.providers))
    }

    func testNewAccountEnablesOnlyWhenItsFamilyIsAlreadyOn() {
        let stored = defaults()
        stored.set(["claude", "cursor"], forKey: "openusage.enabledProviders.v1")
        let store = ProviderEnablementStore(defaults: stored)
        let knownDisabled = ProviderAccountID.make(family: "claude", identityKey: "known-off")
        let fresh = ProviderAccountID.make(family: "claude", identityKey: "fresh")
        _ = store.registerKnownProviders(["claude", "cursor", knownDisabled])
        store.setEnabled(false, for: knownDisabled)

        let unseen = store.registerKnownProviders([fresh])
        let ids = AccountRuntimeUpdate.idsToEnable(
            added: [knownDisabled, fresh, "omp"],
            unseen: unseen,
            providerIDs: ["claude", knownDisabled, fresh, "cursor", "omp"],
            isEnabled: store.isEnabled
        )
        XCTAssertEqual(ids, [fresh])

        var changes = 0
        store.onChange = { changes += 1 }
        store.onProviderEnabled = { _ in XCTFail("explicit discovery must not wake the periodic loop") }
        let wake = expectation(description: "enablement wake")
        wake.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: ProviderEnablementStore.didChangeNotification, object: nil, queue: nil
        ) { _ in wake.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.enableDiscoveredAccounts(ids)
        wait(for: [wake], timeout: 0.2)

        XCTAssertEqual(changes, 1)
        XCTAssertTrue(store.isEnabled(fresh))
        XCTAssertFalse(store.isEnabled(knownDisabled))
        XCTAssertFalse(store.isEnabled("omp"))
        let reloaded = ProviderEnablementStore(defaults: stored)
        XCTAssertTrue(reloaded.isEnabled(fresh))
        XCTAssertFalse(reloaded.isEnabled(knownDisabled))
    }

    func testLegacyEnablementLeavesDiscoveryAsANoOp() {
        let store = ProviderEnablementStore(defaults: defaults())
        XCTAssertNil(store.enabledIDs)
        let fresh = ProviderAccountID.make(family: "claude", identityKey: "fresh")
        XCTAssertTrue(store.isEnabled(fresh))
        store.enableDiscoveredAccounts([fresh])
        XCTAssertNil(store.enabledIDs)
    }

    func testLayoutKeepsChoicesAndSeedsANewCardBesideItsFamily() {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let pi = Provider(id: "pi", displayName: "pi", icon: .providerMark("pi"))
        let secondID = ProviderAccountID.make(family: "claude", identityKey: "user-b|org-b")
        let second = Provider(id: secondID, displayName: "Claude — B", icon: .providerMark("claude"))
        func metrics(_ provider: Provider) -> [WidgetDescriptor] {
            [
                .percent(id: "\(provider.id).session", provider: provider, title: "Session"),
                .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly"),
            ]
        }
        let original = WidgetRegistry(
            providers: [claude, pi],
            descriptors: metrics(claude) + [.percent(id: "pi.trend", provider: pi, title: "Usage Trend")]
        )
        let layout = LayoutStore(registry: original, defaults: stored, storageKey: "layout")
        layout.setMetricEnabled("claude.weekly", false)
        layout.setPinned(true, for: "pi.trend")
        XCTAssertTrue(layout.reorderProvider(dragged: "pi", target: "claude"))

        let expanded = WidgetRegistry(
            providers: [claude, pi, second],
            descriptors: original.descriptors + metrics(second)
        )
        layout.customizeProviderID = secondID
        layout.adoptDiscoveredProviders(expanded)
        layout.adoptDiscoveredProviders(expanded)

        XCTAssertEqual(layout.orderedProviderIDs(), ["pi", "claude", secondID])
        XCTAssertFalse(layout.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(layout.isPinned("claude.session"))
        XCTAssertTrue(layout.isPinned("pi.trend"))
        XCTAssertTrue(layout.isMetricEnabled("\(secondID).session"))
        XCTAssertTrue(layout.isMetricEnabled("\(secondID).weekly"))
        XCTAssertTrue(layout.isPinned("\(secondID).session"))
        XCTAssertTrue(layout.isPinned("\(secondID).weekly"))
        XCTAssertEqual(layout.displayGroups.map(\.provider.id), ["pi", "claude", secondID])

        let reloaded = LayoutStore(registry: expanded, defaults: stored, storageKey: "layout")
        XCTAssertEqual(reloaded.orderedProviderIDs(), ["pi", "claude", secondID])
        XCTAssertFalse(reloaded.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(reloaded.isPinned("pi.trend"))
        XCTAssertTrue(reloaded.isMetricEnabled("\(secondID).session"))

        reloaded.customizeProviderID = secondID
        let back = WidgetRegistry(providers: [claude, pi], descriptors: original.descriptors)
        reloaded.adoptDiscoveredProviders(back)
        XCTAssertNil(reloaded.customizeProviderID)
        XCTAssertFalse(reloaded.displayGroups.contains { $0.provider.id == secondID })
        XCTAssertFalse(reloaded.pinnedGroups.contains { $0.provider.id == secondID })
        XCTAssertTrue(reloaded.pinnedMetricIDs.contains("\(secondID).session"))
        XCTAssertTrue(reloaded.providerOrder.contains(secondID))

        reloaded.providerOrder = [secondID, "pi", "claude"]
        reloaded.persistProviderOrder()
        reloaded.adoptDiscoveredProviders(expanded)
        XCTAssertEqual(reloaded.orderedProviderIDs(), [secondID, "pi", "claude"])

        layout.resetToDefault()
        XCTAssertEqual(layout.placed.filter { $0.descriptorID == "\(secondID).session" }.count, 1)
    }

    func testReturningCardKeepsOptedOutMetricsAndPins() {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let pi = Provider(id: "pi", displayName: "pi", icon: .providerMark("pi"))
        let secondID = ProviderAccountID.make(family: "claude", identityKey: "user-b|org-b")
        let second = Provider(id: secondID, displayName: "Claude — B", icon: .providerMark("claude"))
        func metrics(_ provider: Provider) -> [WidgetDescriptor] {
            [
                .percent(id: "\(provider.id).session", provider: provider, title: "Session"),
                .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly"),
            ]
        }
        let original = WidgetRegistry(
            providers: [claude, pi],
            descriptors: metrics(claude) + [.percent(id: "pi.trend", provider: pi, title: "Usage Trend")]
        )
        let layout = LayoutStore(registry: original, defaults: stored, storageKey: "layout-opt-out")
        layout.setMetricEnabled("claude.session", false)
        layout.setMetricEnabled("claude.weekly", false)
        layout.setPinned(false, for: "claude.session")
        layout.setPinned(false, for: "claude.weekly")
        XCTAssertFalse(layout.isMetricEnabled("claude.session"))
        XCTAssertFalse(layout.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(layout.isPinned("claude.session"))
        XCTAssertFalse(layout.isPinned("claude.weekly"))

        let removed = WidgetRegistry(
            providers: [pi],
            descriptors: [.percent(id: "pi.trend", provider: pi, title: "Usage Trend")]
        )
        layout.adoptDiscoveredProviders(removed)
        XCTAssertFalse(layout.orderedProviderIDs().contains("claude"))
        XCTAssertTrue(layout.providerOrder.contains("claude"))

        let returned = WidgetRegistry(
            providers: [claude, pi, second],
            descriptors: metrics(claude) + metrics(second) + [.percent(id: "pi.trend", provider: pi, title: "Usage Trend")]
        )
        layout.adoptDiscoveredProviders(returned)

        XCTAssertFalse(layout.isMetricEnabled("claude.session"))
        XCTAssertFalse(layout.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(layout.isPinned("claude.session"))
        XCTAssertFalse(layout.isPinned("claude.weekly"))
        XCTAssertTrue(layout.isMetricEnabled("\(secondID).session"))
        XCTAssertTrue(layout.isMetricEnabled("\(secondID).weekly"))
        XCTAssertTrue(layout.isPinned("\(secondID).session"))
        XCTAssertTrue(layout.isPinned("\(secondID).weekly"))
        XCTAssertEqual(layout.orderedProviderIDs(), ["claude", secondID, "pi"])

        let reloaded = LayoutStore(registry: returned, defaults: stored, storageKey: "layout-opt-out")
        XCTAssertFalse(reloaded.isMetricEnabled("claude.session"))
        XCTAssertFalse(reloaded.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(reloaded.isPinned("claude.session"))
        XCTAssertFalse(reloaded.isPinned("claude.weekly"))
        XCTAssertTrue(reloaded.isMetricEnabled("\(secondID).session"))
        XCTAssertTrue(reloaded.isPinned("\(secondID).weekly"))
    }

    /// A saved card can leave, the app can launch again without it, and an unrelated edit can
    /// rewrite the layout before the card comes back. The choices made while it was present —
    /// including a second card with every metric and pin turned off — come back unchanged, and
    /// the absent cards stay off the dashboard in the meantime.
    func testAbsentCardLayoutSurvivesRelaunchAndUnrelatedEdits() {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let quietID = ProviderAccountID.make(family: "claude", identityKey: "quiet-user|quiet-org")
        let quiet = Provider(id: quietID, displayName: "Claude — Quiet", icon: .providerMark("claude"))
        let pi = Provider(id: "pi", displayName: "pi", icon: .providerMark("pi"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        func accountMetrics(_ provider: Provider) -> [WidgetDescriptor] {
            [
                .percent(id: "\(provider.id).session", provider: provider, title: "Session"),
                .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly"),
                .percent(id: "\(provider.id).extra", provider: provider, title: "Extra"),
            ]
        }
        let piMetrics: [WidgetDescriptor] = [
            .percent(id: "pi.session", provider: pi, title: "Session"),
            .percent(id: "pi.weekly", provider: pi, title: "Weekly"),
        ]
        let codexMetrics: [WidgetDescriptor] = [
            .percent(id: "codex.session", provider: codex, title: "Session"),
            .percent(id: "codex.weekly", provider: codex, title: "Weekly"),
        ]
        let full = WidgetRegistry(
            providers: [claude, quiet, pi, codex],
            descriptors: accountMetrics(claude) + accountMetrics(quiet) + piMetrics + codexMetrics
        )
        let absent = WidgetRegistry(providers: [pi, codex], descriptors: piMetrics + codexMetrics)
        let defaultMetrics = [
            "claude.session", "claude.weekly",
            "\(quietID).session", "\(quietID).weekly",
            "pi.session", "pi.weekly", "codex.session", "codex.weekly",
        ]
        let original = LayoutStore(
            registry: full,
            defaults: stored,
            storageKey: "layout-absent",
            defaultMetricIDs: defaultMetrics,
            migrationBaselineMetricIDs: defaultMetrics,
            defaultPinnedMetricIDs: ["claude.session", "\(quietID).session", "pi.session", "codex.session"],
            defaultExpandedMetricIDs: ["claude.weekly", "\(quietID).weekly"]
        )

        original.setMetricEnabled("claude.session", false)
        original.setMetricEnabled("claude.extra", true)
        original.setPinned(false, for: "claude.session")
        original.setPinned(true, for: "claude.weekly")
        original.setPinned(true, for: "claude.extra")
        XCTAssertTrue(original.applyMetricDividerOrder(
            ["claude.extra", "claude.session", "claude::divider", "claude.weekly"],
            dragged: "claude.extra",
            dividerID: "claude::divider",
            in: "claude"
        ))
        XCTAssertTrue(original.setProviderExpanded(true, for: "claude"))

        original.setMetricEnabled("\(quietID).session", false)
        original.setMetricEnabled("\(quietID).weekly", false)
        original.setMetricEnabled("\(quietID).extra", false)
        original.setPinned(false, for: "\(quietID).session")
        XCTAssertTrue(original.applyMetricDividerOrder(
            ["\(quietID).weekly", "\(quietID).extra", "\(quietID)::divider", "\(quietID).session"],
            dragged: "\(quietID).session",
            dividerID: "\(quietID)::divider",
            in: quietID
        ))
        XCTAssertTrue(original.reorderProvider(dragged: "pi", target: quietID))

        let claudeOrder = ["claude.extra", "claude.session", "claude.weekly"]
        let quietOrder = ["\(quietID).weekly", "\(quietID).extra", "\(quietID).session"]
        let providerOrder = ["claude", "pi", quietID, "codex"]
        XCTAssertEqual(original.metricOrder(for: "claude"), claudeOrder)
        XCTAssertEqual(original.metricOrder(for: quietID), quietOrder)
        XCTAssertEqual(original.providerOrder, providerOrder)
        XCTAssertEqual(
            original.placed.map(\.descriptorID).filter { $0.hasPrefix("claude.") },
            ["claude.extra", "claude.weekly"]
        )
        XCTAssertFalse(original.placed.contains { $0.descriptorID.hasPrefix("\(quietID).") })
        XCTAssertEqual(
            Set(original.pinnedMetricIDs.filter { $0.hasPrefix("claude.") || $0.hasPrefix("\(quietID).") }),
            ["claude.extra", "claude.weekly"]
        )
        XCTAssertTrue(original.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertTrue(original.expandedMetricIDs.contains("\(quietID).session"))
        XCTAssertFalse(original.expandedMetricIDs.contains("\(quietID).weekly"))
        XCTAssertTrue(original.isProviderExpanded("claude"))

        let relaunched = LayoutStore(
            registry: absent,
            defaults: stored,
            storageKey: "layout-absent",
            defaultMetricIDs: defaultMetrics,
            migrationBaselineMetricIDs: defaultMetrics,
            defaultPinnedMetricIDs: ["claude.session", "\(quietID).session", "pi.session", "codex.session"],
            defaultExpandedMetricIDs: ["claude.weekly", "\(quietID).weekly"]
        )
        XCTAssertEqual(relaunched.orderedProviderIDs(), ["pi", "codex"])
        XCTAssertEqual(Set(relaunched.displayGroups.map(\.provider.id)), ["pi", "codex"])
        XCTAssertEqual(Set(relaunched.pinnedGroups.map(\.provider.id)), ["pi", "codex"])
        XCTAssertEqual(Set(relaunched.customizeProviderRows.map(\.provider.id)), ["pi", "codex"])
        XCTAssertNil(relaunched.customizeDetail(for: "claude"))
        XCTAssertNil(relaunched.customizeDetail(for: quietID))

        relaunched.setMetricEnabled("codex.weekly", false)
        relaunched.setPinned(false, for: "pi.session")
        relaunched.setPinned(true, for: "pi.weekly")
        XCTAssertTrue(relaunched.applyMetricDividerOrder(
            ["pi.session", "pi::divider", "pi.weekly"],
            dragged: "pi.weekly",
            dividerID: "pi::divider",
            in: "pi"
        ))
        XCTAssertTrue(relaunched.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(relaunched.reorderProvider(dragged: "codex", target: "pi"))
        XCTAssertEqual(Set(relaunched.displayGroups.map(\.provider.id)), ["pi", "codex"])
        XCTAssertFalse(relaunched.displayGroups.contains { $0.provider.id == "claude" || $0.provider.id == quietID })

        relaunched.adoptDiscoveredProviders(full)
        let returnedOrder = ["claude", "codex", quietID, "pi"]
        assertRestoredAbsentCards(
            relaunched,
            quietID: quietID,
            claudeOrder: claudeOrder,
            quietOrder: quietOrder,
            providerOrder: returnedOrder
        )
        XCTAssertFalse(relaunched.isMetricEnabled("codex.weekly"))
        XCTAssertFalse(relaunched.isPinned("pi.session"))
        XCTAssertTrue(relaunched.isPinned("pi.weekly"))
        XCTAssertEqual(relaunched.metricOrder(for: "pi"), ["pi.session", "pi.weekly"])
        XCTAssertTrue(relaunched.expandedMetricIDs.contains("pi.weekly"))
        XCTAssertTrue(relaunched.isProviderExpanded("codex"))

        let persisted = LayoutStore(
            registry: full,
            defaults: stored,
            storageKey: "layout-absent",
            defaultMetricIDs: defaultMetrics,
            migrationBaselineMetricIDs: defaultMetrics,
            defaultPinnedMetricIDs: ["claude.session", "\(quietID).session", "pi.session", "codex.session"],
            defaultExpandedMetricIDs: ["claude.weekly", "\(quietID).weekly"]
        )
        assertRestoredAbsentCards(
            persisted,
            quietID: quietID,
            claudeOrder: claudeOrder,
            quietOrder: quietOrder,
            providerOrder: returnedOrder
        )
        XCTAssertFalse(persisted.isMetricEnabled("codex.weekly"))
        XCTAssertTrue(persisted.isPinned("pi.weekly"))
        XCTAssertTrue(persisted.expandedMetricIDs.contains("pi.weekly"))
        XCTAssertFalse(persisted.isMetricEnabled("claude.session"))
        XCTAssertFalse(persisted.isMetricEnabled("\(quietID).session"))
        XCTAssertFalse(persisted.isMetricEnabled("\(quietID).weekly"))
        XCTAssertFalse(persisted.isMetricEnabled("\(quietID).extra"))
    }

    /// Turning every default metric and pin off, without ever reordering, is still a saved choice.
    /// A later launch that does not see the card must not treat it as new and put the defaults back.
    func testAllOffCardIsNotReseededAfterRelaunchWhileAbsent() {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let pi = Provider(id: "pi", displayName: "pi", icon: .providerMark("pi"))
        let full = WidgetRegistry(
            providers: [claude, pi],
            descriptors: [
                .percent(id: "claude.session", provider: claude, title: "Session"),
                .percent(id: "claude.weekly", provider: claude, title: "Weekly"),
                .percent(id: "pi.session", provider: pi, title: "Session"),
            ]
        )
        let absent = WidgetRegistry(
            providers: [pi],
            descriptors: [.percent(id: "pi.session", provider: pi, title: "Session")]
        )
        let original = LayoutStore(
            registry: full,
            defaults: stored,
            storageKey: "layout-all-off",
            defaultMetricIDs: ["claude.session", "claude.weekly", "pi.session"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly", "pi.session"],
            defaultPinnedMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        original.setMetricEnabled("claude.session", false)
        original.setMetricEnabled("claude.weekly", false)
        original.setPinned(false, for: "claude.session")
        original.setPinned(false, for: "claude.weekly")
        XCTAssertFalse(original.placed.contains { $0.descriptorID.hasPrefix("claude.") })
        XCTAssertFalse(original.pinnedMetricIDs.contains { $0.hasPrefix("claude.") })

        let relaunched = LayoutStore(
            registry: absent,
            defaults: stored,
            storageKey: "layout-all-off",
            defaultMetricIDs: ["claude.session", "claude.weekly", "pi.session"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly", "pi.session"],
            defaultPinnedMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertFalse(relaunched.orderedProviderIDs().contains("claude"))
        XCTAssertFalse(relaunched.displayGroups.contains { $0.provider.id == "claude" })
        relaunched.setPinned(true, for: "pi.session")
        relaunched.adoptDiscoveredProviders(full)

        XCTAssertFalse(relaunched.isMetricEnabled("claude.session"))
        XCTAssertFalse(relaunched.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(relaunched.isPinned("claude.session"))
        XCTAssertFalse(relaunched.isPinned("claude.weekly"))
        XCTAssertTrue(relaunched.isPinned("pi.session"))
        XCTAssertEqual(relaunched.orderedProviderIDs().filter { $0 == "claude" }.count, 1)

        let persisted = LayoutStore(
            registry: full,
            defaults: stored,
            storageKey: "layout-all-off",
            defaultMetricIDs: ["claude.session", "claude.weekly", "pi.session"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly", "pi.session"],
            defaultPinnedMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertFalse(persisted.isMetricEnabled("claude.session"))
        XCTAssertFalse(persisted.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(persisted.isPinned("claude.session"))
        XCTAssertFalse(persisted.isPinned("claude.weekly"))
        XCTAssertTrue(persisted.isPinned("pi.session"))
    }

    private func assertRestoredAbsentCards(
        _ layout: LayoutStore,
        quietID: String,
        claudeOrder: [String],
        quietOrder: [String],
        providerOrder: [String]
    ) {
        XCTAssertEqual(layout.providerOrder, providerOrder)
        XCTAssertEqual(layout.orderedProviderIDs(), providerOrder)
        XCTAssertEqual(layout.metricOrder(for: "claude"), claudeOrder)
        XCTAssertEqual(layout.metricOrder(for: quietID), quietOrder)
        XCTAssertEqual(
            layout.placed.map(\.descriptorID).filter { $0.hasPrefix("claude.") },
            ["claude.extra", "claude.weekly"]
        )
        XCTAssertFalse(layout.placed.contains { $0.descriptorID.hasPrefix("\(quietID).") })
        XCTAssertFalse(layout.isMetricEnabled("claude.session"))
        XCTAssertTrue(layout.isMetricEnabled("claude.extra"))
        XCTAssertTrue(layout.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(layout.isMetricEnabled("\(quietID).session"))
        XCTAssertFalse(layout.isMetricEnabled("\(quietID).weekly"))
        XCTAssertFalse(layout.isMetricEnabled("\(quietID).extra"))
        XCTAssertEqual(
            Set(layout.pinnedMetricIDs.filter { $0.hasPrefix("claude.") || $0.hasPrefix("\(quietID).") }),
            ["claude.extra", "claude.weekly"]
        )
        XCTAssertTrue(layout.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertFalse(layout.expandedMetricIDs.contains("claude.extra"))
        XCTAssertFalse(layout.expandedMetricIDs.contains("claude.session"))
        XCTAssertTrue(layout.expandedMetricIDs.contains("\(quietID).session"))
        XCTAssertFalse(layout.expandedMetricIDs.contains("\(quietID).weekly"))
        XCTAssertTrue(layout.isProviderExpanded("claude"))
        XCTAssertEqual(
            layout.displayGroups.map(\.provider.id),
            providerOrder.filter { $0 != quietID }
        )
        XCTAssertFalse(layout.displayGroups.contains { $0.provider.id == quietID })
        XCTAssertTrue(layout.customizeProviderRows.contains { $0.provider.id == quietID })
    }

    func testStaleInFlightRefreshCannotPublishOrClearTheReplacement() async {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let registry = WidgetRegistry(providers: [claude], descriptors: [])
        let old = GateProvider(provider: claude, displayName: "Old", used: 1)
        let replacement = GateProvider(provider: claude, displayName: "New", used: 9)
        let cache = ProviderSnapshotCache(userDefaults: stored)
        let store = WidgetDataStore(
            registry: registry,
            providers: [old],
            cache: cache,
            defaults: stored,
            providerIdentityKeys: ["claude": "old-user"]
        )
        defer {
            old.resume()
            replacement.resume()
        }

        let stale = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { old.starts == 1 }
        store.installAccountRuntimes(
            registry: registry,
            providers: [replacement],
            identityKeys: ["claude": "new-user"],
            invalidateIDs: ["claude"],
            dropSnapshotIDs: ["claude"]
        )
        let fresh = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { replacement.starts == 1 }
        XCTAssertTrue(store.refreshingProviderIDs.contains("claude"))

        old.resume()
        let staleOutcome = await stale.value
        XCTAssertEqual(staleOutcome, .skipped)
        XCTAssertTrue(store.refreshingProviderIDs.contains("claude"))
        XCTAssertNil(store.localSnapshots["claude"])
        XCTAssertNil(cache.producedByIdentityKey(providerID: "claude"))

        replacement.resume()
        let freshOutcome = await fresh.value
        XCTAssertEqual(freshOutcome, .refreshed)
        XCTAssertFalse(store.refreshingProviderIDs.contains("claude"))
        XCTAssertEqual(store.localSnapshots["claude"]?.displayName, "New")
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "claude"), "new-user")
        XCTAssertEqual(cache.snapshot(providerID: "claude")?.displayName, "New")
    }

    func testSameGenerationNonForceRefreshIsSkippedUntilTheEpochMoves() async {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let gate = GateProvider(provider: claude, displayName: "Live", used: 3)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [claude], descriptors: []),
            providers: [gate],
            defaults: defaults()
        )
        defer { gate.resume() }
        let first = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { gate.starts == 1 }
        let second = await store.refresh(providerID: "claude", force: false)
        XCTAssertEqual(second, .skipped)
        XCTAssertEqual(gate.starts, 1)
        XCTAssertEqual(store.inflightJoinCount(for: "claude"), 0)
        gate.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .refreshed)
    }

    func testForceRefreshJoinsTheInFlightFetchInsteadOfReturningTheOldCache() async {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let cache = ProviderSnapshotCache(userDefaults: stored)
        cache.store(snapshot(claude, name: "Old", used: 1))
        let gate = GateProvider(provider: claude, displayName: "Live", used: 9)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [claude], descriptors: []),
            providers: [gate],
            cache: cache,
            defaults: stored
        )
        defer { gate.resume() }
        XCTAssertEqual(store.localSnapshots["claude"]?.displayName, "Old")

        let owner = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { gate.starts == 1 }
        var joinedOutcome: WidgetDataStore.RefreshOutcome?
        let joined = Task { @MainActor in
            let outcome = await store.refresh(providerID: "claude", force: true)
            joinedOutcome = outcome
            return (outcome, store.localSnapshots["claude"]?.displayName)
        }
        await waitUntil { store.inflightJoinCount(for: "claude") == 1 }
        XCTAssertNil(joinedOutcome)
        XCTAssertEqual(store.localSnapshots["claude"]?.displayName, "Old")
        XCTAssertEqual(gate.starts, 1)

        gate.resume()
        let ownerOutcome = await owner.value
        let (joinedResult, joinedName) = await joined.value
        XCTAssertEqual(ownerOutcome, .refreshed)
        XCTAssertEqual(joinedResult, .refreshed)
        XCTAssertEqual(joinedOutcome, .refreshed)
        XCTAssertEqual(joinedName, "Live")
        XCTAssertEqual(store.localSnapshots["claude"]?.displayName, "Live")
        XCTAssertEqual(gate.starts, 1)
    }

    func testForceJoinOfAStaleFetchDoesNotReportTheOldCacheAsFresh() async {
        let stored = defaults()
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let registry = WidgetRegistry(providers: [claude], descriptors: [])
        let cache = ProviderSnapshotCache(userDefaults: stored)
        cache.store(snapshot(claude, name: "Old", used: 1))
        let gate = GateProvider(provider: claude, displayName: "Live", used: 9)
        let replacement = GateProvider(provider: claude, displayName: "Replacement", used: 4)
        let store = WidgetDataStore(
            registry: registry,
            providers: [gate],
            cache: cache,
            defaults: stored,
            providerIdentityKeys: ["claude": "old-user"]
        )
        defer {
            gate.resume()
            replacement.resume()
        }
        let owner = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { gate.starts == 1 }
        let joined = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { store.inflightJoinCount(for: "claude") == 1 }

        store.installAccountRuntimes(
            registry: registry,
            providers: [replacement],
            identityKeys: ["claude": "new-user"],
            invalidateIDs: ["claude"],
            dropSnapshotIDs: ["claude"]
        )
        XCTAssertNil(store.localSnapshots["claude"])
        gate.resume()
        let ownerOutcome = await owner.value
        let joinedOutcome = await joined.value
        XCTAssertEqual(ownerOutcome, .skipped)
        XCTAssertEqual(joinedOutcome, .skipped)
        XCTAssertNil(store.localSnapshots["claude"])
        XCTAssertEqual(gate.starts, 1)
        XCTAssertEqual(replacement.starts, 0)
    }

    func testLocalRefreshOverlapsSlowProviders() async {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let claudeGate = GateProvider(provider: claude, displayName: "Claude", used: 1)
        let codexGate = GateProvider(provider: codex, displayName: "Codex", used: 2)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [claude, codex], descriptors: []),
            providers: [claudeGate, codexGate],
            defaults: defaults(),
            isProviderEnabled: { $0 == "claude" }
        )
        defer {
            claudeGate.resume()
            codexGate.resume()
        }
        let batch = Task {
            await store.refreshIDs(["claude", "codex"], force: true) { id in id != "codex" }
        }
        await waitUntil { claudeGate.starts == 1 && codexGate.starts == 1 }
        XCTAssertEqual(claudeGate.starts, 1)
        XCTAssertEqual(codexGate.starts, 1)
        claudeGate.resume()
        codexGate.resume()
        let outcomes = await batch.value
        XCTAssertEqual(outcomes, [.refreshed, .refreshed])
    }

    func testRemovingACardClearsItsSpinnerAndSameIdentityRebindKeepsTheSnapshot() async {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let registry = WidgetRegistry(providers: [claude], descriptors: [])
        let gate = GateProvider(provider: claude, displayName: "Old", used: 1)
        let store = WidgetDataStore(
            registry: registry,
            providers: [gate],
            defaults: defaults(),
            providerIdentityKeys: ["claude": "user-a"]
        )
        defer { gate.resume() }
        let hung = Task { await store.refresh(providerID: "claude", force: true) }
        await waitUntil { gate.starts == 1 }
        XCTAssertTrue(store.refreshingProviderIDs.contains("claude"))
        store.installAccountRuntimes(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            identityKeys: [:],
            invalidateIDs: ["claude"],
            dropSnapshotIDs: ["claude"]
        )
        XCTAssertFalse(store.refreshingProviderIDs.contains("claude"))
        gate.resume()
        let removedOutcome = await hung.value
        XCTAssertEqual(removedOutcome, .skipped)

        let kept = CountingProviderRuntime(
            provider: claude,
            descriptors: [],
            snapshot: snapshot(claude, name: "Kept", used: 4)
        )
        let reboundStore = WidgetDataStore(
            registry: registry,
            providers: [kept],
            cache: ProviderSnapshotCache(userDefaults: defaults()),
            defaults: defaults(),
            providerIdentityKeys: ["claude": "user-a"]
        )
        let keptOutcome = await reboundStore.refresh(providerID: "claude", force: true)
        XCTAssertEqual(keptOutcome, .refreshed)
        let replacement = CountingProviderRuntime(
            provider: claude,
            descriptors: [],
            snapshot: snapshot(claude, name: "Rebound", used: 8)
        )
        reboundStore.installAccountRuntimes(
            registry: registry,
            providers: [replacement],
            identityKeys: ["claude": "user-a"],
            invalidateIDs: ["claude"],
            dropSnapshotIDs: []
        )
        XCTAssertEqual(reboundStore.localSnapshots["claude"]?.displayName, "Kept")
        let reboundOutcome = await reboundStore.refresh(providerID: "claude", force: true)
        XCTAssertEqual(reboundOutcome, .refreshed)
        XCTAssertEqual(replacement.refreshCount, 1)
        XCTAssertEqual(reboundStore.localSnapshots["claude"]?.displayName, "Rebound")
        XCTAssertEqual(reboundStore.snapshots["claude"]?.displayName, "Rebound")
    }

    func testUserRefreshFetchesTheNamedCardAndChangedCards() async {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let pi = Provider(id: "pi", displayName: "pi", icon: .providerMark("pi"))
        let claudeRuntime = CountingProviderRuntime(provider: claude, descriptors: [], snapshot: snapshot(claude, name: "Claude", used: 1))
        let codexRuntime = CountingProviderRuntime(provider: codex, descriptors: [], snapshot: snapshot(codex, name: "Codex", used: 1))
        let piRuntime = CountingProviderRuntime(provider: pi, descriptors: [], snapshot: snapshot(pi, name: "pi", used: 1))
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [claude, codex, pi], descriptors: []),
            providers: [claudeRuntime, codexRuntime, piRuntime],
            defaults: defaults(),
            isProviderEnabled: { $0 != "codex" }
        )
        store.prepareUserRefresh = { ["codex", "claude"] }
        await store.refreshOnUserRequest(providerID: "claude")
        XCTAssertEqual(claudeRuntime.refreshCount, 1)
        XCTAssertEqual(codexRuntime.refreshCount, 0)
        XCTAssertEqual(piRuntime.refreshCount, 0)

        let forced = await store.refresh(providerID: "codex", force: true, requireEnabled: false)
        XCTAssertEqual(forced, .refreshed)
        XCTAssertEqual(codexRuntime.refreshCount, 1)
    }

    func testRunningAppRouteClassifiesOnlyTheExplicitRefresh() {
        XCTAssertEqual(LocalUsageServer.action(for: head("POST /v1/refresh HTTP/1.1", ["X-OpenUsage-Refresh": "1"])), .refresh(nil))
        XCTAssertEqual(
            LocalUsageServer.action(for: head("POST /v1/refresh/claude HTTP/1.1", ["x-openusage-refresh": "1"])),
            .refresh("claude")
        )
        XCTAssertEqual(
            LocalUsageServer.action(for: head("POST /v1/refresh/claude@ab12cd34 HTTP/1.1", ["X-OpenUsage-Refresh": "1"])),
            .refresh("claude@ab12cd34")
        )
        XCTAssertEqual(
            LocalUsageServer.action(for: head("POST /v1/refresh?unused=1 HTTP/1.1", ["X-OpenUsage-Refresh": "1"])),
            .refresh(nil)
        )
        XCTAssertEqual(LocalUsageServer.action(for: head("POST /v1/refresh HTTP/1.1")), .rejectMethod)
        XCTAssertEqual(LocalUsageServer.action(for: head("POST /v1/refresh HTTP/1.1", ["X-OpenUsage-Refresh": "0"])), .rejectMethod)
        XCTAssertEqual(LocalUsageServer.action(for: head("GET /v1/refresh HTTP/1.1", ["X-OpenUsage-Refresh": "1"])), .rejectMethod)
        XCTAssertEqual(LocalUsageServer.action(for: head("GET /v1/limits HTTP/1.1")), .respond(method: "GET", path: "/v1/limits"))
        XCTAssertEqual(LocalUsageServer.action(for: head("OPTIONS /v1/limits HTTP/1.1")), .respond(method: "OPTIONS", path: "/v1/limits"))
    }

    func testLocalRefreshTargetsIncludeANamedDisabledCardAndEnabledChanges() {
        let second = ProviderAccountID.make(family: "claude", identityKey: "second")
        let ordered = ["claude", second, "codex", "pi"]
        let enabled: (String) -> Bool = { $0 == "claude" || $0 == "codex" }
        XCTAssertEqual(
            AccountRuntimeUpdate.localRefreshTargets(
                orderedIDs: ordered, requested: [second], changed: ["codex", "pi"], isEnabled: enabled
            ),
            [second, "codex"]
        )
        XCTAssertEqual(
            AccountRuntimeUpdate.localRefreshTargets(
                orderedIDs: ordered, requested: nil, changed: ["pi"], isEnabled: enabled
            ),
            ["claude", "codex"]
        )
    }

    func testForceReadUsesTheRunningAppAndInjectedProvidersDoNot() async throws {
        let stored = defaults()
        let body = Data(#"{"errors":[{"providerId":"claude","message":"Not logged in"}]}"#.utf8)
        var requested: String?
        let attached = UsageReader(userDefaults: stored) { id in
            requested = id
            return .handled(UsageReadResult(data: body, warnings: RunningAppRefreshClient.warnings(in: body)))
        }
        let handled = try await attached.read(providerID: "claude", force: true)
        XCTAssertEqual(requested, "claude")
        XCTAssertEqual(handled.data, body)
        XCTAssertEqual(handled.warnings, ["claude: Not logged in"])

        let missing = UsageReader(userDefaults: stored) { _ in .unknownProvider("missing") }
        do {
            _ = try await missing.read(providerID: "missing", force: true)
            XCTFail("expected the running app's unknown provider")
        } catch UsageReaderError.unknownProvider(let id) {
            XCTAssertEqual(id, "missing")
        }

        let provider = Provider(id: "stub", displayName: "Stub", icon: .providerMark("stub"))
        let runtime = CountingProviderRuntime(provider: provider, descriptors: [], snapshot: snapshot(provider, name: "Stub", used: 2))
        let cache = ProviderSnapshotCache(userDefaults: stored)
        cache.store(runtime.snapshot)
        var delegated = 0
        let isolated = UsageReader(userDefaults: stored, providers: [runtime]) { _ in
            delegated += 1
            return .unavailable
        }
        _ = try await isolated.read(providerID: "stub")
        _ = try await isolated.read(providerID: "stub", force: true)
        XCTAssertEqual(delegated, 0)
        XCTAssertEqual(runtime.refreshCount, 1)
    }

    func testRunningAppRefreshFallsBackOnlyWhenNothingIsListening() throws {
        let refused = RunningAppRefreshClient.classify(url: refreshURL, error: URLError(.cannotConnectToHost))
        XCTAssertEqual(refreshLabel(refused), "unavailable")
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNREFUSED.rawValue))]
        )
        XCTAssertEqual(refreshLabel(RunningAppRefreshClient.classify(url: refreshURL, error: wrapped)), "unavailable")

        let timeout = RunningAppRefreshClient.classify(url: refreshURL, error: URLError(.timedOut))
        XCTAssertEqual(refreshLabel(timeout), "failed:The running app did not finish the refresh before the client timed out.")
        let unreadable = RunningAppRefreshClient.classify(url: refreshURL, error: URLError(.badServerResponse))
        XCTAssertEqual(refreshLabel(unreadable), "failed:The running app returned a response the client could not read.")
        let other = RunningAppRefreshClient.classify(url: refreshURL, error: URLError(.networkConnectionLost))
        guard case .failed(let otherMessage) = other else {
            return XCTFail("a reached transport failure must not fall back")
        }
        XCTAssertFalse(otherMessage.isEmpty)

        XCTAssertEqual(refreshLabel(RunningAppRefreshClient.classify(url: nil)), "failed:The local refresh address is invalid.")
        let httpURL = try XCTUnwrap(refreshURL)
        let serverError = try XCTUnwrap(HTTPURLResponse(url: httpURL, statusCode: 503, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(
            refreshLabel(RunningAppRefreshClient.classify(url: httpURL, response: serverError)),
            "failed:The running app failed the refresh (HTTP 503)."
        )
        let rejected = try XCTUnwrap(HTTPURLResponse(url: httpURL, statusCode: 405, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(
            refreshLabel(RunningAppRefreshClient.classify(url: httpURL, response: rejected)),
            "failed:The running app rejected the refresh (HTTP 405)."
        )
        let missing = try XCTUnwrap(HTTPURLResponse(url: httpURL, statusCode: 404, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(
            refreshLabel(RunningAppRefreshClient.classify(url: httpURL, response: missing, providerID: "claude")),
            "unknown:claude"
        )
        let body = Data(#"{"errors":[{"providerId":"claude","message":"Not logged in"}]}"#.utf8)
        let ok = try XCTUnwrap(HTTPURLResponse(url: httpURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let handled = RunningAppRefreshClient.classify(url: httpURL, response: ok, data: body, providerID: "claude")
        guard case .handled(let result) = handled else {
            return XCTFail("200 must stay handled")
        }
        XCTAssertEqual(result.warnings, ["claude: Not logged in"])
        let notHTTP = URLResponse(url: httpURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertEqual(
            refreshLabel(RunningAppRefreshClient.classify(url: httpURL, response: notHTTP)),
            "failed:The running app returned a response the client could not read."
        )
    }

    func testFailedRunningAppDoesNotRefreshAgain() async {
        let reader = UsageReader(userDefaults: defaults()) { _ in
            .failed("The running app failed the refresh (HTTP 503).")
        }
        do {
            _ = try await reader.read(providerID: "claude", force: true)
            XCTFail("a reached app must not fall through to a second refresh")
        } catch UsageReaderError.refreshFailed(let message) {
            XCTAssertEqual(message, "The running app failed the refresh (HTTP 503).")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPreservingCodexKeepsTheRunningCodexInstance() throws {
        var appliedCodex = CodexAccountDiscovery()
        appliedCodex.plainAuthHomes = ["/tmp/openusage-codex-applied"]
        var discoveredCodex = CodexAccountDiscovery()
        discoveredCodex.plainAuthHomes = ["/tmp/openusage-codex-discovered"]
        let first = card(id: "claude", identity: "user-a|org-a")
        let secondID = ProviderAccountID.make(family: "claude", identityKey: "user-b|org-b")
        let second = card(id: secondID, identity: "user-b|org-b", pi: false)
        let applied = assembly(
            cards: [first],
            identity: ["claude": first.identityKey, "codex": "codex-user"],
            codex: appliedCodex
        )
        let discovered = assembly(
            cards: [card(id: "claude", identity: "user-a|org-a", pi: false), second],
            identity: ["claude": first.identityKey, secondID: second.identityKey, "codex": "other-codex"],
            codex: discoveredCodex
        )
        let current = ProviderCatalog.make(
            claudeCards: applied.claudeCards,
            codex: applied.codex,
            claudeIdentityKeys: applied.identityKeysByCard
        )
        let unscoped = try XCTUnwrap(AccountRuntimeUpdate.change(current: current, from: applied, to: discovered))
        XCTAssertTrue(unscoped.rebound.contains("codex"))

        let scoped = AccountRuntimeUpdate.preservingCodex(discovered: discovered, applied: applied)
        XCTAssertEqual(scoped.codex, applied.codex)
        XCTAssertEqual(scoped.identityKeysByCard["codex"], "codex-user")
        XCTAssertEqual(scoped.identityKeysByCard[secondID], second.identityKey)
        XCTAssertNil(scoped.identityKeysByCard["other-codex"])
        let update = try XCTUnwrap(AccountRuntimeUpdate.change(current: current, from: applied, to: scoped))
        XCTAssertFalse(update.rebound.contains("codex"))
        XCTAssertFalse(update.removed.contains("codex"))
        XCTAssertFalse(update.added.contains("codex"))
        XCTAssertTrue(runtime("codex", in: current) === runtime("codex", in: update.providers))
        XCTAssertEqual(update.added, [secondID])
    }

    func testPreservingCodexDropsACodexOnlyDifference() {
        var other = CodexAccountDiscovery()
        other.plainAuthHomes = ["/tmp/openusage-codex-only"]
        let applied = assembly(identity: ["codex": "codex-user"])
        let discovered = assembly(identity: ["codex": "other"], codex: other)
        let scoped = AccountRuntimeUpdate.preservingCodex(discovered: discovered, applied: applied)
        XCTAssertNil(AccountRuntimeUpdate.change(current: [], from: applied, to: scoped))
        XCTAssertNotNil(AccountRuntimeUpdate.change(current: [], from: applied, to: discovered))
    }

    func testClaudeOnlyAssemblyDoesNotRewriteCodexRecords() async throws {
        let stored = defaults()
        let store = ProviderAccountsStore(defaults: stored)
        store.reconcile(with: [
            ProviderAccountsStore.Observation(
                family: "codex",
                identityKey: "workspace-a",
                label: "A",
                sources: [ProviderAccountSource(kind: .codexHome, anchor: "/tmp/codex-a", holdsDefaultSource: true)]
            ),
        ])
        let before = store.records.filter { $0.family == "codex" }
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "acct-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["claude"]
        )

        XCTAssertEqual(store.records.filter { $0.family == "codex" }, before)
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1")
        XCTAssertNil(assembly.identityKeysByCard["codex"])
        XCTAssertTrue(assembly.codex.cards.isEmpty)
        XCTAssertTrue(assembly.codex.plainAuthHomes.isEmpty)
        XCTAssertEqual(store.records.filter { $0.family == "codex" }.map(\.identityKey), ["workspace-a"])
    }

    func testIncompleteLocalRefreshIsNotAFreshLimitsEnvelope() {
        let limits = LocalUsageAPI.Response(status: 200, body: Data(#"{"providers":{}}"#.utf8))
        let incomplete = AccountRuntimeUpdate.responseAfterLocalRefresh(outcomes: [.skipped], limits: limits)
        XCTAssertEqual(incomplete.status, 503)
        XCTAssertEqual(incomplete.body, Data(#"{"error":"refresh_incomplete"}"#.utf8))
        let finished = AccountRuntimeUpdate.responseAfterLocalRefresh(
            outcomes: [.refreshed, .failed],
            limits: limits
        )
        XCTAssertEqual(finished, limits)
        let empty = AccountRuntimeUpdate.responseAfterLocalRefresh(outcomes: [], limits: limits)
        XCTAssertEqual(empty, limits)
    }

    private var refreshURL: URL? { URL(string: "http://127.0.0.1:9/v1/refresh") }

    private func refreshLabel(_ result: RunningAppRefreshResult) -> String {
        switch result {
        case .handled:
            "handled"
        case .unavailable:
            "unavailable"
        case .unknownProvider(let id):
            "unknown:\(id)"
        case .failed(let message):
            "failed:\(message)"
        }
    }

    private func head(_ start: String, _ headers: [String: String] = [:]) -> String {
        ( [start] + headers.map { "\($0.key): \($0.value)" } ).joined(separator: "\r\n")
    }

    private func snapshot(_ provider: Provider, name: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: name,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)]
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > 2 {
                XCTFail("timed out waiting for the refresh to start")
                return
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class GateProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    let snapshot: ProviderSnapshot
    private var pending: [CheckedContinuation<ProviderSnapshot, Never>] = []
    private(set) var starts = 0

    init(provider: Provider, displayName: String, used: Double) {
        self.provider = provider
        self.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: displayName,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)]
        )
    }

    func refresh() async -> ProviderSnapshot {
        starts += 1
        return await withCheckedContinuation { pending.append($0) }
    }

    func resume() {
        let waiting = pending
        pending = []
        for continuation in waiting {
            continuation.resume(returning: snapshot)
        }
    }
}
