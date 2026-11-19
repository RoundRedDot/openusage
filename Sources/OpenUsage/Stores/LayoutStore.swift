import SwiftUI
import Observation

/// Mutable layout: which widgets are enabled, provider order, and each provider's metric order.
/// `placed` is the enabled set (with stable widget ids); `metricOrderByProvider` is the user's custom order.
@MainActor
@Observable
final class LayoutStore {
    // Swift's private access is file-scoped. Members shared with `LayoutStore+Customization.swift`
    // stay module-internal below; implementation details used only here remain private.
    var placed: [PlacedWidget]

    /// In-popover navigation (screen, Customize master/detail, screen-switch slide). Its own store so
    /// screen routing isn't tangled with layout state; the `screen`/`isEditing`/`customizeProviderID`/
    /// `screenSlide*` surface below forwards to it, so existing call sites are unchanged. Private so the
    /// forwarding surface stays the ONLY spelling — two live paths to the same state invites drift.
    private let navigation = PopoverNavigationStore()

    /// Which in-popover screen is showing. Drives the footer buttons, the Esc handler, and the
    /// popover-closed reset alike.
    var screen: PopoverScreen {
        get { navigation.screen }
        set { navigation.screen = newValue }
    }
    /// The screen being left plus a per-switch counter, for DashboardView's horizontal slide.
    var screenSlideFrom: PopoverScreen { navigation.screenSlideFrom }
    var screenSlideID: Int { navigation.screenSlideID }
    /// Whether the Customize screen is showing — a bridge over `screen` for edit-mode call sites.
    var isEditing: Bool {
        get { navigation.isEditing }
        set { navigation.isEditing = newValue }
    }
    /// The provider whose Customize detail (L2) is showing (nil shows the L1 list).
    var customizeProviderID: String? {
        get { navigation.customizeProviderID }
        set { navigation.customizeProviderID = newValue }
    }
    /// Placed widget being drag-reordered (transient). `PlacedWidget.id`, never persisted.
    var draggingID: UUID?
    /// Persisted provider display order (provider IDs). Drives both the dashboard groups and the
    /// Customize sections, so the user can drag whole providers into the order they want.
    var providerOrder: [String]
    /// Persisted metric order within each provider. Toggle switches do not mutate this, so turning a metric on
    /// or off never makes rows jump around in Customize.
    var metricOrderByProvider: [String: [String]]

    /// Descriptor ids pinned to the menu bar. Membership only — display order is derived from the
    /// provider + metric order above, so pins follow the same sequence shown in Customize. Capped via
    /// `canPin` to at most `maxPinsPerProvider` per provider (the strip stacks a provider's values in pairs).
    private(set) var pinnedMetricIDs: Set<String>

    /// Descriptor ids that sit below the per-provider "Shown on expand" divider: the dashboard hides
    /// them behind a caret until the user taps it, and Customize lists them under the divider.
    /// Membership only — the sequence within each section follows the provider's metric order, like
    /// pins. A metric keeps its membership while disabled, so re-enabling restores its section.
    var expandedMetricIDs: Set<String>

    /// Provider IDs whose dashboard cards are currently opened with their expanded metrics visible.
    /// Unlike hover and drag state, this is a user preference: if someone likes Codex open, it should
    /// stay open across popover closes and app restarts.
    private(set) var expandedProviderIDs: Set<String>

    /// The three transient popover pills, each an auto-clearing `TransientNotice` (was three copy-pasted
    /// value+trigger+clearTask machines). The public `pinLimitNotice`/`shareConfirmation`/
    /// `customizationNotice` surface below forwards to these, so call sites are unchanged.
    private let pinNotice = TransientNotice<String?>(clearedValue: nil, timeout: .seconds(3))
    private let shareNotice = TransientNotice<Bool>(clearedValue: false, timeout: .seconds(2.5))
    private let customizeNotice = TransientNotice<CustomizationNoticeContent?>(clearedValue: nil, timeout: .seconds(2.5))

    /// Transient explanation for a denied pin attempt; the popover footer renders it in place of the pin
    /// counter. Set by `notePinDenied`, auto-cleared a few seconds later.
    var pinLimitNotice: String? { pinNotice.value }
    /// Bumped on every denied pin click so the footer notice plays its deny shake each time.
    var pinNoticeShakeTrigger: Int { pinNotice.trigger }

