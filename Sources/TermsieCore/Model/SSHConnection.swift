import Foundation

/// What makes a terminal an SSH session rather than a local shell: where to connect and how to
/// log in.
///
/// Termsie runs the system's own `ssh` with these settings, so `~/.ssh/config`, the agent,
/// `known_hosts` and ProxyJump all keep working. Credentials never reach a file Termsie writes:
/// a password, a key's passphrase or a stored private key lives in the Keychain, and the
/// definition holds only the opaque reference, exactly like a secret environment variable.
public struct SSHConnection: Codable, Equatable {
    /// Which private key `ssh` offers.
    public enum Identity: String, Codable, CaseIterable {
        /// Whatever `~/.ssh/config` and the agent provide. Nothing is passed.
        case automatic
        /// A key file on disk, passed with `-i`.
        case keyFile
        /// A private key kept in the Keychain, written to a private file only while connected.
        case storedKey
    }

    public var host: String = ""
    /// `nil` lets `~/.ssh/config` or the local user name decide.
    public var user: String?
    /// `nil` lets `~/.ssh/config` decide, normally 22.
    public var port: Int?
    public var identity: Identity = .automatic
    /// The key file for `.keyFile`, stored tilde-preserving.
    public var identityFile: String?
    /// Keychain reference of the login password, answered when the server asks for one.
    public var passwordRef: String?
    /// Keychain reference of the private key's passphrase.
    public var passphraseRef: String?
    /// Keychain reference of the private key itself, for `.storedKey`.
    public var privateKeyRef: String?
    /// Extra `ssh -o` options as `Key=Value`, e.g. `ProxyJump=bastion`.
    public var options: [String] = []

    public init(host: String = "", user: String? = nil, port: Int? = nil) {
        self.host = host
        self.user = user
        self.port = port
    }

    /// Tolerant decode, like the rest of the model: a hand-written `{"host": "db1"}` is enough.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identity = (try? c.decodeIfPresent(Identity.self, forKey: .identity)) ?? .automatic
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        passwordRef = try c.decodeIfPresent(String.self, forKey: .passwordRef)
        passphraseRef = try c.decodeIfPresent(String.self, forKey: .passphraseRef)
        privateKeyRef = try c.decodeIfPresent(String.self, forKey: .privateKeyRef)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
    }

    /// `user@host:port`, leaving out what is not set. What the terminal is called by default.
    public var destination: String {
        var out = host
        if let user, !user.isEmpty { out = user + "@" + out }
        if let port, port != 22 { out += ":\(port)" }
        return out
    }

    /// Every Keychain reference this connection uses.
    public var secretRefs: [String] {
        [passwordRef, passphraseRef, privateKeyRef].compactMap { $0 }
    }

    // MARK: Validation

    /// Options that make `ssh` run a local command. A workspace file can be shared, so opening
    /// one must never be able to run something on this computer just by connecting.
    public static let refusedOptions: Set<String> = [
        "proxycommand", "localcommand", "permitlocalcommand", "knownhostscommand",
        "pkcs11provider", "securitykeyprovider", "include", "match",
    ]

    /// Why this connection cannot be started, or nil when it can.
    public var problem: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return "no host is set" }
        // A leading dash would be read by ssh as an option rather than a host.
        guard !h.hasPrefix("-"), !Self.hasUnsafeCharacters(h) else { return "“\(host)” is not a valid host" }
        if let user, user.hasPrefix("-") || Self.hasUnsafeCharacters(user) {
            return "“\(user)” is not a valid user name"
        }
        if let port, !(1...65535).contains(port) { return "port \(port) is out of range" }
        for option in options {
            let parts = option.split(separator: "=", maxSplits: 1)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard parts.count == 2, !key.isEmpty, !key.contains(" "), !key.hasPrefix("-") else {
                return "“\(option)” is not an option of the form Key=Value"
            }
            if Self.refusedOptions.contains(key.lowercased()) {
                return "\(key) is not allowed here, because it runs a command on this computer — put it in ~/.ssh/config instead"
            }
        }
        if identity == .keyFile, (identityFile ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "no key file is chosen"
        }
        if identity == .storedKey, privateKeyRef == nil { return "no private key is stored" }
        return nil
    }

    // MARK: Remote command

    /// What the server runs instead of a bare login shell, or nil when there is nothing to do.
    ///
    /// The server hands this line to the user's login shell, which may be fish or anything
    /// else, so the real script runs under `sh`. Commands are chained with `&&`, so one that
    /// fails or is interrupted with Ctrl-C stops the rest, as the local shim does; the INT trap
    /// keeps that Ctrl-C from ending the connection, and the login shell always follows.
    public static func remoteCommand(commands: [String], directory: String?) -> String? {
        var steps: [String] = []
        if let dir = directory?.trimmingCharacters(in: .whitespaces), !dir.isEmpty {
            let target: String
            if dir == "~" {
                target = "\"$HOME\""
            } else if dir.hasPrefix("~/") {
                target = "\"$HOME\"/" + shellQuote(String(dir.dropFirst(2)))
            } else {
                target = shellQuote(dir)
            }
            steps.append("cd -- \(target) || printf '\\033[33m[remote folder %s not found]\\033[0m\\n' \(shellQuote(dir))")
        }
        let runnable = commands.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !runnable.isEmpty {
            steps.append("trap : INT; { " + runnable.joined(separator: " && ") + "; }; trap - INT")
        }
        guard !steps.isEmpty else { return nil }
        let script = steps.joined(separator: "; ") + "; exec \"${SHELL:-/bin/sh}\" -l"
        return "exec /bin/sh -c " + shellQuote(script)
    }

    /// Single-quotes a string for a POSIX shell.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func hasUnsafeCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}
