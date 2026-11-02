import Foundation
import TermsieCore

/// Turns an `SSHConnection` into the `ssh.exe` process a terminal runs.
///
/// SSH terminals are made on a Mac and reach Windows in a shared workspace. Windows' own OpenSSH
/// client is used, so the user's `~/.ssh/config`, agent and `known_hosts` apply as they do in any
/// terminal. Stored passwords and passphrases live in the Mac's Keychain, so here `ssh` asks for
/// them on the terminal itself; a private key stored in the Keychain cannot be used.
enum SSHLaunch {
    struct Plan {
        var executable: String
        var args: [String]
    }

    struct Failure: Error {
        let reason: String
    }

    /// - Parameters:
    ///   - commands: run on the server, in order, before its interactive shell.
    ///   - remoteDirectory: where on the server the shell starts, tilde allowed.
    static func prepare(_ connection: SSHConnection, commands: [String], remoteDirectory: String?,
                        environment: [String: String]) -> Result<Plan, Failure> {
        if let problem = connection.problem { return .failure(Failure(reason: problem)) }
        guard let executable = locate(environment: environment) else {
            return .failure(Failure(reason: "ssh.exe was not found — add the OpenSSH Client optional feature in Windows Settings"))
        }
        var args: [String] = []
        if let port = connection.port { args += ["-p", String(port)] }
        if let user = connection.user, !user.isEmpty { args += ["-l", user] }

        switch connection.identity {
        case .automatic:
            break
        case .keyFile:
            let path = HomePath.expand((connection.identityFile ?? "").trimmingCharacters(in: .whitespaces))
            args += ["-i", path, "-o", "IdentitiesOnly=yes"]
        case .storedKey:
            return .failure(Failure(reason: "its private key is stored in a Mac's Keychain — choose a key file instead"))
        }

        for option in connection.options where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-o", option.trimmingCharacters(in: .whitespaces)]
        }

        let remote = SSHConnection.remoteCommand(commands: commands, directory: remoteDirectory)
        // A command on the line means no tty unless asked for, and the session is interactive.
        if remote != nil { args.append("-t") }
        args.append(connection.host.trimmingCharacters(in: .whitespaces))
        if let remote { args.append(remote) }
        return .success(Plan(executable: executable, args: args))
    }

    /// `ssh.exe` on PATH (a newer OpenSSH the user installed), else the one Windows ships.
    static func locate(environment: [String: String]) -> String? {
        if let found = ShellLocator.searchPath("ssh.exe", environment: environment) { return found }
        let root = environment["SystemRoot"] ?? environment["SYSTEMROOT"] ?? "C:\\Windows"
        let bundled = root + "\\System32\\OpenSSH\\ssh.exe"
        return FileManager.default.fileExists(atPath: bundled) ? bundled : nil
    }
}
