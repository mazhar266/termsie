import AppKit
import TermsieCore

// Secrets live in the login Keychain. Scripted test runs may use a file instead, and a secret
// still used by an open tab is never deleted.
SecretStore.backend = KeychainSecretBackend()
SecretStore.testModeEnabled = DebugDriver.isActive || SSHAskpass.isTestRun
SecretStore.openTabs = { AppDelegate.shared.controllers.map { $0.snapshot() } }

// Run by `ssh` as its SSH_ASKPASS helper: answer the prompt and exit, never becoming an app.
if SSHAskpass.isRequested { exit(SSHAskpass.run()) }

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
