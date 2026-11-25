import ArgumentParser
import Testing
import agtermctlKit

struct PublicCatalogTests {
    @Test func libraryConsumerCanAppendAHostCommand() throws {
        #expect(try PublicCatalogRoot.parseAsRoot(["host-extension"]) is PublicHostExtension)
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["host-extension"]) }
        #expect(AgtermctlCommandCatalog.subcommands.count + 1
            == PublicCatalogRoot.configuration.subcommands.count)
    }
}

private struct PublicCatalogRoot: ParsableCommand {
    static let configuration = AgtermctlCommandCatalog.rootConfiguration(
        appending: [PublicHostExtension.self])
}

private struct PublicHostExtension: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "host-extension")
}
