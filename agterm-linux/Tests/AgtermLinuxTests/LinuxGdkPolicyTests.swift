import Foundation
import Testing
@testable import AgtermLinux

/// `GhosttySurface.realize()` used to discard the `GError` behind a failed GL context, so a journal
/// never learned why the terminal fell back to the generic "needs OpenGL" overlay.
/// The formatting seam decides what that stderr line says.
@Suite("Linux GDK policy — GL context error line")
struct LinuxGdkPolicyTests {
    @Test("a GError message is appended after the bare wording")
    func messageIsAppended() {
        #expect(LinuxGdkPolicy.glContextErrorLine(message: "Unable to create a GL context") ==
                "agterm: GtkGLArea failed to create a GL context: Unable to create a GL context")
    }

    @Test("a nil message keeps the bare wording")
    func nilMessageKeepsBareWording() {
        #expect(LinuxGdkPolicy.glContextErrorLine(message: nil) == "agterm: GtkGLArea failed to create a GL context")
    }

    @Test("an empty message keeps the bare wording, with no dangling colon")
    func emptyMessageKeepsBareWording() {
        #expect(LinuxGdkPolicy.glContextErrorLine(message: "") == "agterm: GtkGLArea failed to create a GL context")
    }

    @Test("a whitespace-only message keeps the bare wording")
    func whitespaceOnlyMessageKeepsBareWording() {
        #expect(LinuxGdkPolicy.glContextErrorLine(message: "  \n ") == "agterm: GtkGLArea failed to create a GL context")
    }

    /// Every newline spelling has to go, not just `\n`: a surviving carriage return does not wrap the
    /// journal line, it overwrites the start of whatever line it lands on in a terminal.
    @Test("an embedded newline of any spelling stays one stderr line",
          arguments: ["no GL implementation\nis available\n",
                      "no GL implementation\r\nis available",
                      "no GL implementation\ris available",
                      "  no GL implementation\u{2028}is available\t"])
    func newlinesAreFlattened(message: String) {
        #expect(LinuxGdkPolicy.glContextErrorLine(message: message) ==
                "agterm: GtkGLArea failed to create a GL context: no GL implementation is available")
    }
}

/// `main()`'s one stderr line per assignment is the verification evidence of record — it is what the
/// docs tell a user to look for — so it is built by the same host-free seam as the GL-error line rather
/// than inline at the call site.
@Suite("Linux GDK policy — assignment log line")
struct LinuxGdkPolicyAssignmentLogTests {
    private let assignment = LinuxGdkPolicy.Assignment(name: "GDK_DISABLE", value: "gles-api,vulkan")

    @Test("an applied assignment names what was set")
    func appliedLine() {
        #expect(LinuxGdkPolicy.assignmentLogLine(assignment, applied: true) ==
                "agterm: setting GDK_DISABLE=gles-api,vulkan")
    }

    /// `setenv` can fail, and the old unconditional line claimed success either way — leaving a journal
    /// asserting the fix was applied while every surface fell back to the GL-error overlay.
    @Test("a failed setenv is reported as a failure, not as a setting")
    func failedLine() {
        #expect(LinuxGdkPolicy.assignmentLogLine(assignment, applied: false) ==
                "agterm: failed to set GDK_DISABLE=gles-api,vulkan")
    }

    /// The value embeds the user's own pre-launch value verbatim, so it is untrusted for line-shape
    /// purposes exactly like the `GError` message is.
    @Test("a value carrying a newline still logs as one line")
    func valueIsFlattened() {
        let noisy = LinuxGdkPolicy.Assignment(name: "GDK_DEBUG", value: "frames\r\ngl-disable-gles")
        #expect(LinuxGdkPolicy.assignmentLogLine(noisy, applied: true) ==
                "agterm: setting GDK_DEBUG=frames gl-disable-gles")
    }
}

