import Foundation

public enum PagerConfig {
    /// Set after creating the Firebase project (docs/firebase-setup.md).
    public static let databaseURLString = "https://CHANGE-ME-default-rtdb.firebasedatabase.app"

    public static var databaseURL: URL? {
        guard !databaseURLString.contains("CHANGE-ME") else { return nil }
        return URL(string: databaseURLString)
    }
}
