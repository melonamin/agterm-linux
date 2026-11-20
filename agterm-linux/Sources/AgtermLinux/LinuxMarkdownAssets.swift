import Foundation
import LinuxIntegrations

/// Read the same upstream renderer sources in a checkout and in share/agterm after packaging.
/// Missing resources refuse the page instead of presenting a successful but empty document.
struct MarkdownAssets: Sendable {
    static let shared = MarkdownAssets(root: IntegrationEnvironment.process().resource(named: "markdown"))
    let script: String
    let style: String
    let textScript: String
    let textStyle: String

    init(root: URL?) {
        func read(_ name: String) -> String {
            guard let root else { return "" }
            return (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let names = ["markdown-it-14.1.0.min.js", "highlight-11.11.1.min.js", "render.js"]
        let scripts = names.map(read)
        script = scripts.allSatisfy { !$0.isEmpty } ? scripts.joined(separator: ";\n") : ""
        style = read("page.css")
        let text = [read("highlight-11.11.1.min.js"), read("text.js")]
        textScript = text.allSatisfy { !$0.isEmpty } ? text.joined(separator: ";\n") : ""
        textStyle = style + "\n" + read("text.css")
    }

    var available: Bool { !script.isEmpty && !style.isEmpty }
}
