import Foundation

enum MCPProtocolServerError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let key):
            "Missing required argument: \(key)."
        case .invalidArgument(let message):
            message
        }
    }
}
