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
        guard isAbsoluteOrHomeRelativePath(trimmed) else {
            return nil
        }
        return expandedHomePath(trimmed)
    }

    private static func isAbsoluteOrHomeRelativePath(_ path: String) -> Bool {
        path == "~" || path.hasPrefix("~/") || path.hasPrefix("/")
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
        guard trimmed.isEmpty == false,
              isValidHost(trimmed)
        else {
            return defaults.mcpHost
        }
        return trimmed
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

    private static func isValidHost(_ host: String) -> Bool {
        guard host.contains("[") == false,
              host.contains("]") == false
        else {
            return false
        }

        let dnsHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard dnsHost.isEmpty == false,
              dnsHost.utf8.count <= 253
        else {
            return false
        }

        if dnsHost.contains("."),
           dnsHost.unicodeScalars.allSatisfy({ isASCIIDigit($0) || $0 == "." }) {
            return isValidIPv4Address(dnsHost)
        }

        return isValidDNSHost(dnsHost)
    }

    private static func isValidIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }

        for part in parts {
            guard part.isEmpty == false,
                  part.count <= 3,
                  part.unicodeScalars.allSatisfy(isASCIIDigit),
                  let value = Int(part),
                  (0...255).contains(value),
                  part.count == 1 || part.first != "0"
            else {
                return false
            }
        }
        return true
    }

    private static func isValidDNSHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.isEmpty == false else {
            return false
        }

        for label in labels {
            guard (1...63).contains(label.utf8.count),
                  let first = label.unicodeScalars.first,
                  let last = label.unicodeScalars.last,
                  isASCIIAlphanumeric(first),
                  isASCIIAlphanumeric(last),
                  label.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "-" })
            else {
                return false
            }
        }
        return true
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        isASCIIDigit(scalar)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
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
