import AppKit
@preconcurrency import AuthenticationServices
import Foundation
import OSLog
import CodexReviewKit

private let nativeAuthenticationLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "native-authentication"
)

public enum CodexReviewNativeAuthentication {}

@MainActor
public extension CodexReviewNativeAuthentication {
    struct Configuration: Sendable {
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
}

extension CodexReviewNativeAuthentication {
    package enum PresentationMode: Equatable, Sendable {
        case webAuthenticationSession
        case externalBrowser
    }

    package enum PresentationEvent: Equatable, Sendable {
        case cancelled
        case failed(message: String)
    }

    @MainActor
    package protocol Presentation: AnyObject {
        var mode: PresentationMode { get }
        var eventStream: AsyncStream<PresentationEvent>? { get }

        func close()
    }

    @MainActor
    package protocol SystemWebAuthenticationSession: AnyObject {
        var prefersEphemeralWebBrowserSession: Bool { get set }
        var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
        var canStart: Bool { get }

        func start() -> Bool
        func cancel()
    }

    package typealias WebSessionFactory = @MainActor @Sendable (
        URL,
        String,
        @escaping ASWebAuthenticationSession.CompletionHandler
    ) -> any SystemWebAuthenticationSession
}

extension ASWebAuthenticationSession: CodexReviewNativeAuthentication.SystemWebAuthenticationSession {}

@MainActor
package struct CodexReviewAuthenticationPresenter: Sendable {
    private let configuration: CodexReviewNativeAuthentication.Configuration?
    private let webSessionFactory: CodexReviewNativeAuthentication.WebSessionFactory
    private let externalURLOpener: ExternalURLOpener

    package init(
        configuration: CodexReviewNativeAuthentication.Configuration?,
        webSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping ExternalURLOpener
    ) {
        self.configuration = configuration
        self.webSessionFactory = webSessionFactory
        self.externalURLOpener = externalURLOpener
    }

    package func present(
        _ url: URL
    ) throws -> any CodexReviewNativeAuthentication.Presentation {
        if let presentation = makeSystemPresentation(url: url) {
            return presentation
        }

        try externalURLOpener(url)
        return ExternalBrowserAuthenticationPresentation()
    }

    private func makeSystemPresentation(
        url: URL
    ) -> (any CodexReviewNativeAuthentication.Presentation)? {
        guard let configuration,
              let anchor = configuration.presentationAnchorProvider() else {
            return nil
        }

        let eventSink = AuthenticationPresentationEventSink(
            fallbackURL: url,
            externalURLOpener: externalURLOpener
        )
        let session = webSessionFactory(
            url,
            configuration.callbackScheme
        ) { [weak eventSink] callbackURL, error in
            let event = Self.presentationEvent(callbackURL: callbackURL, error: error)
            Task { @MainActor [weak eventSink] in
                eventSink?.receive(event)
            }
        }
        let contextProvider = AuthenticationPresentationContextProvider(anchor: anchor)

        switch configuration.browserSessionPolicy {
        case .ephemeral:
            session.prefersEphemeralWebBrowserSession = true
        }
        session.presentationContextProvider = contextProvider

        guard session.canStart else {
            nativeAuthenticationLogger.info(
                "ASWebAuthenticationSession cannot start; using the external browser"
            )
            return nil
        }
        guard session.start() else {
            nativeAuthenticationLogger.info(
                "ASWebAuthenticationSession did not start; using the external browser"
            )
            return nil
        }

        nativeAuthenticationLogger.info("Started ephemeral ASWebAuthenticationSession")
        return SystemAuthenticationPresentation(
            session: session,
            contextProvider: contextProvider,
            eventSink: eventSink
        )
    }

    private nonisolated static func presentationEvent(
        callbackURL: URL?,
        error: (any Error)?
    ) -> SystemAuthenticationPresentationEvent {
        if callbackURL != nil {
            // The stock app-server owns the localhost OAuth callback. A URL delivered
            // to the app callback scheme is therefore outside this login contract.
            return .failed(message: "Authentication returned an unexpected callback URL.")
        }
        if let error {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                return .cancelled
            }
            let isPresentationContextFailure =
                nsError.code == ASWebAuthenticationSessionError.Code.presentationContextNotProvided.rawValue
                || nsError.code == ASWebAuthenticationSessionError.Code.presentationContextInvalid.rawValue
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               isPresentationContextFailure {
                return .nativePresentationUnavailable
            }
            return .failed(message: error.localizedDescription)
        }
        return .cancelled
    }

