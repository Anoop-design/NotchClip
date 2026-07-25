import Foundation
import AppKit

/// One pasteboard item’s retained types and bytes (immutable, Sendable).
public struct PasteboardItemSnapshot: Equatable, Sendable {
    public var types: [String]
    public var dataByType: [String: Data]

    public init(types: [String], dataByType: [String: Data]) {
        self.types = types
        self.dataByType = dataByType
    }
}

/// Immutable pasteboard capture for off-main parse/persist.
public struct PasteboardSnapshot: Equatable, Sendable {
    public var changeCount: Int
    public var boardTypes: [String]
    public var items: [PasteboardItemSnapshot]
    public var source: SourceMetadata
    /// False when the live board’s changeCount advanced during snapshot construction.
    public var isConsistent: Bool
    public var totalBytesRetained: Int

    public init(
        changeCount: Int,
        boardTypes: [String],
        items: [PasteboardItemSnapshot],
        source: SourceMetadata,
        isConsistent: Bool = true,
        totalBytesRetained: Int = 0
    ) {
        self.changeCount = changeCount
        self.boardTypes = boardTypes
        self.items = items
        self.source = source
        self.isConsistent = isConsistent
        self.totalBytesRetained = totalBytesRetained
    }
}

/// Snapshots pasteboard contents on the calling thread (production: main actor).
public enum PasteboardSnapshotter {
    /// Per-representation cap (matches parser).
    public static let defaultMaxRepresentationBytes = PasteboardParser.defaultMaxRepresentationBytes
    /// Total retained-byte budget across all representations in one snapshot (v1: 128 MiB).
    public static let defaultTotalRetainedBytes = 128 * 1024 * 1024

    public static func snapshot(
        pasteboard: NSPasteboard,
        source: SourceMetadata,
        maxRepresentationBytes: Int = defaultMaxRepresentationBytes,
        maxTotalRetainedBytes: Int = defaultTotalRetainedBytes
    ) -> PasteboardSnapshot {
        let startCount = pasteboard.changeCount
        let boardTypes = pasteboard.types?.map(\.rawValue) ?? []
        let pbItems = pasteboard.pasteboardItems ?? []
        var total = 0
        var budgetExhausted = false

        func accept(_ data: Data) -> Bool {
            if data.count > maxRepresentationBytes { return false }
            if total + data.count > maxTotalRetainedBytes {
                budgetExhausted = true
                return false
            }
            total += data.count
            return true
        }

        var items: [PasteboardItemSnapshot] = []

        if pbItems.isEmpty {
            var dataByType: [String: Data] = [:]
            var types: [String] = []
            for typeID in boardTypes {
                if budgetExhausted { break }
                if PasteboardMarkerTypes.rejected.contains(typeID) { continue }
                if typeID == PasteboardMarkerTypes.source { continue }
                let pbType = NSPasteboard.PasteboardType(typeID)
                guard let data = pasteboard.data(forType: pbType), !data.isEmpty else { continue }
                guard accept(data) else { continue }
                types.append(typeID)
                dataByType[typeID] = data
            }
            if !types.isEmpty {
                items.append(PasteboardItemSnapshot(types: types, dataByType: dataByType))
            }
        } else {
            for item in pbItems {
                if budgetExhausted { break }
                let typeIDs = item.types.map(\.rawValue)
                var dataByType: [String: Data] = [:]
                var keptTypes: [String] = []
                for typeID in typeIDs {
                    if budgetExhausted { break }
                    if PasteboardMarkerTypes.rejected.contains(typeID) { continue }
                    if typeID == PasteboardMarkerTypes.source { continue }
                    let pbType = NSPasteboard.PasteboardType(typeID)
                    guard let data = item.data(forType: pbType), !data.isEmpty else { continue }
                    guard accept(data) else { continue }
                    keptTypes.append(typeID)
                    dataByType[typeID] = data
                }
                if !keptTypes.isEmpty {
                    items.append(PasteboardItemSnapshot(types: keptTypes, dataByType: dataByType))
                }
            }
        }

        let endCount = pasteboard.changeCount
        let consistent = endCount == startCount
        return PasteboardSnapshot(
            changeCount: consistent ? startCount : endCount,
            boardTypes: boardTypes,
            items: items,
            source: source,
            isConsistent: consistent,
            totalBytesRetained: total
        )
    }
}
