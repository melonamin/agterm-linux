# Linux v0.41.1 catch-up and release

Target exact upstream `v0.41.1` (`911345a87df1aa32c8617ce0445b0be8975abb49`).
Base maintained Linux branch: `75a0b65f29ed1bad1241708b9189bedbb228551c`.
Upstream range: `v0.40.0..v0.41.1`.
The six commits after the stable tag are excluded, as requested.
Existing worktrees and the main checkout's older local branch are preserved.

## Integration contract

- Inherit portable protocol, models, renderer resources, CLI, tests, cookbook, and documentation unchanged wherever possible.
- Retain portable Linux Foundation/POSIX adaptations and public adapter entry points.
- Keep GTK/WebKit/process effects in Linux adapters.
- Preserve the exact upstream `ConfigPathsTests.swift`.
- Every new action needs the GUI/keybinding, control channel, readback, and bundled skill in sync.
- macOS-only titlebar geometry, menu evaluation, keyboard-layout lock, and macOS 27 menu swatches remain upstream-owned.
- Linux rendering and teardown must be exercised against the adopted Ghostty version.
- Retain direct Arch release packages and optional AUR publication without credentials.
- AppImage remains omitted under the maintained release workflow's WebKit helper constraint.

## Upstream inventory and acceptance

- [x] Merge exact stable tag, preserve Linux CI/docs, and resolve shared changes toward upstream.
- [x] Text/source/config pages and path:line links, including bounded regular-file reads and line marking.
- [x] Local HTML documents with inert content and no network/resource/control grant.
- [x] Log tail/follow, rotation/truncation, bounded reads, paused scroll state, and disposal.
- [x] Text/log search with native find routing and control query/step/close.
- [x] Diff language highlighting and previous/next change navigation, GUI/key/control/readback.
- [x] Remote image/Markdown/text pages and bounded image resources through the existing page channel.
- [x] Compact sidebar density in Preferences/control/readback, native row sizing, and persistence.
- [x] Workspace chevron setting with accessible collapse/expand menu actions.
- [x] Five tint colors, custom hex tints, and remembered Show On defaults in row menus.
- [x] Five status shapes through settings, glyph rendering, control, and remote fallback.
- [x] Live shell from Ghostty command, preserving already-running daemon shell identity.
- [x] Snapshot failure readback and the quit-time daemon listing budget.
- [x] Coalesced title notifications without main-loop dispatch starvation.
- [x] Hidden clicked-page replacement, trailing punctuation, and reveal chord behavior.
- [x] YAML frontmatter rendering with the upstream Markdown assets.
- [x] Palette move actions resolve the current selection.
- [x] Adopt Ghostty v1.4.0, its toolchain pin, portable Linux adapters, and teardown patches.
- [x] Inherit authored cookbook updates and document Linux platform adaptations as needed.
- [x] Update Linux docs/site mirrors, bundled skill, CI pins, and curated release notes.

## Validation

- [x] Host-free Swift tests, including new upstream protocol/model/CLI coverage.
- [x] Linux package tests and Debug/Release builds with pinned toolchain.
- [x] Strict SwiftLint, actionlint/ShellCheck, whitespace, CLI drift, and core-boundary gates.
- [x] Focused real GTK/WebKit/control scenarios for all new capabilities and failure/disposal paths.
- [x] Rendering, font increase/resize, input, process lifetime, and control socket after Ghostty adoption.
- [x] Full GTK suite and native multi-instance remote page checks.
- [x] Local tar/DEB/RPM/Arch build, metadata, checksums, runtime closure, and clean package installation.
- [x] Review final downstream diff and confirm exclusions.
- [ ] Prepare exact branch/ref push gate, then green branch CI.
- [ ] Prepare full release notes and immutable `linux-v0.41.1` tag gate.
- [ ] After tag approval, verify published artifact set, checksums, and provenance.

## Validation commands

```sh
cd agtermCore && swift test --no-parallel
cd ../agterm-linux && swift test && swift build && swift build -c release
cd ..
swiftlint lint --strict --quiet
scripts/check-linux-core-boundary.sh v0.41.1
scripts/check-linux-cli-drift.sh
scripts/test-linux-ui.sh
make packages-linux VERSION=0.41.1
scripts/verify-published-linux-release.sh linux-v0.41.1 --require-arch
git diff --check
```

## Current evidence

- Exact stable upstream tag is merged by `cacb89a1`; the six later master commits remain excluded.
- Shared Swift package: 5,131 tests in 230 suites passed.
- Linux package: 631 Swift Testing tests plus the text/document XCTest suites passed.
- Debug and Release builds passed with Swift 6.3.2.
- Strict SwiftLint 0.65.0, actionlint, CLI drift, core boundary, resource/cache fixtures, architecture fixtures, and whitespace gates passed.
- The protected `ConfigPathsTests.swift` matches upstream exactly.
- Native text/search/diff/log operations, rotation and binary recovery, inert HTML, punctuation and path:line clicks passed.
- Default/compact sidebar geometry and info-row indentation passed in actual GTK layouts.
- Ghostty's included `command` selects fish over a password-database zsh and stays latched for the app run.
- Two native apps exchanged generated pages, assets, bridge calls, resize/hide/reload/close and companion groups over real SSH to a disposable sshd.
  Remote generated text and Markdown were inspected in rendered screenshots because this two-app WebKit setup exposes no AT-SPI subtree.
- Tar/DEB/RPM metadata, runtime closure and checksums passed.
  DEB and RPM installed and ran the CLI in clean Ubuntu 24.04 and Fedora 44 containers.
  Arch built and installed in clean Arch, then passed the installed GTK/WebKit scenario.
- All 72 scenarios in the final complete UI run passed.
  The final package set passed metadata, runtime-library closure and SHA-256 verification.
- Hidden workspace chevrons retain working Collapse/Expand Workspace menus with row-click expansion disabled.
  All five new status shapes were inspected in rendered GTK screenshots.
  Real snapshot write failure and successful-write recovery remain visible through Linux tree readback.
- Hidden clicked-page replacement passes for document, text and log pages after refreshing the embedded modifier-dependent link cache.
- EGL and GLX teardown traces pass with Ghostty 1.4's first-draw shader allocation.
  The checker's 42 regression tests still reject missing samplers and invalid ownership/deletion.
- GitHub's unit, lint, cookbook and Arch jobs passed on `feea9e22`.
  The GTK job completed builds and continued passing UI scenarios until its 45-minute job cap cancelled it.
  Its cold setup/build phase consumed about 24 minutes, so the job cap is now 75 minutes.
  Complete branch CI remains required before publication.

## Platform assessments

- Linux already records title callbacks synchronously and coalesces sidebar metadata with its GLib-backed debouncer.
  It has no macOS per-title main-queue backlog to port.
- Linux palette Move Session closures resolve the selected session at activation.
- Generated remote text is static; its native find bar is meaningful, while control search and file following are refused as upstream.
- GTK retains hidden-pane GPU resources because the render thread does not own its GL context.
  Final teardown is checked on the owning native EGL/GLX context.
- AppImage remains deliberately disabled by the maintained WebKit helper packaging constraint.
- Published checksums, attestations, protected branch updates and the immutable tag remain pending their publication gates.

## Local candidate commits

- `cacb89a1`: merge exact upstream stable release.
- `9ff2171d`: Ghostty 1.4, dual Zig toolchains, context ownership and embedded input handoff.
- `b8d3da4a`: Linux page, sidebar, status, shell and control parity with documentation and regression coverage.
