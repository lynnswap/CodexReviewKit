//
//  MCPServerUnavailableView.swift
//  CodexReviewKit
//
//  Created by Kazuki Nakashima on 2026/04/10.
//

import SwiftUI
import CodexReview

struct MCPServerUnavailableView: View {
    let store: CodexReviewStore

    @State private var isRestarting = false

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    restartServer()
                } label: {
                    Label("Reset Server", systemImage: "arrow.clockwise")
                        .padding(.vertical, 8)
                }
                .labelStyle(.titleAndIcon)
                .buttonSizing(.flexible)
                .buttonBorderShape(.capsule)
                .buttonStyle(.bordered)
                .disabled(isRestarting || presentation.canRestart == false)
            }
        } description: {
            VStack {
                Text(presentation.title)
                if let message = presentation.message {
                    Text(message)
                        .textScale(.secondary)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight:.infinity)
    }

    private var presentation: ServerPresentation {
        switch store.serverState {
        case .failed(let message):
            return .init(
                title: "MCP Server Unavailable",
                message: Self.trimmedMessage(message),
                canRestart: true,
                showsProgress: false
            )
        case .starting:
            return .init(
                title: "Starting MCP Server",
                message: "The embedded server is starting.",
                canRestart: false,
                showsProgress: true
            )
        case .stopped:
            return .init(
                title: "MCP Server Stopped",
                message: "The embedded server is not running.",
                canRestart: true,
                showsProgress: false
            )
        case .running:
            return .init(
                title: "MCP Server Running",
                message: nil,
                canRestart: false,
                showsProgress: false
            )
        }
    }

    private static func trimmedMessage(_ message: String) -> String? {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? nil : trimmedMessage
    }

    private func restartServer() {
        guard isRestarting == false else {
            return
        }
        isRestarting = true
        Task { @MainActor in
            defer {
                isRestarting = false
            }
            if store.auth.isAuthenticating {
                await store.cancelAuthentication()
            }
            await store.restart()
        }
    }

    private struct ServerPresentation {
        var title: String
        var message: String?
        var canRestart: Bool
        var showsProgress: Bool
    }
}