/// libghostty's renderer is desktop-GL-only, so GDK's GLES API — and the Vulkan GSK renderer that
/// cannot import a desktop-GL GLArea texture without a retained per-frame CPU readback — must both be
/// off before GTK initializes. Which variable carries the tokens depends on the GTK runtime version.
@Suite("Linux GDK policy — environment assignments")
struct LinuxGdkPolicyAssignmentTests {
    private func assignments(_ major: Int, _ minor: Int,
                             disable: String? = nil,
                             debug: String? = nil) -> [LinuxGdkPolicy.Assignment] {
        LinuxGdkPolicy.assignments(gtkMajor: major, gtkMinor: minor, existingDisable: disable, existingDebug: debug)
    }

    @Test("GTK 3 gets no assignments")
    func gtk3IsUntouched() {
        #expect(assignments(3, 24).isEmpty)
    }

    @Test("GTK 4.13 predates both spellings, so nothing is assigned")
    func belowFourteenIsUntouched() {
        #expect(assignments(4, 13).isEmpty)
    }

    @Test("GTK 4.14 and 4.15 use the GDK_DEBUG spelling", arguments: [14, 15])
    func fourteenUsesDebug(minor: Int) {
        #expect(assignments(4, minor) == [.init(name: "GDK_DEBUG", value: "gl-disable-gles,vulkan-disable")])
    }

    @Test("GTK 4.16 and later use the GDK_DISABLE spelling", arguments: [16, 22])
    func sixteenUsesDisable(minor: Int) {
        #expect(assignments(4, minor) == [.init(name: "GDK_DISABLE", value: "gles-api,vulkan")])
    }

    @Test("a major above 4 counts as at least 4.16")
    func majorAboveFourUsesDisable() {
        #expect(assignments(5, 0) == [.init(name: "GDK_DISABLE", value: "gles-api,vulkan")])
    }

    @Test("inverted all already selects both required flags on either GTK branch")
    func invertedAllNeedsNoAssignment() {
        #expect(assignments(4, 14, debug: "all").isEmpty)
        #expect(assignments(4, 22, disable: "all").isEmpty)
    }

    @Test("ordinary exclusions after inverted all do not disturb the required flags")
    func invertedAllWithOrdinaryExclusionsNeedsNoAssignment() {
        #expect(assignments(4, 14, debug: "all,gl").isEmpty)
        #expect(assignments(4, 22, disable: "all,gl").isEmpty)
    }

