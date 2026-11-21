import Foundation

/// Removes personal and secret-looking data from text before it leaves the app
/// (diagnostic reports, copied process info). Users still review exports before saving.
public struct Redactor: Sendable {
    public var homeDirectory: String
    public var userName: String
    public var hostName: String?

    public init(homeDirectory: String, userName: String, hostName: String?) {
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.hostName = hostName
    }

    private static let rules: [(pattern: String, replacement: String)] = [
        // key=value / --key=value / --key value secrets in command lines
        (#"(?i)((?:--?|\b)(?:password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|auth|credential)s?[=:\s]\s*)("[^"]*"|'[^']*'|\S+)"#, "$1<redacted>"),
        // Bearer tokens
        (#"(?i)(bearer\s+)[A-Za-z0-9\-._~+/]+=*"#, "$1<redacted>"),
        // URL credentials scheme://user:pass@host
        (#"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1<redacted>@"),
        // email addresses
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        // IPv4 (keep loopback)
        (#"\b(?!127\.0\.0\.1\b)(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
        // MAC addresses
        (#"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#, "<mac>"),
    ]

    public func redact(_ text: String) -> String {
        var output = text
        if !homeDirectory.isEmpty {
            output = output.replacingOccurrences(of: homeDirectory, with: "~")
        }
        for rule in Self.rules {
            output = output.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }
        if userName.count >= 3 {
            output = output.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/<user>")
        }
        if let hostName, hostName.count >= 3 {
            output = output.replacingOccurrences(of: hostName, with: "<host>", options: .caseInsensitive)
        }
        return output
    }
}
