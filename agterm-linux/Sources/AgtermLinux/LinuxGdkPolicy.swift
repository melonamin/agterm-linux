import Foundation

/// Host-free decisions about GDK's environment and the stderr lines that report them. The toolkit side
/// effects live with their GTK callers: `main()` applies the assignments, `launchDefaultHandler(forURI:)`
/// carries the restore into GIO. Full contract: `.claude/rules/main-loop.md`.
enum LinuxGdkPolicy {
    /// An environment assignment to apply with `setenv(name, value, 1)` before GTK initializes.
    struct Assignment: Equatable {
        let name: String
        let value: String
    }

    private static let disableVariable = "GDK_DISABLE"
    private static let debugVariable = "GDK_DEBUG"

    /// The GDK environment as it stood BEFORE agterm touched it, and what follows from it. Separate from
    /// the reads so it is exercisable without a GTK runtime: tests build one from literals.
    struct PreLaunchEnvironment {
        /// What `main()` applies with `setenv(name, value, 1)` before GTK initializes.
        let assignments: [Assignment]
        /// The pre-launch value of every variable those assignments overwrite (`""` for one that was
        /// unset), so children never inherit agterm's renderer constraints. Derived FROM `assignments`,
        /// so a variable added to the policy later cannot be assigned without also being restored.
        let childRestore: [String: String]

        init(gtkMajor: Int, gtkMinor: Int, environment: [String: String]) {
            assignments = LinuxGdkPolicy.assignments(
                gtkMajor: gtkMajor, gtkMinor: gtkMinor,
                existingDisable: environment[LinuxGdkPolicy.disableVariable],
                existingDebug: environment[LinuxGdkPolicy.debugVariable])
            childRestore = assignments.reduce(into: [:]) { restore, assignment in
                restore[assignment.name] = environment[assignment.name] ?? ""
            }
        }

        /// For a caller building a child environment from SCRATCH (`GhosttySurface`): the restore merges
        /// UNDER the caller, so an `AGTERM_*` key wins. A caller starting from agterm's own already-mutated
        /// process environment needs the opposite — `restoringChildEnvironment(_:)`.
        func childEnvironment(merging env: [String: String]) -> [String: String] {
            childRestore.merging(env) { _, caller in caller }
        }

        /// For an environment COPIED from agterm's own process: the copy already carries the `setenv`'d
        /// overrides, so here the restore must WIN. Everything else passes through untouched.
        func restoringChildEnvironment(_ environment: [String: String]) -> [String: String] {
            environment.merging(childRestore) { _, restore in restore }
        }
    }

    /// The stderr line for a GL-context failure. A nil, empty, or whitespace-only message yields the
    /// bare wording; anything else is appended after a colon, flattened to stay one line.
    static func glContextErrorLine(message: String?) -> String {
        let base = "agterm: GtkGLArea failed to create a GL context"
        guard let message else { return base }
        let flattened = oneLine(message)
        guard !flattened.isEmpty else { return base }
        return "\(base): \(flattened)"
    }

    /// The stderr line `main()` writes for one assignment. The wording follows the result because
    /// `setenv` can fail (ENOMEM), and announcing it either way would claim the fix was applied while
    /// every surface fell back to the GL-error overlay.
    static func assignmentLogLine(_ assignment: Assignment, applied: Bool) -> String {
        "agterm: \(applied ? "setting" : "failed to set") \(assignment.name)=\(oneLine(assignment.value))"
    }

    /// Whitespace runs collapsed to single spaces, ends trimmed. Both stderr lines carry text agterm did
    /// not author (a driver's `GError`, a user's own variable value), and an embedded `\r` would overwrite
    /// the start of the line on a terminal rather than wrapping.
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The GDK assignments for a given GTK runtime version, mirroring upstream ghostty's `setGtkEnv()`.
    /// Both tokens are load-bearing:
    /// - GLES off, because libghostty's renderer is desktop-GL-only. On GTK ≥ 4.16 GDK builds its own
    ///   paint context with the GLES API and the desktop-GL sibling cannot be realized at all.
    /// - **Vulkan off — do NOT remove this token.** Upstream cites startup time, which reads like a
    ///   nicety; it is not. Vulkan-GSK cannot import the desktop-GL GLArea texture and falls back to a
    ///   per-frame CPU readback retained forever — ~400 MB/s measured, enough to freeze the machine
    ///   (GTK #8228/#8303, MR !10130, first fixed in 4.23.3).
    ///
    /// The version gate exists because the tokens moved from `GDK_DEBUG` to `GDK_DISABLE` in 4.16 and
    /// neither spelling exists below 4.14. Ordinary user values are appended to per token, never clobbered.
    /// GDK's special `all` token inverts the list, so required flags are instead removed from its exclusions.
    static func assignments(gtkMajor: Int,
                            gtkMinor: Int,
                            existingDisable: String?,
                            existingDebug: String?) -> [Assignment] {
        guard gtkMajor >= 4 else { return [] }
        if gtkMajor > 4 || gtkMinor >= 16 {
            guard let value = enforcing(["gles-api", "vulkan"], in: existingDisable) else { return [] }
            return [Assignment(name: disableVariable, value: value)]
        }
        guard gtkMinor >= 14 else { return [] }
        guard let value = enforcing(["gl-disable-gles", "vulkan-disable"], in: existingDebug) else { return [] }
        return [Assignment(name: debugVariable, value: value)]
    }

    /// GDK tokenizes these with its own `gdk_parse_debug_var`, not glib's `g_parse_debug_string`. This set
    /// was verified against GTK's own `Unrecognized value` warnings; do not widen it on assumption, since
    /// an over-broad split risks a false "already present" that silently skips the fix.
    private static let delimiters = CharacterSet(charactersIn: ",;: \t")

    /// The new value for a variable, or nil when its parsed flags already include every required flag.
    /// GDK treats `all` as the complement of every other token: there the required flags must be absent
    /// from the textual exclusions. A rewritten inverted value is canonicalized to comma separators while
    /// preserving the spelling, order, and duplicates of every non-policy token. The ordinary append path
    /// preserves the user's value verbatim and matches whole tokens, never substrings.
    private static func enforcing(_ required: [String], in existing: String?) -> String? {
        let parsed = (existing ?? "")
            .components(separatedBy: delimiters)
            .filter { !$0.isEmpty }
        let requiredLowercase = Set(required.map { $0.lowercased() })
        if parsed.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) {
            let normalized = parsed.filter { !requiredLowercase.contains($0.lowercased()) }
            guard normalized.count != parsed.count else { return nil }
            return normalized.joined(separator: ",")
        }

        let present = Set(parsed.map { $0.lowercased() })
        let missing = required.filter { !present.contains($0.lowercased()) }
        guard !missing.isEmpty else { return nil }
        let appended = missing.joined(separator: ",")
        guard let existing, !existing.isEmpty else { return appended }
        return "\(existing),\(appended)"
    }
}
