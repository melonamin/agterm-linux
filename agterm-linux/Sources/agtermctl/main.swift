import ArgumentParser
import Foundation
import Glibc
import agtermctlKit

struct AgtermctlLinux: ParsableCommand {
    static let configuration = AgtermctlCommandCatalog.rootConfiguration(
        abstract: "Drive agterm and manage local integrations.",
        appending: [Integration.self])
}

// The desktop keeps its established XDG data directory. Upstream's headless CLI uses XDG state;
// select the desktop rendezvous only in this host wrapper, preserving explicit --socket/AGTERM_STATE_DIR.
if ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]?.isEmpty != false,
   let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    setenv("AGTERM_STATE_DIR", data.appendingPathComponent("agterm").path, 1)
}
AgtermctlLinux.main()
