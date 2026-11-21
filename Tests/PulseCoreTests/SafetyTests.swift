import XCTest
@testable import PulseCore

final class ProcessActionPolicyTests: XCTestCase {
    private func process(_ name: String, pid: Int32 = 500, uid: UInt32 = 501, path: String? = "/Applications/Foo.app/Contents/MacOS/Foo") -> ProcessSample {
        ProcessSample(
            identity: ProcessIdentity(pid: pid, startTime: Date()), parentPID: 1, name: name, executablePath: path, userID: uid,
            userName: nil, access: .full, cpuPercent: nil, memoryFootprint: nil, diskReadRate: nil, diskWriteRate: nil, threadCount: nil
        )
    }

    func testUserAppCanQuitWithConfirmation() {
        XCTAssertEqual(
            ProcessActionPolicy.decide(.quitApp, process: process("Foo"), currentUserID: 501, ownPID: 1),
            .allowed(requiresConfirmation: true, warning: nil)
        )
    }

    func testForceQuitWarnsAboutDataLoss() {
        guard case let .allowed(confirm, warning) = ProcessActionPolicy.decide(.forceQuit, process: process("Foo"), currentUserID: 501, ownPID: 1) else {
            return XCTFail("expected allowed")
        }
        XCTAssertTrue(confirm)
        XCTAssertNotNil(warning)
    }

    func testCriticalProcessesAreProtected() {
        for name in ["WindowServer", "kernel_task", "loginwindow", "Finder"] {
            XCTAssertFalse(ProcessActionPolicy.decide(.terminateProcess, process: process(name), currentUserID: 501, ownPID: 1).isAllowed, name)
        }
        XCTAssertFalse(ProcessActionPolicy.decide(.terminateProcess, process: process("x", pid: 1), currentUserID: 501, ownPID: 9).isAllowed)
        XCTAssertFalse(ProcessActionPolicy.decide(.terminateProcess, process: process("x", path: "/System/Library/foo"), currentUserID: 501, ownPID: 9).isAllowed)
    }

    func testOtherUsersProcessesAreDenied() {
        XCTAssertFalse(ProcessActionPolicy.decide(.terminateProcess, process: process("postgres", uid: 0), currentUserID: 501, ownPID: 1).isAllowed)
    }

    func testOwnProcessDenied() {
        XCTAssertFalse(ProcessActionPolicy.decide(.forceQuit, process: process("PulseMac", pid: 777), currentUserID: 501, ownPID: 777).isAllowed)
    }

    func testQuitAppRequiresBundle() {
        XCTAssertFalse(ProcessActionPolicy.decide(.quitApp, process: process("node", path: "/usr/local/bin/node"), currentUserID: 501, ownPID: 1).isAllowed)
        XCTAssertTrue(ProcessActionPolicy.decide(.terminateProcess, process: process("node", path: "/usr/local/bin/node"), currentUserID: 501, ownPID: 1).isAllowed)
    }
}

final class RedactorTests: XCTestCase {
    let redactor = Redactor(homeDirectory: "/Users/alex", userName: "alex", hostName: "Alexs-MacBook-Pro")

    func testRedactsHomeAndSecrets() {
        let input = "/Users/alex/app/server --token=abc123 --password hunter2 API_KEY=xyz on Alexs-MacBook-Pro.local"
        let output = redactor.redact(input)
        XCTAssertFalse(output.contains("abc123"))
        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertFalse(output.contains("xyz"))
        XCTAssertFalse(output.contains("Alexs-MacBook-Pro"))
        XCTAssertTrue(output.hasPrefix("~/app/server"))
    }

    func testRedactsNetworkIdentifiers() {
        let output = redactor.redact("connect 192.168.1.20 from 127.0.0.1 mac a4:83:e7:12:34:56 mail me@example.com https://u:p@host/x Bearer abc.def")
        XCTAssertTrue(output.contains("<ip>"))
        XCTAssertTrue(output.contains("127.0.0.1"))
        XCTAssertTrue(output.contains("<mac>"))
        XCTAssertTrue(output.contains("<email>"))
        XCTAssertFalse(output.contains("u:p@"))
        XCTAssertFalse(output.contains("abc.def"))
    }
}

final class StorageSafetyTests: XCTestCase {
    let home = "/Users/alex"

    func testNodeModulesNeedsPackageJSON() {
        XCTAssertEqual(DevArtifactMatcher.classify(path: "\(home)/p/node_modules", entries: [], parentEntries: ["package.json"], homeDirectory: home)?.id, "node.modules")
        XCTAssertNil(DevArtifactMatcher.classify(path: "\(home)/p/node_modules", entries: [], parentEntries: [], homeDirectory: home))
    }

    func testBuildFolderOnlyForGradle() {
        XCTAssertEqual(DevArtifactMatcher.classify(path: "\(home)/p/build", entries: [], parentEntries: ["build.gradle.kts"], homeDirectory: home)?.id, "gradle.build")
        XCTAssertNil(DevArtifactMatcher.classify(path: "\(home)/p/build", entries: [], parentEntries: ["Makefile"], homeDirectory: home))
    }

