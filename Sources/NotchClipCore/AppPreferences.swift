import Foundation

/// Persisted app preferences (UserDefaults; local only).
public struct AppPreferences: Equatable, Sendable {
    public var fetchLinkPreviews: Bool
    /// The brief "Copied · Source" notch acknowledgment. Off by default —
    /// ambient motion on every copy proved unwelcome in practice.
    public var showCapturePulse: Bool

    public static let fetchLinkPreviewsKey = "com.anoop.notchclip.fetchLinkPreviews"
    public static let showCapturePulseKey = "com.anoop.notchclip.showCapturePulse"

    public init(fetchLinkPreviews: Bool = true, showCapturePulse: Bool = false) {
        self.fetchLinkPreviews = fetchLinkPreviews
        self.showCapturePulse = showCapturePulse
    }

    public static func load(defaults: UserDefaults = .standard) -> AppPreferences {
        let fetchLinkPreviews = defaults.object(forKey: fetchLinkPreviewsKey) == nil
            ? true
            : defaults.bool(forKey: fetchLinkPreviewsKey)
        // Absent key means the default (off); bool(forKey:) already returns false.
        let showCapturePulse = defaults.bool(forKey: showCapturePulseKey)
        return AppPreferences(
            fetchLinkPreviews: fetchLinkPreviews,
            showCapturePulse: showCapturePulse
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(fetchLinkPreviews, forKey: Self.fetchLinkPreviewsKey)
        defaults.set(showCapturePulse, forKey: Self.showCapturePulseKey)
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
