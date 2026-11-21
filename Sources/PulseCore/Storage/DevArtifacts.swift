import Foundation

/// How safe it is to remove a finding. Drives default selection in the cleanup preview.
public enum CleanupSafety: String, Codable, Sendable, Comparable {
    /// Regenerated automatically by tooling (build output, caches).
    case rebuildable
    /// Can be recreated, but with user effort (reinstalling deps, re-downloading).
    case recreatable
    /// Shown for information only; PulseMac never offers to remove it.
    case reviewOnly

    private var order: Int { self == .rebuildable ? 0 : (self == .recreatable ? 1 : 2) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

public struct DevArtifactRule: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var why: String
    public var impact: String
    public var regenerate: String
    public var safety: CleanupSafety

    /// Static catalogue. Order matters: first match wins.
    public static let catalogue: [DevArtifactRule] = [
        DevArtifactRule(
            id: "xcode.derivedData", title: "Xcode DerivedData",
            why: "Xcode stores build products, indexes and logs here for every project you have built.",
            impact: "The next build of each project will be a full rebuild and indexing will rerun.",
            regenerate: "Rebuilt automatically the next time you open and build the project.",
            safety: .rebuildable
        ),
        DevArtifactRule(
            id: "xcode.archives", title: "Xcode Archives",
            why: "Archives are created when you distribute an app and contain its debug symbols (dSYMs).",
            impact: "You will no longer be able to symbolicate crash reports for those builds.",
            regenerate: "Cannot be regenerated exactly. Keep archives for releases you still support.",
            safety: .reviewOnly
        ),
        DevArtifactRule(
            id: "xcode.deviceSupport", title: "iOS DeviceSupport files",
            why: "Xcode copies debug symbols from each iOS version of devices you connect.",
            impact: "Xcode re-copies symbols the next time you connect a device on that iOS version.",
            regenerate: "Recreated automatically when a device is connected.",
            safety: .rebuildable
        ),
        DevArtifactRule(
            id: "simulator.devices", title: "Simulator devices",
            why: "Each simulator device stores its installed apps and data.",
            impact: "Deleting a device removes its apps and data. Prefer `xcrun simctl delete unavailable` to remove only obsolete devices.",
            regenerate: "Create devices again in Xcode; app data is lost.",
            safety: .reviewOnly
        ),
        DevArtifactRule(
            id: "node.modules", title: "Node.js dependencies (node_modules)",
            why: "Installed JavaScript packages for a project.",
            impact: "The project will not run until dependencies are installed again.",
            regenerate: "Run your package manager's install command (npm install, pnpm install, yarn).",
            safety: .recreatable
        ),
        DevArtifactRule(
            id: "python.venv", title: "Python virtual environment",
            why: "An isolated Python installation with project packages.",
            impact: "The project's Python environment will need to be recreated.",
            regenerate: "Recreate with `python3 -m venv` and reinstall requirements.",
            safety: .recreatable
        ),
        DevArtifactRule(
            id: "rust.target", title: "Rust build output (target)",
            why: "Cargo's compiled artifacts and incremental build cache.",
            impact: "The next build will compile everything from scratch.",
            regenerate: "Rebuilt automatically by `cargo build`.",
            safety: .rebuildable
        ),
        DevArtifactRule(
            id: "gradle.build", title: "Gradle build output (build)",
            why: "Compiled classes and packaged outputs of a Gradle project.",
            impact: "The next build will be a full build.",
            regenerate: "Rebuilt automatically by Gradle.",
            safety: .rebuildable
        ),
        DevArtifactRule(
            id: "gradle.caches", title: "Gradle caches",
            why: "Downloaded dependencies and build caches shared by all Gradle projects.",
            impact: "Dependencies will be downloaded again on the next build (needs network).",
            regenerate: "Re-downloaded automatically.",
            safety: .recreatable
        ),
        DevArtifactRule(
            id: "docker.data", title: "Docker disk image",
            why: "The virtual disk holding images, containers and volumes for Docker Desktop.",
            impact: "Volumes may contain databases and other data that cannot be recreated.",
            regenerate: "Use `docker system df` and `docker image prune` to reclaim space safely. PulseMac never deletes Docker data.",
            safety: .reviewOnly
        ),
    ]

    public static func rule(_ id: String) -> DevArtifactRule? { catalogue.first { $0.id == id } }
}

/// Pure classification of a directory from its name, contents and location.
/// Uses marker files so that, e.g., a folder named `build` is only matched when it belongs to
/// a Gradle project.
public enum DevArtifactMatcher {
    /// - Parameters:
    ///   - path: absolute, standardized directory path
    ///   - entries: names directly inside the directory
    ///   - parentEntries: names directly inside its parent
    ///   - homeDirectory: the user's home directory
    public static func classify(path: String, entries: Set<String>, parentEntries: Set<String>, homeDirectory: String) -> DevArtifactRule? {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let developer = homeDirectory + "/Library/Developer"

        if path == developer + "/Xcode/DerivedData" { return DevArtifactRule.rule("xcode.derivedData") }
        if path == developer + "/Xcode/Archives" { return DevArtifactRule.rule("xcode.archives") }
        if path == developer + "/Xcode/iOS DeviceSupport" { return DevArtifactRule.rule("xcode.deviceSupport") }
        if path == developer + "/CoreSimulator/Devices" { return DevArtifactRule.rule("simulator.devices") }
        if path == homeDirectory + "/.gradle/caches" { return DevArtifactRule.rule("gradle.caches") }
        if path == homeDirectory + "/Library/Containers/com.docker.docker/Data" { return DevArtifactRule.rule("docker.data") }

        switch name {
        case "node_modules" where parentEntries.contains("package.json") && !parent.hasSuffix("/node_modules"):
            return DevArtifactRule.rule("node.modules")
        case _ where entries.contains("pyvenv.cfg"):
            return DevArtifactRule.rule("python.venv")
        case "target" where parentEntries.contains("Cargo.toml") && entries.contains("CACHEDIR.TAG"):
            return DevArtifactRule.rule("rust.target")
        case "build" where parentEntries.contains("build.gradle") || parentEntries.contains("build.gradle.kts"):
            return DevArtifactRule.rule("gradle.build")
        default:
            return nil
        }
    }
}

/// Final gate before any file operation. Independent of the matcher so a bug in matching
/// cannot widen what may be removed.
public enum CleanupGuard {
    public enum Verdict: Equatable, Sendable {
        case permitted
        case refused(String)
    }

    /// Top-level folders that are never cleanup targets themselves.
    static let neverTargets = [
        "", "/Desktop", "/Documents", "/Downloads", "/Library", "/Movies", "/Music", "/Pictures", "/Public",
        "/Applications", "/Library/Mobile Documents", "/Library/CloudStorage",
    ]

    public static func check(
        path: String, rule: DevArtifactRule?, homeDirectory: String, isSymbolicLink: Bool
    ) -> Verdict {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(homeDirectory + "/") else {
            return .refused("Only folders inside your home folder can be cleaned up.")
        }
        if neverTargets.contains(where: { standardized == homeDirectory + $0 }) {
            return .refused("This is a top-level personal folder.")
        }
        if standardized.contains("/Library/Mobile Documents/") || standardized.contains("/Library/CloudStorage/") {
            return .refused("Cloud-synced folders are excluded; removing items would also remove them from your other devices.")
        }
        if isSymbolicLink { return .refused("Symbolic links are skipped to avoid affecting their destination.") }
        guard let rule else { return .refused("Only recognised, rebuildable developer data can be cleaned up.") }
        guard rule.safety != .reviewOnly else {
            return .refused("\(rule.title) is shown for review only. \(rule.regenerate)")
        }
        return .permitted
    }
}
