import Foundation
import PulseCore

/// Contract every collector documents (docs/architecture/architecture.md § Collector contract).
public struct CollectorDescriptor: Sendable {
    public var id: String
    public var capabilities: [CapabilityID]
    /// API / data source, shown in "About this number".
    public var source: String
    /// Collected every `cadence` coordinator ticks.
    public var cadence: Int
    /// Permission or entitlement needed; nil when none.
    public var permission: String?
    /// Expected cost per call, from profiling (see performance budgets).
    public var expectedCost: String
    /// Failure behaviour: what the UI shows when this collector fails.
    public var failureBehavior: String

    public init(
        id: String, capabilities: [CapabilityID], source: String, cadence: Int = 1, permission: String? = nil,
        expectedCost: String, failureBehavior: String = "Domain marked unavailable with the error; other collectors continue."
    ) {
        self.id = id
        self.capabilities = capabilities
        self.source = source
        self.cadence = cadence
        self.permission = permission
        self.expectedCost = expectedCost
        self.failureBehavior = failureBehavior
    }
}

/// A collector fills its own domain of a `SystemSnapshot`. Collectors are stateful (they keep
/// previous counter readings) and are confined to the coordinator; they are not thread-safe.
public protocol Collector: AnyObject {
    var descriptor: CollectorDescriptor { get }
    /// Initial capability evaluation, run once at startup.
    func probe() -> [Capability]
    /// - Parameter monotonicTime: seconds from a monotonic clock, for rate calculations.
    func collect(into snapshot: inout SystemSnapshot, monotonicTime: TimeInterval) throws
    /// Forget previous counter readings (sleep/wake, resumed after pause).
    func reset()
}

public struct CollectorFailure: Error, CustomStringConvertible, Sendable {
    public var collector: String
    public var message: String
    public init(collector: String, message: String) {
        self.collector = collector
        self.message = message
    }
    public var description: String { "\(collector): \(message)" }
}

/// What the coordinator samples from. Live (macOS collectors) or fixture.
public protocol SnapshotSource: AnyObject {
    /// True for synthetic data; the UI shows a persistent "Fixture data" banner.
    var isFixture: Bool { get }
    var topology: CPUTopology { get }
    func capabilities() -> [Capability]
    func snapshot(at date: Date, monotonicTime: TimeInterval, tick: Int, includeProcesses: Bool) -> SystemSnapshot
    func resetCounters()
}

/// Runs a list of collectors with per-collector cadence and isolates failures.
public final class CollectorSet: SnapshotSource {
    public let isFixture = false
    public let topology: CPUTopology
    private let collectors: [any Collector]
    private let registry: CapabilityRegistry
    private let processCollectorID: String?

    public init(collectors: [any Collector], topology: CPUTopology, registry: CapabilityRegistry, processCollectorID: String? = "processes") {
        self.collectors = collectors
        self.topology = topology
        self.registry = registry
        self.processCollectorID = processCollectorID
        for collector in collectors {
            for capability in collector.probe() { registry.set(capability) }
        }
    }

    public func capabilities() -> [Capability] { registry.all() }

    public func snapshot(at date: Date, monotonicTime: TimeInterval, tick: Int, includeProcesses: Bool) -> SystemSnapshot {
        var snapshot = SystemSnapshot(timestamp: date)
        for collector in collectors {
            let descriptor = collector.descriptor
            if descriptor.id == processCollectorID, !includeProcesses { continue }
            guard tick % max(descriptor.cadence, 1) == 0 else { continue }
            do {
                try collector.collect(into: &snapshot, monotonicTime: monotonicTime)
            } catch {
                for id in descriptor.capabilities {
                    registry.set(Capability(id: id, status: .failed(String(describing: error)), source: descriptor.source))
                }
            }
        }
        return snapshot
    }

    public func resetCounters() {
        for collector in collectors { collector.reset() }
    }
}

/// Synthetic source for UI development, demo mode and tests.
public final class FixtureSource: SnapshotSource {
    public let isFixture = true
    public let topology = FixtureGenerator.topology
    private var generator: FixtureGenerator
    private let origin: Date

    public init(scenario: FixtureScenario, start: Date = Date(), seed: UInt64 = 42) {
        generator = FixtureGenerator(scenario: scenario, start: start, seed: seed)
        origin = start
    }

    public func capabilities() -> [Capability] {
        CapabilityID.allCases.map { id in
            let status: CapabilityStatus
            switch id {
            case .perProcessNetwork, .perProcessGPU, .neuralEngine, .temperatureSensors, .fans, .listeningPorts:
                status = .deferred("Not available in this version.")
            case .processCPUOtherUsers:
                status = .needsPermission("Requires administrator privileges, which PulseMac does not use.")
            default:
                status = .available
            }
            return Capability(id: id, status: status, source: "Fixture data")
        }
    }

    public func snapshot(at date: Date, monotonicTime: TimeInterval, tick: Int, includeProcesses: Bool) -> SystemSnapshot {
        var snapshot = generator.snapshot(at: date.timeIntervalSince(origin))
        snapshot.timestamp = date
        if !includeProcesses { snapshot.processes = nil }
        return snapshot
    }

    public func resetCounters() {}
}
