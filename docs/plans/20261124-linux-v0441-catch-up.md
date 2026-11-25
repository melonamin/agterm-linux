# Linux v0.44.1 catch-up and release

Target exact upstream `v0.44.1` (`f37a8a2fcc01a626bed2c114a590bb97ced8d328`).
The incorporated upstream base is `v0.43.0` (`be92bc63eca595a2955a0dc5c9a2b1e593e31a66`).
The downstream starting point is `984861cdd5cd8a1338d8640c1d597b6fddbc34c3`, including PRs #63 and #64.
The user selected the stable release and excluded the 24 later commits on upstream/master.
Preserve other branches, worktrees, live application state, and unrelated screenshots.

## Integration rules

- Keep upstream protocol, persistence, models, and shared CLI implementations.
- Preserve portable GLib timer and callback seams; GTK does not drain the main-actor executor.
- Keep process, clipboard, display, terminal, URI-handler, and packaging effects in Linux adapters.
- Keep the protected ConfigPaths test identical to the selected upstream tag.
- Preserve the Linux CI jobs and PR #63's explicit token permissions.
- Preserve PR #64's process and empty-output leak fixes and regression scenario.
- Audit GUI, palette, keymap, control, read-back, CLI, tests, and bundled documentation together.
- Obtain approval before pushing maintained branches or creating/pushing the release tag.
- Preserve the published v0.43.0 tag and use a new immutable v0.44.1 release tag.

## Parity inventory

- [x] Merge the exact tag and reconcile carried portable fixes.
- [x] Inherit host-free model, persistence, protocol, server, shared CLI, and regression changes.
- [x] Render and manipulate root sessions outside named workspaces through GTK, palette, keymap, control, and restore.
- [x] Support companion promotion and nesting through pointer drops, Move to, Move Under, and control commands.
- [x] Follow origin companions on attached top-level rows and expose the shared read-back.
- [x] Honor named workspace placement for remote attachment and preserve remote argument forwarding.
- [x] Run configured file-opening rules for detected paths, including bounded remote snapshots and opener events.
- [x] Paste/drop files, folders, text, and images consistently, copying remote inputs before inserting paths.
- [x] Register and route external agterm session links through cold and warm native launches.
- [x] Preserve image-page bytes and reload errors and adopt the text-search rendering optimization.
- [x] Reveal hidden overlays when opening configuration editors.
- [x] Capture Live commands per daemon from the kernel without a serial zmx inventory dependency.
- [x] Reclaim saved and dropped leads and preserve reconnect command/cover behavior.
- [x] Hold command startup until attachment, preserve wait policy, and publish late restart confirmations.
- [x] Upgrade zmx to v1.0.1 with Zig 0.17, updated patches, baseline CPU, cache checks, and old-daemon compatibility.
- [x] Adopt bounded-file rejection and shared server stack/lifecycle fixes.
- [x] Update Linux documentation, bundled skill, exact upstream CI pins, packaging, and server archive pins.
- [x] Audit the complete downstream diff and protected-file equality.

## Platform assessments

- AppKit saved-state, Apple log commands, macOS window lifecycle, signing, notarization, Homebrew, and DMG behavior are host-specific.
  Preserve native GTK startup and provide useful Linux launch diagnostics where applicable.
- Linux retains package-manager updates and its existing Wayland/window-placement and global-shortcut limitations.
- Preserve the maintained tar, DEB, RPM, and Arch artifact set.
  AppImage remains excluded by the existing WebKit helper packaging constraint; this catch-up does not claim AppImage support.
- New shared state and user actions require their corresponding GUI and control surfaces.
  Pure diagnostic logging and visual styling require no new control command.

## Validation

- [x] Swift 6.3.2 shared tests and required real zmx/fish lifecycle fixtures.
- [x] Linux package tests, CLI, GTK Debug, and Release/WMO builds.
- [x] Strict SwiftLint 0.65.0 and whitespace checks.
- [x] Boundary, CLI drift, architecture, deterministic resources, and runtime cache checks.
- [x] New-feature GTK/control tests with isolated state and representative files and remote fixtures.
- [x] Full GTK suite and real SSH/headless/GUI-origin workflows.
- [x] Package metadata, closure, clean-container installation, and artifact checksums.
- [ ] Exact-commit hosted branch CI after approved branch pushes.
- [ ] Complete release notes and immutable release-tag approval gate.
- [ ] Published artifacts, checksums, attestations, and release source identity after approved publication.

## Validation commands

```sh
cd agtermCore && AGTERM_REQUIRE_ZMX=1 AGTERM_REQUIRE_FISH=1 swift test --no-parallel
cd ../agterm-linux && swift test && swift build && swift build -c release
cd ..
mise x swiftlint@0.65.0 -- swiftlint lint --strict --quiet
scripts/check-linux-core-boundary.sh v0.44.1
scripts/check-linux-cli-drift.sh
scripts/test-linux-ui.sh
make packages-linux VERSION=0.44.1
scripts/verify-published-linux-release.sh linux-v0.44.1 --require-arch
git diff --check
```

