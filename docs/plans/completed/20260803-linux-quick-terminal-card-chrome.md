# Linux Quick Terminal Card Chrome

## Overview
- The Linux quick terminal (Ctrl+`) renders with no visible boundary against the session behind
  it. Corrected diagnosis (plan-review verified against libadwaita 1.9.2's stylesheet): the
  GtkFrame **already carries** a 1px border and a 12px radius — the `frame` node ships
  `border: 1px solid color-mix(in srgb, currentColor var(--border-opacity), transparent)` and
  `border-radius: 12px`, and `.card` adds a faint box-shadow. What's missing is **contrast** (a
  themed `currentColor`-derived border is invisible dark-on-dark) and the **clip** (the square
  opaque `GtkGLArea` child paints over the corner arcs, erasing the rounded silhouette).
- macOS draws the chrome explicitly (`WindowContentView.swift:780-790`): solid backing, 12pt
  rounded **clip** of the terminal content, a 1px white stroke at 18% opacity, and a 24pt shadow.
- The fix is therefore: swap the border **color** to light polarity at the **unchanged 1px
  width**, state the radius explicitly, add a strong soft box-shadow, and clip the GL child with
  `GTK_OVERFLOW_HIDDEN`. Border, radius, and clip match macOS exactly (user-confirmed parity
  goal); the shadow deliberately diverges (offset + stronger than SwiftUI's default; see
  Solution Overview).
- The floating session overlay (`session.overlay --size-percent`) shares the `agterm-quick` CSS
  class and the same GtkFrame shape, so it gains the identical chrome by construction.

## Context (from discovery)
- **Base branch: `linux-port` (= `upstream-linux-port`, tip `d2f8795`)** — per request, the fix is
  authored against upstream's linux-port branch. `linux-port-wip` is 41 commits ahead.
  - **DUAL-LANDING REQUIREMENT (user-requested): every hunk sits inside a region that is
    byte-identical on `linux-port` AND `linux-port-wip`, so the same commit cherry-picks cleanly
    onto both.** Verified placements:
    - `App.swift`: the `.agterm-quick` line has 46 identical lines above and 12 below on both
      branches (divergence below is wip's `sidebarHoverCSS` interpolation) — the one-line swap
      dual-lands with ample context.
    - `AppController.swift`: `setQuick()`'s frame-construction block is identical on both;
      divergence starts only at the focus leg after `set_visible` (wip added the
      `refocusIfStranded` handling). The insertion point after the `"agterm-quick"` class add
      has ~14 identical lines each side — dual-lands.
    - `AppControllerSurfaces.swift`: the floating-branch frame-setup PREFIX
      (`gtk_frame_new → "card" → "agterm-quick" → halign → valign → let dw = …`) is identical on
      both; divergence starts only after it (wip commit `83e6c11` added the `gtk_widget_measure`
      sizing machinery there — **no** measures/`sizeFallback`/`contentSize` exist on
      `linux-port`). The `set_overflow` insertion goes IMMEDIATELY AFTER the `"agterm-quick"`
      class add — **ZERO SLACK: exactly 3 identical lines below** (halign/valign/`let dw`), the
      bare minimum of git context; empirically verified — this placement cherry-picks clean,
      the same call one line later CONFLICTS. Do not "tidy" the call downward. On wip this
      position also satisfies the measure-ordering rule by construction (render-only call,
      before the measures).
    - Tests: the pins go in a **new file** `LinuxQuickCardPolicyTests.swift` — new files (the
      policy file too) land on both branches unconditionally. Rationale for not appending to
      `LinuxPolicyTests.swift`: an append would currently merge cleanly, but its cleanliness
      depends on where wip happens to have inserted (wip's copy is 612 lines vs 211); a new
      file is future-proof against further wip growth, and `agterm-linux/Tests/` has NO nested
      `.swiftlint.yml`, so the 612-line file sits under the root 1000-line `file_length` budget
      already.
- Files involved:
  - `agterm-linux/Sources/AgtermLinux/App.swift` — `installAppCSS()`, currently
    `.agterm-quick { background-color: #1e2228; }` only.
  - `agterm-linux/Sources/AgtermLinux/AppController.swift` — `setQuick()` builds the quick card
    GtkFrame (`card` + `agterm-quick` classes, 44/56px margins). **992/1000 lint lines** — see
    the lint budget constraint below.
  - `agterm-linux/Sources/AgtermLinux/AppControllerSurfaces.swift` — `syncOverlay()` floating
    branch builds the same frame shape (also `card` + `agterm-quick`).
- Patterns found:
  - `.agterm-switcher` (same CSS block) already draws a light border:
    `border: 1px solid alpha(#ffffff, 0.12)` — in-repo precedent that light contour chrome is
    needed over terminal content.
  - `LinuxSidebarPolicy.sidebarCSS(fontSize:)` exists on `linux-port` and is string-pinned at
    `LinuxPolicyTests.swift:101-129` — the host-free pinned-CSS-constant precedent, including the
    house style of "pin + why" comments.
- Dependencies / constraints:
  - **Border width must stay exactly 1px.** libadwaita's `frame` border is already 1px, so a
    color swap at the same width leaves the widget's measured chrome **unchanged** — which is the
    invariant that keeps `linux-port-wip`'s `contentSize(request:chrome:)` sizing math valid
    after the cherry-pick onto wip. The unit pin encodes this (Task 1).
  - No `padding` may be added to `.agterm-quick`: the GL child must keep filling the content box.
  - `box-shadow` is layout-neutral (never measured); it draws outside the border box into
    whatever surround the CONSUMER gives the card — and the two consumers do NOT share one.
    For the QUICK card the surround is the fixed 44/56px margins: blur is capped at 32px so the
    halo fully resolves inside them, the BOTTOM edge being the binding one (8px down-offset +
    32px blur = 40px against 44px margin, 4px slack), so a future "stronger shadow" tweak cannot
    push blur past ~36px without clipping at the bottom window edge. The floating OVERLAY card
    has NO margins — `syncOverlay` centers it at a `sizePercent`% size request, leaving
    `(100 - sizePercent)/2` % per side — so at 95 (`editKeymap`) or 100 the halo truncates at the
    window edge and the border/rounded clip hug the window content edge. Accepted, documented in
    the policy doc comment; the 44px arithmetic bounds the quick card ONLY.
  - **swiftlint budget:** `AppController.swift` is 992 lines against a 1000-line `--strict`
    limit; Task 2's addition must stay within ~8 lines, and the limit must NOT be bumped
    (CLAUDE.md). The contract prose lives in `LinuxQuickCardPolicy`'s doc comment, not in
    `setQuick` comments.
  - Keep-in-sync: control-API **exempt** (pure visual chrome, nothing to drive, no state to read
    back on `tree`); no Settings ▸ Interface toggle (not a hideable affordance); cookbook exempt
    by policy; no README/site/skill impact.

## Development Approach
- **testing approach**: Regular (code first, then tests) — user-confirmed
- complete each task fully before moving to the next; make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task, except
  where the Testing Strategy below records an explicit no-seam exemption
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- maintain backward compatibility (the `#1e2228` opaque backing must stay — it prevents
  see-through when the ghostty surface draws transparent under `background-opacity < 1`)
- **anchor all commands at the worktree-absolute root** (CLAUDE.md: the Bash cwd DRIFTS) — every
  `swift test`/`swift build` below means `<wt>/agterm-linux`, spelled absolutely once the
  worktree path is known; never a relative `cd`
- work happens in an **isolated git worktree forked from `linux-port`** (Claude Code native
  worktree support). Worktree artifact setup for the LINUX build: symlink the gitignored
  `agterm-linux/vendor/ghostty` from the main checkout with an ABSOLUTE target
  (`ln -s /home/n/p/github/agterm-linux/agterm-linux/vendor/ghostty <wt>/agterm-linux/vendor/ghostty`)
  — without it the first `swift test` triggers a multi-minute zig libghostty rebuild. (The
  CLAUDE.md worktree rule names only the macOS artifacts; this is the Linux equivalent.)

## Testing Strategy
- **unit tests**: the CSS contract lives in a host-free `LinuxQuickCardPolicy.cardCSS` constant
  pinned by a NEW `LinuxQuickCardPolicyTests.swift` (same pin style as `LinuxPolicyTests`'
  `sidebarCSS` pins; a separate file so the commit dual-lands — see Context). The pins that
  carry contract weight:
  (a) the opaque `#1e2228` backing survives (translucency invariant), (b) no `padding`,
  (c) border width is **exactly 1px** (the measured-chrome invariant for wip's sizing math),
  (d) a `box-shadow` and `border-radius` are present. Exact color values are pinned once with a
  comment stating why light polarity is load-bearing (dark-on-dark invisibility), per the house
  "pin + why" style.
- **explicit exemption**: the two `gtk_widget_set_overflow` calls have no host-free seam and no
  accessibility-observable effect — AT-SPI cannot see clipping, and no `atspi_smoke.py`
  quick-terminal scenario exists on `linux-port`. They are verified by eye (Post-Completion),
  like the cursor and OSC-background cases in `.claude/rules/libghostty.md`.
- full suite: `swift test` in `<wt>/agterm-linux` must stay green. Lint: `swiftlint` is not
  installed locally on this machine — verified by CI's `lint-linux` job; do not fake a local pass.
- **where the new tests run in CI**: `test-linux` runs `swift test` in `agtermCore` only; the new
  `LinuxQuickCardPolicyTests` execute in the **`build-linux`** job (`working-directory: agterm-linux`),
  which also runs `scripts/test-linux-ui.sh` — the AT-SPI suite under Xvfb + llvmpipe software
  GL, a THIRD renderer path (beyond local Vulkan/ngl). ⚠️ It does NOT reach either
  `set_overflow` site on `linux-port`: the branch has no quick-terminal scenario, and the one
  `session overlay open` case passes no `--size-percent`, so `syncOverlay`'s floating branch never
  runs. Both new calls are therefore DEAD in this branch's CI, which also means the change's most
  likely CI failure mode — a headless-GL crash/hang from the new rounded-clip offscreen pass —
  has no test that would produce the signal. Adding `--size-percent 60` to that scenario would
  cover it; `atspi_smoke.py` has diverged between the branches, so it is a per-branch follow-up
  (recorded under Post-Completion), not part of the dual-landing commit. What the UI smoke DOES
  now enforce for this change is CSS validity: the app's stderr is captured and any
  `Theme parser error` fails the run.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- Hoist the quick-card CSS into a host-free constant (`LinuxQuickCardPolicy.cardCSS`),
  interpolate it in `installAppCSS()`, and give the `.agterm-quick` rule the explicit chrome:
  - `border: 1px solid alpha(#ffffff, 0.18)` — matches the macOS stroke
    (`Color.white.opacity(0.18)`, 1pt). Same 1px width the theme already draws, light color
    instead of themed-invisible. GTK allocates the child *inside* the border box, so the border
    is never overdrawn. The frame's `#1e2228` background paints under the border area (CSS
    default `border-box` clip — plain `.card`, unlike `button.card`, does NOT set
    `background-clip`), so the 18% white composites over the backing, matching macOS's
    `.strokeBorder` over `.background(terminalColor)`.
  - `border-radius: 12px` — matches macOS `cornerRadius: 12` (equals the theme value; stated
    explicitly so the contract doesn't depend on Adwaita).
  - `box-shadow: 0 8px 32px alpha(#000000, 0.8)` — a **deliberate divergence** from SwiftUI's
    centered ~⅓-alpha `.shadow(radius: 24)`: offset and stronger, because a subtle centered
    shadow is exactly what proved invisible dark-on-dark. 32px blur resolves fully inside the
    quick card's 44px margins; the marginless overlay card truncates it at high `--size-percent`
    (see the box-shadow bullet in Context).
- Clip the GL child to the rounded silhouette with `gtk_widget_set_overflow(W(frame),
  GTK_OVERFLOW_HIDDEN)` at both frame-construction sites. GTK renders the CSS background/border/
  shadow *before* pushing the overflow clip, and the clip is the padding-box rounded rect — so
  the widget's own border and shadow are unaffected while the square GL child stops overdrawing
  the corner arcs. This clips ~3–4px of the corner terminal cells, exactly as macOS's
  `clipShape` does (parity, not a defect). This is the tree's first `set_overflow` call.
- The `card` class **stays** on both frames even though background, radius, and shadow are now
  overridden: it still supplies `color: var(--card-fg-color)` and the `:focus-visible` outline
  rules, and removing it would change more than this fix intends.
- Provider priority makes the overrides stick: app CSS installs at priority 600 (APPLICATION) vs
  the theme's 200 (THEME) — the same mechanism that already makes `background-color: #1e2228`
  win.
- Key decision: one shared CSS class (`agterm-quick`) keeps the quick card and the floating
  overlay card visually identical, exactly as today — no second class, no divergence.

## Technical Details
- New file `agterm-linux/Sources/AgtermLinux/LinuxQuickCardPolicy.swift` (~15 lines): an enum
  with `static let cardCSS: String` emitting the full `.agterm-quick { … }` rule, doc comment
  carrying the contract (light-polarity rationale; macOS equivalence + the deliberate shadow
  divergence; opaque-backing, no-padding, and 1px-width invariants and why each is load-bearing).
  This is where the prose lives — NOT in `setQuick` comments (lint budget).
- `installAppCSS()` replaces the inline `.agterm-quick` line with
  `\(LinuxQuickCardPolicy.cardCSS)`.
- `setQuick()` (`AppController.swift`): add `gtk_widget_set_overflow(W(frame),
  GTK_OVERFLOW_HIDDEN)` next to the class adds with a short trailing comment (+1–2 lines →
  993–994 of the 1000 `file_length` limit). Do NOT trim existing comments unless the count
  actually exceeds 1000 — every extra edited line is extra hunk surface on the dual-landing
  change.
- `syncOverlay()` floating branch (`AppControllerSurfaces.swift`, as it exists on `linux-port`):
  add the same `set_overflow` call with the other frame setup calls. On this branch there are no
  measure calls and no ordering comment at the site — nothing to preserve.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code changes, tests, comment/doc updates in this repo
- **Post-Completion** (no checkboxes): manual visual verification, branch integration

## Implementation Steps

### Task 1: Add LinuxQuickCardPolicy with the card CSS and wire it into installAppCSS

**Files:**
- Create: `agterm-linux/Sources/AgtermLinux/LinuxQuickCardPolicy.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/App.swift`
- Create: `agterm-linux/Tests/AgtermLinuxTests/LinuxQuickCardPolicyTests.swift`

- [x] create `LinuxQuickCardPolicy.cardCSS` emitting the `.agterm-quick` rule: opaque `#1e2228`
      backing (preserved), `border: 1px solid alpha(#ffffff, 0.18)`, `border-radius: 12px`,
      `box-shadow: 0 8px 32px alpha(#000000, 0.8)`; contract doc comment per Technical Details
- [x] replace the inline `.agterm-quick` line in `installAppCSS()` with the interpolated constant
- [x] write pins in NEW `LinuxQuickCardPolicyTests.swift` per Testing Strategy: (a) `#1e2228`
      backing survives, (b) no `padding` in the rule, (c) border width exactly `1px`
      (measured-chrome invariant), (d) `box-shadow` + `border-radius` present; pin the light
      border color once with a "why" comment (house style: `LinuxPolicyTests.swift:101-129`;
      separate file for unconditional dual-landing — see the rationale in Context)
      ➕ **Revised in the review-fix pass to ONE equality pin over the whole rule.** The nine
      substring pins re-stated the same literal in the same repo and still let real drift through
      (`hasPrefix`/`hasSuffix` pass for a two-rule constant, so the "one rule, both cards identical"
      claim in the comment was unbacked; `!contains("padding")` also matched a legitimate future
      `background-clip: padding-box`). Equality subsumes every one of them, kills both fragile
      negative pins, and is honest about what a string test over a bare constant IS: a
      change-detector that forces an editor to re-read the contract doc comment. The rationale for
      each invariant lives in that comment, not duplicated in the test.
- [x] run `swift test` in `<wt>/agterm-linux` (absolute path) - must pass before task 2
      (new suite green; one PRE-EXISTING unrelated failure — see the ⚠️ note below)

⚠️ Pre-existing, unrelated `swift test` failure in `<wt>/agterm-linux`: `Linux integration service`
▸ "Flatpak process environments do not offer a host launcher" (`IntegrationServiceTests.swift:765`)
fails on the CLEAN tree too (186 tests / 1 failure before this change, 187 / same 1 failure after).
Not caused by, and not fixable within, this plan's scope.

### Task 2: Clip the GL child to the rounded card at both frame sites

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/AppController.swift`
- Modify: `agterm-linux/Sources/AgtermLinux/AppControllerSurfaces.swift`

- [x] `setQuick()`: add `gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)` after the CSS
      class adds with a short trailing comment pointing at `LinuxQuickCardPolicy` for the
      contract (+1–2 lines → 993–994/1000; no comment trimming — see Technical Details)
- [x] `syncOverlay()` floating branch: same `set_overflow` call inserted IMMEDIATELY AFTER the
      `gtk_widget_add_css_class(W(frame), "agterm-quick")` line — the dual-landing placement
      with ZERO slack (exactly 3 identical lines of context below; one line lower is a verified
      cherry-pick CONFLICT — do not move it down); on wip this position sits before the measure
      calls, satisfying the ordering rule by construction
- [x] commit Tasks 1–2 as a SINGLE commit — the dual-landing unit Task 3 verifies is a commit
- [x] verify `wc -l` on `AppController.swift` stays ≤ 1000 (swiftlint fires above 1000;
      staying strictly under is deliberate headroom) — 993 after the +1 line
- [x] build: `swift build` in `<wt>/agterm-linux` (tests exemption for the two GTK calls is
      recorded in Testing Strategy — no host-free seam, verified by eye post-completion)
- [x] run `swift test` in `<wt>/agterm-linux` (absolute path) - must pass before task 3
      (187 tests, only the PRE-EXISTING Flatpak failure noted above)

### Task 3: Verify acceptance criteria
- [x] verify all requirements from Overview are implemented (light border, explicit radius +
      real clip, strong shadow; overlay card inherits all three; opaque backing preserved)
      — read back from `git show 708c772`. All six Overview/Solution-Overview requirements
      confirmed in `LinuxQuickCardPolicy.cardCSS` and the two call sites:
      (1) `border: 1px solid alpha(#ffffff, 0.18)` — light polarity at the UNCHANGED 1px width
      (no `border-width` declaration anywhere, pinned negatively by the test);
      (2) `border-radius: 12px` stated explicitly;
      (3) `box-shadow: 0 8px 32px alpha(#000000, 0.8)` — the strong offset shadow;
      (4) `gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)` at BOTH frame sites —
      `AppController.swift:515` (`setQuick()`) and `AppControllerSurfaces.swift:151`
      (`syncOverlay()` floating branch, inside `if let pct = s.overlaySizePercent`), each
      immediately after the `"agterm-quick"` class add, exactly the zero-slack placement;
      (5) the overlay card inherits all three declarations by construction — both frames add the
      SAME `card` + `agterm-quick` classes, and there is exactly ONE `.agterm-quick` rule
      (`css.hasPrefix(".agterm-quick {")` / `hasSuffix("}")` pins single-selector, single-rule);
      (6) the opaque `#1e2228` backing is preserved verbatim (`background-color: #1e2228;`, with
      `alpha(#1e2228` pinned absent). `installAppCSS()` swaps the inline literal for
      `\(LinuxQuickCardPolicy.cardCSS)` at the same App-priority (600) provider — one-line diff.
- [x] run full test suite: `swift test` in `<wt>/agterm-linux`, and in `<wt>/agtermCore` as a
      smoke check (this change cannot touch core, so a core failure means environment trouble)
      — `agterm-linux`: **187 tests / 28 suites, 1 failure**, and that failure is EXACTLY the
      pre-existing unrelated `Linux integration service` ▸ "Flatpak process environments do not
      offer a host launcher" (`IntegrationServiceTests.swift:765`) recorded under Task 1. The new
      `Linux quick-terminal card chrome` suite is green. No regression.
      `agtermCore`: **2040 tests / 84 suites, 3 failures**, all three in `CodexStatusHookTests`
      (`stopReportsBlockedWhenAssistantMessageContainsQuestionMark`,
      `…WhenQuestionPrecedesRecommendation`, `…WhenAnsweredQuestionIsNotTrailing`).
      ⚠️ PRE-EXISTING and environmental, NOT a regression — proven by construction:
      `git diff --name-only 708c772^ 708c772 -- agtermCore` returns **0 files**, and the worktree
      is clean apart from this untracked plan file, so all of `agtermCore` is byte-identical to
      the `linux-port` tip `d2f8795`. The three tests shell out through `/bin/bash` to the macOS
      resource script `agterm/Resources/agent-status/agterm-codex-status.sh`; they are host-shell
      dependent, out of this plan's scope, and cannot be affected by a GTK CSS change.
- [x] lint: verified by CI's `lint-linux` job on push (`swiftlint` not installed locally — do
      not fake a local pass); locally sanity-check only the file-length budget from Task 2
      — no local `swiftlint` run was attempted or faked. File-length sanity check (root
      `.swiftlint.yml`, 1000-line `file_length`; confirmed `agterm-linux/Tests/` has NO nested
      config — the only nested ones are `agtermUITests/`, `agtermCore/Tests/`, `agtermTests/` —
      so 1000 applies to the new test file too):
      `AppController.swift` **993**, `AppControllerSurfaces.swift` **611**, `App.swift` **302**,
      `LinuxQuickCardPolicy.swift` **32**, `LinuxQuickCardPolicyTests.swift` **40** — all under
      1000, and no limit was bumped. After the cherry-pick onto wip the merged files are
      `AppController.swift` **971** and `AppControllerSurfaces.swift` **762** — also under.
      `line_length` (warning 200) also checked: longest lines are 195 / 164 / 198 / 157 / 105.
- [x] confirm no keep-in-sync surface is owed (control-API exempt: pure visual chrome — recorded
      here as the required call-out)
      — **CALL-OUT: no keep-in-sync surface is owed, and the control-API exemption is deliberate.**
      Verified against the actual 5-file diff, which touches only
      `agterm-linux/Sources/AgtermLinux/{App,AppController,AppControllerSurfaces,LinuxQuickCardPolicy}.swift`
      and `agterm-linux/Tests/AgtermLinuxTests/LinuxQuickCardPolicyTests.swift`:
      (a) **control API exempt** — no `AppActions`/`AppStore` action was added, no `Command` case,
      no `ControlServer` arm, no `agtermctl` subcommand. The change is pure rendering chrome on
      frames that already exist and are already driven by `quick` and
      `session.overlay --size-percent`; there is nothing new to drive and no new per-session state,
      so the paired WRITE→READ-BACK rule is vacuous (no new `ControlSessionNode` field is owed).
      (b) **no Settings ▸ Interface toggle** — the border/radius/shadow/clip are not a hideable
      affordance; they are the card's own silhouette, exactly the "transient/decorative chrome
      with nothing to hide" case the CLAUDE.md norm exempts.
      (c) **cookbook exempt by policy** (not a keep-in-sync surface at all).
      (d) **no README / `site/` / `plugins/agterm/skills/agterm/` impact** — no command, flag,
      keybinding, mode, keymap-format, or window/workspace/session/pane model change; the
      documented surface is byte-identical.
- [x] **verify dual-landing** (branch-free, from the FEATURE worktree — the main checkout is
      never touched; it holds `linux-port-wip`, which is exactly why the check must not try to
      check that branch out) — used the fully NON-MUTATING alternative, so no HEAD, branch, index,
      or worktree was touched anywhere (the `git checkout --detach` variant was deliberately NOT
      run):
      `git -C <wt> merge-tree --write-tree --merge-base=708c772^ linux-port-wip 708c772`
      → **exit 0, ZERO `CONFLICT` lines**, merged tree `1da792521739df923dc5b0c423f98aa575e445b0`.
      Substantive ordering check performed on that merged tree, not just on exit status:
      in the merged `AppControllerSurfaces.swift` the `set_overflow` call lands at **line 151**,
      while the two `gtk_widget_measure` calls sit at **lines 170–171** — the clip call is BEFORE
      both, satisfying wip's measure-ordering rule by construction. Both numbered ordering
      comments survive untouched (the "TWO orderings around the measurements are load-bearing,
      and BOTH degrade SILENTLY" block at line 161 with its `gtk_widget_measure` short-circuit
      note at 166, and the "Keep this AFTER the two `gtk_widget_measure` calls above — see
      ordering 2 there." comment at 176).
      Full merged-tree-vs-wip diff is exactly the three intended hunks and nothing else:
      `AppControllerSurfaces.swift` +1 line (150a151), `AppController.swift` +1 line (514a515),
      `App.swift` the single `.agterm-quick` → `\(LinuxQuickCardPolicy.cardCSS)` swap (148c148);
      plus both new files present in the merged tree. No collateral change, no comment loss.
- [x] ⚠️ the dual-landing proof is only valid against the wip tip it ran on — if
      `linux-port-wip` advances afterwards, RE-RUN the check immediately before the real
      cherry-pick
      — **the proof above ran against `linux-port-wip` tip `de48110ce486f0b9d8bda6cf61d680ead62bdf0d`**
      ("docs: add linux quick-terminal card chrome implementation plan"), with the feature commit
      at `708c772ee007492f63a9861fb67a487551134916` (NOT amended — every check passed, so the
      commit stands unchanged and the proof needs no re-run for a commit-side reason). The caveat
      binds only on the wip side: if `linux-port-wip` moves past `de48110`, re-run
      `git merge-tree --write-tree --merge-base=708c772^ linux-port-wip 708c772` immediately
      before the real cherry-pick.

### Task 4: [Final] Update documentation
- [x] PROPOSE (do not apply unprompted) a rules note for `LinuxQuickCardPolicy.swift`: it
      matches only `main-loop.md`'s catch-all `agterm-linux/Sources/AgtermLinux/**` glob, which
      carries GTK main-loop/focus guidance and nothing about CSS/chrome — propose a topical
      home (e.g. a chrome bullet in `libghostty.md`) and let the user decide. ⚠️ If accepted,
      the rules edit is a **SEPARATE commit explicitly OUTSIDE the dual-landing set**: every
      candidate rules file diverged between the branches (`main-loop.md` +297, `sidebar.md`
      +528, `libghostty.md` +32, `linux-surface-sizing.md` +101), so folding it into the code
      commit would break the same-commit-applies-to-both property

      ---

      **PROPOSAL — ready to apply, NOT applied. Nothing under `.claude/rules/` was touched.**

      **Premise verified (glob audit of all 14 rule files on `linux-port`).** The only `paths:`
      entry in the whole rules tree that matches
      `agterm-linux/Sources/AgtermLinux/LinuxQuickCardPolicy.swift` is `main-loop.md`'s catch-all
      `agterm-linux/Sources/AgtermLinux/**`. Every other Linux-touching rule globs explicit
      filenames or a narrow prefix and does NOT match: `keymap.md` (explicit list),
      `control-api.md` (`Control*.swift`, `LinuxControlDispatcher.swift`),
      `theme-picker.md` (`ThemePicker.swift`, `GhosttyConfigTheme.swift`), and `libghostty.md`
      (no `agterm-linux` glob at all on this branch). So the plan's premise holds exactly as
      written: the note's only automatic home today is a rule titled "Main loop and deferred
      work (GTK/Linux port)", which says nothing about CSS or chrome — the trigger is accidental,
      not topical. The new test file
      `agterm-linux/Tests/AgtermLinuxTests/LinuxQuickCardPolicyTests.swift` matches NO rule at all
      (`ui-tests.md` globs only `agtermUITests/**` and `agtermTests/**`).

      **Recommended home: `.claude/rules/libghostty.md`** (the plan's own suggestion — confirmed
      as the best fit after checking the alternatives). Three reasons:
      1. Topical fit. `libghostty.md` is the tree's rendering/chrome rule: it already owns
         "Window overlays sit BELOW the custom titlebar", "Under window translucency every
         surface renders a fully transparent background — never leave a surface visible beneath
         the FULL overlay" (which explicitly discusses the quick terminal's opaque backing),
         and the OSC-11 per-pane background bullet. The quick-card chrome is the same genre.
      2. It already carries Linux content. The bullet "**Linux Dashboard mirrors live surfaces;
         it never reparents a `GtkGLArea`**" (line 395 on `linux-port`) lives there, and on
         `linux-port-wip` the file has ALREADY gained a Linux glob
         (`agterm-linux/Sources/AgtermLinux/Ghostty*.swift`). Adding a Linux source path there
         is precedented, not novel.
      3. The verify-by-eye escape hatch is already this file's convention — the plan's own
         no-seam exemption for the two `gtk_widget_set_overflow` calls cites the cursor and
         OSC-background cases in `libghostty.md`.

      **`paths:` frontmatter — YES, a new glob is needed.** `LinuxQuickCardPolicy.swift` does not
      match wip's `Ghostty*.swift` entry and there is no entry at all on `linux-port`. Add to
      `libghostty.md`'s `paths:` (branch-appropriately — on `linux-port` these are the file's
      first `agterm-linux` entries):

          - "agterm-linux/Sources/AgtermLinux/LinuxQuickCardPolicy.swift"
          - "agterm-linux/Tests/AgtermLinuxTests/LinuxQuickCardPolicyTests.swift"

      Globbing the test file mirrors wip's `sidebar.md`, which lists
      `agterm-linux/Tests/AgtermLinuxTests/LinuxPolicyTests.swift` alongside
      `LinuxSidebarPolicy.swift` — the established pattern for a Linux policy + its pin file.
      Do NOT add `AppController.swift` or `AppControllerSurfaces.swift`: they are hub files, and
      pulling a 48 KB rule into context on every edit to them is exactly the cost the path
      scoping exists to avoid (CLAUDE.md already tells the reader to open a rule by hand for a
      hub file).

      **Exact bullet text to append** (append at the END of the `## libghostty gotchas` list, after
      the OSC 52 clipboard bullet — it is the newest gotcha and the file is append-ordered;
      semantic line breaks, one sentence per line, per CLAUDE.md's note-writing convention):

          - **The Linux quick-terminal / floating-overlay card chrome lives in ONE host-free CSS
            constant, and its border WIDTH is a sizing contract, not a style choice.**
            `LinuxQuickCardPolicy.cardCSS` emits the single `.agterm-quick` rule that
            `installAppCSS()` interpolates at the application priority (600), which is what makes it
            win over libadwaita's theme rules (200) for the same `frame`/`.card` nodes.
            Both floating cards — the quick terminal (`AppController.setQuick`) and the sized session
            overlay (`AppControllerSurfaces.syncOverlay`) — put the same `card` + `agterm-quick`
            classes on the same GtkFrame shape, so ONE rule dresses both and they cannot drift apart.
            The card was reported as having "no visible boundary", but libadwaita's `frame` node was
            already drawing a 1px border: what was missing is CONTRAST (the theme's border color is
            mixed from `currentColor` and is invisible dark-on-dark) and the CLIP (the square opaque
            `GtkGLArea` child paints over the corner arcs and erases the rounded silhouette).
            The fix is therefore a light-polarity border color at the UNCHANGED 1px width, plus
            `gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)` at BOTH frame-construction sites
            — GTK renders the CSS background/border/shadow BEFORE pushing the overflow clip, so the
            widget's own chrome is untouched and only the child stops overdrawing the corners.
            Roughly 3–4px of the corner terminal cells are clipped as a result; that is macOS
            `clipShape` parity, not a defect.
            Three declarations are load-bearing and are pinned by `LinuxQuickCardPolicyTests`:
            the `#1e2228` backing stays OPAQUE (it is what stops the card going see-through when the
            surface below draws at `background-opacity < 1`), no `padding` may be added (the GL child
            must keep filling the content box), and the border width stays exactly 1px.
            The width matters because it changes the frame's MEASURED chrome, which the surface-sizing
            math subtracts from the requested size — widen the border and that subtraction silently
            starts under-sizing the pty.
            `box-shadow` is layout-neutral (never measured) and draws outward into whatever surround
            the consumer gives the card, and the two consumers do NOT share one: the quick card's
            fixed 44/56px margins bind at 8px offset + 32px blur = 40px against 44px (so a stronger
            shadow cannot push the blur past ~36px), while the floating overlay card has NO margins
            and truncates its halo at high `--size-percent`.
            A CSS typo here fails SILENTLY — GTK drops an unparseable declaration and the chrome
            simply does not appear, which is indistinguishable from the fix not working — and the
            string pins assert a Swift string, not GTK parseability, so verify a change by eye and
            check the instance's stderr for `Gtk-WARNING` / `Theme parser error` lines.

      **Per-branch wording note.** The bullet above deliberately spells the sizing contract in prose
      ("the surface-sizing math subtracts [the measured chrome] from the requested size") instead of
      naming a rule file, because `.claude/rules/linux-surface-sizing.md` exists ONLY on
      `linux-port-wip`. When applying to wip, that clause can name it and
      `GhosttySurfaceGeometry.contentSize(request:chrome:)` directly; on `linux-port` leave the prose
      as written — a dangling cross-reference to a nonexistent rule is worse than the prose.

      **Alternatives considered and rejected.**
      - `main-loop.md` (the accidental current match): would need no `paths:` change and would load
        automatically, but the note has nothing to do with the main loop, deferred work, or keyboard
        focus. Filing it there entrenches the catch-all glob as a junk drawer and makes the file
        harder to trust as a focused contract. Rejected on topicality.
      - `linux-surface-sizing.md` (wip only): the single best home for the 1px-width invariant
        specifically — it owns `contentSize(request:chrome:)` and the measure-ordering rules, and it
        already globs `AppControllerSurfaces.swift`, one of the two `set_overflow` sites. But it does
        not exist on `linux-port`, so it cannot host the primary note. **Optional follow-up on wip
        only:** add a one-line back-reference in its "Store the frame's size request MINUS its
        measured chrome" bullet, e.g. "the quick/overlay card's 1px border width is pinned for exactly
        this reason — see the card-chrome bullet in `libghostty.md`."
      - A NEW `linux-chrome.md` rule: cleanest scoping in the abstract, but one bullet does not earn
        a 15th rule file plus a new CLAUDE.md index entry. Revisit if GTK CSS/chrome notes accumulate
        (`.agterm-switcher`, `.agterm-dashboard-cell`, `LinuxSidebarPolicy.sidebarCSS` and
        `sidebarHoverCSS` are all latent members of that cluster).

      **Also owed if accepted:** the `libghostty.md` entry in CLAUDE.md's
      `## Subsystem notes (path-scoped rules)` index ends "Triggers on the `Ghostty/` surfaces,
      `ContentView.swift`, `TerminalView`/`TerminalSearchBar`." — that sentence must gain the Linux
      quick-card policy + its tests, or the index misdescribes the file's triggers.

      ⚠️ **Separate commit, explicitly OUTSIDE the dual-landing set.** Re-verified with
      `git diff --numstat linux-port linux-port-wip`: `libghostty.md` +32/-0, `main-loop.md`
      +291/-6, `sidebar.md` +528/-0, `linux-surface-sizing.md` +101/-0 (wip-only file), and
      **`CLAUDE.md` itself +27/-1**. So BOTH files this proposal touches have diverged between the
      branches. Folding the rules note into `708c772` would destroy the same-commit-applies-to-both
      property that Task 3 proved. Land it as its own commit, per branch, after the code commit has
      dual-landed.
      **Also owed if accepted (2):** a back-pointer line in `LinuxQuickCardPolicy.cardCSS`'s doc
      comment — "Read the card-chrome bullet in `.claude/rules/libghostty.md` before changing this" —
      matching the house style of `LinuxSidebarPolicy.sidebarCSS`'s pointer at its own rule. It must
      land WITH or AFTER the rules bullet on each branch, never before: `linux-port`'s `sidebar.md`
      has no Linux content at all, so `LinuxSidebarPolicy`'s pointer is already dead on this branch
      and the precedent should not be copied dangling.
- [ ] move this plan to `docs/plans/completed/` — NOT yet done. Handled by the orchestrator after the
      review phases; the plan file stays untracked in this worktree by design (it is tracked on
      `linux-port-wip`, not on `linux-port`, and must stay out of the dual-landing commit)

## Post-Completion

**Manual verification (acceptance):**
- Build and launch an ISOLATED dev instance (`AGTERM_STATE_DIR=<short tmp>`, socket derived) from
  the worktree; Ctrl+` over a dark full-bleed session (the reported scene: split running a TUI)
  and confirm the card reads as a floating panel: light contour line, corners actually clipped
  round, soft shadow halo; repeat for `agtermctl session overlay open --size-percent` on the
  isolated socket to confirm the overlay card matches. Hands-off after launch — the user drives.
- **Hard acceptance step (not conditional): check BOTH GSK renderers** — default (Vulkan on this
  GTK 4.22 machine) AND `GSK_RENDERER=ngl`. TWO new GSK surfaces are in play and an artifact
  must be attributed to the right one: (1) the rounded overflow clip forces an offscreen pass
  for the GL texture node — the surface the known Vulkan text-artifact story touches; (2) the
  32px-blur outset shadow is a blurred `GskOutsetShadowNode`, which the tree has no precedent
  for (the only existing box-shadow, `.agterm-dashboard-cell.selected`, uses spread with zero
  blur).
- **CSS parse check (the only validity check anywhere in the plan):** capture the dev instance's
  stderr and confirm zero `Gtk-WARNING`/`Theme parser error` lines — GTK drops an unparseable
  declaration SILENTLY, and the `LinuxQuickCardPolicyTests` string pins assert a Swift string,
  not GTK parseability; a syntax typo would present as "chrome silently missing,"
  indistinguishable from the fix not working.
- Expected and acceptable: ~3–4px of the corner cells are clipped (macOS `clipShape` parity).
- Do NOT run `stage-linux.sh` from inside a running agterm session with inherited
  `LD_LIBRARY_PATH=/opt/agterm-linux/lib` (known silent-corruption gotcha).

**Branch integration (dual-landing, verified in Task 3):**
- The change is authored so the SAME commit(s) apply cleanly to BOTH branches: every hunk's
  context is inside a branch-identical region, and both test/policy files are new (see the
  dual-landing bullet in Context). Land on `linux-port` (the PR base), then cherry-pick or merge
  the identical commit(s) into `linux-port-wip` — Task 3's throwaway-branch check has already
  proven zero conflicts.
- Safety on wip after landing: the `set_overflow` placement (with the class adds) sits before
  the `gtk_widget_measure` calls, so both silently-degrading orderings
  (`.claude/rules/linux-surface-sizing.md`) are untouched; and the 1px-width border pin
  (Task 1c) guarantees wip's `contentSize(request:chrome:)` subtraction sees unchanged chrome —
  the theme border was already 1px, only its color changed.
- Bonus CI signal on wip: unlike `linux-port`, wip's `atspi_smoke.py` HAS quick-terminal
  scenarios (Ctrl+` show/hide, quick-focus/stranding), so after the cherry-pick wip's
  `build-linux` job exercises the quick-terminal path — clip active — live under Xvfb +
  llvmpipe, a second and better CI check than the port-side run gets.

**Post-Completion results (as of the review-fix pass):**
- ⚠️ **The manual visual acceptance above is OUTSTANDING — it has NOT been run.** Neither GSK
  renderer was checked (default Vulkan nor `GSK_RENDERER=ngl`), no dev instance was launched, and
  the corner-clip/halo/contour appearance has never been observed. Tasks 1–3 were verified by
  reading `git show 708c772`, by `swift build`/`swift test`, and by the `git merge-tree` dual-landing
  dry run — none of which renders a pixel. The `[x]` on Task 3 covers the CSS/Swift contract, NOT
  visual verification. The two GSK node types the change introduces (a rounded overflow clip forcing
  an offscreen pass over the GL texture node, and a 32px-blur `GskOutsetShadowNode` the tree has no
  precedent for) remain unexercised on real hardware, and the project's known GTK-Vulkan text-artifact
  issue makes the two-renderer check specifically load-bearing. Run it before merge.
- The **CSS parse check is now automated** and no longer depends on that manual step alone: the UI
  smoke sends every launched app instance's stderr to `artifacts/linux-ui/agterm-stderr.log`
  (`atspi_smoke.py`'s `app_stderr_sink`) and `scripts/test-linux-ui.sh` fails the run on any
  `Theme parser error` OR `Theme parser warning` line — GTK emits the warning variant from the same
  call site for a deprecated/unimplemented construct, which drops the declaration just as silently.
  The runner hands the smoke the exact log PATH (`AGTERM_UI_APP_STDERR`) instead of both sides
  re-deriving a filename, and the sink stamps a marker line the runner requires afterwards, so a
  degraded sink fails LOUD rather than turning `grep` into a pass over an empty file. That covers the
  whole of `installAppCSS`, not just this rule. It is a SEPARATE commit outside the dual-landing set —
  both files have diverged between the branches.
- **The floating overlay card now runs in CI on `linux-port` too.** The `surface-lifetimes` scenario's
  `session overlay open` passes `--size-percent 60 --follow`, so `syncOverlay`'s floating branch —
  frame, `GTK_OVERFLOW_HIDDEN` clip, `agterm-quick` chrome — is constructed AND rendered under Xvfb +
  llvmpipe (`--follow` is load-bearing: a floating frame on a non-selected session is
  `set_visible(0)`, skipped in layout, so the rounded clip would never reach GSK). Its assertions are
  unchanged — the overlay's program must still run in its own cwd — so it stays a
  no-crash/no-regression check, not a pixel check; AT-SPI cannot see clipping. `atspi_smoke.py` has
  diverged between branches, so this edit is per-branch (wip's quick-terminal scenarios already cover
  the first site, and its `background-overlay-grid` scenario already covers the floating one).
- Still uncovered by any automated test, and deliberately so (recorded as a follow-up, not fixed here,
  because it needs a diff larger than this commit's budget):
  - The `installAppCSS()` WIRING. Reverting `App.swift`'s `\(LinuxQuickCardPolicy.cardCSS)` to an
    inline literal leaves the whole suite green and produces no unused-symbol warning. Closing it
    means hoisting the entire `installAppCSS` literal into a host-free `appCSS` constant and pinning
    `appCSS.contains(LinuxQuickCardPolicy.cardCSS)`.
- **Two behaviour changes to look for during the outstanding manual acceptance** (both accepted, both
  invisible to any automated check):
  - Under window translucency (`window.agterm-translucent { background-color: transparent; }`) the new
    `box-shadow: 0 8px 32px alpha(#000000, 0.8)` paints an 80%-opaque black halo into a region that
    previously showed straight through. Nothing is broken, but the card's surroundings read darker in
    that mode than before — confirm it looks intentional rather than like a rendering fault.
  - `GTK_OVERFLOW_HIDDEN` also narrows `gtk_widget_pick`, so the ~12px corner arcs of the quick and
    floating-overlay terminals become click-dead (a click there falls through to whatever is beneath).
    This is the same trade-off macOS takes with `clipShape`, hence accepted.
- **Owed follow-up, deliberately SEQUENCED after the Task-4 rules bullet (not done here):** trim
  `LinuxQuickCardPolicy.swift`'s doc comment to the three pinned invariants plus a one-line
  "Read the card-chrome bullet in `.claude/rules/libghostty.md` before changing this", matching
  `LinuxSidebarPolicy.sidebarCSS`'s 7-line delegate style (CLAUDE.md's model: detailed engineering
  notes live in `.claude/rules/*.md`, the source carries the pointer). As drafted, the Task-4 bullet
  restates the shadow-budget arithmetic, the macOS equivalence and the libadwaita `currentColor`
  derivation almost sentence for sentence, so once it lands the same contract lives in two files that
  must be hand-synced. NOT done in this change for three reasons: (1) the trim must land AFTER the
  rules bullet on each branch or the back-pointer dangles — the same trap already flagged for
  `LinuxSidebarPolicy` on `linux-port`; (2) `LinuxQuickCardPolicy.swift` is in the DUAL-LANDING commit,
  so trimming now costs an amend + merge-tree re-verification for a style change; (3) the per-consumer
  shadow detail in that comment was ADDED in the phase-1 review fix pass and is currently the ONLY
  written record of the overlay-card budget — removing it before the rules bullet exists would delete
  verified work rather than relocate it.
- Known latent (NOT introduced here, unreachable today, follow-up not fixed): `AppController`'s
  `applyWindowThemeColors` falls back to `let fg = colors.foreground ?? "inherit"` and then emits
  `@define-color window_fg_color inherit;` / `alpha(inherit, 0.22)`, which GTK rejects with the *error*
  quark. No current AT-SPI scenario selects a theme and the default theme defines `foreground`, so the
  new parse guard cannot see it — but a future theme-picker scenario against a theme that defines
  `background` without `foreground` would turn that cosmetic degradation into a red `build-linux`. Fix
  the fallback (or drop the declaration when the color is absent) when such a scenario lands.
