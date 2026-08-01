import Foundation

/// Persisted app preferences (UserDefaults; local only).
public struct AppPreferences: Equatable, Sendable {
    public var fetchLinkPreviews: Bool
    /// The brief "Copied · Source" notch acknowledgment. Off by default —
    /// ambient motion on every copy proved unwelcome in practice.
    public var showCapturePulse: Bool
    /// Maximum unpinned entries kept in history; `RetentionPolicy.unlimited` keeps everything.
    public var historyLimit: Int

    public static let fetchLinkPreviewsKey = "com.anoop.notchclip.fetchLinkPreviews"
    public static let showCapturePulseKey = "com.anoop.notchclip.showCapturePulse"
    public static let historyLimitKey = "com.anoop.notchclip.historyLimit"

    public init(
        fetchLinkPreviews: Bool = true,
        showCapturePulse: Bool = false,
        historyLimit: Int = RetentionPolicy.defaultLimit
    ) {
        self.fetchLinkPreviews = fetchLinkPreviews
        self.showCapturePulse = showCapturePulse
        self.historyLimit = historyLimit
    }

    public static func load(defaults: UserDefaults = .standard) -> AppPreferences {
        let fetchLinkPreviews = defaults.object(forKey: fetchLinkPreviewsKey) == nil
            ? true
            : defaults.bool(forKey: fetchLinkPreviewsKey)
        // Absent key means the default (off); bool(forKey:) already returns false.
        let showCapturePulse = defaults.bool(forKey: showCapturePulseKey)
        // Absent key must not read as 0 — that is the Unlimited sentinel.
        let historyLimit = defaults.object(forKey: historyLimitKey) == nil
            ? RetentionPolicy.defaultLimit
            : defaults.integer(forKey: historyLimitKey)
        return AppPreferences(
            fetchLinkPreviews: fetchLinkPreviews,
            showCapturePulse: showCapturePulse,
            historyLimit: historyLimit
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(fetchLinkPreviews, forKey: Self.fetchLinkPreviewsKey)
        defaults.set(showCapturePulse, forKey: Self.showCapturePulseKey)
        defaults.set(historyLimit, forKey: Self.historyLimitKey)
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
