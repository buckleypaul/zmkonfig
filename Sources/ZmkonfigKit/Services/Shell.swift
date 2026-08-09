import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }

    /// stdout with trailing newline removed — what callers almost always want.
    public var trimmed: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to show when the command failed: whatever it said on stderr, or
    /// stdout for the tools that report failures there instead.
    public var failureDetail: String {
        (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ShellError: Error, CustomStringConvertible {
    public let command: String
    public let result: ShellResult

    public var description: String {
        "`\(command)` failed (\(result.status)): \(result.failureDetail)"
    }
}

/// Thin wrapper around Process for the CLIs the app drives (`git`, `gh`, `unzip`).
///
/// Everything routes through here so that command execution stays off the main
/// actor and failures carry the command text for display.
public enum Shell {
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + arguments
                if let cwd { process.currentDirectoryURL = cwd }
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }

                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read both pipes before waiting so a large artifact listing
                // cannot fill a pipe buffer and deadlock the child.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Runs a command and throws unless it exits zero.
    @discardableResult
    public static func checked(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, cwd: cwd, environment: environment)
        guard result.ok else {
            throw ShellError(command: ([executable] + arguments).joined(separator: " "), result: result)
        }
        return result
    }
}
