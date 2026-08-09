import CodexAppServerKit
import Foundation

public struct CodexAppServerTestModel: Equatable, Sendable {
    public enum InputModality: Equatable, Sendable {
        case text
        case image

        fileprivate var wireValue: String {
            switch self {
            case .text: "text"
            case .image: "image"
            }
        }
    }

    public struct UpgradeInfo: Equatable, Sendable {
        public var model: String
        public var upgradeCopy: String?
        public var modelLink: String?
        public var migrationMarkdown: String?

        public init(
            model: String,
            upgradeCopy: String? = nil,
            modelLink: String? = nil,
            migrationMarkdown: String? = nil
        ) throws {
            try requireNonEmpty(model, field: "upgrade model")
            self.model = model
            self.upgradeCopy = upgradeCopy
            self.modelLink = modelLink
            self.migrationMarkdown = migrationMarkdown
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "model": .string(model),
                "upgradeCopy": upgradeCopy.map(CodexJSONValue.string) ?? .null,
                "modelLink": modelLink.map(CodexJSONValue.string) ?? .null,
                "migrationMarkdown": migrationMarkdown.map(CodexJSONValue.string) ?? .null,
            ])
        }
    }

    public struct AvailabilityNUX: Equatable, Sendable {
        public var message: String

        public init(message: String) {
            self.message = message
        }

        fileprivate var wireValue: CodexJSONValue {
            .object(["message": .string(message)])
        }
    }

    public struct ServiceTier: Equatable, Sendable {
        public var id: String
        public var name: String
        public var description: String

        public init(id: String, name: String, description: String) throws {
            try requireNonEmpty(id, field: "service-tier id")
            try requireNonEmpty(name, field: "service-tier name")
            self.id = id
            self.name = name
            self.description = description
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "id": .string(id),
                "name": .string(name),
                "description": .string(description),
            ])
        }
    }

    private let id: String
    private let model: String
    private let upgrade: String?
    private let upgradeInfo: UpgradeInfo?
    private let availabilityNUX: AvailabilityNUX?
    private let displayName: String
    private let modelDescription: String
    private let hidden: Bool
    private let supportedReasoningEfforts: [CodexModel.ReasoningOption]
    private let defaultReasoningEffort: CodexReasoningEffort
    private let inputModalities: [InputModality]
    private let supportsPersonality: Bool
    private let additionalSpeedTiers: [String]
    private let serviceTiers: [ServiceTier]
    private let defaultServiceTier: String?
    private let isDefault: Bool

    public init(
        id: String,
        model: String,
        upgrade: String?,
        upgradeInfo: UpgradeInfo?,
        availabilityNUX: AvailabilityNUX?,
        displayName: String,
        description: String,
        hidden: Bool,
        supportedReasoningEfforts: [CodexModel.ReasoningOption],
        defaultReasoningEffort: CodexReasoningEffort,
        inputModalities: [InputModality],
        supportsPersonality: Bool,
        additionalSpeedTiers: [String],
        serviceTiers: [ServiceTier],
        defaultServiceTier: String?,
        isDefault: Bool
    ) throws {
        try requireNonEmpty(id, field: "model id")
        try requireNonEmpty(model, field: "model wire name")
        try requireNonEmpty(displayName, field: "model display name")
        guard inputModalities.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture(
                "model input modalities must not be empty"
            )
        }
        if let defaultServiceTier,
            serviceTiers.contains(where: { $0.id == defaultServiceTier }) == false
        {
            throw CodexAppServerTestError.invalidFixture(
                "default service tier must reference a declared service tier"
            )
        }
        self.id = id
        self.model = model
        self.upgrade = upgrade
        self.upgradeInfo = upgradeInfo
        self.availabilityNUX = availabilityNUX
        self.displayName = displayName
        self.modelDescription = description
        self.hidden = hidden
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.inputModalities = inputModalities
        self.supportsPersonality = supportsPersonality
        self.additionalSpeedTiers = additionalSpeedTiers
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
        self.isDefault = isDefault
    }

    public var domainProjection: CodexModel {
        guard let data = try? JSONEncoder().encode(wireValue),
            let model = try? JSONDecoder().decode(CodexModel.self, from: data)
        else {
            preconditionFailure("Validated model fixture failed to decode.")
        }
        return model
    }

    package var wireValue: CodexJSONValue {
        .object([
            "id": .string(id),
            "model": .string(model),
            "upgrade": upgrade.map(CodexJSONValue.string) ?? .null,
            "upgradeInfo": upgradeInfo?.wireValue ?? .null,
            "availabilityNux": availabilityNUX?.wireValue ?? .null,
            "displayName": .string(displayName),
            "description": .string(modelDescription),
            "hidden": .bool(hidden),
            "supportedReasoningEfforts": .array(supportedReasoningEfforts.map {
                .object([
                    "reasoningEffort": .string($0.reasoningEffort.rawValue),
                    "description": .string($0.description),
                ])
            }),
            "defaultReasoningEffort": .string(defaultReasoningEffort.rawValue),
            "inputModalities": .array(inputModalities.map { .string($0.wireValue) }),
            "supportsPersonality": .bool(supportsPersonality),
            "additionalSpeedTiers": .array(additionalSpeedTiers.map(CodexJSONValue.string)),
            "serviceTiers": .array(serviceTiers.map(\.wireValue)),
            "defaultServiceTier": defaultServiceTier.map(CodexJSONValue.string) ?? .null,
            "isDefault": .bool(isDefault),
        ])
    }
}