## Environment

The host is Omarchy/Arch.
Mise's Swift 6.3.2 installation selects a build requiring unavailable libncurses/libform/libpanel and Python 3.9 libraries.
Use the existing CI-pinned Swift 6.3.2 Noble container for native dependency compatibility.
SwiftLint 0.65.0 and Zig 0.17.0 are installed through mise.
Keep temporary data and logs under `/mnt/bulk/agterm-v0441-task`, and build in the isolated persistent worktree.

## Initial checkpoint

Local master is fast-forwarded to the selected tag; no remote branch or tag has been pushed.
The isolated merge initially had nine conflicts across carried callback/CLI adapters, CI, and documentation.
Release text, tags, and publication remain pending.

The initial shared test suite passes 7,190 tests in 335 suites.
The Linux Debug app builds after the root-session and companion-promotion routing additions.
zmx v1.0.1 builds with the exact upstream v0.44.1 patch series and Zig 0.17.0.
Its full compatibility script passes against a Linux build of the exact upstream v0.44.0 zmx patch series.
Against the shipped v0.43.0 daemon, explicit claiming, typing, reads, printing, and shutdown pass.
That older daemon lacks the new reclaim handshake; the script's reclaim expectation and the grid assertion dependent on it fail.
Preserve that distinction when stating upgrade compatibility.

## Local candidate evidence

The merge commit is `683ebc29949d8c2c460b9c9f7dab8e49113b5b5a`.
Runtime and release pins are in `a2d5a6c2`; Linux parity is in `4c71d2b5`.
The GTK origin-history regression fix is `d5999b9f`.
The Arch test runner keeps temporary data on the persistent bind mount in `5e9dec60`.

- Shared Swift tests: 7,190 tests in 335 suites pass, including required real zmx and fish fixtures.
- Linux Swift tests: 648 tests in 95 suites pass after the origin-history fix.
- Debug app/CLI and Release/WMO builds pass with Swift 6.3.2.
  Strict SwiftLint 0.65.0 passes.
- The broad GTK run passes 75 scenarios initially.
  Its four failing fixtures are corrected and their focused reruns pass: session drag, workspace drag,
  multiselect, and shell-escaped file clipboard paste.
  The first three ignore only the implicit empty root, preserving assertions about unexpected root sessions.
  The clipboard check verifies two distinct shell arguments and keeps OSC 52 raw-read assertions unchanged.
- The new v0.44.1 runtime scenario passes with root placement, nesting/promotion, cold/warm URI handling,
  real detected-path openers, clipboard images, and a visibly rendered 48 MB PNG.
  It also checks theme changes, persistent reload failure, and recovery after restoring the file.
- Real SSH v0.44.1 acceptance passes named workspace placement, companion baselining/following,
  terminal/page additions and moves, selection preservation, duplicate prevention, remote paste,
  and byte-checked remote opener staging.
- Real SSH GUI-origin v0.39.1 and headless-origin v0.43.0 regressions pass.
  Real SSH two-viewer acceptance passes asks, pickers, pages, history, content navigation, restart,
  new remote sessions, catalog windows, and attached split/scratch/terminate.
- GTK's palette supplies the origin Recent Closed action that macOS exposes through its menu.
  Its Linux enablement adapter preserves that native route while shared macOS predicates stay unchanged.
- The stopped-daemon capture regression passes without any zmx inventory request.
- zmx tests report 66/66 successful build steps, 151 passed tests, and one Linux pty skip.
  The expected negative-test warnings do not indicate a failed build.
- The exact v0.44.0 daemon compatibility checker passes.
  The shipped v0.43.0 daemon supports basic claim/type/read/print/shutdown but lacks the new reclaim handshake.
- Both upstream v0.44.1 server archive hashes match their pinned manifests.
- Tar, DEB, RPM, and Arch metadata, runtime closure, resources, and consolidated checksums pass.
  Clean Ubuntu 24.04 and Fedora 43 containers install their packages and execute both CLI help paths.
  Arch builds and installs the package, then passes the installed GTK/WebKit/resource smoke scenario.
- Core boundary, CLI drift, x86_64/aarch64 ELF checks, deterministic resources, cache rejection checks,
  actionlint, and whitespace checks pass.
- Full downstream path audit retains the Linux boundary; macOS app and hosted/UI test sources are unchanged.
  The new core delta consists of portable timer/callback seams and public argument parsers.
  The protected ConfigPaths test matches upstream exactly; the screenshot and downstream changelog are untouched.

Logs and runtime artifacts are retained under `/mnt/bulk/agterm-v0441-task`.
The maintained-branch push, exact-commit hosted CI, release tag, release text publication,
and downloaded artifact/attestation checks remain pending their explicit gates.
Do not move this plan to completed until those release steps pass.