    func testRustTargetNeedsCargoAndCachedirTag() {
        XCTAssertEqual(DevArtifactMatcher.classify(path: "\(home)/r/target", entries: ["CACHEDIR.TAG"], parentEntries: ["Cargo.toml"], homeDirectory: home)?.id, "rust.target")
        XCTAssertNil(DevArtifactMatcher.classify(path: "\(home)/r/target", entries: [], parentEntries: ["Cargo.toml"], homeDirectory: home))
    }

    func testKnownLocations() {
        XCTAssertEqual(DevArtifactMatcher.classify(path: "\(home)/Library/Developer/Xcode/DerivedData", entries: [], parentEntries: [], homeDirectory: home)?.safety, .rebuildable)
        XCTAssertEqual(DevArtifactMatcher.classify(path: "\(home)/Library/Developer/Xcode/Archives", entries: [], parentEntries: [], homeDirectory: home)?.safety, .reviewOnly)
        XCTAssertEqual(DevArtifactMatcher.classify(path: "\(home)/Library/Containers/com.docker.docker/Data", entries: [], parentEntries: [], homeDirectory: home)?.safety, .reviewOnly)
    }

    func testGuardRefusals() {
        let derived = DevArtifactRule.rule("xcode.derivedData")
        XCTAssertEqual(CleanupGuard.check(path: "\(home)/Library/Developer/Xcode/DerivedData", rule: derived, homeDirectory: home, isSymbolicLink: false), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "/Library/Caches", rule: derived, homeDirectory: home, isSymbolicLink: false), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "\(home)/Documents", rule: derived, homeDirectory: home, isSymbolicLink: false), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "\(home)/p/node_modules", rule: DevArtifactRule.rule("node.modules"), homeDirectory: home, isSymbolicLink: true), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "\(home)/p/x", rule: nil, homeDirectory: home, isSymbolicLink: false), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "\(home)/Library/Mobile Documents/p/node_modules", rule: DevArtifactRule.rule("node.modules"), homeDirectory: home, isSymbolicLink: false), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "\(home)/Library/Developer/Xcode/Archives", rule: DevArtifactRule.rule("xcode.archives"), homeDirectory: home, isSymbolicLink: false), .permitted)
        XCTAssertNotEqual(CleanupGuard.check(path: "\(home)/../bob/node_modules", rule: DevArtifactRule.rule("node.modules"), homeDirectory: home, isSymbolicLink: false), .permitted, "Path traversal must be normalized")
    }
}

final class WorkloadTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(WorkloadClassifier.classify(name: "ollama", executablePath: "/usr/local/bin/ollama")?.runtime, "Ollama")
        XCTAssertEqual(WorkloadClassifier.classify(name: "node", executablePath: "/Applications/LM Studio.app/Contents/MacOS/node")?.runtime, "LM Studio")
        XCTAssertEqual(WorkloadClassifier.classify(name: "java", executablePath: "/opt/jdk/bin/java")?.kind, .jvm)
        XCTAssertEqual(WorkloadClassifier.classify(name: "python3.12", executablePath: nil)?.kind, .python)
        XCTAssertEqual(WorkloadClassifier.classify(name: "postgres", executablePath: nil)?.runtime, "PostgreSQL")
        XCTAssertNil(WorkloadClassifier.classify(name: "Mail", executablePath: "/System/Applications/Mail.app/Contents/MacOS/Mail"))
    }

    func testLocalAINoteNeverClaimsModelIdentity() {
        XCTAssertTrue(WorkloadKind.localAI.note!.contains("not the model"))
    }

    func testAppGroupingUsesOutermostBundle() {
        let path = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        XCTAssertEqual(AppGrouping.outermostAppBundle(in: path), "/Applications/Slack.app")
        XCTAssertNil(AppGrouping.outermostAppBundle(in: "/usr/bin/node"))
    }

    func testGroupSumsOnlyReadableValues() {
        let start = Date()
        func p(_ pid: Int32, _ path: String, _ cpu: Double?) -> ProcessSample {
            ProcessSample(identity: ProcessIdentity(pid: pid, startTime: start), parentPID: 1, name: "x\(pid)", executablePath: path, userID: 501, userName: nil, access: cpu == nil ? .limited : .full, cpuPercent: cpu, memoryFootprint: nil, diskReadRate: nil, diskWriteRate: nil, threadCount: nil)
        }
        let groups = AppGrouping.group([p(1, "/Applications/A.app/Contents/MacOS/A", 10), p(2, "/Applications/A.app/Contents/Helpers/H.app/Contents/MacOS/H", 5), p(3, "/bin/zsh", nil)])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "A")
        XCTAssertEqual(groups[0].cpuPercent, 15)
        XCTAssertNil(groups[1].cpuPercent, "Unreadable is nil, not zero")
        XCTAssertNil(groups[1].memoryFootprint)
    }
}