public struct CodexAppServerTestModelPage: Equatable, Sendable {
    public var models: [CodexAppServerTestModel]
    public var nextCursor: String?

    public init(models: [CodexAppServerTestModel], nextCursor: String? = nil) {
        self.models = models
        self.nextCursor = nextCursor
    }

    package var wireValue: CodexJSONValue {
        .object([
            "data": .array(models.map(\.wireValue)),
            "nextCursor": nextCursor.map(CodexJSONValue.string) ?? .null,
        ])
    }
}

public enum CodexAppServerTestBedrockCredentialSource: Equatable, Sendable {
    case codexManaged
    case awsManaged

    fileprivate var wireValue: String {
        switch self {
        case .codexManaged: "codexManaged"
        case .awsManaged: "awsManaged"
        }
    }
}

public struct CodexAppServerTestAccount: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case apiKey
        case chatGPT(email: String?, planType: CodexAppServerTestPlanType)
        case amazonBedrock(credentialSource: CodexAppServerTestBedrockCredentialSource)
    }

    private let kind: Kind

    public init(kind: Kind) throws {
        if case .chatGPT(let email?, _) = kind, email.isEmpty {
            throw CodexAppServerTestError.invalidFixture("account email must not be empty")
        }
        self.kind = kind
    }

    public var domainProjection: CodexAccount {
        guard let data = try? JSONEncoder().encode(wireValue),
            let snapshot = try? JSONDecoder().decode(
                AppServerAPI.Account.Snapshot.self,
                from: data
            )
        else {
            preconditionFailure("Validated account fixture failed to decode.")
        }
        return CodexAppServer.account(from: snapshot)
    }

    package var wireValue: CodexJSONValue {
        switch kind {
        case .apiKey:
            .object(["type": .string("apiKey")])
        case .chatGPT(let email, let planType):
            .object([
                "type": .string("chatgpt"),
                "email": email.map(CodexJSONValue.string) ?? .null,
                "planType": .string(planType.wireValue),
            ])
        case .amazonBedrock(let credentialSource):
            .object([
                "type": .string("amazonBedrock"),
                "credentialSource": .string(credentialSource.wireValue),
            ])
        }
    }
}

public struct CodexAppServerTestRateLimitsResponse: Equatable, Sendable {
    public enum ResetType: Equatable, Sendable {
        case codexRateLimits
        case unknown

        fileprivate var wireValue: String {
            switch self {
            case .codexRateLimits: "codex_rate_limits"
            case .unknown: "unknown"
            }
        }
    }

    public enum ResetCreditStatus: Equatable, Sendable {
        case available
        case redeeming
        case redeemed
        case unknown

        fileprivate var wireValue: String {
            switch self {
            case .available: "available"
            case .redeeming: "redeeming"
            case .redeemed: "redeemed"
            case .unknown: "unknown"
            }
        }
    }

    public struct ResetCredit: Equatable, Sendable {
        public var id: String
        public var resetType: ResetType
        public var status: ResetCreditStatus
        public var grantedAtUnixSeconds: Int64
        public var expiresAtUnixSeconds: Int64?
        public var title: String?
        public var description: String?

