//
//  CodeBlogLoginView.swift
//  CodeBlog
//
//  Onboarding step: sign in to CodeBlog via browser OAuth.
//  Layout mirrors ScreenRecordingPermissionView.
//

import SwiftUI
import AppKit

struct CodeBlogLoginView: View {
    var onBack: () -> Void
    var onNext: () -> Void

    @StateObject private var auth = CodeBlogAuthService.shared
    @State private var loginState: LoginState = .notStarted

    enum LoginState: Equatable {
        case notStarted
        case waiting   // browser opened, waiting for callback
        case success
        case failed(String)
    }

    var body: some View {
        HStack(spacing: 60) {

            // ── Left side ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 24) {

                Text("Let's get started!")
                    .font(.custom("Nunito", size: 20))
                    .foregroundColor(.black.opacity(0.7))
                    .padding(.bottom, 20)

                Text("Sign in to CodeBlog")
                    .font(.custom("Nunito", size: 32))
                    .fontWeight(.bold)
                    .foregroundColor(.black.opacity(0.9))

                Text("Connect your CodeBlog account to share your coding sessions with the community and browse posts from other developers.")
                    .font(.custom("Nunito", size: 16))
                    .foregroundColor(.black.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                // State message
                Group {
                    switch loginState {
                    case .notStarted:
                        EmptyView()
                    case .waiting:
                        Text("Browser opened — complete sign-in there, then come back here.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.orange)
                    case .success:
                        if let username = auth.token?.username {
                            Text("✓ Signed in as @\(username). Click Next to continue.")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.green)
                        } else {
                            Text("✓ Signed in successfully. Click Next to continue.")
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.green)
                        }
                    case .failed(let msg):
                        Text("⚠ \(msg). Please try again.")
                            .font(.custom("Nunito", size: 14))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
                .padding(.top, 8)

                // Action button
                Group {
                    switch loginState {
                    case .notStarted, .failed:
                        CodeBlogSurfaceButton(
                            action: startLogin,
                            content: {
                                HStack(spacing: 8) {
                                    Image(systemName: "safari")
                                    Text("Continue with Browser")
                                        .font(.custom("Nunito", size: 16))
                                        .fontWeight(.medium)
                                }
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 24,
                            verticalPadding: 12,
                            showOverlayStroke: true
                        )
                    case .waiting:
                        CodeBlogSurfaceButton(
                            action: startLogin,
                            content: {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.75)
                                        .tint(.white)
                                    Text("Waiting for browser...")
                                        .font(.custom("Nunito", size: 16))
                                        .fontWeight(.medium)
                                }
                            },
                            background: Color(red: 0.25, green: 0.17, blue: 0).opacity(0.7),
                            foreground: .white,
                            borderColor: .clear,
                            cornerRadius: 8,
                            horizontalPadding: 24,
                            verticalPadding: 12,
                            showOverlayStroke: false
                        )
                        .disabled(true)
                    case .success:
                        EmptyView()
                    }
                }
                .padding(.top, 16)

                // Back / Next navigation
                HStack(spacing: 16) {
                    CodeBlogSurfaceButton(
                        action: onBack,
                        content: {
                            Text("Back")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        },
                        background: .white,
                        foreground: Color(red: 0.25, green: 0.17, blue: 0),
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 20,
                        verticalPadding: 12,
                        minWidth: 120,
                        isSecondaryStyle: true
                    )

                    let canAdvance = (loginState == .success)
                    CodeBlogSurfaceButton(
                        action: { if canAdvance { onNext() } },
                        content: {
                            Text("Next")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        },
                        background: canAdvance
                            ? Color(red: 0.25, green: 0.17, blue: 0)
                            : Color(red: 0.25, green: 0.17, blue: 0).opacity(0.3),
                        foreground: canAdvance ? .white : .white.opacity(0.5),
                        borderColor: .clear,
                        cornerRadius: 8,
                        horizontalPadding: 20,
                        verticalPadding: 12,
                        minWidth: 120,
                        showOverlayStroke: canAdvance
                    )
                    .disabled(!canAdvance)
                }
                .padding(.top, 20)

                Spacer()
            }
            .frame(maxWidth: 400)

            // ── Right side: CodeBlog branding ───────────────────────
            VStack(spacing: 24) {
                Spacer()
                Image("CodeBlogLogoMainApp")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .opacity(0.85)

                Text("codeblog.ai")
                    .font(.custom("Nunito", size: 18))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.35))
                Spacer()
            }
            .frame(maxWidth: 360)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // If already logged in (app restart mid-onboarding), mark success
            if auth.isAuthenticated {
                loginState = .success
            }
        }
    }

    // MARK: - Actions

    private func startLogin() {
        loginState = .waiting
        Task {
            await auth.loginWithBrowser()
            await MainActor.run {
                if auth.isAuthenticated {
                    loginState = .success
                } else {
                    loginState = .failed(auth.error ?? "Unknown error")
                }
            }
        }
    }
}
