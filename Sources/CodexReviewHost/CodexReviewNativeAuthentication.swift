import AppKit
import AuthenticationServices
import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexReviewKit", category: "native-auth")

@MainActor
public struct CodexReviewNativeAuthenticationConfiguration: Sendable {
    public enum BrowserSessionPolicy: Sendable {
        case ephemeral
    }

    public var callbackScheme: String
    public var browserSessionPolicy: BrowserSessionPolicy
    public var presentationAnchorProvider: @MainActor @Sendable () -> ASPresentationAnchor?

    public init(
        callbackScheme: String,
        browserSessionPolicy: BrowserSessionPolicy,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.callbackScheme = callbackScheme
        self.browserSessionPolicy = browserSessionPolicy
        self.presentationAnchorProvider = presentationAnchorProvider
    }
}

@MainActor
public protocol CodexReviewWebAuthenticationSession: AnyObject, Sendable {
    func waitForCallbackURL() async throws -> URL
    func cancel() async
}

public typealias CodexReviewWebAuthenticationSessionFactory = @MainActor @Sendable (
    URL,
    String,
    CodexReviewNativeAuthenticationConfiguration.BrowserSessionPolicy,
    @escaping @MainActor @Sendable () -> ASPresentationAnchor?
) async throws -> any CodexReviewWebAuthenticationSession

public enum CodexReviewWebAuthenticationSessions {
    public static let system: CodexReviewWebAuthenticationSessionFactory = {
        url,
        callbackScheme,
        browserSessionPolicy,
        presentationAnchorProvider in
        try await SystemCodexReviewWebAuthenticationSession.start(
            using: url,
            callbackScheme: callbackScheme,
            browserSessionPolicy: browserSessionPolicy,
            presentationAnchorProvider: presentationAnchorProvider
        )
    }
}

@MainActor
private final class SystemCodexReviewWebAuthenticationSession: NSObject, CodexReviewWebAuthenticationSession {
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }

        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor
        }
    }

    private var session: ASWebAuthenticationSession?
    private var provider: PresentationContextProvider?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    static func start(
        using url: URL,
        callbackScheme: String,
        browserSessionPolicy: CodexReviewNativeAuthenticationConfiguration.BrowserSessionPolicy,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> SystemCodexReviewWebAuthenticationSession {
        guard let anchor = presentationAnchorProvider() else {
            throw CodexReviewNativeAuthenticationError.loginFailed(
                "Unable to present authentication session."
            )
        }

        let activeSession = SystemCodexReviewWebAuthenticationSession()
        let provider = PresentationContextProvider(anchor: anchor)
        let session = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(callbackScheme),
            completionHandler: makeSystemCodexReviewWebAuthenticationCompletionHandler(activeSession)
        )
        switch browserSessionPolicy {
        case .ephemeral:
            session.prefersEphemeralWebBrowserSession = true
        }
        session.presentationContextProvider = provider
        activeSession.session = session
        activeSession.provider = provider

        logger.info("Starting ASWebAuthenticationSession")
        guard session.start() else {
            activeSession.finishAuthenticationSession(with: .failure(CodexReviewNativeAuthenticationError.loginFailed(
                "Unable to start authentication session."
            )))
            throw CodexReviewNativeAuthenticationError.loginFailed(
                "Unable to start authentication session."
            )
        }
        return activeSession
    }

    func waitForCallbackURL() async throws -> URL {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
        }
    }

    func cancel() async {
        logger.info("Cancelling ASWebAuthenticationSession")
        session?.cancel()
    }

    fileprivate func finishAuthenticationSession(with result: Result<URL, Error>) {
        guard self.result == nil else {
            return
        }
        self.result = result
        session = nil
        provider = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

private func makeSystemCodexReviewWebAuthenticationCompletionHandler(
    _ activeSession: SystemCodexReviewWebAuthenticationSession
) -> ASWebAuthenticationSession.CompletionHandler {
    { [weak activeSession] callbackURL, error in
        let mappedResult = mapAuthenticationResult(callbackURL: callbackURL, error: error)
        Task { @MainActor [weak activeSession] in
            activeSession?.finishAuthenticationSession(with: mappedResult)
        }
    }
}

package enum CodexReviewNativeAuthenticationError: LocalizedError, Sendable {
    case cancelled
    case loginFailed(String)

    package var errorDescription: String? {
        switch self {
        case .cancelled:
            "Authentication was cancelled."
        case .loginFailed(let message):
            message
        }
    }
}

private func mapAuthenticationResult(callbackURL: URL?, error: Error?) -> Result<URL, Error> {
    if let callbackURL {
        return .success(callbackURL)
    }
    if let error {
        let nsError = error as NSError
        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
           nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
        {
            return .failure(CodexReviewNativeAuthenticationError.cancelled)
        }
        return .failure(CodexReviewNativeAuthenticationError.loginFailed(error.localizedDescription))
    }
    return .failure(CodexReviewNativeAuthenticationError.cancelled)
}
