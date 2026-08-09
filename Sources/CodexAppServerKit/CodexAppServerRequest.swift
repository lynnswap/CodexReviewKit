import CoreFoundation
import Foundation

package enum CodexServerRequestID: Hashable, Sendable, Codable {
    case integer(Int64)
    case string(String)

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    package init?(jsonObject: Any?) {
        switch jsonObject {
        case let value as String:
            self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
            let integer = value.int64Value
            guard value.doubleValue.isFinite,
                  value.doubleValue == Double(integer) else {
                return nil
            }
            self = .integer(integer)
        default:
            return nil
        }
    }

    package var jsonObject: Any {
        switch self {
        case .integer(let value):
            value
        case .string(let value):
            value
        }
    }
}

/// A typed request initiated by the Codex app-server.
public enum CodexAppServerRequest: Equatable, Sendable {
    case commandExecutionApproval(CodexCommandExecutionApprovalRequest)
    case fileChangeApproval(CodexFileChangeApprovalRequest)
    case userInput(CodexUserInputRequest)
    case mcpElicitation(CodexMCPElicitationRequest)
    case permissions(CodexPermissionsRequest)
    case dynamicToolCall(CodexDynamicToolCallRequest)
    case chatGPTAuthTokensRefresh(CodexChatGPTAuthTokensRefreshRequest)
    case attestationGenerate(CodexAttestationGenerateRequest)
    case currentTimeRead(CodexCurrentTimeReadRequest)
    case unknown(CodexRawServerRequest)

    /// The current-v2 JSON-RPC method represented by this request.
    public var method: String {
        switch self {
        case .commandExecutionApproval:
            "item/commandExecution/requestApproval"
        case .fileChangeApproval:
            "item/fileChange/requestApproval"
        case .userInput:
            "item/tool/requestUserInput"
        case .mcpElicitation:
            "mcpServer/elicitation/request"
        case .permissions:
            "item/permissions/requestApproval"
        case .dynamicToolCall:
            "item/tool/call"
        case .chatGPTAuthTokensRefresh:
            "account/chatgptAuthTokens/refresh"
        case .attestationGenerate:
            "attestation/generate"
        case .currentTimeRead:
            "currentTime/read"
        case .unknown(let request):
            request.method
        }
    }
}

public struct CodexCommandExecutionApprovalRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let startedAtMs: Int64
    public let approvalID: String?
    public let environmentID: String?
    public let reason: String?
    public let networkApprovalContext: CodexJSONValue?
    public let command: String?
    public let cwd: String?
    public let commandActions: [CodexJSONValue]?
    public let additionalPermissions: CodexJSONValue?
    public let proposedExecpolicyAmendment: CodexExecPolicyAmendment?
    public let proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]?
    public let availableDecisions: [CodexApprovalDecision]?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case startedAtMs
        case approvalID = "approvalId"
        case environmentID = "environmentId"
        case reason
        case networkApprovalContext
        case command
        case cwd
        case commandActions
        case additionalPermissions
        case proposedExecpolicyAmendment
        case proposedNetworkPolicyAmendments
        case availableDecisions
    }
}

public struct CodexFileChangeApprovalRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let startedAtMs: Int64
    public let reason: String?
    public let grantRoot: String?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case startedAtMs
        case reason
        case grantRoot
    }
}

public struct CodexUserInputOption: Codable, Equatable, Sendable {
    public let label: String
    public let description: String
}

public struct CodexUserInputQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let isOther: Bool
    public let isSecret: Bool
    public let options: [CodexUserInputOption]?
}

public struct CodexUserInputRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let questions: [CodexUserInputQuestion]
    public let autoResolutionMs: UInt64?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case questions
        case autoResolutionMs
    }
}

public struct CodexMCPElicitationRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String?
    public let serverName: String
    public let elicitation: CodexMCPElicitation

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case serverName
        case mode
        case meta = "_meta"
        case message
        case requestedSchema
        case url
        case elicitationID = "elicitationId"
    }

    private enum Mode: String, Codable {
        case form
        case openAIForm = "openai/form"
        case url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.threadID = try container.decode(String.self, forKey: .threadID)
        self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        self.serverName = try container.decode(String.self, forKey: .serverName)
        let meta = try container.decodeIfPresent(CodexJSONValue.self, forKey: .meta)
        let message = try container.decode(String.self, forKey: .message)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .form:
            self.elicitation = .form(
                meta: meta,
                message: message,
                requestedSchema: try container.decode(
                    CodexJSONValue.self,
                    forKey: .requestedSchema
                )
            )
        case .openAIForm:
            self.elicitation = .openAIForm(
                meta: meta,
                message: message,
                requestedSchema: try container.decode(
                    CodexJSONValue.self,
                    forKey: .requestedSchema
                )
            )
        case .url:
            self.elicitation = .url(
                meta: meta,
                message: message,
                url: try container.decode(String.self, forKey: .url),
                elicitationID: try container.decode(String.self, forKey: .elicitationID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(serverName, forKey: .serverName)
        switch elicitation {
        case .form(let meta, let message, let requestedSchema):
            try container.encode(Mode.form, forKey: .mode)
            try container.encode(meta, forKey: .meta)
            try container.encode(message, forKey: .message)
            try container.encode(requestedSchema, forKey: .requestedSchema)
        case .openAIForm(let meta, let message, let requestedSchema):
            try container.encode(Mode.openAIForm, forKey: .mode)
            try container.encode(meta, forKey: .meta)
            try container.encode(message, forKey: .message)
            try container.encode(requestedSchema, forKey: .requestedSchema)
        case .url(let meta, let message, let url, let elicitationID):
            try container.encode(Mode.url, forKey: .mode)
            try container.encode(meta, forKey: .meta)
            try container.encode(message, forKey: .message)
            try container.encode(url, forKey: .url)
            try container.encode(elicitationID, forKey: .elicitationID)
        }
    }
}

public enum CodexMCPElicitation: Equatable, Sendable {
    case form(meta: CodexJSONValue?, message: String, requestedSchema: CodexJSONValue)
    case openAIForm(meta: CodexJSONValue?, message: String, requestedSchema: CodexJSONValue)
    case url(meta: CodexJSONValue?, message: String, url: String, elicitationID: String)
}

public struct CodexPermissionsRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let environmentID: String?
    public let startedAtMs: Int64
    public let cwd: String
    public let reason: String?
    public let permissions: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case environmentID = "environmentId"
        case startedAtMs
        case cwd
        case reason
        case permissions
    }
}

