import AppKit
import ArgumentParser
import Darwin
import Foundation

// Automation sockets can be closed by short-lived CLI clients while the host
// process is still writing a response.  Ignore SIGPIPE process-wide so a
// broken pipe never terminates the VM host.
signal(SIGPIPE, SIG_IGN)

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    case let manager as VPhoneManagerCLI:
        let app = NSApplication.shared
        let delegate = VPhoneManagerAppDelegate(cli: manager)
        app.delegate = delegate
        app.run()

    case var patch as PatchFirmwareCLI:
        try patch.run()

    case var patch as PatchComponentCLI:
        try patch.run()

    default:
        break
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
