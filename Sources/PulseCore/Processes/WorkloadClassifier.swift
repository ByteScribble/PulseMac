import Foundation

/// Logical developer workloads recognised from verifiable process attributes
/// (executable path / name). Classification never hides the underlying processes.
public enum WorkloadKind: String, CaseIterable, Codable, Sendable {
    case xcode, simulator, vsCode, jetBrains, docker, jvm, node, python, database, localAI, browser

    public var displayName: String {
        switch self {
        case .xcode: return "Xcode"
        case .simulator: return "iOS Simulator"
        case .vsCode: return "VS Code"
        case .jetBrains: return "JetBrains IDE"
        case .docker: return "Docker"
        case .jvm: return "Java / JVM"
        case .node: return "Node.js"
        case .python: return "Python"
        case .database: return "Local database"
        case .localAI: return "Local AI runtime"
        case .browser: return "Web browser"
        }
    }

    /// Context shown in the workload inspector; keeps interpretation honest.
    public var note: String? {
        switch self {
        case .jvm:
            return "Process memory includes the JVM heap, metaspace, thread stacks, JIT code and native buffers. Heap usage alone does not equal process memory."
        case .docker:
            return "On macOS, containers run inside a Linux virtual machine. Container memory appears as the VM's memory, not as separate macOS processes."
        case .localAI:
            return "PulseMac identifies the runtime, not the model. Model identity is shown only when a local source verifies it. GPU use cannot be attributed to a single process with public APIs."
        case .simulator:
            return "Each booted simulator runs many macOS processes; they are grouped here."
        default:
            return nil
        }
    }
}

public struct WorkloadMatch: Equatable, Sendable {
    public var kind: WorkloadKind
    /// Specific runtime when distinguishable, e.g. "Ollama", "llama.cpp server", "PostgreSQL".
    public var runtime: String?
}

public enum WorkloadClassifier {
    private struct Rule {
        let kind: WorkloadKind
        let runtime: String?
        let matches: (_ name: String, _ path: String) -> Bool
    }

    private static func pathContains(_ fragment: String) -> (String, String) -> Bool {
        { _, path in path.contains(fragment) }
    }

    private static func nameIs(_ names: Set<String>) -> (String, String) -> Bool {
        { name, _ in names.contains(name.lowercased()) }
    }

    // Ordered: first match wins. More specific rules precede generic runtimes
    // (e.g. LM Studio bundles Node/Python helpers).
    private static let rules: [Rule] = [
        Rule(kind: .localAI, runtime: "LM Studio", matches: pathContains("/LM Studio.app/")),
        Rule(kind: .localAI, runtime: "Ollama", matches: { name, path in
            name.lowercased() == "ollama" || path.contains("/Ollama.app/")
        }),
        Rule(kind: .localAI, runtime: "llama.cpp", matches: nameIs(["llama-server", "llama-cli", "llama-bench"])),
        Rule(kind: .simulator, runtime: nil, matches: { _, path in
            path.contains("/CoreSimulator/") || path.contains("/Simulator.app/")
        }),
        Rule(kind: .xcode, runtime: nil, matches: { name, path in
            path.contains("/Xcode.app/") || path.contains("/Xcode-beta.app/") || name == "SourceKitService"
        }),
        Rule(kind: .vsCode, runtime: nil, matches: { _, path in
            path.contains("/Visual Studio Code.app/") || path.contains("/Cursor.app/") || path.contains("/VSCodium.app/")
        }),
        Rule(kind: .jetBrains, runtime: nil, matches: { _, path in
            ["/IntelliJ IDEA", "/PyCharm", "/WebStorm", "/GoLand", "/Android Studio", "/CLion", "/RustRover", "/Rider"]
                .contains { path.contains($0) }
        }),
        Rule(kind: .docker, runtime: nil, matches: { name, path in
            path.contains("/Docker.app/") || ["com.docker.backend", "com.docker.virtualization", "dockerd", "colima", "limactl", "orbstack"]
                .contains(name.lowercased()) || path.contains("/OrbStack.app/")
        }),
        Rule(kind: .database, runtime: "PostgreSQL", matches: nameIs(["postgres", "postmaster"])),
        Rule(kind: .database, runtime: "MySQL", matches: nameIs(["mysqld", "mariadbd"])),
        Rule(kind: .database, runtime: "Redis", matches: nameIs(["redis-server"])),
        Rule(kind: .database, runtime: "MongoDB", matches: nameIs(["mongod"])),
        Rule(kind: .jvm, runtime: nil, matches: { name, path in
            name == "java" || path.hasSuffix("/bin/java")
        }),
        Rule(kind: .node, runtime: nil, matches: nameIs(["node", "bun", "deno"])),
        Rule(kind: .python, runtime: nil, matches: { name, _ in
            let lower = name.lowercased()
            return lower == "python" || lower.hasPrefix("python3")
        }),
        Rule(kind: .browser, runtime: nil, matches: { _, path in
            ["/Google Chrome.app/", "/Safari.app/", "/Firefox.app/", "/Arc.app/", "/Microsoft Edge.app/", "/Brave Browser.app/",
             "/com.apple.WebKit."]
                .contains { path.contains($0) }
        }),
    ]

    public static func classify(name: String, executablePath: String?) -> WorkloadMatch? {
        let path = executablePath ?? ""
        for rule in rules where rule.matches(name, path) {
            return WorkloadMatch(kind: rule.kind, runtime: rule.runtime)
        }
        return nil
    }

    public static func classify(_ process: ProcessSample) -> WorkloadMatch? {
        classify(name: process.name, executablePath: process.executablePath)
    }
}
