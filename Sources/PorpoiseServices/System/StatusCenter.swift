import Foundation

/// Short app-wide messages shown in the active view's status bar.
public enum StatusCenter {
    public static let message = Notification.Name("PorpoiseStatusMessage")
    public static func post(_ s: String) { NotificationCenter.default.post(name: message, object: s) }
    public static func error(_ s: String) { NotificationCenter.default.post(name: message, object: s, userInfo: ["error": true]) }
}
