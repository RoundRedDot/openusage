import XCTest
@testable import OpenUsage

@MainActor
final class ProviderAliasStoreTests: XCTestCase {
    func testEditingPrefillsAccountNameOrSavedAlias() throws {
        let suite = "ProviderAliasStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ClaudeProvider.makeProvider(id: "claude", displayName: "Claude: name@example.com")
        XCTAssertEqual(ProviderAliasStore.editValue(for: provider, defaults: defaults), "name@example.com")
        let organization = ClaudeProvider.makeProvider(id: "claude@12345678", displayName: "Claude — Organization")
        XCTAssertEqual(ProviderAliasStore.editValue(for: organization, defaults: defaults), "Organization")
        ProviderAliasStore.set("Work", for: provider.id, defaults: defaults)
        XCTAssertEqual(ProviderAliasStore.editValue(for: provider, defaults: defaults), "Work")
        ProviderAliasStore.set("", for: provider.id, defaults: defaults)
        XCTAssertEqual(ProviderAliasStore.editValue(for: provider, defaults: defaults), "name@example.com")
    }

    func testAliasesPersistIndependentlyAndCanBeCleared() throws {
        let suite = "ProviderAliasStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        ProviderAliasStore.set(" Work ", for: "claude", defaults: defaults)
        ProviderAliasStore.set("Personal", for: "claude@12345678", defaults: defaults)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(ProviderAliasStore.alias(for: "claude", defaults: reloaded), "Work")
        XCTAssertEqual(ProviderAliasStore.alias(for: "claude@12345678", defaults: reloaded), "Personal")

        ProviderAliasStore.set("  ", for: "claude", defaults: reloaded)
        XCTAssertEqual(ProviderAliasStore.alias(for: "claude", defaults: defaults), "")
        XCTAssertEqual(ProviderAliasStore.alias(for: "claude@12345678", defaults: defaults), "Personal")
    }

    func testOtherProvidersUseTheirOriginalNamesAndIndependentAliases() throws {
        let suite = "ProviderAliasStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let codex = Provider(id: "codex@12345678", displayName: "Codex: user@example.com", icon: .providerMark("codex"))
        let omp = Provider(id: "omp", displayName: "Oh My Pi", icon: .providerMark("omp"))
        XCTAssertEqual(ProviderAliasStore.editValue(for: codex, defaults: defaults), "user@example.com")
        XCTAssertEqual(ProviderAliasStore.editValue(for: omp, defaults: defaults), "Oh My Pi")
        XCTAssertEqual(ProviderAliasStore.displayName(for: codex, alias: "Work"), "Codex: Work")
        XCTAssertEqual(ProviderAliasStore.displayName(for: omp, alias: "Personal"), "Oh My Pi: Personal")
        XCTAssertEqual(ProviderAliasStore.displayName(for: omp, alias: "Oh My Pi"), "Oh My Pi")
        ProviderAliasStore.set("Work", for: codex.id, defaults: defaults)
        ProviderAliasStore.set("Personal", for: omp.id, defaults: defaults)
        XCTAssertEqual(ProviderAliasStore.editValue(for: codex, defaults: defaults), "Work")
        XCTAssertEqual(ProviderAliasStore.editValue(for: omp, defaults: defaults), "Personal")
    }
}
