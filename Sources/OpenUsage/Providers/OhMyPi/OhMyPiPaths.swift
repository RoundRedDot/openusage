import Foundation

/// Mirrors OMP's macOS session root, including named profiles and migrated XDG data.
struct OhMyPiPaths: Sendable {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func sessionsDirectory() throws -> URL {
        let profile = (environment.value(for: "OMP_PROFILE") ?? environment.value(for: "PI_PROFILE") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let namedProfile = !profile.isEmpty && profile != "default"
        if namedProfile {
            guard profile.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
                  !profile.hasSuffix("."),
                  profile.range(of: #"^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)"#, options: .regularExpression) == nil
            else { throw OhMyPiUsageError.invalidProfile }
        }

        var root = homeDirectory().appendingPathComponent(environment.value(for: "PI_CONFIG_DIR")?.nilIfEmpty ?? ".omp")
        if namedProfile { root.appendPathComponent("profiles/\(profile)") }
        let defaultAgent = root.appendingPathComponent("agent")
        if !namedProfile, let override = environment.value(for: "PI_CODING_AGENT_DIR")?.nilIfEmpty {
            let agent = URL(fileURLWithPath: expandHome(override)).standardizedFileURL
            if agent != defaultAgent.standardizedFileURL { return agent.appendingPathComponent("sessions") }
        }

        if let xdg = environment.value(for: "XDG_DATA_HOME")?.nilIfEmpty {
            var dataRoot = URL(fileURLWithPath: expandHome(xdg)).appendingPathComponent("omp")
            if namedProfile { dataRoot.appendPathComponent("profiles/\(profile)") }
            if FileManager.default.fileExists(atPath: dataRoot.path) {
                return dataRoot.appendingPathComponent("sessions")
            }
        }
        return defaultAgent.appendingPathComponent("sessions")
    }

    func hasSessionLogs() throws -> Bool {
        !JSONLScanning.jsonlFiles(under: try sessionsDirectory()).isEmpty
    }
}