        public init(
            id: String,
            resetType: ResetType,
            status: ResetCreditStatus,
            grantedAtUnixSeconds: Int64,
            expiresAtUnixSeconds: Int64?,
            title: String?,
            description: String?
        ) throws {
            try requireNonEmpty(id, field: "reset-credit id")
            self.id = id
            self.resetType = resetType
            self.status = status
            self.grantedAtUnixSeconds = grantedAtUnixSeconds
            self.expiresAtUnixSeconds = expiresAtUnixSeconds
            self.title = title
            self.description = description
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "id": .string(id),
                "resetType": .string(resetType.wireValue),
                "status": .string(status.wireValue),
                "grantedAt": .int(Int(grantedAtUnixSeconds)),
                "expiresAt": expiresAtUnixSeconds.map { .int(Int($0)) } ?? .null,
                "title": title.map(CodexJSONValue.string) ?? .null,
                "description": description.map(CodexJSONValue.string) ?? .null,
            ])
        }
    }

    public struct ResetCreditsSummary: Equatable, Sendable {
        public var availableCount: Int64
        public var credits: [ResetCredit]?

        public init(availableCount: Int64, credits: [ResetCredit]?) throws {
            guard availableCount >= 0 else {
                throw CodexAppServerTestError.invalidFixture(
                    "reset-credit count must not be negative"
                )
            }
            self.availableCount = availableCount
            self.credits = credits
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "availableCount": .int(Int(availableCount)),
                "credits": credits.map { .array($0.map(\.wireValue)) } ?? .null,
            ])
        }
    }

    private let primarySnapshot: CodexAppServerTestRateLimitSnapshot
    private let snapshotsByLimitID: [String: CodexAppServerTestRateLimitSnapshot]?
    private let resetCredits: ResetCreditsSummary?

    public init(
        primarySnapshot: CodexAppServerTestRateLimitSnapshot,
        snapshotsByLimitID: [String: CodexAppServerTestRateLimitSnapshot]?,
        resetCredits: ResetCreditsSummary?
    ) throws {
        if let snapshotsByLimitID,
            snapshotsByLimitID.keys.contains(where: \.isEmpty)
        {
            throw CodexAppServerTestError.invalidFixture(
                "rate-limit map keys must not be empty"
            )
        }
        self.primarySnapshot = primarySnapshot
        self.snapshotsByLimitID = snapshotsByLimitID
        self.resetCredits = resetCredits
    }

    public var domainProjection: CodexRateLimits {
        let decoder = JSONDecoder()
        guard let primaryData = try? JSONEncoder().encode(primarySnapshot.wireValue),
            let primary = try? decoder.decode(
                AppServerAPI.Account.RateLimits.Snapshot.self,
                from: primaryData
            )
        else {
            preconditionFailure("Validated rate-limit fixture failed to decode.")
        }
        let snapshots = snapshotsByLimitID.map { values in
            values.reduce(into: [String: AppServerAPI.Account.RateLimits.Snapshot]()) {
                result, pair in
                guard let data = try? JSONEncoder().encode(pair.value.wireValue),
                    let value = try? decoder.decode(
                        AppServerAPI.Account.RateLimits.Snapshot.self,
                        from: data
                    )
                else {
                    preconditionFailure("Validated rate-limit fixture failed to decode.")
                }
                result[pair.key] = value
            }
        }
        return CodexRateLimits(appServer: .init(
            rateLimits: primary,
            rateLimitsByLimitID: snapshots
        ))
    }

    package var wireValue: CodexJSONValue {
        .object([
            "rateLimits": primarySnapshot.wireValue,
            "rateLimitsByLimitId": snapshotsByLimitID.map { snapshots in
                .object(snapshots.mapValues(\.wireValue))
            } ?? .null,
            "resetCredits": resetCredits?.wireValue ?? .null,
        ])
    }
}

public enum CodexAppServerTestConfigurationLayerSource: Equatable, Sendable {
    case mdm(domain: String, key: String)
    case system(file: URL)
    case enterpriseManaged(id: String, name: String)
    case user(file: URL, profile: String?)
    case project(dotCodexFolder: URL)
    case sessionFlags
    case legacyManagedConfigTomlFromFile(file: URL)
    case legacyManagedConfigTomlFromMdm

