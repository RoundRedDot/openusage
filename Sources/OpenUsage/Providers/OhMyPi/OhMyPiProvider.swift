import Foundation

enum OhMyPiUsageError: Error, LocalizedError, Equatable {
    case notDetected
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .notDetected: "Oh My Pi not detected. Run `omp` once so it writes session logs."
        case .invalidProfile: "Invalid Oh My Pi profile. Check OMP_PROFILE or PI_PROFILE."
        }
    }
}

/// OMP owns its usage card and parse cache; only the Pi-compatible log format and pricing are shared.
@MainActor
final class OhMyPiProvider: ProviderRuntime {
    let provider = Provider(id: "omp", displayName: "Oh My Pi", icon: .providerMark("omp"))

    private static let parseCache = IncrementalJSONLScanner<PiUsageScanner.Entry>(
        logTag: LogTag.plugin("omp"),
        persistence: JSONLScanCachePersistence(namespace: "omp", schemaVersion: 1)
    )
    private static let sharedScanner = PiUsageScanner(incrementalScanner: parseCache)

    private let scanner: PiUsageScanner
    private let paths: OhMyPiPaths
    private let pricing: @Sendable () async -> ModelPricing
    private let now: @Sendable () -> Date
    private let sourceNote = "From your Oh My Pi logs (estimated)"

    init(
        scanner: PiUsageScanner? = nil,
        paths: OhMyPiPaths = OhMyPiPaths(),
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scanner = scanner ?? Self.sharedScanner
        self.paths = paths
        self.pricing = pricing
        self.now = now
    }

    static func flushPersistentCacheWrites() async {
        await parseCache.flushPendingWrites()
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .usageTrend(provider: provider)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: sourceNote)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        do {
            return try await loadOffMainActor { [paths] in try paths.hasSessionLogs() }
        } catch {
            AppLog.error(LogTag.plugin("omp"), error.localizedDescription)
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        do {
            let directory = try await loadOffMainActor { [paths] in try paths.sessionsDirectory() }
            let pricing = await pricing()
            guard let scan = await scanner.scan(cardID: nil, now: refreshedAt, pricing: pricing, directory: directory) else {
                return ProviderSnapshot.error(provider: provider, error: OhMyPiUsageError.notDetected)
            }
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(
                provider: provider, plan: nil, lines: lines, refreshedAt: refreshedAt,
                usageHistory: ProviderUsageHistory(
                    series: scan.series, modelUsage: scan.modelUsage,
                    unknownModelsByDay: scan.unknownModelsByDay
                )
            )
        } catch {
            AppLog.error(LogTag.plugin("omp"), error.localizedDescription)
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
