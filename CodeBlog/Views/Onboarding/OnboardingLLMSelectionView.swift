//
//  OnboardingLLMSelectionView.swift
//  CodeBlog
//
//  LLM provider selection view for onboarding flow
//

import SwiftUI
import AppKit

struct OnboardingLLMSelectionView: View {
    // Navigation callbacks
    var onBack: () -> Void
    var onNext: (String) -> Void  // Now passes the selected provider
    
    @AppStorage("selectedLLMProvider") private var selectedProvider: String = "gemini" // Default to "Bring your own API"
    @State private var titleOpacity: Double = 0
    @State private var cardsOpacity: Double = 0
    @State private var bottomTextOpacity: Double = 0
    @State private var hasAppeared: Bool = false
    @State private var cliDetected: Bool = false
    @State private var cliDetectionTask: Task<Void, Never>?
    @State private var didUserSelectProvider: Bool = false
    @State private var creditBalanceUSD: String? = nil
    @State private var creditCheckOpacity: Double = 0
    
    var body: some View {
        GeometryReader { geometry in
            let windowWidth = geometry.size.width
            let windowHeight = geometry.size.height

            // Constants
            let edgePadding: CGFloat = 40
            let cardGap: CGFloat = 20
            let headerHeight: CGFloat = creditBalanceUSD != nil ? 100 : 70
            let footerHeight: CGFloat = 70

            // Card width calc (no min width, cap at 480)
            let availableWidth = windowWidth - (edgePadding * 2)
            let rawCardWidth = (availableWidth - (cardGap * 2)) / 3
            let cardWidth = max(1, min(480, floor(rawCardWidth)))

            // Card height calc
            let availableHeight = windowHeight - headerHeight - footerHeight
            let cardHeight = min(500, max(300, availableHeight - 20))

            // Title font size
            let titleSize: CGFloat = windowWidth <= 900 ? 32 : 48

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Text("Choose a way to run CodeBlog")
                        .font(.custom("InstrumentSerif-Regular", size: titleSize))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.black.opacity(0.9))
                        .frame(maxWidth: .infinity)

                    // Credit balance prompt
                    if let balance = creditBalanceUSD {
                        HStack(spacing: 4) {
                            Text("You have")
                                .foregroundColor(.black.opacity(0.6))
                            + Text(" $\(balance) ")
                                .fontWeight(.semibold)
                                .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.3))
                            + Text("in AI credits — you can use CodeBlog's built-in AI at no extra cost.")
                                .foregroundColor(.black.opacity(0.6))
                        }
                        .font(.custom("Nunito", size: 13))
                        .multilineTextAlignment(.center)
                        .opacity(creditCheckOpacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)
                .opacity(titleOpacity)
                .onAppear {
                    guard !hasAppeared else { return }
                    hasAppeared = true
                    detectCLIInstallation()
                    checkCreditBalance()
                    withAnimation(.easeOut(duration: 0.6)) { titleOpacity = 1 }
                    animateContent()
                }

                // Dynamic card area
                Spacer(minLength: 10)

