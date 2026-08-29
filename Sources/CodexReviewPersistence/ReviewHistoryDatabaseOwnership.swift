import Darwin
import Foundation

final class ReviewHistoryDatabaseOwnership {
    private var descriptor: Int32?
    private let lockPath: String

    init(databaseURL: URL) throws {
        lockPath = databaseURL.path(percentEncoded: false) + ".lock"
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK
        let descriptor = lockPath.withCString { pointer in
            Self.retryingEINTR {
                Darwin.open(pointer, flags, mode_t(0o600))
            }
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw ReviewHistoryDatabaseError.databaseInUse
            }
            throw ReviewHistoryDatabaseError.ownershipFailed(
                "open failed for \(lockPath): \(String(cString: strerror(code)))"
            )
        }
        var status = stat()
        guard Self.retryingEINTR({ fstat(descriptor, &status) }) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw ReviewHistoryDatabaseError.ownershipFailed(
                "inspect failed for \(lockPath): \(String(cString: strerror(code)))"
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = Darwin.close(descriptor)
            throw ReviewHistoryDatabaseError.ownershipFailed(
                "expected a regular lock file at \(lockPath)"
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        if let descriptor {
            _ = Darwin.close(descriptor)
        }
    }

    func close() throws {
        guard let descriptor else {
            return
        }
        self.descriptor = nil
        guard Darwin.close(descriptor) == 0 else {
            throw ReviewHistoryDatabaseError.ownershipFailed(
                "close failed for \(lockPath): \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func retryingEINTR(_ operation: () -> Int32) -> Int32 {
        var result: Int32
        repeat {
            result = operation()
        } while result == -1 && errno == EINTR
        return result
    }
}
