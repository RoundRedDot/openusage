import Foundation
import XCTest
@testable import OpenUsage

final class OhMyPiProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-10-27T12:00:00.000Z")!

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("omp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeSession(home: URL, path: String, lines: [String]) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func line(id: String = "m1", cost: Double = 0.25) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"2026-10-27T10:00:00.000Z","message":{"role":"assistant","provider":"deepseek","model":"deepseek-flash","usage": {"input":100,"output":50,"cacheRead":20,"cacheWrite":10,"totalTokens":180,"cost":{"total":\(cost)}}}}
        """
    }

    @MainActor
    private func provider(home: URL, environment: [String: String] = [:], pricing: ModelPricing = .empty) -> OhMyPiProvider {
        let refreshedAt = now
        return OhMyPiProvider(
            scanner: PiUsageScanner(incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()),
            paths: OhMyPiPaths(environment: FakeEnvironment(environment), homeDirectory: { home }),
            pricing: { pricing }, now: { refreshedAt }
        )
    }

    func testDefaultDirectoryIsSeparateFromPiAndIgnoresPiSessionOverride() throws {
        let home = try makeHome()
        let environment = FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": "/pi-only/sessions"])
        XCTAssertEqual(
            try OhMyPiPaths(environment: environment, homeDirectory: { home }).sessionsDirectory(),
            home.appendingPathComponent(".omp/agent/sessions")
        )
        XCTAssertEqual(
            PiPaths.sessionsDirectory(environment: environment, homeDirectory: home).path,
            "/pi-only/sessions"
        )
    }

    func testProfilesAndAgentDirectoryFollowOmpPrecedence() throws {
        let home = try makeHome()
        let cases: [([String: String], String)] = [
            (["PI_CODING_AGENT_DIR": home.appendingPathComponent("custom").path], "custom/sessions"),
            (["OMP_PROFILE": "work", "PI_PROFILE": "old", "PI_CODING_AGENT_DIR": "/ignored"], ".omp/profiles/work/agent/sessions"),
            (["PI_PROFILE": "work"], ".omp/profiles/work/agent/sessions"),
            (["OMP_PROFILE": "", "PI_PROFILE": "old"], ".omp/agent/sessions"),
            (["OMP_PROFILE": "default"], ".omp/agent/sessions"),
            (["PI_CONFIG_DIR": ".omp-custom"], ".omp-custom/agent/sessions")
        ]
        for (environment, expected) in cases {
            XCTAssertEqual(
                try OhMyPiPaths(environment: FakeEnvironment(environment), homeDirectory: { home }).sessionsDirectory(),
                home.appendingPathComponent(expected)
            )
        }
    }

    func testXdgDirectoryIsUsedOnlyAfterMigrationAndCustomAgentWins() throws {
        let home = try makeHome()
        let environment = ["XDG_DATA_HOME": home.appendingPathComponent("data").path]
        let paths = OhMyPiPaths(environment: FakeEnvironment(environment), homeDirectory: { home })
        XCTAssertEqual(try paths.sessionsDirectory(), home.appendingPathComponent(".omp/agent/sessions"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("data/omp"), withIntermediateDirectories: true)
        XCTAssertEqual(try paths.sessionsDirectory(), home.appendingPathComponent("data/omp/sessions"))

        let custom = environment.merging(["PI_CODING_AGENT_DIR": home.appendingPathComponent("custom").path]) { _, new in new }
        XCTAssertEqual(
            try OhMyPiPaths(environment: FakeEnvironment(custom), homeDirectory: { home }).sessionsDirectory(),
            home.appendingPathComponent("custom/sessions")
        )

        let profile = environment.merging(["OMP_PROFILE": "work"]) { _, new in new }
        let profilePaths = OhMyPiPaths(environment: FakeEnvironment(profile), homeDirectory: { home })
        XCTAssertEqual(try profilePaths.sessionsDirectory(), home.appendingPathComponent(".omp/profiles/work/agent/sessions"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("data/omp/profiles/work"), withIntermediateDirectories: true)
        XCTAssertEqual(try profilePaths.sessionsDirectory(), home.appendingPathComponent("data/omp/profiles/work/sessions"))
    }

    @MainActor
    func testCountsAssistantAndModelUsageAcrossNestedSessionsOnce() async throws {
        let home = try makeHome()
        let modelUsage = """
        {"type":"model_usage","id":"compact1","timestamp":"2026-10-27T10:01:00.000Z","provider":"anthropic","model":"claude-test","usage":{"input":60,"output":20,"cacheRead":10,"cacheWrite":10,"cost":{"total":0.5}}}
        """
        try writeSession(home: home, path: ".omp/agent/sessions/project/main.jsonl", lines: [line(), modelUsage])
        try writeSession(home: home, path: ".omp/agent/sessions/project/subagents/child.jsonl", lines: [line(), line(id: "child1")])
        try writeSession(home: home, path: ".pi/agent/sessions/project/pi.jsonl", lines: [line(id: "pi-only", cost: 99)])

        let omp = provider(home: home)
        let detected = await omp.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await omp.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.providerID, "omp")
        let day = try XCTUnwrap(snapshot.usageHistory?.series.daily.first)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 1, accuracy: 0.0001)
        XCTAssertEqual(day.totalTokens, 460)
        XCTAssertEqual(
            Set(snapshot.usageHistory?.modelUsage?.daily.first?.models.map(\.model) ?? []),
            ["deepseek-flash · DeepSeek", "claude-test · Claude"]
        )

        let piScan = await PiUsageScanner(
            environment: FakeEnvironment(), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        ).scan(cardID: nil, now: now, pricing: .empty)
        XCTAssertEqual(piScan?.series.daily.first?.costUSD, 99)
        XCTAssertFalse(PiProviderMapping.foldsIntoProviderCards)
    }

    @MainActor
    func testEstimatesZeroCostWithSharedPricingAndPreservesUnknownModelWarning() async throws {
        let home = try makeHome()
        try writeSession(home: home, path: ".omp/agent/sessions/project/test.jsonl", lines: [
            line(cost: 0),
            line(id: "unknown", cost: 0).replacingOccurrences(of: "deepseek-flash", with: "unpriced-model")
        ])
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["deepseek-flash": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20, cacheWritePerMillion: 10, cacheReadPerMillion: 1
            )]), secondary: PricingCatalog(entries: [:])
        )
        let snapshot = await provider(home: home, pricing: pricing).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD ?? 0, 0.00212, accuracy: 0.000001)
        XCTAssertTrue(snapshot.usageHistory?.unknownModelsByDay.values.contains { $0.contains("unpriced-model · DeepSeek") } == true)
    }

    func testOrchestrationBucketsAndAuthoritativeTotal() throws {
        let raw = """
        {"type":"model_usage","id":"orchestration","timestamp":"2026-10-27T10:01:00.000Z","provider":"deepseek","model":"deepseek-flash","usage":{"input":100,"output":20,"cacheRead":10,"cacheWrite":5,"orchestration":{"input":30,"output":5,"cacheRead":2}}}
        """
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(Data(raw.utf8)))
        XCTAssertEqual(entry.reportedTotalTokens, 172)
        XCTAssertEqual(entry.tokens.input, 130)
        XCTAssertEqual(entry.tokens.output, 25)
        XCTAssertEqual(entry.tokens.cacheRead, 12)
        let reported = raw.replacingOccurrences(of: "\"input\":100", with: "\"totalTokens\":999,\"input\":100")
        XCTAssertEqual(PiUsageScanner.parseLine(Data(reported.utf8))?.reportedTotalTokens, 999)
    }

    @MainActor
    func testNotDetectedAndInvalidProfileAreExplicitErrors() async throws {
        let home = try makeHome()
        try writeSession(home: home, path: ".pi/agent/sessions/project/pi.jsonl", lines: [line()])
        let missing = provider(home: home)
        let detected = await missing.hasLocalCredentials()
        XCTAssertFalse(detected)
        let missingSnapshot = await missing.refresh()
        XCTAssertEqual(missingSnapshot.errorCategory, .notLoggedIn)

        let invalid = provider(home: home, environment: ["OMP_PROFILE": "../bad"])
        let invalidSnapshot = await invalid.refresh()
        XCTAssertEqual(invalidSnapshot.errorCategory, .authInvalid)
    }

    @MainActor
    func testDescriptorsAndApprovedDefaults() throws {
        let home = try makeHome()
        let descriptors = provider(home: home).widgetDescriptors.map(\.id)
        XCTAssertEqual(descriptors, ["omp.trend", "omp.today", "omp.yesterday", "omp.last30"])
        XCTAssertTrue(descriptors.allSatisfy(DefaultLayout.metricIDs.contains))
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("omp.trend"))
        XCTAssertTrue(descriptors.dropFirst().allSatisfy(DefaultLayout.expandedMetricIDs.contains))
        XCTAssertTrue(Set(descriptors).isDisjoint(with: DefaultLayout.pinnedMetricIDs))
        let ids = ProviderCatalog.make().map { $0.provider.id }
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: "grok")), try XCTUnwrap(ids.firstIndex(of: "omp")))
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: "omp")), try XCTUnwrap(ids.firstIndex(of: "ollama")))
        XCTAssertNotNil(ProviderMarks.mark(for: "omp"))
    }
}
