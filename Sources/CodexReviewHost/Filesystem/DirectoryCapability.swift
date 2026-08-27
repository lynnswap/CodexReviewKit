import Darwin
import Foundation
import Synchronization

package struct DirectoryPOSIXFailure: Equatable, Sendable {
    package let operation: String
    package let code: Int32
    package let path: String
}
package enum DirectoryCapabilityError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest(String)
    case policyViolation(String)
    case userActionRequired(DirectoryPOSIXFailure)
    case retryable(DirectoryPOSIXFailure)
    case ioFailure(DirectoryPOSIXFailure)
    case closed

    package var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .policyViolation(let message):
            message
        case .userActionRequired(let failure), .retryable(let failure), .ioFailure(let failure):
            "\(failure.operation) failed for \(failure.path): \(String(cString: strerror(failure.code)))"
        case .closed:
            "The directory capability is closed."
        }
    }
}
package final class DirectoryCapability: Sendable {
    package struct Name: Hashable, Sendable {
        fileprivate let value: String
        package init(_ value: String) throws {
            guard value.isEmpty == false, value != ".", value != "..",
                  value.contains("/") == false, value.utf8.contains(0) == false else {
                throw DirectoryCapabilityError.invalidRequest(
                    "A directory entry name must be one non-empty, non-dot component."
                )
            }
            self.value = value
        }
    }

    package struct Identity: Hashable, Sendable {
        package let deviceID: UInt64
        package let inode: UInt64
        fileprivate init(_ status: stat) {
            deviceID = UInt64(bitPattern: Int64(status.st_dev))
            inode = UInt64(status.st_ino)
        }
    }

    package struct Requirements: Equatable, Sendable {
        fileprivate enum Policy: Equatable, Sendable { case trustedAnchor, managed }
        fileprivate let policy: Policy
        fileprivate let ownerUserID: uid_t
        fileprivate let deviceID: UInt64?
        package static func trustedAnchor(ownerUserID: uid_t) -> Self {
            Self(policy: .trustedAnchor, ownerUserID: ownerUserID, deviceID: nil)
        }
        package static func managed(ownerUserID: uid_t, deviceID: UInt64) -> Self {
            Self(policy: .managed, ownerUserID: ownerUserID, deviceID: deviceID)
        }
        fileprivate var creationMode: mode_t? { policy == .managed ? 0o700 : nil }
    }
    package enum Acquisition: Equatable, Sendable { case existing, existingOrCreate, new }
    package enum Relationship: Equatable, Sendable { case same, ancestor, descendant, disjoint }
    private struct State: Sendable {
        var descriptor: Int32?
        var closeFailure: DirectoryPOSIXFailure?
    }
    package let identity: Identity
    private let requirements: Requirements
    private let url: URL
    private let state: Mutex<State>
    private init(descriptor: Int32, identity: Identity, requirements: Requirements, url: URL) {
        self.identity = identity
        self.requirements = requirements
        self.url = url
        state = Mutex(.init(descriptor: descriptor, closeFailure: nil))
    }
    deinit { try? close() }
    package static func openExisting(
        at absoluteURL: URL,
        requirements: Requirements
    ) throws -> DirectoryCapability {
        try validateAbsoluteURL(absoluteURL)
        let descriptor = try walkAbsoluteURL(absoluteURL)
        var transfersDescriptor = false
        defer { if transfersDescriptor == false { _ = Darwin.close(descriptor) } }
        let status = try directoryStatus(descriptor, path: absoluteURL.path)
        try validate(descriptor, status: status, requirements: requirements, path: absoluteURL.path)
        transfersDescriptor = true
        return DirectoryCapability(
            descriptor: descriptor,
            identity: Identity(status),
            requirements: requirements,
            url: absoluteURL
        )
    }

    package func directory(
        named name: Name,
        acquisition: Acquisition,
        requirements childRequirements: Requirements
    ) throws -> DirectoryCapability {
        try withBorrowedDescriptor { parent in
            try Self.validateOwned(parent, capability: self)
            let childURL = url.appendingPathComponent(name.value, isDirectory: true)
            let child = try Self.acquireChild(
                parent: parent,
                name: name,
                acquisition: acquisition,
                requirements: childRequirements,
                path: childURL.path
            )
            return DirectoryCapability(
                descriptor: child.descriptor,
                identity: child.identity,
                requirements: childRequirements,
                url: childURL
            )
        }
    }

    package func relationship(to other: DirectoryCapability) throws -> Relationship {
        try withBorrowedDescriptor { lhs in
            try other.withBorrowedDescriptor { rhs in
                try Self.validateOwned(lhs, capability: self)
                try Self.validateOwned(rhs, capability: other)
                if identity == other.identity { return .same }
                if try Self.isAncestor(identity, of: rhs, path: other.url.path) { return .ancestor }
                if try Self.isAncestor(other.identity, of: lhs, path: url.path) { return .descendant }
                return .disjoint
            }
        }
    }
    package func withRevalidatedPath<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try withBorrowedDescriptor { borrowed in
            try Self.validateOwned(borrowed, capability: self)
            let reopened = try Self.walkAbsoluteURL(url)
            defer { _ = Darwin.close(reopened) }
            let status = try Self.directoryStatus(reopened, path: url.path)
            guard Identity(status) == identity else {
                throw DirectoryCapabilityError.policyViolation(
                    "The directory changed identity before path handoff at \(url.path)."
                )
            }
            try Self.validate(reopened, status: status, requirements: requirements, path: url.path)
            // Path-only Process/GRDB APIs cannot consume this descriptor. The documented threat
            // model excludes a malicious same-UID rename after this synchronous boundary.
            return try body(url)
        }
    }

    package func close() throws {
        let path = url.path
        let failure = state.withLock { state -> DirectoryPOSIXFailure? in
            if let failure = state.closeFailure { return failure }
            guard let descriptor = state.descriptor else { return nil }
            state.descriptor = nil
            guard Darwin.close(descriptor) != 0 else { return nil }
            let failure = DirectoryPOSIXFailure(
                operation: "close directory capability", code: errno, path: path
            )
            state.closeFailure = failure
            return failure
        }
        if let failure { throw DirectoryCapabilityError.ioFailure(failure) }
    }

    private func withBorrowedDescriptor<Result>(_ body: (Int32) throws -> Result) throws -> Result {
        let path = url.path
        let descriptor = try state.withLock { state -> Int32 in
            guard let owned = state.descriptor else { throw DirectoryCapabilityError.closed }
            let duplicate = Self.retryingEINTR { fcntl(owned, F_DUPFD_CLOEXEC, 0) }
            guard duplicate >= 0 else {
                throw Self.posixError(operation: "duplicate directory descriptor", code: errno, path: path)
            }
            return duplicate
        }
        var needsClose = true
        defer { if needsClose { _ = Darwin.close(descriptor) } }
        let value = try body(descriptor)
        let closeResult = Darwin.close(descriptor)
        needsClose = false
        guard closeResult == 0 else {
            throw Self.posixError(operation: "close borrowed descriptor", code: errno, path: path)
        }
        return value
    }

    private static func acquireChild(
        parent: Int32,
        name: Name,
        acquisition: Acquisition,
        requirements: Requirements,
        path: String
    ) throws -> (descriptor: Int32, identity: Identity) {
        let mode = requirements.creationMode
        var createdIdentity: Identity?
        let descriptor: Int32
        do {
            switch acquisition {
            case .existing:
                descriptor = try openChild(parent: parent, name: name, path: path)
            case .new:
                guard let mode else {
                    throw DirectoryCapabilityError.invalidRequest("Only managed directories can be created.")
                }
                createdIdentity = try createChild(
                    parent: parent, name: name, mode: mode, allowExisting: false, path: path)
                descriptor = try openChild(parent: parent, name: name, path: path)
            case .existingOrCreate:
                if let opened = try openChildIfPresent(parent: parent, name: name, path: path) {
                    descriptor = opened
                } else {
                    guard let mode else {
                        throw DirectoryCapabilityError.invalidRequest("Only managed directories can be created.")
                    }
                    createdIdentity = try createChild(
                        parent: parent, name: name, mode: mode, allowExisting: true, path: path)
                    descriptor = try openChild(parent: parent, name: name, path: path)
                }
            }
        } catch {
            if let createdIdentity {
                try rollbackChild(parent: parent, name: name, identity: createdIdentity, path: path)
            }
            throw error
        }
        var transfersDescriptor = false
        defer { if transfersDescriptor == false { _ = Darwin.close(descriptor) } }
        let identity: Identity
        do {
            var status = try directoryStatus(descriptor, path: path)
            identity = Identity(status)
            guard createdIdentity == nil || createdIdentity == identity else {
                throw DirectoryCapabilityError.policyViolation(
                    "The created directory changed identity before reopening at \(path).")
            }
            if createdIdentity != nil, let mode {
                let result = retryingEINTR { fchmod(descriptor, mode) }
                guard result == 0 else {
                    throw posixError(operation: "set created directory permissions", code: errno, path: path)
                }
                status = try directoryStatus(descriptor, path: path)
            }
            try validate(descriptor, status: status, requirements: requirements, path: path)
        } catch {
            _ = Darwin.close(descriptor)
            transfersDescriptor = true
            if let createdIdentity {
                try rollbackChild(parent: parent, name: name, identity: createdIdentity, path: path)
            }
            throw error
        }
        transfersDescriptor = true
        return (descriptor, identity)
    }
    private static func openChildIfPresent(parent: Int32, name: Name, path: String) throws -> Int32? {
        let result = name.value.withCString { pointer in
            retryingEINTR { openat(parent, pointer, directoryOpenFlags) }
        }
        if result >= 0 { return result }
        if errno == ENOENT { return nil }
        throw openError(code: errno, path: path)
    }
    private static func openChild(parent: Int32, name: Name, path: String) throws -> Int32 {
        if let descriptor = try openChildIfPresent(parent: parent, name: name, path: path) {
            return descriptor
        }
        throw posixError(operation: "open directory", code: ENOENT, path: path)
    }
    private static func createChild(
        parent: Int32,
        name: Name,
        mode: mode_t,
        allowExisting: Bool,
        path: String
    ) throws -> Identity? {
        let result = name.value.withCString { pointer in
            retryingEINTR { mkdirat(parent, pointer, mode) }
        }
        if result == 0 {
            var status = stat()
            let inspected = name.value.withCString { pointer in
                retryingEINTR { fstatat(parent, pointer, &status, AT_SYMLINK_NOFOLLOW) }
            }
            guard inspected == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw posixError(operation: "inspect created directory", code: errno, path: path)
            }
            return Identity(status)
        }
        if errno == EEXIST, allowExisting { return nil }
        if errno == EEXIST {
            throw DirectoryCapabilityError.policyViolation("A directory already exists at \(path).")
        }
        throw posixError(operation: "create directory", code: errno, path: path)
    }
    private static func rollbackChild(
        parent: Int32,
        name: Name,
        identity: Identity,
        path: String
    ) throws {
        var status = stat()
        let inspected = name.value.withCString { pointer in
            retryingEINTR { fstatat(parent, pointer, &status, AT_SYMLINK_NOFOLLOW) }
        }
        guard inspected == 0 else {
            throw posixError(operation: "inspect directory rollback", code: errno, path: path)
        }
        guard Identity(status) == identity,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DirectoryCapabilityError.policyViolation(
                "The created directory changed identity before rollback at \(path)."
            )
        }
        let removed = name.value.withCString { pointer in
            retryingEINTR { unlinkat(parent, pointer, AT_REMOVEDIR) }
        }
        guard removed == 0 else {
            throw posixError(operation: "roll back created directory", code: errno, path: path)
        }
    }
    private static func walkAbsoluteURL(_ url: URL) throws -> Int32 {
        try validateAbsoluteURL(url)
        let names = try url.path.split(separator: "/").map { try Name(String($0)) }
        var current = retryingEINTR { Darwin.open("/", directoryOpenFlags) }
        guard current >= 0 else {
            throw posixError(operation: "open root directory", code: errno, path: "/")
        }
        var transfersDescriptor = false
        defer { if transfersDescriptor == false { _ = Darwin.close(current) } }
        var pathURL = URL(fileURLWithPath: "/", isDirectory: true)
        for name in names {
            pathURL.appendPathComponent(name.value, isDirectory: true)
            let next = try openChild(parent: current, name: name, path: pathURL.path)
            _ = Darwin.close(current)
            current = next
        }
        transfersDescriptor = true
        return current
    }

    private static func validateAbsoluteURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" else {
            throw DirectoryCapabilityError.invalidRequest(
                "Directory acquisition requires an absolute local file URL."
            )
        }
    }
    private static func validateOwned(_ descriptor: Int32, capability: DirectoryCapability) throws {
        let status = try directoryStatus(descriptor, path: capability.url.path)
        guard Identity(status) == capability.identity else {
            throw DirectoryCapabilityError.policyViolation(
                "The opened directory changed identity at \(capability.url.path)."
            )
        }
        try validate(
            descriptor,
            status: status,
            requirements: capability.requirements,
            path: capability.url.path
        )
    }
    private static func validate(
        _ descriptor: Int32,
        status: stat,
        requirements: Requirements,
        path: String
    ) throws {
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DirectoryCapabilityError.policyViolation("Expected a directory at \(path).")
        }
        guard status.st_uid == requirements.ownerUserID else {
            throw DirectoryCapabilityError.policyViolation("Directory owner mismatch at \(path).")
        }
        let permissions = status.st_mode & 0o7777
        switch requirements.policy {
        case .trustedAnchor:
            guard permissions & 0o022 == 0 else {
                throw DirectoryCapabilityError.policyViolation(
                    "Trusted directory is writable by another principal at \(path)."
                )
            }
        case .managed:
            guard Identity(status).deviceID == requirements.deviceID, permissions == 0o700 else {
                throw DirectoryCapabilityError.policyViolation(
                    "Managed directory device or permissions mismatch at \(path)."
                )
            }
        }
        try validateACL(descriptor, policy: requirements.policy, path: path)
    }
    private static func validateACL(
        _ descriptor: Int32,
        policy: Requirements.Policy,
        path: String
    ) throws {
        var acl: acl_t?
        repeat {
            errno = 0
            acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
        } while acl == nil && errno == EINTR
        guard let acl else {
            if errno == ENOENT { return }
            throw posixError(operation: "read directory ACL", code: errno == 0 ? EIO : errno, path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            errno = 0
            let result = acl_get_entry(acl, entryID, &entry)
            if result == -1, entryID == Int32(ACL_NEXT_ENTRY.rawValue), errno == EINVAL { return }
            guard result == 0, let entry else {
                throw posixError(
                    operation: "read directory ACL entry",
                    code: errno == 0 ? EIO : errno,
                    path: path
                )
            }
            if policy == .managed {
                throw DirectoryCapabilityError.policyViolation("Managed directory has an ACL at \(path).")
            }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw DirectoryCapabilityError.policyViolation(
                    "Trusted directory ACL grants or has unknown access at \(path)."
                )
            }
            entryID = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private static func isAncestor(_ ancestor: Identity, of descriptor: Int32, path: String) throws -> Bool {
        var current = retryingEINTR { fcntl(descriptor, F_DUPFD_CLOEXEC, 0) }
        guard current >= 0 else {
            throw posixError(operation: "duplicate directory for ancestry", code: errno, path: path)
        }
        defer { _ = Darwin.close(current) }
        while true {
            let currentIdentity = Identity(try directoryStatus(current, path: path))
            if currentIdentity == ancestor { return true }
            let parent = retryingEINTR { openat(current, "..", directoryOpenFlags) }
            guard parent >= 0 else { throw openError(code: errno, path: path) }
            let parentStatus: stat
            do {
                parentStatus = try directoryStatus(parent, path: path)
            } catch {
                _ = Darwin.close(parent)
                throw error
            }
            let parentIdentity = Identity(parentStatus)
            if parentIdentity == currentIdentity {
                _ = Darwin.close(parent)
                return false
            }
            _ = Darwin.close(current)
            current = parent
        }
    }

    private static func directoryStatus(_ descriptor: Int32, path: String) throws -> stat {
        var status = stat()
        let result = retryingEINTR { fstat(descriptor, &status) }
        guard result == 0 else {
            throw posixError(operation: "inspect directory", code: errno, path: path)
        }
        return status
    }

    private static func openError(code: Int32, path: String) -> DirectoryCapabilityError {
        if code == ELOOP { return .policyViolation("Symbolic links are not allowed at \(path).") }
        if code == ENOTDIR {
            return .policyViolation("A directory component is not a directory at \(path).")
        }
        return posixError(operation: "open directory", code: code, path: path)
    }
    private static func posixError(
        operation: String,
        code: Int32,
        path: String
    ) -> DirectoryCapabilityError {
        let failure = DirectoryPOSIXFailure(operation: operation, code: code, path: path)
        if code == EAGAIN || code == EBUSY || code == ETXTBSY { return .retryable(failure) }
        if [EACCES, EPERM, ENOENT, ENOSPC, EDQUOT, EMFILE, ENFILE, EROFS].contains(code) {
            return .userActionRequired(failure)
        }
        return .ioFailure(failure)
    }
    private static func retryingEINTR(_ operation: () -> Int32) -> Int32 {
        var result: Int32
        repeat { result = operation() } while result == -1 && errno == EINTR
        return result
    }
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
}
