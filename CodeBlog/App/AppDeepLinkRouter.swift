import Foundation
import AppKit

@MainActor
protocol AppDeepLinkRouterDelegate: AnyObject {
    func prepareForRecordingToggle(reason: String)
}

@MainActor
final class AppDeepLinkRouter {
    enum Action: String {
        case startRecording = "start-recording"
        case stopRecording = "stop-recording"
        case authComplete = "auth-complete"

        init?(identifier: String) {
            switch identifier.lowercased() {
            case Self.startRecording.rawValue, "start", "resume":
                self = .startRecording
            case Self.stopRecording.rawValue, "stop", "pause":
                self = .stopRecording
            case Self.authComplete.rawValue:
                self = .authComplete
            default:
                return nil
            }
        }
    }

    private weak var delegate: AppDeepLinkRouterDelegate?

    init(delegate: AppDeepLinkRouterDelegate?) {
        self.delegate = delegate
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let action = resolveAction(from: url) else {
            print("[DeepLink] Unsupported URL: \(url.absoluteString)")
            return false
        }

        perform(action)
        return true
    }

    private func resolveAction(from url: URL) -> Action? {
        guard let scheme = url.scheme, scheme.caseInsensitiveCompare("codeblog") == .orderedSame else {
            return nil
        }

        var candidates: [String] = []
        if let host = url.host, !host.isEmpty {
            candidates.append(host)
        }

        let pathComponents = url.path
            .split(separator: "/")
            .map { String($0) }

        candidates.append(contentsOf: pathComponents)

        if candidates.isEmpty {
            if let actionItem = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.lowercased() == "action" }),
               let value = actionItem.value, !value.isEmpty {
                candidates.append(value)
            }
        }

        guard let identifier = candidates.first else { return nil }
        return Action(identifier: identifier)
    }

    private func perform(_ action: Action) {
        switch action {
        case .startRecording:
            startRecording()
        case .stopRecording:
            stopRecording()
        case .authComplete:
            activateApp()
        }
    }

    private func startRecording() {
        guard !AppState.shared.isRecording else {
            print("[DeepLink] Recording already active; ignoring start request")
            return
        }
        delegate?.prepareForRecordingToggle(reason: "deeplink")
        AppState.shared.isRecording = true
    }

    private func stopRecording() {
        guard AppState.shared.isRecording else {
            print("[DeepLink] Recording already stopped; ignoring stop request")
            return
        }
        delegate?.prepareForRecordingToggle(reason: "deeplink")
        AppState.shared.isRecording = false
    }

    private func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Bring the main window to front if it exists
        if let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
        print("[DeepLink] App activated via auth-complete")
    }

}
