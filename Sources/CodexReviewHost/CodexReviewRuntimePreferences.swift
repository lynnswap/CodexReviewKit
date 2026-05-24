import Foundation

public struct CodexReviewRuntimePreferences: Codable, Equatable, Sendable {
    public static let defaults = CodexReviewRuntimePreferences()

    public var codexHomePath: String?
    public var mcpHost: String
    public var mcpPort: Int
    public var mcpPath: String
    public var codexExecutablePath: String?

    public init(
        codexHomePath: String? = nil,
        mcpHost: String = "localhost",
        mcpPort: Int = 9417,
        mcpPath: String = "/mcp",
        codexExecutablePath: String? = nil
    ) {
        self.codexHomePath = Self.normalizedPath(codexHomePath)
        self.mcpHost = Self.normalizedHost(mcpHost)
        self.mcpPort = Self.normalizedPort(mcpPort)
        self.mcpPath = Self.normalizedMCPPath(mcpPath)
        self.codexExecutablePath = Self.normalizedPath(codexExecutablePath)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            codexHomePath: try container.decodeIfPresent(String.self, forKey: .codexHomePath),
            mcpHost: try container.decodeIfPresent(String.self, forKey: .mcpHost) ?? Self.defaults.mcpHost,
            mcpPort: try container.decodeIfPresent(Int.self, forKey: .mcpPort) ?? Self.defaults.mcpPort,
            mcpPath: try container.decodeIfPresent(String.self, forKey: .mcpPath) ?? Self.defaults.mcpPath,
            codexExecutablePath: try container.decodeIfPresent(String.self, forKey: .codexExecutablePath)
        )
    }

    package var normalized: Self {
        Self(
            codexHomePath: codexHomePath,
            mcpHost: mcpHost,
            mcpPort: mcpPort,
            mcpPath: mcpPath,
            codexExecutablePath: codexExecutablePath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case codexHomePath
        case mcpHost
        case mcpPort
        case mcpPath
        case codexExecutablePath
    }

    private static func normalizedPath(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else {
            return nil
        }
        return expandedHomePath(trimmed)
    }

    private static func expandedHomePath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return homePath
        }
        if path.hasPrefix("~/") {
            return homePath + String(path.dropFirst())
        }
        return path
    }

    private static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaults.mcpHost : trimmed
    }

    private static func normalizedPort(_ port: Int) -> Int {
        (1...65535).contains(port) ? port : defaults.mcpPort
    }

    private static func normalizedMCPPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return defaults.mcpPath
        }
        let normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        guard isUnescapedURLPath(normalized) else {
            return defaults.mcpPath
        }
        return normalized
    }

    private static func isUnescapedURLPath(_ path: String) -> Bool {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.path = path
        return components.url != nil && components.percentEncodedPath == path
    }
}

@MainActor
public protocol CodexReviewRuntimePreferencesStore: AnyObject {
    func load() -> CodexReviewRuntimePreferences
    func save(_ preferences: CodexReviewRuntimePreferences) throws
}

@MainActor
public final class UserDefaultsCodexReviewRuntimePreferencesStore: CodexReviewRuntimePreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "codexReview.runtimePreferences"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> CodexReviewRuntimePreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? decoder.decode(CodexReviewRuntimePreferences.self, from: data)
        else {
            return .defaults
        }
        return preferences.normalized
    }

    public func save(_ preferences: CodexReviewRuntimePreferences) throws {
        let data = try encoder.encode(preferences.normalized)
        defaults.set(data, forKey: key)
    }
}
