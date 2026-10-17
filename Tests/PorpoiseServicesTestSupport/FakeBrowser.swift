import Foundation

/// Plays the browser in a sign-in: follows the link the app opens, as a user signing in at once would (the fake
/// servers' consent page redirects straight back to the app's loopback listener).
public func openInFakeBrowser(_ url: URL) {
    Task { _ = try? await URLSession.shared.data(from: url) }
}
