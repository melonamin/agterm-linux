import CGtk
import CWebKit
import Foundation
import agtermCore

/// The local text renderer owns its bounded reads and one GLib timer while a visible log follows.
/// No Swift main-actor task is scheduled: WebKit completions and worker results return through GLib.
@MainActor
final class LinuxTextPage {
    weak var page: LinuxHtmlOverlayPage?
    private var cancel: (@MainActor () -> Void)?
    private var reading = false
    private var generation = 0
    private var ready = false
    private var staticText: String?
    private var appliedWrap: Bool?
    private var appliedExpand = false
    private var searchSelection: (Int, Int)?
    private var stopped = false
    private var stamp: BoundedFile.FileStamp?
    private var snapshot: LogTail.Snapshot?
    private var typedRevisions = Set<Int>()
    private var searchRevision = -1
    private var appliedFollowing: Bool?
    private var pauseEpoch = 0

    init(page: LinuxHtmlOverlayPage) { self.page = page }

    func stop() {
        stopped = true
        generation += 1
        cancel?()
        cancel = nil
    }

    func load(fresh: Bool = true) {
        guard let page, let location = LinuxTextReads.location(page) else { return }
        let place = ready ? evaluate("agtermTextNavigation()") : nil
        searchSelection = place?["focused"] as? Bool == true
            ? (place?["start"] as? Int ?? 0, place?["end"] as? Int ?? 0) : nil
        let document = LinuxTextDocument(path: location.path, line: location.line, anchor: place?["top"] as? Double,
            search: TextPage.SearchState(query: page.overlay.textSearch?.query ?? "", revision: page.overlay.searchRevision,
                                         current: page.overlay.textSearch?.current ?? 0),
            wrap: page.overlay.textWrap, expand: page.overlay.textExpand,
            top: page.overlay.textExpand != appliedExpand ? place?["line"] as? Int : nil)
        appliedExpand = document.expand
        appliedWrap = document.wrap
        generation += 1
        let mine = generation
        ready = false
        reading = false
        cancel?(); cancel = nil
        appliedFollowing = nil
        searchRevision = -1
        if page.overlay.textLog != nil {
            LinuxTextReads.log(page, stamp: nil) { [weak self] result in
                guard let self, !stopped, mine == generation, let page = self.page, !page.closed else { return }
                let read = try? result.get()
                stamp = read?.stamp
                if let shown = read?.snapshot { snapshot = shown }
                let report = read?.snapshot.map { TextLogReport(lines: $0.lines, clipped: $0.clipped) }
                    ?? TextLogReport(waiting: read == nil, unreadable: read != nil)
                page.store?.setTextLogReport(page.id, report)
                let log = TextLogState(following: page.overlay.logState?.following ?? false, report: report)
                build(document, text: snapshot?.text ?? "", log: log, generation: mine)
            }
        } else if !fresh, let staticText {
            build(document, text: staticText, log: nil, generation: mine)
        } else {
            LinuxTextReads.text(page) { [weak self] result in
                guard let self, !stopped, mine == generation, let page = self.page, !page.closed else { return }
                switch result {
                case .failure(let failure): page.fail(failure.description)
                case .success(let text):
                    staticText = text
                    build(document, text: text, log: nil, generation: mine)
                }
            }
        }
    }