    /// Transient "Copied to clipboard" confirmation for the floating pill above the footer.
    var shareConfirmation: Bool { shareNotice.value }
    /// Bumped on every successful share so the pill replays its pop-in even on a repeat copy.
    var shareConfirmationTrigger: Int { shareNotice.trigger }

    /// Transient in-Customize notice (e.g. "Starred for menu bar", or the orange cap denial).
    var customizationNotice: String? { customizeNotice.value?.message }
    /// The notice's tone: `.positive` (green checkmark) or `.notice` (orange denial). Falls back to
    /// `.positive` once cleared (tone is only read while `customizationNotice` is non-nil, so the
    /// snap-back is unobservable — message and tone now clear atomically, which the old split state
    /// machine couldn't guarantee).
    var customizationNoticeTone: CustomizationNoticeTone { customizeNotice.value?.tone ?? .positive }
    /// Bumped on every present so the pill replays its pop-in even when the same notice repeats.
    var customizationNoticeTrigger: Int { customizeNotice.trigger }

    /// Bounded, app-wide undo stack for layout customization (remove/add a metric, reorder metrics or
    /// providers, pin/unpin, move across the expand caret). UI-only state (not persisted): undo is a
    /// within-session affordance, so a relaunch starts fresh. Each entry is a pre-change `LayoutSnapshot`;
    /// `undo()` pops and restores one.
    private var undoHistory = LayoutUndoHistory()
    /// True while `undo()` is replaying a snapshot, so the mutations it triggers don't push themselves
    /// back onto the stack (an undo must not be recorded as a new, separately-undoable action).
    private var isApplyingUndo = false

    /// Menu-bar display style (Text strip vs. compact Bars). Persisted; defaults to `.text`.
    var menuBarStyle: MenuBarStyle {
        didSet { persistence.saveMenuBarStyle(menuBarStyle) }
    }

    private(set) var registry: WidgetRegistry
    private let persistence: LayoutPersistence
    private var defaultMetricIDs: [String]
    private var defaultPinnedMetricIDs: [String]
    private var defaultExpandedMetricIDs: [String]
    var defaultExpandedOnEnableIDs: Set<String>
    /// Defaults already offered on this install, including ones whose provider is currently absent.
    /// A returning card that appears here has been saved before, so discovery must not turn its
    /// disabled metrics back on.
    private var seededDefaultMetricIDs: Set<String>
    let isProviderEnabled: @MainActor (String) -> Bool