                HStack(spacing: cardGap) {
                    ForEach(providerCards, id: \.id) { card in
                        card
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .padding(.horizontal, edgePadding)
                .opacity(cardsOpacity)

                Spacer(minLength: 10)

                // Footer
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Group {
                            if cliDetected {
                                Text("You have Codex/Claude CLI installed! ")
                                    .foregroundColor(.black.opacity(0.6))
                                + Text("We recommend using it for the best experience.")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.black.opacity(0.8))
                                + Text(" You can switch at any time in the settings.")
                                    .foregroundColor(.black.opacity(0.6))
                            } else {
                                Text("Not sure which to choose? ")
                                    .foregroundColor(.black.opacity(0.6))
                                + Text("Bring your own keys is the easiest setup (30s).")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.black.opacity(0.8))
                                + Text(" You can switch at any time in the settings.")
                                    .foregroundColor(.black.opacity(0.6))
                            }
                        }
                        .font(.custom("Nunito", size: 14))
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    Button(action: { onNext("thirdparty") }) {
                        Text("Looking for OpenAI, Anthropic, or other providers? Configure here →")
                            .font(.custom("Nunito", size: 13))
                            .foregroundColor(Color(red: 1, green: 0.42, blue: 0.02))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .frame(maxWidth: .infinity)
                .frame(height: footerHeight)
                .opacity(bottomTextOpacity)
            }
            .animation(.easeOut(duration: 0.2), value: cardWidth)
            .animation(.easeOut(duration: 0.2), value: cardHeight)
        }
        .onDisappear {
            cliDetectionTask?.cancel()
            cliDetectionTask = nil
        }
    }
    
    // Create provider cards as a computed property for reuse
    private var providerCards: [FlexibleProviderCard] {
        [
            // Run locally card
            FlexibleProviderCard(
                id: "ollama",
                title: "Use local AI",
                badgeText: "MOST PRIVATE",
                badgeType: .green,
                icon: "desktopcomputer",
                features: [
                    ("100% private - everything's processed on your computer", true),
                    ("Works completely offline", true),
                    ("Significantly less intelligence", false),
                    ("Requires the most setup", false),
                    ("16GB+ of RAM recommended", false),
                    ("Can be battery-intensive", false)
                ],
                isSelected: selectedProvider == "ollama",
                buttonMode: .onboarding(onProceed: {
                    // Only proceed if this provider is selected
                    if selectedProvider == "ollama" {
                        saveProviderSelection()
                        onNext("ollama")
                    } else {
                        // Select the card first
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            didUserSelectProvider = true
                            selectedProvider = "ollama"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        didUserSelectProvider = true
                        selectedProvider = "ollama"
                    }
                }
            ),
            
            // Bring your own API card (selected by default)
            FlexibleProviderCard(
                id: "gemini",
                title: "Gemini",
                badgeText: cliDetected ? "NEW" : "RECOMMENDED",
                badgeType: cliDetected ? .blue : .orange,
                icon: "gemini_asset",
                features: [
                    ("Utilizes more intelligent AI via Google's Gemini models", true),
                    ("Uses Gemini's generous free tier (no credit card needed)", true),
                    ("Faster, more accurate than local models", true),
                    ("Requires getting an API key (takes 2 clicks)", false)
                ],
                isSelected: selectedProvider == "gemini",
                buttonMode: .onboarding(onProceed: {
                    // Only proceed if this provider is selected
                    if selectedProvider == "gemini" {
                        saveProviderSelection()
                        onNext("gemini")
                    } else {
                        // Select the card first
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            didUserSelectProvider = true
                            selectedProvider = "gemini"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        didUserSelectProvider = true
                        selectedProvider = "gemini"
                    }
                }
            ),

            // ChatGPT/Claude CLI card
            FlexibleProviderCard(
                id: "chatgpt_claude",
                title: "ChatGPT or Claude",
                badgeText: cliDetected ? "RECOMMENDED" : "NEW",
                badgeType: cliDetected ? .orange : .blue,
                icon: "chatgpt_claude_asset",
                features: [
                    ("Perfect for existing ChatGPT Plus or Claude Pro subscribers", true),
                    ("Superior intelligence and reliability", true),
                    ("Minimal impact - uses <1% of your daily limit", true),
                    ("Requires installing Codex or Claude CLI", false),
                    ("Requires a paid ChatGPT or Claude subscription", false)
                ],
                isSelected: selectedProvider == "chatgpt_claude",
                buttonMode: .onboarding(onProceed: {
                    if selectedProvider == "chatgpt_claude" {
                        saveProviderSelection()
                        onNext("chatgpt_claude")
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            didUserSelectProvider = true
                            selectedProvider = "chatgpt_claude"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        didUserSelectProvider = true
                        selectedProvider = "chatgpt_claude"
                    }
                }
            ),
            
            /*
            // CodeBlog Pro card
            FlexibleProviderCard(
                id: "codeblog",
                title: "CodeBlog Pro",
                badgeText: "EASIEST SETUP",
                badgeType: .blue,
                icon: "sparkles",
                features: [
                    ("Zero setup - just sign in and go", true),
                    ("Your data is processed then immediately deleted", true),
                    ("Never used to train AI models", true),
                    ("Always the fastest, most capable AI", true),
                    ("Fixed monthly pricing, no surprises", true),
                    ("Requires internet connection", false)
                ],
                isSelected: selectedProvider == "codeblog",
                buttonMode: .onboarding(onProceed: {
                    // Only proceed if this provider is selected
                    if selectedProvider == "codeblog" {
                        saveProviderSelection()
                        onNext("codeblog")
                    } else {
                        // Select the card first
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            selectedProvider = "codeblog"
                        }
                    }
                }),
                onSelect: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        selectedProvider = "codeblog"
                    }
                }
            )
            */
        ]
    }
    
    private func saveProviderSelection() {
        let providerType: LLMProviderType

        switch selectedProvider {
        case "ollama":
            providerType = .ollamaLocal()
        case "gemini":
            providerType = .geminiDirect
        case "codeblog":
            providerType = .codeblogBackend()
        case "chatgpt_claude":
            providerType = .chatGPTClaude
        case "thirdparty":
            // Don't persist yet — will be done in the setup view after configuration
            return
        default:
            providerType = .geminiDirect
        }

        providerType.persist()
    }
    
    private func animateContent() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.6)) {
                cardsOpacity = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.4)) {
                bottomTextOpacity = 1
            }
        }
    }

    private func detectCLIInstallation() {
        cliDetectionTask?.cancel()
        cliDetectionTask = Task { @MainActor in
            let installed = await Task.detached(priority: .utility) {
                let codexInstalled = CLIDetector.isInstalled(.codex)
                let claudeInstalled = CLIDetector.isInstalled(.claude)
                return codexInstalled || claudeInstalled
            }.value

            guard !Task.isCancelled else { return }

            cliDetected = installed

            if !didUserSelectProvider {
                selectedProvider = installed ? "chatgpt_claude" : "gemini"
            }
        }
    }

    private func checkCreditBalance() {
        let auth = CodeBlogAuthService.shared
        guard auth.isAuthenticated, let apiKey = auth.token?.apiKey else { return }

        Task {
            do {
                var request = URLRequest(url: URL(string: "https://codeblog.ai/api/v1/ai-credit/balance")!)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 5

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

                struct CreditBalanceResponse: Decodable {
                    let balance_cents: Int
                    let balance_usd: String
                }
                let balance = try JSONDecoder().decode(CreditBalanceResponse.self, from: data)
                guard balance.balance_cents > 0 else { return }

                await MainActor.run {
                    creditBalanceUSD = balance.balance_usd
                    withAnimation(.easeOut(duration: 0.5).delay(0.5)) {
                        creditCheckOpacity = 1
                    }
                }
            } catch {
                // Silently fail — don't show credit info if check fails
            }
        }
    }
}

struct OnboardingLLMSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingLLMSelectionView(
            onBack: {},
            onNext: { _ in }  // Takes provider string now
        )
        .frame(width: 1400, height: 900)
        .background(
            Image("OnboardingBackgroundv2")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        )
    }
}
