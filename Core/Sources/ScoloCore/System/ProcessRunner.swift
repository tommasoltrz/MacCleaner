import Foundation

public enum ProcessError: Error, Equatable {
    case executableMissing(String)
    case timedOut(String)
    case failed(command: String, status: Int32, stderr: String)
}

/// Runs external tools. The only executables Scolo shells out to are
/// `diskutil`, `docker`, and a read-only Homebrew ownership query — everything
/// else uses Foundation APIs.
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

        // Set before launching, or an immediate exit could beat the handler into
        // place and the wait below would never be woken.
        let exit = ExitWaiter()
        process.terminationHandler = { _ in exit.markExited() }

        try process.run()

        // Every signal goes through here, and none is sent once the child has been
        // reaped: after that its pid is just a number the kernel may have handed to
        // somebody else.
        let signals = ChildSignals(process)

        // Draining starts immediately — a full pipe buffer would block the child
        // before it could exit. Unstructured tasks rather than `async let`, which
        // the cancellation handler below would not be allowed to capture.
        let outputTask = Task { await Self.readToEnd(outputPipe) }
        let errorTask = Task { await Self.readToEnd(errorPipe) }

        // The watchdog owns the "took too long" verdict. A signal death alone is
        // not evidence of a timeout — crashes die by signal too — so the flag
        // records whether it was us who pulled the trigger. SIGTERM first, and two
        // seconds later SIGKILL for the process that ignores polite requests (a
        // wedged `docker` was the motivating case).
        let timedOut = ExpiryFlag()
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.raise()
            signals.send(SIGTERM)
            try await Task.sleep(for: .seconds(2))
            signals.send(SIGKILL)
        }
        defer { watchdog.cancel() }

        // A cancelled caller takes the child with it — an orphaned `docker system
        // df` grinding on with nobody to read its answer serves no one — with the
        // same escalation the watchdog uses, owned so it can be called off the
        // moment the child is reaped.
        let escalation = KillEscalation(signals: signals)

        // Wait for the child *before* draining to the end. Reading first was the
        // hang: a descendant that inherited stdout keeps the pipe open long after
        // the child it was forked from is dead, and `readToEnd` waits for the pipe,
        // not for the process.
        //
        // Awaited through `terminationHandler`, never `waitUntilExit()`: that call
        // blocks its thread, and blocking a cooperative-pool thread starves the
        // libdispatch source Foundation uses to notice the exit — a deadlock this
        // suite reproduced immediately.
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            signals.send(SIGTERM)
            escalation.arm()
        }
        signals.markReaped()
        escalation.disarm()

        // The child is gone; anything still holding these pipes is not it. Give the
        // readers a moment to finish normally, then close the read ends so they
        // cannot wait on a grandchild forever. Only ever runs in that pathological
        // case — a healthy child's pipes are at EOF the instant it exits.
        let unblock = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }
        let output = await outputTask.value
        let errorOutput = await errorTask.value
        unblock.cancel()

        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            let command = "\(executable) \(arguments.joined(separator: " "))"
            if timedOut.isRaised {
                throw ProcessError.timedOut(command)
            }
            let stderr = process.terminationReason == .uncaughtSignal
                ? "terminated by signal \(process.terminationStatus)"
                : String(decoding: errorOutput, as: UTF8.self)
            throw ProcessError.failed(
                command: command,
                status: process.terminationStatus,
                stderr: stderr
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

/// Bridges `Process.terminationHandler` to `await`.
///
/// The handler can fire before anyone is waiting — a fast child beats the first
/// suspension — so the flag is what the waiter reads, and the continuation is only
/// parked when the child is still alive.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markExited() {
        lock.lock()
        exited = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// The one place this file signals a child.
///
/// A pid identifies a process only until it is reaped; after that the kernel is
/// free to hand the same number to something else, and a stray `kill` would land
/// on a stranger. Both delayed-SIGKILL paths route through here, and both are shut
/// off by `markReaped()` — taken under the same lock the sends use, so a send that
/// is already inside the lock finishes before the flag is set and one that arrives
/// afterwards is refused.
private final class ChildSignals: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var reaped = false

    init(_ process: Process) { self.process = process }

    func send(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // `isRunning` is the second guard: Foundation clears it as the child exits,
        // which covers a process that died on its own before we were reaped.
        guard !reaped, process.isRunning else { return }
        kill(process.processIdentifier, signal)
    }

    func markReaped() {
        lock.lock()
        reaped = true
        lock.unlock()
    }
}

/// A SIGKILL scheduled for a process that ignored SIGTERM, cancellable the moment
/// the process is reaped.
private final class KillEscalation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var disarmed = false
    private let signals: ChildSignals

    init(signals: ChildSignals) { self.signals = signals }

    func arm() {
        lock.lock()
        defer { lock.unlock() }
        guard !disarmed, task == nil else { return }
        let signals = self.signals
        task = Task.detached {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return   // disarmed: the child is already gone.
            }
            // Refused outright if the child has been reaped meanwhile.
            signals.send(SIGKILL)
        }
    }

    func disarm() {
        lock.lock()
        let pending = task
        task = nil
        disarmed = true
        lock.unlock()
        pending?.cancel()
    }
}

/// Set once by the watchdog, read after the child exits, possibly from another
/// thread — hence the lock rather than a plain `var` the compiler would rightly
/// refuse to share.
private final class ExpiryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock(); raised = true; lock.unlock()
    }

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }; return raised
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
