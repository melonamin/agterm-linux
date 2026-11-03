import ArgumentParser
import agtermctlKit

struct AgtermctlLinux: ParsableCommand {
    static let configuration = AgtermctlCommandCatalog.rootConfiguration(
        abstract: "Drive agterm and manage local integrations.",
        appending: [Integration.self])
}

AgtermctlLinux.main()
