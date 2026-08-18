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

    /// Throws when the user declines the prompt or the script fails.
    static func run(_ script: String) async throws {
        let appleScript = "do shell script \""
            + script.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            + "\" with administrator privileges"
        _ = try await ProcessRunner().run(
            SystemExecutable.osascript, ["-e", appleScript], timeout: .seconds(180)
        )
    }
}