    init(
        registry: WidgetRegistry,
        defaults: UserDefaults = .standard,
        storageKey: String = "openusage.layout.v1",
        defaultMetricIDs: [String] = DefaultLayout.metricIDs,
        migrationBaselineMetricIDs: [String] = DefaultLayout.migrationBaselineMetricIDs,
        defaultPinnedMetricIDs: [String] = DefaultLayout.pinnedMetricIDs,
        defaultExpandedMetricIDs: [String] = DefaultLayout.expandedMetricIDs,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) {
        self.registry = registry
        let persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        self.persistence = persistence
        self.defaultMetricIDs = defaultMetricIDs
        self.defaultPinnedMetricIDs = defaultPinnedMetricIDs
        self.defaultExpandedMetricIDs = defaultExpandedMetricIDs
        self.isProviderEnabled = isProviderEnabled

        let initial = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: defaultMetricIDs,
                migrationBaselineMetricIDs: migrationBaselineMetricIDs,
                pinnedMetricIDs: defaultPinnedMetricIDs,
                expandedMetricIDs: defaultExpandedMetricIDs
            )
        )
        placed = initial.placed
        providerOrder = initial.providerOrder
        metricOrderByProvider = initial.metricOrderByProvider
        pinnedMetricIDs = initial.pinnedMetricIDs
        expandedMetricIDs = initial.expandedMetricIDs
        expandedProviderIDs = initial.expandedProviderIDs
        defaultExpandedOnEnableIDs = initial.defaultExpandedOnEnableIDs
        seededDefaultMetricIDs = initial.seededDefaults
        menuBarStyle = initial.menuBarStyle

        if initial.shouldPersistExpandOnEnable { persistExpandOnEnable() }
        if initial.shouldPersistExpanded { persistExpanded() }
        if let seededDefaults = initial.seededDefaultsToPersist { persistSeededDefaults(seededDefaults) }
        syncPlacedOrder(persistChanges: initial.shouldPersistPlaced)
    }

    /// Swaps in the registry an explicit account refresh just built. Surviving cards keep their
    /// order, enabled metrics, pins, and expanded-section choices. A card already saved here,
    /// including one that left and came back after a relaunch that did not show it, keeps those
    /// choices even when every default metric is off and every pin is gone. Only a card this
    /// install has never saved is inserted after the last card of its family and receives that
    /// family's default metrics and pins. A removed card leaves the dashboard, but its saved
    /// choices stay.
    func adoptDiscoveredProviders(_ registry: WidgetRegistry) {
        let previousIDs = Set(self.registry.providers.map(\.id))
        let nextIDs = registry.providers.map(\.id)
        let added = nextIDs.filter { !previousIDs.contains($0) }
        self.registry = registry
        defaultMetricIDs = Self.expandedDefaults(defaultMetricIDs, providerIDs: nextIDs)
        defaultPinnedMetricIDs = Self.expandedDefaults(defaultPinnedMetricIDs, providerIDs: nextIDs)
        defaultExpandedMetricIDs = Self.expandedDefaults(defaultExpandedMetricIDs, providerIDs: nextIDs)
        if let current = customizeProviderID, registry.provider(id: current) == nil {
            customizeProviderID = nil
        }
        guard !added.isEmpty else { return }

        // Absent from the previous registry is not "never seen". Order, pins, an empty placed
        // list, and the seeded-default record are all saved choices. Zero placed widgets is a
        // real opt-out, so it must not be treated as a card that still needs its defaults.
        let introduced = added.filter { !hasSavedLayout($0) }
        var order = providerOrder
        for id in added where !order.contains(id) {
            let family = ProviderAccountID.family(of: id)
            if let index = order.lastIndex(where: { ProviderAccountID.family(of: $0) == family }) {
                order.insert(id, at: order.index(after: index))
            } else {
                order.append(id)
            }
        }
        if order != providerOrder {
            providerOrder = order
            persistProviderOrder()
        }

        let placedIDs = Set(placed.map(\.descriptorID))
        var appended: [PlacedWidget] = []
        var pinnedAdditions: [String] = []
        var expandedAdditions: [String] = []
        var queuedAdditions: [String] = []
        for id in introduced {
            let owned = registry.descriptors(for: id).map(\.id)
            let ownedSet = Set(owned)
            if metricOrderByProvider[id] == nil {
                metricOrderByProvider[id] = owned
            }
            let defaultsOn = defaultMetricIDs.filter { ownedSet.contains($0) && !placedIDs.contains($0) }
            appended.append(contentsOf: defaultsOn.map { PlacedWidget(descriptorID: $0) })
            let expandedDefaults = defaultExpandedMetricIDs.filter { ownedSet.contains($0) }
            expandedAdditions.append(contentsOf: expandedDefaults.filter { defaultsOn.contains($0) })
            queuedAdditions.append(contentsOf: expandedDefaults.filter { !defaultsOn.contains($0) })
            pinnedAdditions.append(contentsOf: defaultPinnedMetricIDs.filter { ownedSet.contains($0) })
        }
        if !appended.isEmpty { placed.append(contentsOf: appended) }
        if !introduced.isEmpty { persistMetricOrder() }
        for id in pinnedAdditions where canPin(id) {
            pinnedMetricIDs.insert(id)
        }
        if !pinnedAdditions.isEmpty { persistPins() }
        if !expandedAdditions.isEmpty {
            expandedMetricIDs.formUnion(expandedAdditions)
            persistExpanded()
        }
        if !queuedAdditions.isEmpty {
            defaultExpandedOnEnableIDs.formUnion(queuedAdditions)
            persistExpandOnEnable()
        }
        syncPlacedOrder()
    }

    /// True when this install already has a choice for the provider, including a choice that was
    /// kept dormant while the provider was missing from the registry.
    private func hasSavedLayout(_ providerID: String) -> Bool {
        if providerOrder.contains(providerID) || metricOrderByProvider[providerID] != nil {
            return true
        }
        if expandedProviderIDs.contains(providerID) { return true }
        let owns: (String) -> Bool = { LayoutOrdering.providerID(forMetricID: $0) == providerID }
        if placed.contains(where: { owns($0.descriptorID) }) { return true }
        if pinnedMetricIDs.contains(where: owns) { return true }
        if expandedMetricIDs.contains(where: owns) { return true }
        if defaultExpandedOnEnableIDs.contains(where: owns) { return true }
        if seededDefaultMetricIDs.contains(where: owns) { return true }
        return false
    }

    private static func expandedDefaults(_ ids: [String], providerIDs: [String]) -> [String] {
        var seen = Set<String>()
        return DefaultLayout.expandingAccounts(ids, providerIDs: providerIDs).filter { seen.insert($0).inserted }
    }

    func isProviderExpanded(_ providerID: String) -> Bool {
        expandedProviderIDs.contains(providerID)
    }

    @discardableResult
    func setProviderExpanded(_ expanded: Bool, for providerID: String) -> Bool {
        guard registry.provider(id: providerID) != nil else { return false }
        guard expandedProviderIDs.contains(providerID) != expanded else { return false }
        if expanded {
            expandedProviderIDs.insert(providerID)
        } else {
            expandedProviderIDs.remove(providerID)
        }
        persistExpandedProviders()
        return true
    }

    // MARK: - Customize mutations

    /// Toggle a metric on (add to the placed list) or off (remove it). The single seam the Customize
    /// switches drive, so on/off goes through the same add/remove path the rest of the app uses.
    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        recordingUndoStep {
            if enabled {
                if defaultExpandedOnEnableIDs.remove(descriptorID) != nil {
                    expandedMetricIDs.insert(descriptorID)
                    persistExpanded()
                    persistExpandOnEnable()
                }
                add(descriptorID)
            } else if let widget = placed.first(where: { $0.descriptorID == descriptorID }) {
                remove(widget.id)
            }
        }
    }

    // MARK: - Undo (#603)

    /// Whether there's at least one customization step to walk back. Drives the Customize Undo button's
    /// presence and the app-wide ⌘Z handler's no-op guard.
    var canUndo: Bool { undoHistory.canUndo }

    /// A snapshot of the current undoable layout state.
    private func currentSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            placed: placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs,
            expandedMetricIDs: expandedMetricIDs,
            defaultExpandedOnEnableIDs: defaultExpandedOnEnableIDs
        )
    }

    /// Run a user-facing layout mutation, recording one undo step for it. Snapshots state before the
    /// change and pushes that snapshot only if the change actually altered the layout — so a no-op
    /// action (toggling an already-on metric, dropping a row back where it started) doesn't pollute the
    /// stack with empty steps. Re-entrant calls (a mutation built from smaller ones) and undo replay
    /// itself coalesce into the single outer step via `isApplyingUndo`.
    func recordingUndoStep<T>(_ body: () -> T) -> T {
        // Already inside an undoable scope (or replaying an undo): just run — the outer scope owns the
        // single recorded step, and undo must never record itself.
        guard !isApplyingUndo else { return body() }
        let before = currentSnapshot()
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        let result = body()
        if currentSnapshot() != before {
            undoHistory.record(before)
        }
        return result
    }

    /// Walk back the most recent customization step, restoring the layout to its state just before that
    /// action. A no-op (returns `false`) when there's nothing to undo. Repeated calls step further back.
    /// Available app-wide (dashboard context menus and Customize alike), not just on one screen.
    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoHistory.popLast() else { return false }
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        restore(snapshot)
        return true
    }

    /// Restore every undoable field from a snapshot and persist the result. Called by `undo()`.
    /// Provider card expand/collapse (`expandedProviderIDs`) is deliberately excluded: it's transient
    /// view state, not a layout edit, so undo must not rewind caret toggles done between steps.
    private func restore(_ snapshot: LayoutSnapshot) {
        cancelDrag()
        placed = snapshot.placed
        providerOrder = snapshot.providerOrder
        metricOrderByProvider = snapshot.metricOrderByProvider
        pinnedMetricIDs = snapshot.pinnedMetricIDs
        expandedMetricIDs = snapshot.expandedMetricIDs
        defaultExpandedOnEnableIDs = snapshot.defaultExpandedOnEnableIDs
        persist()
        persistProviderOrder()
        persistMetricOrder()
        persistPins()
        persistExpanded()
        persistExpandOnEnable()
    }

    // MARK: - Menu bar pins

    /// Per-provider cap is a rendering constraint — the Text strip stacks a provider's values two to a
    /// column, so a third would not fit the menu bar height.
    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool { pinnedMetricIDs.contains(descriptorID) }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    /// Whether `descriptorID` can be newly pinned without breaking a cap. Already-pinned ids return
    /// `true`, so the toggle stays active for unpinning.
    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
        guard let descriptor = registry.descriptor(id: descriptorID), descriptor.pinnable else { return false }
        if pinnedCount(forProvider: descriptor.providerID) >= Self.maxPinsPerProvider { return false }
        return true
    }

    /// Why `descriptorID` can't be pinned right now, or `nil` when it can. The single source for the
    /// pin button's tooltip and the denied-click feedback, so both always state the same rule.
    func pinDenialReason(_ descriptorID: String) -> String? {
        guard !canPin(descriptorID) else { return nil }
        if let providerID = registry.descriptor(id: descriptorID)?.providerID,
           pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider {
            return "Up to \(Self.maxPinsPerProvider) stars per provider"
        }
        return nil
    }

    /// Record a denied pin attempt so the footer can explain the cap (shown for a few seconds,
    /// with a deny shake on every attempt).
    func notePinDenied(_ descriptorID: String) {
        guard let reason = pinDenialReason(descriptorID) else { return }
        pinNotice.present(reason)
    }

    /// Record a successful "Share Screenshot" copy so the floating "Copied to clipboard" pill can
    /// confirm it. Shown for a couple of seconds then cleared — the success-side counterpart to
    /// `notePinDenied`'s transient denial notice, with the same lifecycle.
    func presentShareConfirmation() {
        shareNotice.present(true)
    }

    /// Clear any showing "Copied to clipboard" confirmation and cancel its auto-clear task. Called when
    /// the popover closes so a pill mid-countdown can't reappear stale on the next open — the timer is
    /// otherwise the only clearer, and the layout store outlives the popover.
    func clearShareConfirmation() {
        shareNotice.clear()
    }

    /// Show a transient in-Customize pill (the floating confirmation above the Customize content).
    /// `tone` picks the green success style or the orange denial style. Auto-clears after a couple of
    /// seconds; also cleared on popover close via `clearCustomizationNotice`.
    func presentCustomizationNotice(_ message: String, tone: CustomizationNoticeTone = .positive) {
        customizeNotice.present(CustomizationNoticeContent(message: message, tone: tone))
    }

    /// Clear any showing Customize pill and cancel its auto-clear task. Called when the popover closes
    /// so a pill mid-countdown can't reappear stale on the next open.
    func clearCustomizationNotice() {
        customizeNotice.clear()
    }

    /// Pin or unpin a metric for the menu bar. Pinning is a no-op when it would exceed a cap, so callers
    /// can gate the control on `canPin` and trust this never over-pins. Undoable like the other layout
    /// actions — the no-op guards mean a denied or redundant pin records no step.
    func setPinned(_ pinned: Bool, for descriptorID: String) {
        recordingUndoStep {
            if pinned {
                guard canPin(descriptorID), registry.descriptor(id: descriptorID) != nil else { return }
                guard pinnedMetricIDs.insert(descriptorID).inserted else { return }
            } else {
                guard pinnedMetricIDs.remove(descriptorID) != nil else { return }
            }
            persistPins()
        }
    }

    func togglePin(_ descriptorID: String) {
        setPinned(!isPinned(descriptorID), for: descriptorID)
    }

    func persistPins() {
        persistence.savePins(pinnedMetricIDs)
    }

    func persistExpanded() {
        persistence.saveExpandedMetrics(expandedMetricIDs)
    }

    func persistExpandOnEnable() {
        persistence.saveExpandOnEnable(defaultExpandedOnEnableIDs)
    }

    private func persistExpandedProviders() {
        persistence.saveExpandedProviders(expandedProviderIDs)
    }

    // MARK: - Mutations

    func add(_ descriptorID: String) {
        guard registry.descriptor(id: descriptorID) != nil else { return }
        guard !placed.contains(where: { $0.descriptorID == descriptorID }) else { return }
        cancelDrag()
        placed.append(PlacedWidget(descriptorID: descriptorID))
        syncPlacedOrder()
    }

    func remove(_ id: UUID) {
        guard let index = placed.firstIndex(where: { $0.id == id }) else { return }
        cancelDrag()
        placed.remove(at: index)
        persist()
    }

    func resetToDefault() {
        cancelDrag()
        // Reset is its own deliberate action, not an undoable layout edit; the recorded snapshots
        // describe the pre-reset layout, so the undo stack is dropped wholesale here.
        undoHistory.clear()
        placed = defaultMetricIDs
            .filter { registry.descriptor(id: $0) != nil }
            .map { PlacedWidget(descriptorID: $0) }
        providerOrder = registry.providers.map(\.id)
        persistProviderOrder()
        metricOrderByProvider = LayoutOrdering.defaultMetricOrder(registry: registry)
        persistMetricOrder()
        pinnedMetricIDs = Set(defaultPinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        persistPins()
        expandedMetricIDs = Set(defaultExpandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        defaultExpandedOnEnableIDs = []
        persistExpanded()
        persistExpandOnEnable()
        expandedProviderIDs = []
        persistExpandedProviders()
        let seeded = Set(LayoutOrdering.knownMetricIDs(defaultMetricIDs, registry: registry))
        seededDefaultMetricIDs = seeded
        persistSeededDefaults(seeded)
        persist()
    }

    /// Reset a single provider's customization to default — its enabled metrics, metric order, pins,
    /// and expanded (caret) membership — while leaving every other provider, and the overall provider
    /// order, untouched. The per-provider counterpart to `resetToDefault` ("Reset all providers"): same
    /// per-provider effect, scoped to one `providerID` instead of the whole layout. No-op for an
    /// unknown provider.
    func resetProvider(_ providerID: String) {
        guard registry.provider(id: providerID) != nil else { return }
        cancelDrag()
        // A reset is its own action, not an undoable edit. Snapshots are whole-layout, so there's no
        // per-provider trim to do — clear the stack so undo can't restore into the pre-reset layout.
        undoHistory.clear()

        // This provider's descriptor universe — the membership sets below are all scoped to it.
        let owned = Set(registry.descriptors(for: providerID).map(\.id))
        func defaults(_ ids: [String]) -> [String] {
            ids.filter { owned.contains($0) && registry.descriptor(id: $0) != nil }
        }

        // Enabled metrics: drop this provider's placed widgets, re-seed its default-on set. Other
        // providers' widgets keep their identity and position; `syncPlacedOrder` re-sorts the whole
        // list by provider + metric order at the end.
        placed = placed.filter { !owned.contains($0.descriptorID) }
            + defaults(defaultMetricIDs).map { PlacedWidget(descriptorID: $0) }

        // Metric order back to registry order for this provider only.
        metricOrderByProvider[providerID] = registry.descriptors(for: providerID).map(\.id)
        persistMetricOrder()

        // Pins, expanded membership, and the default-expanded-on-enable carry: swap this provider's
        // entries for its defaults, leaving the rest of each set intact.
        pinnedMetricIDs.subtract(owned)
        pinnedMetricIDs.formUnion(defaults(defaultPinnedMetricIDs))
        persistPins()

        expandedMetricIDs.subtract(owned)
        expandedMetricIDs.formUnion(defaults(defaultExpandedMetricIDs))
        defaultExpandedOnEnableIDs.subtract(owned)
        persistExpanded()
        persistExpandOnEnable()

        // Default is a collapsed card.
        if expandedProviderIDs.remove(providerID) != nil {
            persistExpandedProviders()
        }

        syncPlacedOrder() // persists `placed`
    }

    func cancelDrag() {
        draggingID = nil
    }

    func persist() {
        persistence.savePlaced(placed)
    }

    func persistProviderOrder() {
        persistence.saveProviderOrder(providerOrder)
    }

    func persistMetricOrder() {
        persistence.saveMetricOrder(metricOrderByProvider)
    }

    private func persistSeededDefaults(_ ids: Set<String>) {
        persistence.saveSeededDefaults(ids)
    }

    func metricOrder(for providerID: String) -> [String] {
        let valid = registry.descriptors(for: providerID).map(\.id)
        let saved = metricOrderByProvider[providerID] ?? []
        return LayoutOrdering.normalizedMetricIDs(saved, validIDs: valid)
    }

    func syncPlacedOrder(persistChanges: Bool = true) {
        let byDescriptor = Dictionary(
            placed.map { ($0.descriptorID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordered: [PlacedWidget] = []
        for providerID in orderedProviderIDs() {
            ordered.append(contentsOf: metricOrder(for: providerID).compactMap { byDescriptor[$0] })
        }
        let orderedIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: placed.filter { !orderedIDs.contains($0.id) })
        placed = ordered
        if persistChanges { persist() }
    }

}