    private func build(_ document: LinuxTextDocument, text: String, log: TextLogState?, generation mine: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let html = TextPage.html(text: text, language: TextPage.language(forFile: document.path), line: document.line,
                style: MarkdownAssets.shared.textStyle, log: log, anchor: document.anchor, search: document.search,
                wrap: document.wrap, expand: document.expand, top: document.top)
            runOnMain { MainActor.assumeIsolated {
                guard let self, !self.stopped, mine == self.generation, let page = self.page, !page.closed else { return }
                html.withCString { webkit_web_view_load_html(cast(page.webView), $0, nil) }
            } }
        }
    }

    func apply() {
        guard let page, !stopped else { return }
        if ready, appliedExpand != page.overlay.textExpand { load(fresh: false); return }
        if ready, appliedWrap != page.overlay.textWrap {
            appliedWrap = page.overlay.textWrap
            call("agtermTextSetWrap", [page.overlay.textWrap])
        }
        if ready, searchRevision != page.overlay.searchRevision {
            searchRevision = page.overlay.searchRevision
            call("agtermTextSearchSet", [page.overlay.textSearch?.query ?? "", searchRevision,
                                        typedRevisions.contains(searchRevision)])
            typedRevisions = typedRevisions.filter { $0 > searchRevision }
        }
        if ready, page.overlay.textLog != nil, appliedFollowing != page.overlay.logState?.following {
            appliedFollowing = page.overlay.logState?.following
            pauseEpoch += 1
            call("agtermTextSetFollowing", [appliedFollowing ?? false])
        }
        let following = page.onScreen && page.overlay.logState?.following == true
        if !following { cancel?(); cancel = nil }
        if following, ready, cancel == nil, !reading {
            cancel = MainTimer.schedule(after: 1) { [weak self] in
                self?.cancel = nil
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let page, !stopped, !reading, page.onScreen, page.overlay.logState?.following == true,
              let location = LinuxTextReads.location(page), page.overlay.textLog != nil else { return }
        let path = location.path
        reading = true
        let mine = generation, previous = stamp, epoch = pauseEpoch
        LinuxTextReads.log(page, stamp: previous) { [weak self] result in
                guard let self, !self.stopped, mine == self.generation, let page = self.page, !page.closed else { return }
                self.reading = false
                guard epoch == self.pauseEpoch, page.onScreen, page.overlay.logState?.following == true else { return self.apply() }
                switch result {
                case .success(nil): break
                case .success(let read?):
                    let old = self.snapshot, oldStamp = self.stamp
                    self.stamp = read.stamp
                    if let shown = read.snapshot {
                        self.snapshot = shown
                        let report = TextLogReport(lines: shown.lines, clipped: shown.clipped)
                        page.store?.setTextLogReport(page.id, report)
                        let shift = LinuxLogShift.shift(from: old, stamp: oldStamp, to: shown, stamp: read.stamp)
                        self.call("agtermTextUpdate", [shown.text, shown.clipped, false, false,
                                                      TextPage.language(forFile: path) as Any? ?? NSNull(),
                                                      ["dropped": shift.dropped, "cut": shift.cut, "replaced": shift.replaced]])
                    } else {
                        page.store?.setTextLogReport(page.id, TextLogReport(unreadable: true))
                        self.call("agtermTextUpdate", [self.snapshot?.text ?? "", false, false, true, NSNull(), [:]])
                    }
                case .failure:
                    self.stamp = nil
                    page.store?.setTextLogReport(page.id, TextLogReport(waiting: true))
                    self.call("agtermTextUpdate", [self.snapshot?.text ?? "", false, true, false, NSNull(), [:]])
                }
                self.apply()
        }
    }

    func receive(_ value: OpaquePointer?) {
        guard let page, !stopped, !page.closed, let raw = jsc_value_to_json(value, 0) else { return }
        let data = Data(String(cString: raw).utf8)
        g_free(raw)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if body["ready"] as? Bool == true {
            ready = true
            apply()
            if let (start, end) = searchSelection { call("agtermTextRestoreSearch", [start, end]) }
            searchSelection = nil
            return
        }
        if let wrap = body["wrap"] as? Bool { page.store?.setTextWrap(page.id, wrapped: wrap) }
        if let expand = body["expand"] as? Bool { page.store?.setTextExpand(page.id, expanded: expand) }
        if let report = body["files"] as? [String: Any] { takeFiles(report) }
        if let query = body["search"] as? String, let revision = page.store?.setTextSearch(page.id, query: query) {
            typedRevisions.insert(revision)
        }
        if let report = body["report"] as? [String: Any], let revision = report["revision"] as? Int,
           let query = report["query"] as? String, let matches = report["matches"] as? Int, let current = report["current"] as? Int {
            page.store?.setTextSearchReport(page.id, revision: revision, query: query, matches: matches, current: current)
        }
        if let report = body["changes"] as? [String: Any], let count = report["count"] as? Int, let current = report["current"] as? Int {
            page.store?.setTextChangesReport(page.id, changes: TextChanges(count: count, current: current))
        }
        if let following = body["following"] as? Bool { page.store?.setTextLogFollowing(page.id, following: following) }
        page.controller?.reconcile(focusActive: false)
    }

    func focusSearch() { call("agtermTextFocusSearch", []) }

    func step(forward: Bool, changes: Bool = false) -> [String: Any]? {
        guard ready, let page else { return nil }
        let args: [Any] = changes ? [forward] : [forward, page.overlay.textSearch?.query ?? "", page.overlay.searchRevision]
        let result = evaluate(expression(changes ? "agtermTextChangeStep" : "agtermTextSearchStep", args))
        if let result, let current = result["current"] as? Int {
            if changes, let count = result["count"] as? Int {
                page.store?.setTextChangesReport(page.id, changes: TextChanges(count: count, current: current))
            } else if let count = result["matches"] as? Int {
                page.store?.setTextSearchReport(page.id, revision: page.overlay.searchRevision,
                    query: page.overlay.textSearch?.query ?? "", matches: count, current: current)
            }
        }
        return result
    }

    func goFile(_ target: String) -> [String: Any]? {
        guard ready else { return nil }
        let result = evaluate(expression("agtermTextFileGo", [target]))
        if let result { takeFiles(result) }
        return result
    }

    private func takeFiles(_ report: [String: Any]) {
        guard let count = report["count"] as? Int, let current = report["current"] as? Int, let path = report["path"] as? String else { return }
        guard let page else { return }
        page.store?.setTextFilesReport(page.id, files: TextFiles(count: count, current: current, path: path))
    }

    private func expression(_ name: String, _ args: [Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("[]".utf8)
        return "\(name)(...\(String(decoding: json, as: UTF8.self)))"
    }

    private func call(_ name: String, _ args: [Any]) {
        guard let page, !page.closed else { return }
        expression(name, args).withCString { source in
            webkit_web_view_evaluate_javascript(cast(page.webView), source, -1, "agterm-text", nil, nil, nil, nil)
        }
    }

    private func evaluate(_ source: String) -> [String: Any]? {
        guard let page, !page.closed else { return nil }
        let result = LinuxTextEvaluation()
        let cancellable = g_cancellable_new()
        defer { g_object_unref(RAW(OpaquePointer(cancellable))) }
        source.withCString {
            webkit_web_view_evaluate_javascript(cast(page.webView), $0, -1, "agterm-text", nil, cancellable,
                                               onTextEvaluation, Unmanaged.passRetained(result).toOpaque())
        }
        let deadline = Date().addingTimeInterval(2)
        while !result.done, !page.closed, Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            if !result.done { g_usleep(1_000) }
        }
        if !result.done { g_cancellable_cancel(cancellable) }
        return page.closed ? nil : result.value
    }
}

private struct LinuxTextDocument: Sendable {
    let path: String
    let line: Int?
    let anchor: Double?
    let search: TextPage.SearchState
    let wrap: Bool
    let expand: Bool
    let top: Int?
}

@MainActor
private final class LinuxTextEvaluation {
    var done = false
    var value: [String: Any]?
}

private let onTextEvaluation: @MainActor @convention(c)
    (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { object, response, data in
        guard let data else { return }
        let result = Unmanaged<LinuxTextEvaluation>.fromOpaque(data).takeRetainedValue()
        defer { result.done = true }
        guard let value = webkit_web_view_evaluate_javascript_finish(cast(OpaquePointer(object)), response, nil) else { return }
        defer { g_object_unref(RAW(value)) }
        guard let json = jsc_value_to_json(value, 0) else { return }
        defer { g_free(json) }
        result.value = (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8))) as? [String: Any]
    }
