import CodexAppServerKit
import CodexReview
import Foundation

extension AppServerAPI {
    package enum Review {
        package enum Start {}
    }
}

extension AppServerAPI.Review.Start {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var target: CodexReviewAPI.Target
        package var delivery: AppServerAPI.Review.Start.Delivery

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case target
            case delivery
        }

        package init(
            threadID: String,
            target: CodexReviewAPI.Target,
            delivery: AppServerAPI.Review.Start.Delivery = .inline
        ) {
            self.threadID = threadID
            self.target = target
            self.delivery = delivery
        }
    }
}

extension AppServerAPI.Review.Start {
    package enum Delivery: String, Codable, Equatable, Sendable {
        case inline
        case detached
    }
}

extension AppServerAPI.Review.Start {
    package struct Response: Codable, Equatable, Sendable {
        package var turnID: String
        package var reviewThreadID: String?

        enum CodingKeys: String, CodingKey {
            case turn
            case reviewThreadID = "reviewThreadId"
        }

        package init(turnID: String, reviewThreadID: String? = nil) {
            self.turnID = turnID
            self.reviewThreadID = reviewThreadID
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.turnID = try container.decode(AppServerAPI.Turn.Payload.self, forKey: .turn).id
            self.reviewThreadID = try container.decodeIfPresent(
                String.self, forKey: .reviewThreadID)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(AppServerAPI.Turn.Payload(id: turnID), forKey: .turn)
            try container.encodeIfPresent(reviewThreadID, forKey: .reviewThreadID)
        }
    }
}

extension AppServerAPI.Review.Start {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Review.Start.Response

        package static let method = "review/start"
        package var params: AppServerAPI.Review.Start.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Review.Start.Params) {
            self.params = params
        }
    }
}
