# AGENTS.md

## agterm-linux fork principles

This repository is the Linux-maintained fork of upstream macOS [`agterm`](https://github.com/umputun/agterm).
It exists to maintain the GTK4/libadwaita Linux frontend while tracking upstream agterm as closely as possible.

When working in this repo:

- Maintain 1:1 feature parity with upstream macOS agterm wherever the Linux platform allows it.
- Keep shared controller/core behavior upstream-compatible and host-free.
- Keep Linux-specific code isolated to the Linux UI, Linux packaging, and platform adapters.
- Avoid product, protocol, or UX divergence unless Linux platform constraints require it.
- Treat Linux as a port of the same product, not a separate product.
- Preserve a small, reviewable downstream delta from upstream.

If a rule in the inherited macOS notes conflicts with this Linux-port guidance, keep the Linux release branch's
fork principles first and preserve upstream compatibility everywhere else.

## Start with the project shape

Read `README.md` for the product overview and fork policy.
Read `ARCHITECTURE.md` before changing module boundaries, terminal surfaces, control routing, or the
libghostty bridge.

The app is still agterm: a workspace/session terminal for many long-lived coding-agent or shell sessions.
The Linux goal is to carry that model to GTK4/libadwaita without creating a separate product.

## Branch and release model

- `master` tracks upstream `umputun/agterm:master`.
- `linux-port` is the maintained downstream branch.
- `linux-port` combines upstream `master` with the Linux UI, Linux packaging, CI, release workflow, and carried portable core fixes.
- Linux releases are cut from `linux-port`.
- macOS builds, releases, and support belong to upstream agterm, not this fork.
- If a change is intended for upstream agterm, do it on a dedicated upstream-PR branch.
  Keep that branch free of Linux-port-only changes so opening a PR to upstream stays simple.
- `CHANGELOG.md` is release-only; do not touch it for ordinary feature work.

## Code ownership boundaries

- `agtermCore/` is shared Swift code and must remain host-free.
- `agterm-linux/` is the GTK4/libadwaita Linux application.
- `linux/` contains Linux-specific patches and support files.
- `packaging/linux/` contains Linux desktop and Flatpak packaging.
- `scripts/*-linux.sh` are Linux build, run, install, and packaging helpers.

Prefer portable, host-free changes in `agtermCore/` only when they are compatible with upstream agterm.
Put Linux-only behavior behind Linux UI, packaging, or platform-adapter boundaries.
Do not place Linux-fork-only code in global shared areas or macOS-specific parts of the tree.
The Linux fork must operate inside its coding boundaries unless a change is deliberately portable and upstream-compatible.

## Host-free core rules

`agtermCore` must not import app-host frameworks or terminal-rendering bindings.
Do not put GTK, libadwaita, AppKit, SwiftUI, Metal, GhosttyKit, libghostty FFI, CoreGraphics, or other
platform UI/runtime dependencies in `agtermCore`.

Keep model, persistence, naming, command validation, argument parsing, dispatch routing, response shaping,
and static catalogs in `agtermCore` when they can be expressed without host side effects.
Keep the Linux app target as a side-effect adapter for GTK/libadwaita, process, windowing, rendering, and
platform integration.

Use plain portable data types in shared code.
For geometry or UI state, prefer simple Swift structs backed by `Double`/`Int` and convert at the platform
boundary.

## Main-actor deferred work must go through the `MainTimer` seam

GTK owns the Linux main thread through `g_application_run`, and the GLib main loop drains neither
libdispatch's main queue nor the Swift Concurrency main-actor executor.
`DispatchQueue.main.async`/`asyncAfter`, `Task { @MainActor }` + `Task.sleep`, `Timer.scheduledTimer`, and
`RunLoop` scheduling therefore compile, run, and silently never fire on Linux — the failure mode is silence,
not a crash, so it survives review easily.
This applies to shared `agtermCore` code too, where the dispatch dependency is easiest to miss because the
file otherwise looks host-free.

- Schedule deferred main-actor work through `agtermCore`'s `MainTimer` seam (`MainTimer.schedule(after:_:)`,
  or `Debouncer` on top of it), never a dispatch or `Task.sleep` timer.
- Hop to the main thread with `runOnMain` (`g_idle_add`), never `DispatchQueue.main.async`.
  `runOnMain` lives in the Linux target, so host-free `agtermCore` has no hop seam: from main-actor core code
  use `MainTimer.schedule(after: 0)`, and add a hop seam alongside `MainTimer` only if a real need appears.
