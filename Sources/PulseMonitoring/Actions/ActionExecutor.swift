#if os(macOS)
import AppKit
import Foundation
import PulseCore

/// Executes allowlisted remediation actions. Every call re-validates the policy and the
/// process identity (PID reuse) immediately before acting. No shell, no sudo.
@MainActor
public final class ActionExecutor {
    public init() {}

    public enum Failure: Error, LocalizedError {
        case denied(String)
        case processChanged
        case systemError(String)

        public var errorDescription: String? {
            switch self {
            case let .denied(reason): return reason
            case .processChanged: return "The process has already exited or its ID now belongs to a different process. Nothing was done."
            case let .systemError(message): return message
            }
        }
    }

    /// Returns a record in phase `.attempted` (request delivered) or throws.
    /// Success of the *effect* is verified later from measurements, not assumed here.
    public func perform(_ kind: RemediationKind, on process: ProcessSample, incidentID: UUID?) throws -> ActionRecord {
        let decision = ProcessActionPolicy.decide(kind, process: process, currentUserID: getuid(), ownPID: getpid())
        guard case .allowed = decision else {
            if case let .denied(reason) = decision { throw Failure.denied(reason) }
            throw Failure.denied("Not permitted.")
        }
        if kind.isDestructive, !ProcessDetails.isSameProcess(process.identity) { throw Failure.processChanged }

        switch kind {
        case .quitApp:
            guard let app = NSRunningApplication(processIdentifier: process.pid), app.terminate() else {
                throw Failure.systemError("\(process.name) did not accept the quit request.")
            }
        case .terminateProcess:
            guard kill(process.pid, SIGTERM) == 0 else { throw Failure.systemError(String(cString: strerror(errno))) }
        case .forceQuit:
            if let app = NSRunningApplication(processIdentifier: process.pid) {
                guard app.forceTerminate() else { throw Failure.systemError("Force quit was refused.") }
            } else {
                guard kill(process.pid, SIGKILL) == 0 else { throw Failure.systemError(String(cString: strerror(errno))) }
            }
        case .revealInFinder:
            guard let path = process.executablePath else { throw Failure.denied("Location unavailable.") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .openActivityMonitor:
            Self.openActivityMonitor()
        case .moveToTrash:
            throw Failure.denied("Not applicable to processes.")
        }
        return ActionRecord(
            kind: kind, targetDescription: process.name, incidentID: incidentID, requestedAt: Date(),
            phase: kind.isDestructive ? .attempted : .succeeded
        )
    }

    public static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Moves a validated item to the Trash (recoverable). Used by `CleanupPlan.execute`.
    public nonisolated static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
#endif
