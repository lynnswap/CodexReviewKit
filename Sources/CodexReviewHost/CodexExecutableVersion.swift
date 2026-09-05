import Foundation

package struct CodexExecutableVersion: Comparable, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(UInt64)
        case alphanumeric(String)
    }

    private var major: UInt64
    private var minor: UInt64
    private var patch: UInt64
    private var prerelease: [PrereleaseIdentifier]?

    package init?(codexVersionOutput output: String) {
        let fields = output.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, fields[0] == "codex-cli" else { return nil }
        self.init(String(fields[1]))
    }

    private init?(_ value: String) {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2,
              buildParts.count == 1 || Self.validIdentifiers(buildParts[1], permitsLeadingZeroes: true)
        else { return nil }

        let precedenceParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = precedenceParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.coreNumber(core[0]),
              let minor = Self.coreNumber(core[1]),
              let patch = Self.coreNumber(core[2])
        else { return nil }

        let prerelease: [PrereleaseIdentifier]?
        if precedenceParts.count == 2 {
            let rawPrerelease = precedenceParts[1]
            guard Self.validIdentifiers(rawPrerelease, permitsLeadingZeroes: false) else { return nil }
            var identifiers: [PrereleaseIdentifier] = []
            for identifier in rawPrerelease.split(separator: ".") {
                if identifier.utf8.allSatisfy(Self.isASCIIDigit) {
                    guard let number = UInt64(identifier) else { return nil }
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.alphanumeric(String(identifier)))
                }
            }
            prerelease = identifiers
        } else {
            prerelease = nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let lhsIdentifiers), .some(let rhsIdentifiers)):
            for (lhsIdentifier, rhsIdentifier) in zip(lhsIdentifiers, rhsIdentifiers) {
                guard lhsIdentifier != rhsIdentifier else { continue }
                return Self.prereleaseIdentifier(lhsIdentifier, precedes: rhsIdentifier)
            }
            return lhsIdentifiers.count < rhsIdentifiers.count
        }
    }

    private static func coreNumber(_ value: Substring) -> UInt64? {
        guard value.isEmpty == false,
              value.utf8.allSatisfy(isASCIIDigit),
              value.count == 1 || value.first != "0"
        else { return nil }
        return UInt64(value)
    }

    private static func validIdentifiers(
        _ value: Substring,
        permitsLeadingZeroes: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard identifiers.isEmpty == false else { return false }
        return identifiers.allSatisfy { identifier in
            guard identifier.isEmpty == false,
                  identifier.utf8.allSatisfy(isASCIIIdentifierCharacter)
            else { return false }
            return permitsLeadingZeroes
                || identifier.utf8.allSatisfy(isASCIIDigit) == false
                || identifier.count == 1
                || identifier.first != "0"
        }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isASCIIIdentifierCharacter(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == 45
    }

    private static func prereleaseIdentifier(
        _ lhs: PrereleaseIdentifier,
        precedes rhs: PrereleaseIdentifier
    ) -> Bool {
        switch (lhs, rhs) {
        case (.numeric(let lhs), .numeric(let rhs)):
            return lhs < rhs
        case (.numeric, .alphanumeric):
            return true
        case (.alphanumeric, .numeric):
            return false
        case (.alphanumeric(let lhs), .alphanumeric(let rhs)):
            return lhs < rhs
        }
    }
}