    @Test("required flags are removed from an inverted list instead of appended")
    func invertedRequiredFlagsAreRemoved() {
        #expect(assignments(4, 14, debug: "all,gl-disable-gles,vulkan-disable") ==
                [.init(name: "GDK_DEBUG", value: "all")])
        #expect(assignments(4, 22, disable: "all,gles-api,vulkan") ==
                [.init(name: "GDK_DISABLE", value: "all")])
    }

    @Test("one required exclusion is removed while ordinary ordering stays intact")
    func invertedPartialExclusionIsRemoved() {
        #expect(assignments(4, 14, debug: "all,gl,gl-disable-gles") ==
                [.init(name: "GDK_DEBUG", value: "all,gl")])
        #expect(assignments(4, 22, disable: "all,gl,gles-api") ==
                [.init(name: "GDK_DISABLE", value: "all,gl")])
    }

    /// Rewriting is required only for an inverted list that excludes a policy flag. At that point the
    /// normalizer uses one stable delimiter, removes every case-insensitive required duplicate, and keeps
    /// every other token's spelling, order, and duplicates. Ordinary lists remain byte-for-byte intact.
    @Test("inverted rewrites have deterministic ordering and canonical separators")
    func invertedRewriteCanonicalization() {
        #expect(assignments(4, 14,
                            debug: "frames;VULKAN-DISABLE:ALL gl-disable-gles,vulkan-disable;frames") ==
                [.init(name: "GDK_DEBUG", value: "frames,ALL,frames")])
        #expect(assignments(4, 22, disable: "frames;VULKAN:all gles-api,vulkan;frames") ==
                [.init(name: "GDK_DISABLE", value: "frames,all,frames")])
    }

    @Test("ordinary duplicates and ordering survive while the missing flag is appended")
    func ordinaryDuplicatesAndOrderingArePreserved() {
        #expect(assignments(4, 14, debug: "frames;frames;vulkan-disable") ==
                [.init(name: "GDK_DEBUG", value: "frames;frames;vulkan-disable,gl-disable-gles")])
        #expect(assignments(4, 22, disable: "frames;frames;vulkan") ==
                [.init(name: "GDK_DISABLE", value: "frames;frames;vulkan,gles-api")])
    }

    @Test("the effective emitted value always selects both policy flags")
    func effectiveValuesSelectRequiredFlags() {
        let fixtures = [
            (minor: 14, existing: "all", required: ["gl-disable-gles", "vulkan-disable"]),
            (minor: 14, existing: "all,gl,gl-disable-gles,vulkan-disable",
             required: ["gl-disable-gles", "vulkan-disable"]),
            (minor: 14, existing: "frames", required: ["gl-disable-gles", "vulkan-disable"]),
            (minor: 22, existing: "all", required: ["gles-api", "vulkan"]),
            (minor: 22, existing: "all,gl,gles-api,vulkan", required: ["gles-api", "vulkan"]),
            (minor: 22, existing: "gl", required: ["gles-api", "vulkan"]),
        ]
        for fixture in fixtures {
            let result = fixture.minor >= 16
                ? assignments(4, fixture.minor, disable: fixture.existing)
                : assignments(4, fixture.minor, debug: fixture.existing)
            let effective = result.first?.value ?? fixture.existing
            let parsed = Set(effective.components(separatedBy: LinuxGdkPolicyTestSupport.delimiters)
                .filter { !$0.isEmpty }.map { $0.lowercased() })
            for required in fixture.required {
                let selected = parsed.contains("all") ? !parsed.contains(required) : parsed.contains(required)
                #expect(selected, "policy flag \(required) was excluded by \(effective)")
            }
        }
    }

    @Test("only the missing token is appended to an existing value")
    func appendsOnlyTheMissingToken() {
        #expect(assignments(4, 22, disable: "vulkan") == [.init(name: "GDK_DISABLE", value: "vulkan,gles-api")])
        #expect(assignments(4, 22, disable: "gles-api") == [.init(name: "GDK_DISABLE", value: "gles-api,vulkan")])
    }

    @Test("a value already carrying both tokens yields no assignment")
    func bothTokensPresentYieldsNothing() {
        #expect(assignments(4, 22, disable: "gles-api,vulkan").isEmpty)
    }

    /// The delimiter set is GDK's own `gdk_parse_debug_var` set, confirmed empirically against the
    /// installed GTK 4.22.4: comma, space, tab, colon and semicolon all split a token.
    @Test("dedupe sees tokens split by every delimiter GDK honours",
          arguments: ["gles-api vulkan", "gles-api;vulkan", "gles-api:vulkan", "gles-api\tvulkan"])
    func dedupeAcrossDelimiters(value: String) {
        #expect(assignments(4, 22, disable: value).isEmpty)
    }

    /// GDK skips empty tokens, and so does the dedupe — a doc-comment claim with no test until now.
    @Test("empty tokens inside an existing value are ignored", arguments: ["gles-api,,vulkan", ",gles-api, ;vulkan,"])
    func degenerateTokensStillDedupe(value: String) {
        #expect(assignments(4, 22, disable: value).isEmpty)
    }

    /// The append is a plain comma-join onto whatever the user had, so a value that already ends in a
    /// delimiter grows a doubled one. Harmless to GDK (it skips the empty token), pinned so a later
    /// tightening of `appending` is a deliberate change rather than an accident.
    @Test("a value ending in a delimiter appends without tidying it up")
    func appendKeepsATrailingDelimiter() {
        #expect(assignments(4, 22, disable: "vulkan,") == [.init(name: "GDK_DISABLE", value: "vulkan,,gles-api")])
    }

    @Test("dedupe compares case-insensitively, as GDK does")
    func dedupeIgnoresCase() {
        #expect(assignments(4, 22, disable: "GLES-API,Vulkan").isEmpty)
    }

    @Test("a delimiter GDK does not honour is not a token boundary here either")
    func nonDelimiterIsNotSplit() {
        #expect(assignments(4, 22, disable: "gles-api+vulkan") ==
                [.init(name: "GDK_DISABLE", value: "gles-api+vulkan,gles-api,vulkan")])
    }

    @Test("dedupe matches whole tokens, never substrings")
    func substringsDoNotCountAsPresent() {
        #expect(assignments(4, 22, disable: "gles-apis") ==
                [.init(name: "GDK_DISABLE", value: "gles-apis,gles-api,vulkan")])
        #expect(assignments(4, 22, disable: "no-gles-api") ==
                [.init(name: "GDK_DISABLE", value: "no-gles-api,gles-api,vulkan")])
        #expect(assignments(4, 22, disable: "vulkans") ==
                [.init(name: "GDK_DISABLE", value: "vulkans,gles-api,vulkan")])
    }

    @Test("an empty existing value yields the bare token list, with no leading comma")
    func emptyExistingValueYieldsBareTokens() {
        #expect(assignments(4, 22, disable: "") == [.init(name: "GDK_DISABLE", value: "gles-api,vulkan")])
        #expect(assignments(4, 14, debug: "") == [.init(name: "GDK_DEBUG", value: "gl-disable-gles,vulkan-disable")])
    }

    @Test("the branch that is not taken ignores the other variable's value")
    func theUntakenBranchIgnoresTheOtherVariable() {
        #expect(assignments(4, 22, debug: "gles-api,vulkan") == [.init(name: "GDK_DISABLE", value: "gles-api,vulkan")])
        #expect(assignments(4, 14, disable: "gl-disable-gles,vulkan-disable") ==
                [.init(name: "GDK_DEBUG", value: "gl-disable-gles,vulkan-disable")])
    }

    /// The 4.14 branch is the only one CI ever executes (`build-linux` runs GTK 4.14), and appending
    /// rather than clobbering is what keeps the repo's own `GDK_DEBUG=frames` perf tooling working.
    @Test("a user's GDK_DEBUG is appended to, never clobbered")
    func debugValueIsAppendedNotClobbered() {
        #expect(assignments(4, 14, debug: "frames") ==
                [.init(name: "GDK_DEBUG", value: "frames,gl-disable-gles,vulkan-disable")])
    }

    @Test("partial presence in GDK_DEBUG appends only the missing token")
    func debugPartialPresence() {
        #expect(assignments(4, 14, debug: "vulkan-disable") ==
                [.init(name: "GDK_DEBUG", value: "vulkan-disable,gl-disable-gles")])
    }

    @Test("a GDK_DEBUG already carrying both tokens yields no assignment")
    func debugBothTokensPresentYieldsNothing() {
        #expect(assignments(4, 14, debug: "frames,gl-disable-gles,vulkan-disable").isEmpty)
    }
}

