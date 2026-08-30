import Foundation

/// Runs one shell script with administrator rights, via the system authorization
/// dialog. The single entry point exists so every privileged operation in the app
/// shares the same quoting and the same rule: batch the work, prompt once.
enum PrivilegedShell {

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True for the errors an admin retry can actually cure.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain
            && (underlying?.code == 1 || underlying?.code == 13)   // EPERM, EACCES
    }

    /// Runs the script and returns whatever it printed.
    ///
    /// The output matters: a batch that must not abort on its first failure cannot
    /// report per-item success through an exit status, so callers echo a marker per
    /// item and read the result back from here.
    ///
    /// Throws when the user declines the prompt or the script fails.
    @discardableResult
    static func run(_ script: String) async throws -> String {
        let appleScript = "do shell script \""
            + script.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            + "\" with administrator privileges"
        let output = try await ProcessRunner().run(
            SystemExecutable.osascript, ["-e", appleScript], timeout: .seconds(180)
        )
        return String(decoding: output, as: UTF8.self)
    }
}