    package static let systemWebSessionFactory: CodexReviewNativeAuthentication.WebSessionFactory = {
        url,
        callbackScheme,
        completionHandler in
        // This callback is deliberately not sent to Codex. The stock app-server
        // remains the sole owner of its localhost OAuth callback and login result.
        ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(callbackScheme),
            completionHandler: completionHandler
        )
    }
}

private enum SystemAuthenticationPresentationEvent: Sendable {
    case cancelled
    case nativePresentationUnavailable
    case failed(message: String)
}

@MainActor
private final class AuthenticationPresentationContextProvider:
    NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

@MainActor
private final class AuthenticationPresentationEventSink {
    let stream: AsyncStream<CodexReviewNativeAuthentication.PresentationEvent>
    private let continuation: AsyncStream<CodexReviewNativeAuthentication.PresentationEvent>.Continuation
    private let fallbackURL: URL
    private let externalURLOpener: ExternalURLOpener
    private var isFinished = false
    private var didOpenExternalFallback = false

    init(
        fallbackURL: URL,
        externalURLOpener: @escaping ExternalURLOpener
    ) {
        self.fallbackURL = fallbackURL
        self.externalURLOpener = externalURLOpener
        (stream, continuation) = AsyncStream.makeStream(
            of: CodexReviewNativeAuthentication.PresentationEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func receive(_ event: SystemAuthenticationPresentationEvent) {
        guard isFinished == false else {
            return
        }
        switch event {
        case .nativePresentationUnavailable:
            guard didOpenExternalFallback == false else {
                return
            }
            didOpenExternalFallback = true
            do {
                try externalURLOpener(fallbackURL)
                nativeAuthenticationLogger.info(
                    "ASWebAuthenticationSession presentation failed; continuing in the external browser"
                )
                return
            } catch {
                finish(with: .failed(
                    message: CodexReviewAuthenticationFailure.urlOpen(fallbackURL)
                        .localizedDescription
                ))
                return
            }
        case .cancelled:
            finish(with: .cancelled)
        case .failed(let message):
            finish(with: .failed(message: message))
        }
    }

    private func finish(with event: CodexReviewNativeAuthentication.PresentationEvent) {
        guard isFinished == false else {
            return
        }
        isFinished = true
        continuation.yield(event)
        continuation.finish()
    }

    func finish() {
        guard isFinished == false else {
            return
        }
        isFinished = true
        continuation.finish()
    }
}

@MainActor
private final class SystemAuthenticationPresentation: CodexReviewNativeAuthentication.Presentation {
    let mode = CodexReviewNativeAuthentication.PresentationMode.webAuthenticationSession
    let eventStream: AsyncStream<CodexReviewNativeAuthentication.PresentationEvent>?

    private let session: any CodexReviewNativeAuthentication.SystemWebAuthenticationSession
    // ASWebAuthenticationSession holds its presentationContextProvider weakly.
    private let contextProvider: AuthenticationPresentationContextProvider
    private let eventSink: AuthenticationPresentationEventSink
    private var isClosed = false

    init(
        session: any CodexReviewNativeAuthentication.SystemWebAuthenticationSession,
        contextProvider: AuthenticationPresentationContextProvider,
        eventSink: AuthenticationPresentationEventSink
    ) {
        self.session = session
        self.contextProvider = contextProvider
        self.eventSink = eventSink
        eventStream = eventSink.stream
    }

    func close() {
        guard isClosed == false else {
            return
        }
        isClosed = true
        eventSink.finish()
        session.cancel()
        nativeAuthenticationLogger.info("Closed ASWebAuthenticationSession")
    }
}

@MainActor
private final class ExternalBrowserAuthenticationPresentation: CodexReviewNativeAuthentication.Presentation {
    let mode = CodexReviewNativeAuthentication.PresentationMode.externalBrowser
    let eventStream: AsyncStream<CodexReviewNativeAuthentication.PresentationEvent>? = nil

    func close() {}
}