/// What `main()` captures once at startup and what every child-spawning site merges. Upstream ghostty
/// scrubs `GDK_DEBUG`/`GDK_DISABLE` out of a spawned shell's environment ("Don't leak these GTK
/// environment variables to child processes"); agterm restores the pre-launch values instead, which is
/// the same observable behaviour without patching the embedded apprt.
/// The process-wide `gdkEnvironment` global reads the live GTK version and `ProcessInfo`; these build
/// the same value from literals, so the capture and both merge precedences are pinned without one.
@Suite("Linux GDK policy — pre-launch environment capture")
struct LinuxGdkPreLaunchEnvironmentTests {
    @Test("a GLES-first GTK with nothing set assigns the pair and restores the unset values")
    func capturesFromAnEmptyEnvironment() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 22, environment: [:])
        #expect(captured.assignments == [.init(name: "GDK_DISABLE", value: "gles-api,vulkan")])
        #expect(captured.childRestore == ["GDK_DISABLE": ""])
    }

    @Test("a user's own value is appended to and handed back to children verbatim")
    func capturesAUserValue() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 14,
                                                           environment: ["GDK_DEBUG": "frames"])
        #expect(captured.assignments == [.init(name: "GDK_DEBUG", value: "frames,gl-disable-gles,vulkan-disable")])
        #expect(captured.childRestore == ["GDK_DEBUG": "frames"])
    }

    @Test("an inverted user value is normalized for agterm and restored verbatim to children")
    func capturesAnInvertedUserValue() {
        let debug = LinuxGdkPolicy.PreLaunchEnvironment(
            gtkMajor: 4, gtkMinor: 14,
            environment: ["GDK_DEBUG": "all,gl-disable-gles,vulkan-disable"])
        #expect(debug.assignments == [.init(name: "GDK_DEBUG", value: "all")])
        #expect(debug.childRestore == ["GDK_DEBUG": "all,gl-disable-gles,vulkan-disable"])

        let disable = LinuxGdkPolicy.PreLaunchEnvironment(
            gtkMajor: 4, gtkMinor: 22,
            environment: ["GDK_DISABLE": "all,gles-api,vulkan"])
        #expect(disable.assignments == [.init(name: "GDK_DISABLE", value: "all")])
        #expect(disable.childRestore == ["GDK_DISABLE": "all,gles-api,vulkan"])
    }

    @Test("a GTK too old for either spelling assigns nothing and leaves children alone")
    func capturesNothingBelowFourteen() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 13,
                                                           environment: ["GDK_DEBUG": "frames"])
        #expect(captured.assignments.isEmpty)
        #expect(captured.childEnvironment(merging: ["AGTERM_PANE_ID": "p"]) == ["AGTERM_PANE_ID": "p"])
    }

    @Test("the restore pairs join the caller's own vars in a spawned shell's environment")
    func mergesRestoreIntoTheCallersEnvironment() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 22,
                                                           environment: ["GDK_DISABLE": "vulkan"])
        #expect(captured.childEnvironment(merging: ["AGTERM_SESSION_ID": "s"]) ==
                ["AGTERM_SESSION_ID": "s", "GDK_DISABLE": "vulkan"])
    }

    @Test("the caller's own value wins a key collision")
    func callerWinsACollision() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 22, environment: [:])
        #expect(captured.childEnvironment(merging: ["GDK_DISABLE": "caller"]) == ["GDK_DISABLE": "caller"])
    }

    /// The opposite precedence, for a child whose environment is COPIED from agterm's own already-mutated
    /// process (a custom command's `/bin/sh -c`, `notify-send`): there the restore has to win, or the
    /// copy hands the override straight through.
    @Test("restoring into a copy of the mutated process environment overwrites the override")
    func restoreWinsOverAPollutedCopy() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 22, environment: [:])
        let polluted = ["GDK_DISABLE": "gles-api,vulkan", "PATH": "/usr/bin"]
        #expect(captured.restoringChildEnvironment(polluted) == ["GDK_DISABLE": "", "PATH": "/usr/bin"])
    }

    @Test("restoring leaves an environment alone when the policy assigned nothing")
    func restoreIsANoOpWithoutAssignments() {
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: 4, gtkMinor: 13, environment: [:])
        #expect(captured.restoringChildEnvironment(["PATH": "/usr/bin"]) == ["PATH": "/usr/bin"])
    }

    /// The restore is derived from the assignments rather than from a hand-written table, so the two
    /// cannot drift: adding a third variable to `assignments` gives it a restore pair for free. This
    /// pins that invariant across every branch of the version gate.
    @Test("every assigned variable gets exactly one restore pair, and no unassigned one does",
          arguments: [(4, 13), (4, 14), (4, 15), (4, 16), (4, 22), (5, 0)])
    func restoreKeysTrackTheAssignments(version: (major: Int, minor: Int)) {
        let environment = ["GDK_DISABLE": "vulkan", "GDK_DEBUG": "frames"]
        let captured = LinuxGdkPolicy.PreLaunchEnvironment(gtkMajor: version.major, gtkMinor: version.minor,
                                                           environment: environment)
        #expect(Set(captured.childRestore.keys) == Set(captured.assignments.map(\.name)))
        for assignment in captured.assignments {
            #expect(captured.childRestore[assignment.name] == environment[assignment.name])
        }
    }
}

private enum LinuxGdkPolicyTestSupport {
    static let delimiters = CharacterSet(charactersIn: ",;: \t")
}
