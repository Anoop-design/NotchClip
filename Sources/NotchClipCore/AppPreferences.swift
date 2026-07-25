import Foundation

/// Persisted app preferences (UserDefaults; local only).
public struct AppPreferences: Equatable, Sendable {
    public var fetchLinkPreviews: Bool

    public static let fetchLinkPreviewsKey = "com.anoop.notchclip.fetchLinkPreviews"

    public init(fetchLinkPreviews: Bool = true) {
        self.fetchLinkPreviews = fetchLinkPreviews
    }

    public static func load(defaults: UserDefaults = .standard) -> AppPreferences {
        if defaults.object(forKey: fetchLinkPreviewsKey) == nil {
            return AppPreferences(fetchLinkPreviews: true)
        }
        return AppPreferences(fetchLinkPreviews: defaults.bool(forKey: fetchLinkPreviewsKey))
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(fetchLinkPreviews, forKey: Self.fetchLinkPreviewsKey)
    }
}

/// Snapshot of history storage usage for Settings.
public struct StorageStats: Equatable, Sendable {
    public var itemCount: Int
    public var payloadBytes: Int
    public var applicationSupportPath: String

    public init(itemCount: Int, payloadBytes: Int, applicationSupportPath: String) {
        self.itemCount = itemCount
        self.payloadBytes = payloadBytes
        self.applicationSupportPath = applicationSupportPath
    }

    public var formattedBytes: String {
        EntryPresentation.byteCountString(payloadBytes)
    }
}
