#if canImport(Glibc)
import Foundation

/// Swift's Foundation markdown intents are unavailable on Linux. Keep the same HUD row model and render
/// the supported markdown subset here, before the shared wrapping and SGR encoding in HudMarkdown.
extension HudMarkdown {
    static func lines(_ source: String) -> [Line] {
        let input = source.precomposedStringWithCanonicalMapping
            .components(separatedBy: "\n")
        var parser = LinuxParser(input: input)
        return parser.parse()
    }
}

private struct LinuxParser {
    typealias Line = HudMarkdown.Line
    typealias Run = HudMarkdown.Run
    typealias Style = HudMarkdown.Style

    let input: [String]
    var index = 0
    var blocks: [[Line]] = []

    mutating func parse(tight: Bool = false) -> [Line] {
        while index < input.count {
            if input[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            if isFence(input[index]) {
                blocks.append(codeBlock())
            } else if isQuote(input[index]) {
                blocks.append(quoteBlock())
            } else if listMarker(input[index]) != nil {
                blocks.append(listBlock())
            } else if isTableStart(index) {
                blocks.append(tableBlock())
            } else if isRule(input[index]) {
                index += 1
                blocks.append([Line(lead: "", hang: "", runs: [], kind: .rule)])
            } else if let heading = heading(input[index]) {
                index += 1
                blocks.append([Line(lead: "", hang: "", runs: inline(heading, base: .bold))])
            } else if isRawHTML(input[index]) {
                blocks.append(htmlBlock())
            } else if isLinkDefinition(input[index]) {
                index += 1
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks.enumerated().flatMap { offset, block in
            offset > 0 && !tight ? [Line.blank] + block : block
        }
    }

    private mutating func codeBlock() -> [Line] {
        index += 1
        var rows: [Line] = []
        while index < input.count, !isFence(input[index]) {
            let text = HudMarkdown.sanitized(HudMarkdown.expandTabs(input[index]))
            rows.append(Line(lead: HudMarkdown.codeIndent, hang: HudMarkdown.codeIndent,
                             runs: [Run(text: text, style: [])], kind: .code))
            index += 1
        }
        if index < input.count { index += 1 }
        return rows
    }

    private mutating func quoteBlock() -> [Line] {
        var body: [String] = []
        while index < input.count, isQuote(input[index]) {
            var line = String(input[index].dropFirst())
            if line.first == " " { line.removeFirst() }
            body.append(line)
            index += 1
        }
        var child = LinuxParser(input: body)
        return child.parse().map { line in
            Line(lead: HudMarkdown.quoteBar + line.lead, hang: HudMarkdown.quoteBar + line.hang,
                 runs: line.runs, kind: line.kind)
        }
    }

    private mutating func listBlock() -> [Line] {
        guard let first = listMarker(input[index]) else { return [] }
        let base = first.indent
        var rendered: [Line] = []
        while index < input.count, let item = listMarker(input[index]), item.indent == base {
            index += 1
            var body = [item.content]
            while index < input.count {
                let next = input[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty {
                    let following = index + 1 < input.count ? input[index + 1] : ""
                    if let marker = listMarker(following), marker.indent == base {
                        index += 1
                        break
                    }
                    if indentation(following) > base {
                        body.append("")
                        index += 1
                        continue
                    }
                    break
                }
                guard indentation(next) > base else { break }
                body.append(String(next.dropFirst(min(indentation(next), base + 2))))
                index += 1
            }
            var child = LinuxParser(input: body)
            let rows = child.parse(tight: true)
            let pad = String(repeating: " ", count: base + item.marker.count)
            for (offset, row) in rows.enumerated() {
                let lead = offset == 0 ? String(repeating: " ", count: base) + item.marker : pad
                rendered.append(Line(lead: lead + row.lead, hang: pad + row.hang,
                                     runs: row.runs, kind: row.kind))
            }
        }
        return rendered
    }

    private mutating func tableBlock() -> [Line] {
        let header = tableCells(input[index])
        index += 2 // header and separator
        var body: [[[Run]]] = []
        while index < input.count, input[index].contains("|"),
              !input[index].trimmingCharacters(in: .whitespaces).isEmpty {
            body.append(tableCells(input[index]).map { inline($0) })
            index += 1
        }
        let columns = header.count
        let headingRuns = header.map { inline($0, base: .bold) }
        let hasHeader = headingRuns.contains { !$0.isEmpty }
        let rows = (hasHeader ? [headingRuns] : []) + body
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for column in 0..<columns {
                widths[column] = max(widths[column], HudMarkdown.width(column < row.count ? row[column] : []))
            }
        }
        func border(_ left: String, _ join: String, _ right: String) -> Line {
            let spans = widths.map { String(repeating: "─", count: $0 + 2) }
            return Line(lead: "", hang: "", runs: [Run(text: left + spans.joined(separator: join) + right, style: [])],
                        kind: .table)
        }
        func framed(_ cells: [[Run]]) -> Line {
            var runs = [Run(text: "│ ", style: [])]
            for column in 0..<columns {
                if column > 0 { runs.append(Run(text: " ", style: [])) }
                let cell = column < cells.count ? cells[column] : []
                runs += cell
                let padding = widths[column] - HudMarkdown.width(cell) + 1
                runs.append(Run(text: String(repeating: " ", count: padding) + "│", style: []))
            }
            return Line(lead: "", hang: "", runs: runs, kind: .table)
        }
        var output = [border("┌", "┬", "┐")]
        for (offset, row) in rows.enumerated() {
            output.append(framed(row))
            if offset == 0 && hasHeader { output.append(border("├", "┼", "┤")) }
        }
        output.append(border("└", "┴", "┘"))
        return output
    }

    private mutating func htmlBlock() -> [Line] {
        let start = input[index]
        var rows: [Line] = []
        let closing = start.hasPrefix("<div") ? "</div>" : nil
        repeat {
            rows.append(Line(lead: "", hang: "", runs: [Run(text: HudMarkdown.sanitized(input[index]), style: [])]))
            index += 1
        } while index < input.count && closing != nil && !input[index - 1].contains(closing!)
        return rows
    }

    private mutating func paragraph() -> [Line] {
        var source: [String] = []
        while index < input.count {
            let line = input[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if !source.isEmpty && (isFence(line) || isQuote(line) || listMarker(line) != nil
                || isTableStart(index) || isRule(line) || heading(line) != nil || isRawHTML(line)) { break }
            source.append(line)
            index += 1
        }
        var rows: [Line] = []
        var current = ""
        for (offset, line) in source.enumerated() {
            let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
            let body = hard && line.hasSuffix("\\") ? String(line.dropLast()) : line
            current += body.trimmingCharacters(in: .whitespaces)
            if hard || offset == source.count - 1 {
                rows.append(Line(lead: "", hang: "", runs: inline(current)))
                current = ""
            } else {
                current += " "
            }
        }
        return rows
    }

    private func inline(_ source: String, base: Style = []) -> [Run] {
        let chars = Array(source)
        var runs: [Run] = []
        var style = base
        var index = 0
        var mayMerge = true
        func append(_ value: String, style: Style, separate: Bool = false) {
            guard !value.isEmpty else { return }
            let value = HudMarkdown.sanitized(value)
            if !separate && mayMerge && runs.last?.style == style {
                runs[runs.count - 1].text += value
            } else {
                runs.append(Run(text: value, style: style))
            }
            mayMerge = !separate
        }
        while index < chars.count {
            let rest = String(chars[index...])
            if rest.hasPrefix("**") {
                if !base.contains(.bold) {
                    if style.contains(.bold) { style.remove(.bold) } else { style.insert(.bold) }
                }
                mayMerge = false
                index += 2
            } else if rest.hasPrefix("~~") {
                if style.contains(.strikethrough) {
                    style.remove(.strikethrough)
                } else {
                    style.insert(.strikethrough)
                }
                index += 2
            } else if chars[index] == "*" {
                if style.contains(.italic) { style.remove(.italic) } else { style.insert(.italic) }
                index += 1
            } else if chars[index] == "`", let end = chars[(index + 1)...].firstIndex(of: "`") {
                append(String(chars[(index + 1)..<end]), style: base, separate: true)
                index = end + 1
            } else if let link = linkText(chars, at: index) {
                append(link.text, style: style, separate: true)
                index = link.next
            } else if let entity = numericEntity(chars, at: index) {
                append(entity.text, style: style)
                index = entity.next
            } else {
                append(String(chars[index]), style: style)
                index += 1
            }
        }
        return runs
    }

    private func linkText(_ chars: [Character], at start: Int) -> (text: String, next: Int)? {
        let image = chars[start] == "!"
        let open = image ? start + 1 : start
        guard open < chars.count, chars[open] == "[",
              let close = chars[(open + 1)...].firstIndex(of: "]"), close + 1 < chars.count,
              chars[close + 1] == "(", let end = chars[(close + 2)...].firstIndex(of: ")") else { return nil }
        return (String(chars[(open + 1)..<close]), end + 1)
    }

    private func numericEntity(_ chars: [Character], at start: Int) -> (text: String, next: Int)? {
        guard chars[start] == "&", start + 2 < chars.count, chars[start + 1] == "#",
              let end = chars[(start + 2)...].firstIndex(of: ";") else { return nil }
        let body = String(chars[(start + 2)..<end])
        let hex = body.lowercased().hasPrefix("x")
        let digits = hex ? String(body.dropFirst()) : body
        guard let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) else { return nil }
        return (String(scalar), end + 1)
    }

    private func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|") { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func isTableStart(_ at: Int) -> Bool {
        guard at + 1 < input.count, input[at].contains("|") else { return false }
        let cells = tableCells(input[at + 1])
        return !cells.isEmpty && cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: CharacterSet(charactersIn: " :-"))
            return trimmed.isEmpty && cell.contains("-")
        }
    }

    private func listMarker(_ line: String) -> (indent: Int, marker: String, content: String)? {
        let indent = indentation(line)
        let body = String(line.dropFirst(indent))
        if body.hasPrefix("- ") { return (indent, HudMarkdown.bullet, String(body.dropFirst(2))) }
        let digits = body.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (indent, "\(digits). ", String(body.dropFirst(digits.count + 2)))
    }

    private func indentation(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }
    private func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
    private func isQuote(_ line: String) -> Bool { line.hasPrefix(">") }
    private func isRawHTML(_ line: String) -> Bool {
        line.hasPrefix("<!--") || line.hasPrefix("<div") || line.hasPrefix("</div")
    }
    private func isLinkDefinition(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        return line[line.index(after: close)...].hasPrefix(": ")
    }
    private func heading(_ line: String) -> String? {
        let marks = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).first == " " else { return nil }
        return String(line.dropFirst(marks.count + 1))
    }
    private func isRule(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count >= 3 && text.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }
}
#endif