    fileprivate var wireValue: CodexJSONValue {
        switch self {
        case .mdm(let domain, let key):
            .object([
                "type": .string("mdm"),
                "domain": .string(domain),
                "key": .string(key),
            ])
        case .system(let file):
            .object([
                "type": .string("system"),
                "file": .string(file.path),
            ])
        case .enterpriseManaged(let id, let name):
            .object([
                "type": .string("enterpriseManaged"),
                "id": .string(id),
                "name": .string(name),
            ])
        case .user(let file, let profile):
            .object([
                "type": .string("user"),
                "file": .string(file.path),
                "profile": profile.map(CodexJSONValue.string) ?? .null,
            ])
        case .project(let dotCodexFolder):
            .object([
                "type": .string("project"),
                "dotCodexFolder": .string(dotCodexFolder.path),
            ])
        case .sessionFlags:
            .object(["type": .string("sessionFlags")])
        case .legacyManagedConfigTomlFromFile(let file):
            .object([
                "type": .string("legacyManagedConfigTomlFromFile"),
                "file": .string(file.path),
            ])
        case .legacyManagedConfigTomlFromMdm:
            .object(["type": .string("legacyManagedConfigTomlFromMdm")])
        }
    }

    fileprivate func validate() throws {
        switch self {
        case .mdm(let domain, let key):
            try requireNonEmpty(domain, field: "MDM domain")
            try requireNonEmpty(key, field: "MDM key")
        case .system(let file), .legacyManagedConfigTomlFromFile(let file):
            try requireAbsoluteFileURL(file, field: "configuration layer file")
        case .enterpriseManaged(let id, let name):
            try requireNonEmpty(id, field: "enterprise layer id")
            try requireNonEmpty(name, field: "enterprise layer name")
        case .user(let file, let profile):
            try requireAbsoluteFileURL(file, field: "user configuration file")
            if let profile {
                try requireNonEmpty(profile, field: "configuration profile")
            }
        case .project(let dotCodexFolder):
            try requireAbsoluteFileURL(dotCodexFolder, field: "project .codex folder")
        case .sessionFlags, .legacyManagedConfigTomlFromMdm:
            break
        }
    }
}

public struct CodexAppServerTestConfigurationLayerMetadata: Equatable, Sendable {
    public var source: CodexAppServerTestConfigurationLayerSource
    public var version: String

    public init(
        source: CodexAppServerTestConfigurationLayerSource,
        version: String
    ) throws {
        try source.validate()
        try requireNonEmpty(version, field: "configuration layer version")
        self.source = source
        self.version = version
    }

    fileprivate var wireValue: CodexJSONValue {
        .object([
            "name": source.wireValue,
            "version": .string(version),
        ])
    }
}

public struct CodexAppServerTestConfigurationLayer: Equatable, Sendable {
    public var metadata: CodexAppServerTestConfigurationLayerMetadata
    public var configuration: CodexJSONValue
    public var disabledReason: String?

    public init(
        metadata: CodexAppServerTestConfigurationLayerMetadata,
        configuration: CodexJSONValue,
        disabledReason: String? = nil
    ) throws {
        guard case .object = configuration else {
            throw CodexAppServerTestError.invalidFixture(
                "configuration layer value must be a JSON object"
            )
        }
        if let disabledReason {
            try requireNonEmpty(disabledReason, field: "configuration layer disabled reason")
        }
        self.metadata = metadata
        self.configuration = configuration
        self.disabledReason = disabledReason
    }

    fileprivate var wireValue: CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "name": metadata.source.wireValue,
            "version": .string(metadata.version),
            "config": configuration,
        ]
        if let disabledReason {
            fields["disabledReason"] = .string(disabledReason)
        }
        return .object(fields)
    }
}

public struct CodexAppServerTestConfigurationReadResult: Equatable, Sendable {
    public var configuration: CodexConfiguration
    public var origins: [String: CodexAppServerTestConfigurationLayerMetadata]
    public var layers: [CodexAppServerTestConfigurationLayer]?

    public init(
        configuration: CodexConfiguration,
        origins: [String: CodexAppServerTestConfigurationLayerMetadata],
        layers: [CodexAppServerTestConfigurationLayer]? = nil
    ) throws {
        guard origins.keys.contains(where: \.isEmpty) == false else {
            throw CodexAppServerTestError.invalidFixture(
                "configuration origin keys must not be empty"
            )
        }
        try Self.validate(configuration)
        self.configuration = configuration
        self.origins = origins
        self.layers = layers
    }

