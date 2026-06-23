import Foundation

public enum PagerConfig {
    /// Set after creating the Firebase project (docs/firebase-setup.md).
    public static let databaseURLString = "https://bff-pager-default-rtdb.europe-west1.firebasedatabase.app"

    /// Recipient for the in-app "Email a debug report" flow.
    public static let supportEmail = "yo@july.dev"

    public static var databaseURL: URL? {
        guard !databaseURLString.contains("CHANGE-ME") else { return nil }
        return URL(string: databaseURLString)
    }
}
