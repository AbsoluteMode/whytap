import SwiftUI

/// The permission operation outlives an inline view temporarily hidden by a
/// meeting/agent surface. Explicit Cancel ends it; leaving Settings cancels its flow.
@MainActor
final class CalendarConnectionFlow: ObservableObject {
    typealias Authorization = (CalendarProvider, String, String, String) async throws -> (code: String, redirect: String)
    @Published private(set) var working = false
    @Published private(set) var error: String?
    private(set) var lastProvider: CalendarProvider?
    private let connections: CalendarConnections
    private let activityChanged: (Bool) -> Void
    private let authorize: Authorization?
    private let googleReview: () -> Bool
    private var browser: CalendarBrowserSignIn?
    private var task: Task<Void, Never>?

    init(connections: CalendarConnections, activityChanged: @escaping (Bool) -> Void = { _ in },
         googleReview: @escaping () -> Bool = { GoogleCalendarReviewSession.current.isActive },
         authorize: Authorization? = nil) {
        self.connections = connections; self.activityChanged = activityChanged; self.authorize = authorize
        self.googleReview = googleReview
    }

    func clearError() { error = nil }

    /// A refusal shown under Apple Calendar is stale once access is allowed.
    func clearAppleRefusalIfAllowed() {
        guard !working, lastProvider == .apple, !connections.appleAccessOff,
              error == CalendarConnectionError.appleConnectRefusedMessage else { return }
        error = nil
    }
    func cancel() { error = nil; task?.cancel(); browser?.cancel() }

    /// Ordinary Connect goes straight to the provider, using this build's registration.
    @discardableResult
    func startRegistered(provider: CalendarProvider, info: [String: Any]? = Bundle.main.infoDictionary,
                         onSuccess: @escaping () -> Void = {}) -> Bool {
        guard !working else { return false }
        lastProvider = provider; error = nil
        if let message = CalendarAvailability.blockReason { error = message; return false }
        let configuration = CalendarClientConfiguration.registered(provider, info: info)
        if let message = CalendarConnectionReadiness.shared(provider, configuration: configuration,
            googleReview: googleReview()).message {
            error = message; return false
        }
        if provider != .apple, let message = connections.accountConnectionIssue {
            error = message; return false
        }
        if let message = connections.connectionBlockReason {
            error = message; return false
        }
        guard !connections.isConnecting else {
            error = "Finish the calendar connection already open."; return false
        }
        return start(provider: provider, clientID: configuration?.clientID ?? "",
            secret: configuration?.clientSecret ?? "", label: "", info: info, onSuccess: onSuccess)
    }

    @discardableResult
    func start(provider: CalendarProvider, clientID: String, secret: String, label: String,
               info: [String: Any]?, onSuccess: @escaping () -> Void) -> Bool {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working, CalendarAvailability.isOpen, CalendarConnectionReadiness.authorization(provider, clientID: clientID, info: info,
                  googleReview: googleReview()) == .available,
              provider == .apple || connections.accountConnectionIssue == nil,
              connections.beginConnecting(provider: provider) else { return false }
        working = true; error = nil; lastProvider = provider; activityChanged(true)
        let browser = CalendarBrowserSignIn(configurationInfo: info, googleReview: googleReview)
        self.browser = browser
        task = Task {
            defer {
                self.browser = nil; self.task = nil; working = false
                connections.endConnecting(); activityChanged(false)
            }
            do {
                if provider == .apple { try await connections.enableApple() }
                else {
                    let id = UUID()
                    let verifier = try CalendarPKCE.random()
                    let state = try CalendarPKCE.random()
                    let result: (code: String, redirect: String)
                    if let authorize { result = try await authorize(provider, clientID, state, verifier) }
                    else { result = try await browser.authorize(provider: provider, clientID: clientID, state: state, verifier: verifier) }
                    try Task.checkCancellation()
                    try await connections.oauth.connect(provider: provider, clientID: clientID, clientSecret: secret,
                        code: result.code, redirect: result.redirect, verifier: verifier, id: id)
                    do {
                        try Task.checkCancellation()
                        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        try connections.add(ConnectedCalendarAccount(id: id, provider: provider,
                            label: name.isEmpty ? defaultLabel(provider) : String(name.prefix(120))))
                    } catch { try? await connections.oauth.disconnect(id); throw error }
                }
                try Task.checkCancellation()
                onSuccess()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? CalendarConnectionError)?.localizedDescription ?? "Couldn’t connect the calendar. Try again."
            }
        }
        return true
    }

    private func defaultLabel(_ provider: CalendarProvider) -> String {
        let names = Set(connections.accounts.filter { $0.provider == provider }.map(\.label))
        if !names.contains(provider.title) { return provider.title }
        var suffix = 2
        while names.contains("\(provider.title) · \(suffix)") { suffix += 1 }
        return "\(provider.title) · \(suffix)"
    }
}