    package var wireValue: CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "config": Self.configurationWireValue(configuration),
            "origins": .object(origins.mapValues(\.wireValue)),
        ]
        if let layers {
            fields["layers"] = .array(layers.map(\.wireValue))
        }
        return .object(fields)
    }

    private static func validate(_ configuration: CodexConfiguration) throws {
        if let model = configuration.model {
            try requireNonEmpty(model, field: "configuration model")
        }
        if let reviewModel = configuration.reviewModel {
            try requireNonEmpty(reviewModel, field: "configuration review model")
        }
        if let serviceTier = configuration.serviceTier {
            try requireNonEmpty(serviceTier, field: "configuration service tier")
        }
    }

    private static func configurationWireValue(
        _ configuration: CodexConfiguration
    ) -> CodexJSONValue {
        .object([
            "model": configuration.model.map(CodexJSONValue.string) ?? .null,
            "review_model": configuration.reviewModel.map(CodexJSONValue.string) ?? .null,
            "model_context_window": .null,
            "model_auto_compact_token_limit": .null,
            "model_auto_compact_token_limit_scope": .null,
            "model_provider": .null,
            "approval_policy": .null,
            "approvals_reviewer": .null,
            "sandbox_mode": .null,
            "sandbox_workspace_write": .null,
            "forced_chatgpt_workspace_id": .null,
            "forced_login_method": .null,
            "web_search": .null,
            "tools": .null,
            "instructions": .null,
            "developer_instructions": .null,
            "compact_prompt": .null,
            "model_reasoning_effort": configuration.reasoningEffort.map {
                .string($0.rawValue)
            } ?? .null,
            "model_reasoning_summary": .null,
            "model_verbosity": .null,
            "service_tier": configuration.serviceTier.map(CodexJSONValue.string) ?? .null,
            "analytics": .null,
            "apps": .null,
            "desktop": .null,
        ])
    }
}

public struct CodexAppServerTestConfigurationWriteResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case ok
        case okOverridden

        fileprivate var wireValue: String {
            switch self {
            case .ok: "ok"
            case .okOverridden: "okOverridden"
            }
        }
    }

    public struct OverriddenMetadata: Equatable, Sendable {
        public var message: String
        public var overridingLayer: CodexAppServerTestConfigurationLayerMetadata
        public var effectiveValue: CodexJSONValue

        public init(
            message: String,
            overridingLayer: CodexAppServerTestConfigurationLayerMetadata,
            effectiveValue: CodexJSONValue
        ) throws {
            try requireNonEmpty(message, field: "configuration override message")
            self.message = message
            self.overridingLayer = overridingLayer
            self.effectiveValue = effectiveValue
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "message": .string(message),
                "overridingLayer": overridingLayer.wireValue,
                "effectiveValue": effectiveValue,
            ])
        }
    }

    public var status: Status
    public var version: String
    public var fileURL: URL
    public var overriddenMetadata: OverriddenMetadata?

    public init(
        status: Status,
        version: String,
        fileURL: URL,
        overriddenMetadata: OverriddenMetadata? = nil
    ) throws {
        try requireNonEmpty(version, field: "configuration write version")
        try requireAbsoluteFileURL(fileURL, field: "configuration write file")
        switch (status, overriddenMetadata) {
        case (.ok, nil), (.okOverridden, .some):
            break
        case (.ok, .some):
            throw CodexAppServerTestError.invalidFixture(
                "an ok configuration write must not contain override metadata"
            )
        case (.okOverridden, nil):
            throw CodexAppServerTestError.invalidFixture(
                "an overridden configuration write requires override metadata"
            )
        }
        self.status = status
        self.version = version
        self.fileURL = fileURL
        self.overriddenMetadata = overriddenMetadata
    }

    package var wireValue: CodexJSONValue {
        .object([
            "status": .string(status.wireValue),
            "version": .string(version),
            "filePath": .string(fileURL.path),
            "overriddenMetadata": overriddenMetadata?.wireValue ?? .null,
        ])
    }
}

private func requireNonEmpty(_ value: String, field: String) throws {
    guard value.isEmpty == false else {
        throw CodexAppServerTestError.invalidFixture("\(field) must not be empty")
    }
}

private func requireAbsoluteFileURL(_ url: URL, field: String) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
        throw CodexAppServerTestError.invalidFixture(
            "\(field) must be an absolute file URL"
        )
    }
}
