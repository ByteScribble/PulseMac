import Foundation

/// Allowlisted operations. There is no "run command" action and no bulk termination.
public enum RemediationKind: String, Codable, Sendable {
    /// Ask an app to quit normally (it may show a save dialog or refuse).
    case quitApp
    /// SIGTERM: ask a process to exit.
    case terminateProcess
    /// SIGKILL / force quit: unsaved work is lost. Requires explicit confirmation.
    case forceQuit
    case moveToTrash
    case revealInFinder
    case openActivityMonitor

    public var isDestructive: Bool {
        switch self {
        case .quitApp, .terminateProcess, .forceQuit, .moveToTrash: return true
        case .revealInFinder, .openActivityMonitor: return false
        }
    }
}

/// Lifecycle of an action, kept distinct so the UI never conflates "attempted" with "worked"
/// (product principle 2.4 and PRD § Resolution workflow).
public enum ActionPhase: String, Codable, Sendable {
    case suggested, requested, attempted, succeeded, failed
    case effectUnverified, effectVerified, effectNotObserved
}

public struct ActionRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: RemediationKind
    /// Redacted description of the target (process name, folder name).
    public var targetDescription: String
    public var incidentID: UUID?
    public var requestedAt: Date
    public var phase: ActionPhase
    public var message: String?
    /// Metric used to verify the effect, if any.
    public var verificationMetric: MetricID?

    public init(
        id: UUID = UUID(), kind: RemediationKind, targetDescription: String, incidentID: UUID?,
        requestedAt: Date, phase: ActionPhase, message: String? = nil, verificationMetric: MetricID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetDescription = targetDescription
        self.incidentID = incidentID
        self.requestedAt = requestedAt
        self.phase = phase
        self.message = message
        self.verificationMetric = verificationMetric
    }
}

/// Decides whether a process action may be offered. Pure function of process attributes so
/// it can be tested exhaustively; the macOS executor re-checks before acting.
public enum ProcessActionPolicy {
    public enum Decision: Equatable, Sendable {
        case allowed(requiresConfirmation: Bool, warning: String?)
        case denied(reason: String)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }
    }

    /// Processes that must never be offered for termination, regardless of ownership.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "coreaudiod", "configd", "mds", "mds_stores", "opendirectoryd", "securityd",
        "trustd", "powerd", "syslogd", "notifyd", "distnoted", "cfprefsd", "UserEventAgent", "kextd",
        "fseventsd", "diskarbitrationd", "hidd", "bluetoothd", "airportd", "watchdogd", "runningboardd",
    ]

    public static let protectedPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    public static func decide(
        _ kind: RemediationKind, process: ProcessSample, currentUserID: UInt32, ownPID: Int32
    ) -> Decision {
        switch kind {
        case .revealInFinder:
            return process.executablePath == nil
                ? .denied(reason: "The executable location is not available for this process.")
                : .allowed(requiresConfirmation: false, warning: nil)
        case .openActivityMonitor:
            return .allowed(requiresConfirmation: false, warning: nil)
        case .moveToTrash:
            return .denied(reason: "Processes cannot be moved to the Trash.")
        case .quitApp, .terminateProcess, .forceQuit:
            break
        }
        if process.pid <= 1 { return .denied(reason: "This is a core macOS process.") }
        if process.pid == ownPID { return .denied(reason: "Use Quit PulseMac from the menu instead.") }
        if protectedNames.contains(process.name) {
            return .denied(reason: "\(process.name) is part of macOS. Ending it could log you out or make the Mac unstable.")
        }
        if let path = process.executablePath, protectedPathPrefixes.contains(where: path.hasPrefix) {
            return .denied(reason: "This process is part of macOS and is restarted automatically if it ends.")
        }
        if process.userID != currentUserID {
            return .denied(reason: "This process belongs to another user or to macOS. PulseMac does not use administrator privileges.")
        }
        if kind == .quitApp, process.appBundlePath == nil {
            return .denied(reason: "Only apps can be asked to quit. Use End Process instead.")
        }
        switch kind {
        case .forceQuit:
            return .allowed(requiresConfirmation: true, warning: "Force quitting ends the process immediately. Unsaved work will be lost.")
        default:
            return .allowed(requiresConfirmation: true, warning: nil)
        }
    }
}
