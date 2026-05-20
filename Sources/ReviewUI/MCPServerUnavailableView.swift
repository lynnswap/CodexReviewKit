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
            .disabled(isRestarting)
        } description: {
            VStack {
                Text("MCP Server Unavailable")
                if let failureMessage {
                    Text(failureMessage)
                        .textScale(.secondary)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight:.infinity)
    }

    private var failureMessage: String? {
        guard case .failed(let message) = store.serverState else {
            return nil
        }
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
}
