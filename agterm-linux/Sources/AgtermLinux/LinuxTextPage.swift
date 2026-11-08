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

    func load() {
        guard let page, case .text(let path, let line) = page.overlay.source else { return }
        let anchor = ready ? evaluate("({top:document.scrollingElement.scrollTop})")?["top"] as? Double : nil
        generation += 1
        ready = false
        reading = false
        cancel?(); cancel = nil
        appliedFollowing = nil
        searchRevision = -1
        let mine = generation, log = page.overlay.textLog
        let following = page.overlay.logState?.following ?? false
        let cached = snapshot
        let search = TextPage.SearchState(query: page.overlay.textSearch?.query ?? "",
                                         revision: page.overlay.searchRevision, current: page.overlay.textSearch?.current ?? 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: Result<(String, TextProbe.LogRead?), TextProbe.Failure>
            if let log {
                result = TextProbe.loadLog(path: path, tail: log.tail).map { read in
                    let shown = read?.snapshot ?? LogTail.Snapshot(text: "", lines: 0, clipped: false)
                    let state = TextLogState(following: following, report: TextLogReport(lines: shown.lines, clipped: shown.clipped))
                    return (TextPage.html(text: shown.text, language: TextPage.language(forFile: path), line: nil,
                                          style: MarkdownAssets.shared.textStyle, log: state, anchor: anchor, search: search), read)
                }
                if case .failure = result {
                    let report = TextLogReport(waiting: true)
                    let html = TextPage.html(text: cached?.text ?? "", language: TextPage.language(forFile: path), line: nil,
                                             style: MarkdownAssets.shared.textStyle,
                                             log: TextLogState(following: following, report: report), anchor: anchor, search: search)
                    result = .success((html, nil))
                }
            } else {
                result = TextProbe.load(path: path).map {
                    (TextPage.html(text: $0, language: TextPage.language(forFile: path), line: line,
                                   style: MarkdownAssets.shared.textStyle, anchor: anchor, search: search), nil)
                }
            }
            let loaded = result
            runOnMain { MainActor.assumeIsolated {
                guard let self, !self.stopped, mine == self.generation, let page = self.page, !page.closed else { return }
                switch loaded {
                case .failure(let failure): page.fail(failure.description)
                case .success(let (html, read)):
                    self.stamp = read?.stamp
                    if log != nil {
                        if let shown = read?.snapshot { self.snapshot = shown }
                        let report = read?.snapshot.map { TextLogReport(lines: $0.lines, clipped: $0.clipped) }
                            ?? TextLogReport(waiting: read == nil, unreadable: read != nil)
                        page.store?.setTextLogReport(page.id, report)
                    }
                    html.withCString { webkit_web_view_load_html(cast(page.webView), $0, nil) }
                }
            } }
        }
    }

    func apply() {
        guard let page, !stopped else { return }
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
              case .text(let path, _) = page.overlay.source, let log = page.overlay.textLog else { return }
        reading = true
        let mine = generation, previous = stamp, epoch = pauseEpoch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = TextProbe.loadLog(path: path, tail: log.tail, unchangedFrom: previous)
            runOnMain { MainActor.assumeIsolated {
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
            } }
        }
    }

    func receive(_ value: OpaquePointer?) {
        guard let page, !stopped, !page.closed, let raw = jsc_value_to_json(value, 0) else { return }
        let data = Data(String(cString: raw).utf8)
        g_free(raw)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if body["ready"] as? Bool == true { ready = true; apply(); return }
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
        return evaluate(expression(changes ? "agtermTextChangeStep" : "agtermTextSearchStep", args))
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
