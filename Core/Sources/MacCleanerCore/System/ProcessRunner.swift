import Foundation

public enum ProcessError: Error, Equatable {
    case executableMissing(String)
    case timedOut(String)
    case failed(command: String, status: Int32, stderr: String)
}

/// Runs external tools. The only executables MacCleaner shells out to are
/// `diskutil` and `docker` — everything else uses Foundation APIs.
///
/// Executable paths are absolute and explicit. A GUI app does not inherit the
/// shell's `PATH`, so resolving by name works in a terminal and then fails once the
/// app is launched from Finder — a class of bug the Electron version never hit
/// because it was only ever run from a dev shell.
public struct ProcessRunner: Sendable {

    public init() {}

    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration = .seconds(60)
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableMissing(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Read before waiting: a full pipe buffer would deadlock the child.
        async let outputData = Self.readToEnd(outputPipe)
        async let errorData = Self.readToEnd(errorPipe)

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        let output = await outputData
        let errorOutput = await errorData
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw ProcessError.timedOut("\(executable) \(arguments.joined(separator: " "))")
            }
            throw ProcessError.failed(
                command: "\(executable) \(arguments.joined(separator: " "))",
                status: process.terminationStatus,
                stderr: String(decoding: errorOutput, as: UTF8.self)
            )
        }
        return output
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}

public enum SystemExecutable {
    public static let diskutil = "/usr/sbin/diskutil"
    public static let osascript = "/usr/bin/osascript"

    /// Docker Desktop installs to several locations and is often absent entirely.
    public static let dockerCandidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker"
    ]

    public static func resolveDocker() -> String? {
        dockerCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
