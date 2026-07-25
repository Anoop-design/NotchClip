import Foundation

/// Pure generation counter for stale-dismiss of presented clipboard UI (unit-testable).
/// When a new presentation starts, generation increments; dismiss only applies if still current.
public struct PresentationGeneration: Equatable, Sendable {
    public private(set) var generation: UInt64

    public init(generation: UInt64 = 0) {
        self.generation = generation
    }

    /// Begin a new presentation cycle; returns the generation to associate with that presentation.
    @discardableResult
    public mutating func beginPresentation() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Returns `true` when `token` still matches the current generation (safe to dismiss / commit).
    public func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }

    /// Dismiss only if `token` is still the active generation. Returns whether dismiss was applied.
    @discardableResult
    public mutating func dismissIfCurrent(_ token: UInt64) -> Bool {
        guard isCurrent(token) else { return false }
        // Advance so any late callbacks for this presentation become stale.
        generation &+= 1
        return true
    }
}

/// Motion preferences that drive panel animation policy (unit-testable, no AppKit coupling).
public struct MotionPreferences: Equatable, Sendable {
    public var reduceMotion: Bool

    public init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }
}

/// Animation behavior for clipboard panel presentation.
public enum MotionBehavior: Equatable, Sendable {
    /// Full motion: spring / slide allowed.
    case full
    /// Accessibility: fade only (no position springs).
    case fadeOnly
}

/// Maps motion preferences to concrete panel behavior.
public enum MotionPolicy {
    public static func behavior(for preferences: MotionPreferences) -> MotionBehavior {
        preferences.reduceMotion ? .fadeOnly : .full
    }

    public static func behavior(reduceMotion: Bool) -> MotionBehavior {
        behavior(for: MotionPreferences(reduceMotion: reduceMotion))
    }
}

/// High-level panel presentation phase for coordinators.
public enum PanelPresentationPhase: String, Equatable, Sendable {
    case hidden
    case compact
    case expanding
    case expanded
    case collapsing
}