public struct CodexDynamicToolCallRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let callID: String
    public let namespace: String?
    public let tool: String
    public let arguments: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case callID = "callId"
        case namespace
        case tool
        case arguments
    }
}

public enum CodexChatGPTAuthTokensRefreshReason: String, Codable, Equatable, Sendable {
    case unauthorized
}

public struct CodexChatGPTAuthTokensRefreshRequest: Codable, Equatable, Sendable {
    public let reason: CodexChatGPTAuthTokensRefreshReason
    public let previousAccountID: String?

    private enum CodingKeys: String, CodingKey {
        case reason
        case previousAccountID = "previousAccountId"
    }
}

public struct CodexAttestationGenerateRequest: Codable, Equatable, Sendable {}

public struct CodexCurrentTimeReadRequest: Codable, Equatable, Sendable {
    public let threadID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexRawServerRequest: Equatable, Sendable {
    public let method: String
    public let params: Data
}

/// The host's typed resolution for an app-server request.
public enum CodexAppServerRequestResolution: Equatable, Sendable {
    case approval(CodexApprovalDecision)
    case userInput(CodexUserInputResponse)
    case permissions(CodexPermissionsResponse)
    case dynamicToolCall(CodexDynamicToolCallResponse)
    case mcpElicitation(CodexMCPElicitationResponse)
    case chatGPTAuthTokensRefresh(CodexChatGPTAuthTokensRefreshResponse)
    case attestationGenerate(CodexAttestationGenerateResponse)
    case currentTimeRead(CodexCurrentTimeReadResponse)
    case rejectUnknown(code: Int, message: String)
}

/// Handles app-server requests that require a host-side response.
public typealias CodexAppServerRequestHandler =
    @Sendable (CodexAppServerRequest) async throws -> CodexAppServerRequestResolution

public enum CodexApprovalDecision: Codable, Equatable, Sendable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(CodexExecPolicyAmendment)
    case applyNetworkPolicyAmendment(CodexNetworkPolicyAmendment)
    case decline
    case cancel

    private enum Scalar: String, Codable {
        case accept
        case acceptForSession
        case decline
        case cancel
    }

    private enum CodingKeys: String, CodingKey {
        case acceptWithExecpolicyAmendment
        case applyNetworkPolicyAmendment
    }

    private enum ExecPolicyCodingKeys: String, CodingKey {
        case amendment = "execpolicy_amendment"
    }

    private enum NetworkPolicyCodingKeys: String, CodingKey {
        case amendment = "network_policy_amendment"
    }