- Keep `MainTimer`'s default Dispatch-based so upstream macOS semantics are unchanged; the Linux app swaps in
  the GLib implementation once, in `installGLibMainTimer()` at the top of `activateApplication`.
- `DispatchQueue.global` is fine: global queues own their own threads.
- Tests that swap the process-global `MainTimer.scheduleTimer` go through the `withFakeMainTimer` fixture —
  its synchronous closure is what keeps a parallel test's timer from landing on the fake.
  The Linux package cannot see that fixture, so `AgtermLinuxTests/GLibMainTimerTests.swift` installs the real
  seam through its own synchronous `withGLibMainTimer` helper, under the same no-`await` contract.

See `agterm-linux/docs/main-loop.md` for the full main-loop contract, the repro, and the unpersisted-preview
override pattern that live previews need.

## Control API coverage is a first-class requirement

When adding any user-visible feature or capability, evaluate how it should be driven over the control socket.
Proactively propose and implement control coverage when meaningful:

- a `Command` case and arguments in `agtermCore` control protocol code,
- dispatcher/control-server handling,
- an `agtermctl` subcommand or option,
- protocol round-trip tests,
- end-to-end tests where practical.

A new user action is not done until the GUI/menu/keybinding path and control channel stay in sync.
Skip control exposure only when it is genuinely meaningless, such as pure visual chrome with nothing to drive.
Call out that exemption explicitly.

Whenever the Control API, keymap format, or window/workspace/session/pane model changes, update the bundled
agent skill under `agterm/Resources/agent-skill/`.
That directory is the source of truth; never edit installed copies under user home directories.

## UI and platform work

Most maintainers and contributors are not GTK/libadwaita or macOS UI experts.
When a UI request is non-standard, risky, or likely to fight the toolkit, push back gently first.
Explain the trade-offs and offer the simpler native alternative.
If the user still wants the custom approach, implement it.

Keep Linux UI behavior aligned with upstream macOS agterm where platform conventions allow it.
Diverge only for Linux toolkit, desktop, packaging, accessibility, or distribution constraints.

For visual acceptance requests such as "show me", build and run an isolated dev instance for the user to test.
Do not mutate the user's real state or live sessions.
After launching a manual test instance, default to hands-off unless the user asks you to drive it.

## libghostty and C-boundary safety

Copy C string data into Swift-owned values before crossing actors, queues, or callback boundaries.
Do not synchronously touch UI state from C callbacks.
Hop to the appropriate main/UI context first.

Keep rendering demand-driven where possible.
Avoid adding timers or polling loops for idle terminal rendering unless there is a measured need and a clear
shutdown path.

When adopting a newer libghostty or changing bridge behavior, treat it as a deliberate compatibility change.
Re-test terminal rendering, resize/font-size behavior, input, process lifecycle, and control-socket workflows.

## Build, test, and lint expectations

The app must build, host-free `swift test` must stay green, and lint must pass after changes.
Use the repository scripts and `Makefile` as the source of truth for exact Linux commands.

For shared Swift package tests, run `cd agtermCore && swift test` or the repo wrapper if available.
For Linux app or packaging changes, use the Linux-specific scripts and Make targets documented in `README.md`
and the scripts themselves.

Manage file sizes for real.
Source files should stay under the configured lint limits, and tests should stay within their expanded limits.
When touching an already-long file, propose splitting or relocating code, but ask before restructuring.
Do not raise lint limits just to fit new code.

## Keep documentation and surfaces in sync

When adding features, flags, keybindings, modes, packaging behavior, or release behavior, update the relevant
docs alongside code.
At minimum, consider `README.md`, Linux docs, packaging docs, bundled agent-skill docs, and any user-facing
site/docs mirror present in the repo.

Do not update `CHANGELOG.md` outside the release flow.

## Repo hygiene

Anchor path and existence checks at the absolute repo root or use `git -C <root> ...`.
Shell working directories drift between commands; do not claim a file or directory is missing from a relative
`ls`/`find` run in an unknown cwd.

When editing agent/project notes, use semantic line breaks.
Write one sentence per line where practical, and split long bullets at natural clauses so future diffs stay
small and reviewable.

Before touching CI, release, control API, settings, keymap, notifications, sidebar, windowing, libghostty,
or UI-test subsystems, check for matching notes under `.claude/rules/` and follow the relevant guidance.
Prefer Linux-specific adaptations over copying macOS-only mechanics verbatim.
