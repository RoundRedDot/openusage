import XCTest
@testable import OpenUsage

@MainActor
final class LayoutBootstrapTests: XCTestCase {
    func testFreshInstallUsesCurrentDefaults() {
        let (persistence, _) = makePersistence("Fresh")

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session"])
        XCTAssertEqual(state.expandedMetricIDs, ["claude.weekly"])
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
        XCTAssertTrue(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
    }

    func testExistingLayoutUsesLegacyBaselineWithoutRestoringRemovedMetric() {
        let (persistence, _) = makePersistence("ExistingBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertFalse(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
    }

    func testPreviouslySeededMetricStaysOffWhenUserDisabledIt() {
        let (persistence, _) = makePersistence("UserDisabled")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertNil(state.seededDefaultsToPersist)
    }

    func testAbsentProviderChoicesStayDormantWithoutSeedingThem() {
        let (persistence, _) = makePersistence("Dormant")
        persistence.savePlaced([
            PlacedWidget(descriptorID: "claude.session"),
            PlacedWidget(descriptorID: "away.session"),
            PlacedWidget(descriptorID: "away.weekly"),
        ])
        persistence.savePins(["claude.session", "away.weekly"])
        persistence.saveExpandedMetrics(["claude.weekly", "away.session"])
        persistence.saveExpandOnEnable(["away.extra"])
        persistence.saveExpandedProviders(["claude", "away"])
        persistence.saveProviderOrder(["away", "claude"])
        persistence.saveMetricOrder([
            "claude": ["claude.weekly", "claude.session"],
            "away": ["away.weekly", "away.session"],
        ])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly", "away.session", "away.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "away.session", "away.weekly"])
        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session", "away.weekly"])
        XCTAssertTrue(state.expandedMetricIDs.contains("away.session"))
        XCTAssertTrue(state.expandedProviderIDs.contains("away"))
        XCTAssertEqual(state.providerOrder, ["away", "claude"])
        XCTAssertEqual(state.metricOrderByProvider["away"], ["away.weekly", "away.session"])
        XCTAssertEqual(state.defaultExpandedOnEnableIDs, ["away.extra"])
        XCTAssertNil(state.seededDefaultsToPersist)
        XCTAssertTrue(state.seededDefaults.contains("away.session"))
        XCTAssertTrue(state.seededDefaults.contains("away.weekly"))
        XCTAssertFalse(state.placed.contains { $0.descriptorID == "away.extra" })
    }

    func testObsoleteMetricOfAPresentProviderIsStillDropped() {
        let (persistence, _) = makePersistence("Obsolete")
        persistence.savePlaced([
            PlacedWidget(descriptorID: "claude.session"),
            PlacedWidget(descriptorID: "claude.removed"),
            PlacedWidget(descriptorID: "away.session"),
        ])
        persistence.savePins(["claude.removed", "away.session"])
        persistence.saveExpandedMetrics(["claude.removed", "away.weekly"])
        persistence.saveMetricOrder(["claude": ["claude.removed", "claude.session", "claude.weekly"]])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly", "claude.removed", "away.session"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "away.session"])
        XCTAssertEqual(state.pinnedMetricIDs, ["away.session"])
        XCTAssertFalse(state.expandedMetricIDs.contains("claude.removed"))
        XCTAssertTrue(state.expandedMetricIDs.contains("away.weekly"))
        XCTAssertFalse(state.metricOrderByProvider["claude"]?.contains("claude.removed") ?? true)
        XCTAssertEqual(
            state.seededDefaultsToPersist,
            Set(["away.session", "claude.session", "claude.weekly"])
        )
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["claude.weekly"]
        )
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "OpenUsageTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }
}