    public init(from decoder: Decoder) throws {
        if let scalar = try? Scalar(from: decoder) {
            self = switch scalar {
            case .accept: .accept
            case .acceptForSession: .acceptForSession
            case .decline: .decline
            case .cancel: .cancel
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.acceptWithExecpolicyAmendment) {
            let nested = try container.nestedContainer(
                keyedBy: ExecPolicyCodingKeys.self,
                forKey: .acceptWithExecpolicyAmendment
            )
            self = .acceptWithExecpolicyAmendment(
                try nested.decode(CodexExecPolicyAmendment.self, forKey: .amendment)
            )
        } else {
            let nested = try container.nestedContainer(
                keyedBy: NetworkPolicyCodingKeys.self,
                forKey: .applyNetworkPolicyAmendment
            )
            self = .applyNetworkPolicyAmendment(
                try nested.decode(CodexNetworkPolicyAmendment.self, forKey: .amendment)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .accept:
            try Scalar.accept.encode(to: encoder)
        case .acceptForSession:
            try Scalar.acceptForSession.encode(to: encoder)
        case .decline:
            try Scalar.decline.encode(to: encoder)
        case .cancel:
            try Scalar.cancel.encode(to: encoder)
        case .acceptWithExecpolicyAmendment(let amendment):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var nested = container.nestedContainer(
                keyedBy: ExecPolicyCodingKeys.self,
                forKey: .acceptWithExecpolicyAmendment
            )
            try nested.encode(amendment, forKey: .amendment)
        case .applyNetworkPolicyAmendment(let amendment):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var nested = container.nestedContainer(
                keyedBy: NetworkPolicyCodingKeys.self,
                forKey: .applyNetworkPolicyAmendment
            )
            try nested.encode(amendment, forKey: .amendment)
        }
    }

    package var isValidForFileChange: Bool {
        switch self {
        case .accept, .acceptForSession, .decline, .cancel:
            true
        case .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment:
            false
        }
    }
}

public struct CodexExecPolicyAmendment: Codable, Equatable, Sendable {
    public var command: [String]

    public init(command: [String]) {
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.command = try container.decode([String].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(command)
    }
}

public enum CodexNetworkPolicyRuleAction: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

public struct CodexNetworkPolicyAmendment: Codable, Equatable, Sendable {
    public var host: String
    public var action: CodexNetworkPolicyRuleAction

    public init(host: String, action: CodexNetworkPolicyRuleAction) {
        self.host = host
        self.action = action
    }
}

public struct CodexUserInputAnswer: Codable, Equatable, Sendable {
    public var answers: [String]

    public init(answers: [String]) {
        self.answers = answers
    }
}

public struct CodexUserInputResponse: Codable, Equatable, Sendable {
    public var answers: [String: CodexUserInputAnswer]

    public init(answers: [String: CodexUserInputAnswer]) {
        self.answers = answers
    }
}

public struct CodexGrantedPermissionProfile: Codable, Equatable, Sendable {
    public var network: CodexJSONValue?
    public var fileSystem: CodexJSONValue?

    public init(network: CodexJSONValue?, fileSystem: CodexJSONValue?) {
        self.network = network
        self.fileSystem = fileSystem
    }
}

public enum CodexPermissionGrantScope: String, Codable, Equatable, Sendable {
    case turn
    case session
}

public struct CodexPermissionsResponse: Codable, Equatable, Sendable {
    public var permissions: CodexGrantedPermissionProfile
    public var scope: CodexPermissionGrantScope
    public var strictAutoReview: Bool?

    public init(
        permissions: CodexGrantedPermissionProfile,
        scope: CodexPermissionGrantScope,
        strictAutoReview: Bool? = nil
    ) {
        self.permissions = permissions
        self.scope = scope
        self.strictAutoReview = strictAutoReview
    }
}

public enum CodexDynamicToolCallOutputContentItem: Codable, Equatable, Sendable {
    case inputText(text: String)
    case inputImage(imageURL: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "imageUrl"
    }

    private enum Kind: String, Codable {
        case inputText
        case inputImage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .inputText:
            self = .inputText(text: try container.decode(String.self, forKey: .text))
        case .inputImage:
            self = .inputImage(imageURL: try container.decode(String.self, forKey: .imageURL))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode(Kind.inputText, forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputImage(let imageURL):
            try container.encode(Kind.inputImage, forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
        }
    }
}

public struct CodexDynamicToolCallResponse: Codable, Equatable, Sendable {
    public var contentItems: [CodexDynamicToolCallOutputContentItem]
    public var success: Bool

    public init(contentItems: [CodexDynamicToolCallOutputContentItem], success: Bool) {
        self.contentItems = contentItems
        self.success = success
    }
}

public enum CodexMCPElicitationAction: String, Codable, Equatable, Sendable {
    case accept
    case decline
    case cancel
}

public struct CodexMCPElicitationResponse: Codable, Equatable, Sendable {
    public var action: CodexMCPElicitationAction
    public var content: CodexJSONValue?
    public var meta: CodexJSONValue?

    public init(
        action: CodexMCPElicitationAction,
        content: CodexJSONValue? = nil,
        meta: CodexJSONValue? = nil
    ) {
        self.action = action
        self.content = content
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case content
        case meta = "_meta"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(content, forKey: .content)
        try container.encode(meta, forKey: .meta)
    }
}

public struct CodexChatGPTAuthTokensRefreshResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var chatGPTAccountID: String
    public var chatGPTPlanType: String?

    public init(
        accessToken: String,
        chatGPTAccountID: String,
        chatGPTPlanType: String? = nil
    ) {
        self.accessToken = accessToken
        self.chatGPTAccountID = chatGPTAccountID
        self.chatGPTPlanType = chatGPTPlanType
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case chatGPTAccountID = "chatgptAccountId"
        case chatGPTPlanType = "chatgptPlanType"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(chatGPTAccountID, forKey: .chatGPTAccountID)
        try container.encode(chatGPTPlanType, forKey: .chatGPTPlanType)
    }
}

public struct CodexAttestationGenerateResponse: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public struct CodexCurrentTimeReadResponse: Codable, Equatable, Sendable {
    public var currentTimeAt: Int64

    public init(currentTimeAt: Int64) {
        self.currentTimeAt = currentTimeAt
    }
}
