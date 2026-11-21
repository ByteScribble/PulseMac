import Foundation
import PulseCore

public struct FolderSize: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    /// Allocated size on disk (what deleting would free, before APFS snapshot effects).
    public var allocatedBytes: UInt64
    public var fileCount: Int
    public var children: [FolderSize]
    /// Developer artifact classification, if any.
    public var artifactID: String?
    /// Items we could not read (permission). The total is a lower bound when > 0.
    public var unreadableCount: Int

    public var artifact: DevArtifactRule? { artifactID.flatMap(DevArtifactRule.rule) }
}

public struct ScanOptions: Sendable {
    /// Directory depth for which child breakdowns are kept (deeper levels are summed only).
    public var detailDepth: Int = 3
    /// Child entries kept per folder in the result tree (largest first).
    public var maximumChildren: Int = 40
    public var excludedPaths: Set<String> = []
    public var homeDirectory: String = NSHomeDirectory()

    public init() {}
}

/// Recursively sizes folders. Read-only, cancellable (checks `Task.isCancelled`), does not
/// follow symbolic links, and does not cross into other volumes.
///
/// Scanning protected locations (Mail, Messages, Safari, other apps' containers) requires
/// Full Disk Access; without it those folders are counted as unreadable, not as empty.
public struct StorageScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) { self.options = options }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .volumeIdentifierKey, .isPackageKey,
    ]

    public func scan(_ root: URL, progress: (@Sendable (Int) -> Void)? = nil) throws -> FolderSize {
        let rootValues = try root.resourceValues(forKeys: [.volumeIdentifierKey])
        var counter = 0
        return try scanDirectory(
            root.standardizedFileURL, depth: 0, parentEntries: parentEntries(of: root),
            volume: rootValues.volumeIdentifier.map { "\($0)" }, counter: &counter, progress: progress
        )
    }

    private func parentEntries(of url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
    }

    private func scanDirectory(
        _ url: URL, depth: Int, parentEntries: Set<String>, volume: String?, counter: inout Int, progress: (@Sendable (Int) -> Void)?
    ) throws -> FolderSize {
        try Task.checkCancellation()
        let fm = FileManager.default
        var total: UInt64 = 0
        var files = 0
        var unreadable = 0
        var children: [FolderSize] = []
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys, options: [])
        } catch {
            return FolderSize(
                path: url.path, name: url.lastPathComponent, allocatedBytes: 0, fileCount: 0, children: [],
                artifactID: nil, unreadableCount: 1
            )
        }
        let names = Set(entries.map(\.lastPathComponent))

        for entry in entries {
            if options.excludedPaths.contains(entry.path) { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(Self.keys)) else {
                unreadable += 1
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if let volume, let entryVolume = values.volumeIdentifier.map({ "\($0)" }), entryVolume != volume { continue }
                let child = try scanDirectory(entry, depth: depth + 1, parentEntries: names, volume: volume, counter: &counter, progress: progress)
                total += child.allocatedBytes
                files += child.fileCount
                unreadable += child.unreadableCount
                if depth < options.detailDepth { children.append(child) }
            } else {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
                total += UInt64(max(size, 0))
                files += 1
                counter += 1
                if counter % 2000 == 0 { progress?(counter) }
            }
        }

        let artifact = DevArtifactMatcher.classify(
            path: url.path, entries: names, parentEntries: parentEntries, homeDirectory: options.homeDirectory
        )
        children.sort { $0.allocatedBytes > $1.allocatedBytes }
        if children.count > options.maximumChildren { children = Array(children.prefix(options.maximumChildren)) }
        return FolderSize(
            path: url.path, name: url.lastPathComponent, allocatedBytes: total, fileCount: files,
            children: children, artifactID: artifact?.id, unreadableCount: unreadable
        )
    }

    /// Flattens a scan into developer-artifact findings (outermost matches only).
    public static func artifacts(in tree: FolderSize) -> [FolderSize] {
        if tree.artifactID != nil { return [tree] }
        return tree.children.flatMap { artifacts(in: $0) }
    }
}

/// A user-reviewed cleanup. Defaults to dry run; items move to the Trash, never deleted.
public struct CleanupPlan: Sendable {
    public struct Item: Identifiable, Sendable, Equatable {
        public var id: String { path }
        public var path: String
        public var estimatedBytes: UInt64
        public var artifactID: String
        public var selected: Bool
    }

    public enum Outcome: Sendable, Equatable {
        case wouldMove(path: String, bytes: UInt64)
        case moved(path: String, trashURL: String?)
        case skipped(path: String, reason: String)
        case failed(path: String, reason: String)
    }

    public var items: [Item]
    public var homeDirectory: String

    public init(findings: [FolderSize], homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        items = findings.compactMap { finding in
            guard let rule = finding.artifact, rule.safety != .reviewOnly else { return nil }
            // Only rebuildable items are preselected; recreatable ones need an explicit choice.
            return Item(path: finding.path, estimatedBytes: finding.allocatedBytes, artifactID: rule.id, selected: rule.safety == .rebuildable)
        }
    }

    public var selectedBytes: UInt64 { items.filter(\.selected).reduce(0) { $0 + $1.estimatedBytes } }

    /// Executes the plan. With `dryRun` nothing is touched. Every item is re-validated by
    /// `CleanupGuard` immediately before the operation.
    public func execute(dryRun: Bool, trash: (URL) throws -> URL?) -> [Outcome] {
        items.filter(\.selected).map { item in
            let url = URL(fileURLWithPath: item.path)
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
            let verdict = CleanupGuard.check(
                path: item.path, rule: DevArtifactRule.rule(item.artifactID), homeDirectory: homeDirectory, isSymbolicLink: isLink
            )
            if case let .refused(reason) = verdict { return .skipped(path: item.path, reason: reason) }
            if dryRun { return .wouldMove(path: item.path, bytes: item.estimatedBytes) }
            do {
                let destination = try trash(url)
                return .moved(path: item.path, trashURL: destination?.path)
            } catch {
                return .failed(path: item.path, reason: error.localizedDescription)
            }
        }
    }
}
