# Linux v0.44.1 catch-up and release

Target exact upstream `v0.44.1` (`f37a8a2fcc01a626bed2c114a590bb97ced8d328`).
The incorporated upstream base is `v0.43.0` (`be92bc63eca595a2955a0dc5c9a2b1e593e31a66`).
The downstream starting point is `984861cdd5cd8a1338d8640c1d597b6fddbc34c3`, including PRs #63 and #64.
The user selected the stable release and excluded the 24 later commits on upstream/master.
Preserve other branches, worktrees, live application state, and unrelated screenshots.

The user resumed the release on 2026-11-25 after the additional feature audit and fixes.
The new instruction authorizes continuing branch publication and the release after current validation passes.
No `linux-v0.44.1` tag or release has been created yet.
The maintained branches contain candidate `8162c363`; the isolated branch carries audit fixes `6baaa886` and `c442fce7`.

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
The earlier approved maintained-branch pushes and exact-commit hosted CI are complete for `8162c363`.
The additional audit fixes need a separate maintained-branch push and fresh hosted CI before release preparation.
The release tag, release text publication, and downloaded artifact/attestation checks remain pending their explicit gates.
Do not move this plan to completed until those release steps pass.

## Additional feature audit and fixes

The feature audit compares the published `linux-v0.43.0` binaries with the exact v0.44.1 candidate.
It covers GUI, keymap, control/read-back, persistence, actual transfers, real SSH origins and two-viewer lifecycle behavior.
The audit exposed four Linux adapter gaps and a large-log search problem also present in the previous release.
All five have focused regressions and fixes:

| Finding | Fix and regression |
| --- | --- |
| Live `--wait` disappears after config reload | Reassert exit policy even without a watermark; a gated command exits zero and retains first/final output after reload. |
| Takeover refused during disconnected retries | Queue API/key claims until the role report, preserve intent across failed attempts and late held-exit callbacks; two real viewers independently test API and keyboard takeover after the other viewer types. |
| Bare Recent Closed reopens unrelated origin history | Resolve attached history before catalog routing, refuse a remote destination and pin the local destination before SSH; explicit catalog requests retain their origin history route. |
| Empty companion cwd becomes a misleading version error | Reuse the portable argument encoder for cwd, command and name; empty values and dash-prefixed arguments are exercised against the shipped upstream server/CLI/zmx. |
| Large-log keyboard search stops at a partial query | Keep whole-document match counts while painting only viewport highlights; real keyboard typing, followed appends, scrolling and distant navigation exercise 5,001 matches. |

The renderer change is a portable WebKit optimization in the existing shared resource.
It keeps StaticRange highlights and the existing safety cap, coalesces scroll/resize repainting with animation frames,
and refreshes after wrapping without adding an idle polling loop.
The macOS renderer assertion now checks bounded painting and inclusion of the navigated match.
It cannot be executed on the Linux validation host.

Five local audit scenarios join the default GTK suite: `v0441-audit-gui`, `v0441-audit-live`,
`v0441-audit-transfers`, `v0441-audit-pages`, and `v0441-audit-capture`.
The window-activation fixture matches both process ID and title so identically titled viewers cannot mask keyboard failures.
`AGTERM_ATSPI_SCENARIOS` selects a comma-separated subset of the default suite for bounded batches.
Unknown scenario names are rejected; each batch still runs the script's resource, teardown and app-log guards.
Real-SSH extensions use the existing `AGTERM_TEST_SSH_CONFIG` fixture and the following environment:

```sh
AGTERM_ATSPI_SCENARIO=v0441-remote AGTERM_AUDIT_REMOTE=extended scripts/test-linux-ui.sh
AGTERM_ATSPI_SCENARIO=v0441-remote AGTERM_AUDIT_REMOTE=lead scripts/test-linux-ui.sh
AGTERM_ATSPI_SCENARIO=v0430-viewers scripts/test-linux-ui.sh
```

Optional `AGTERM_TEST_ORIGIN_SERVER`, `AGTERM_TEST_REMOTE_CLI`, and `AGTERM_TEST_ORIGIN_ZMX` select the exact shipped bundle.
The explicit upgrade scenario takes `AGTERM_AUDIT_BASELINE` pointing to the extracted published v0.43.0 payload.
These real-SSH and archived-release fixtures are intentionally separate from the self-contained default suite.

Final local validation:

- 7,190 shared tests in 335 suites and 650 Linux tests in 96 suites pass.
- Debug and Release/WMO builds, strict SwiftLint 0.65.0, exact-v0.44.1 core/protected-file checks,
  CLI drift, JavaScript syntax and whitespace checks pass.
- The staged Release payload starts its CLI and passes real keyboard search, followed append,
  scrolled highlight coverage and distant navigation using its staged renderer resources.
- Real SSH extended controls, independently deferred API/key takeover, existing two-viewer regressions,
  delayed restart publication and the actual published-v0.43.0 process upgrade pass.
- All 84 default GTK scenario bodies pass in the aggregate run, whose outer runner subsequently exits 143.
  Three disjoint 28-scenario batches rerun all assertions and postflight guards.
  Two batches exit zero; the other passes 27 scenarios and fails an existing custom-command launch-toast assertion.
  That scenario passed in the aggregate run and passes its isolated rerun with exit zero and unchanged assertions.
  The intermittent toast failure and the aggregate shutdown status remain validation limitations, not proven product regressions.
  Do not describe this as a clean single aggregate runner exit.
- GTK verification is isolated Xvfb/X11 with software rendering; Wayland and macOS execution remain unverified.
  The aarch64 server archive is hash-checked but has not executed on aarch64 hardware.

Current logs and screenshots are retained under `/mnt/bulk/agterm-v0441-feature-audit`.
The original feature matrix and failure evidence remain in that directory's `report.md`.
The earlier release gate remains historical; the resumed release requires fresh exact-commit CI and rebuilt packages.

### Resumed release CI investigation

Hosted run `45650380070` on `5b3b11a8` passes shared and Linux unit tests, lint, Debug/Release builds,
and 83 GTK scenarios, but the startup-query fixture receives its DSR response without finding its final output marker.
No tag is created from this failed run.
The failure does not reproduce in repeated unprivileged/root cold launches or two 100-query stress runs with CI-length temporary paths.
Application code is unchanged because the evidence does not establish a product fix.
The fixture now runs five rapid startup/exit queries with the original response and output assertions,
and preserves the failed row, visible text, scrollback, DSR bytes and screenshot if it fails again.
Fresh exact-commit CI remains required before tagging.

Hosted run `45659129555` on `75e53c36` passes all five startup-query repetitions and 83 GTK scenarios.
Its sole failure is the GUI audit's context action after dragging a companion.
The uncalibrated container-center click does not establish that the intended row's menu opened.
Ten isolated original-path repetitions pass under a two-CPU root container, so no product defect is established.
The audit now targets the name label, uses the existing bounded sidebar pointer calibration,
and verifies that the intended session owns the open menu before checking its required action.
A correct menu missing the action still fails without retrying that assertion.
Failures retain model, accessibility and screenshot diagnostics.
Ten calibrated GUI repetitions pass with all assertions and postflight guards under a two-CPU root container.
Application code remains unchanged; the test correction requires fresh exact-commit CI before release tagging.

### Release-run exit races

Branch CI `45670569018` passes all 84 GTK scenarios, so immutable tag object
`390ab92f3a0449da60021158a15bc37625a04e38` is created at `d767443a`.
No GitHub release is published.
The maintained workflow gains bounded toolchain downloads, compatible gzip runtime-cache use,
and a 75-minute build budget in `5e0cc634` after two infrastructure-limited release attempts.

Release run `45688798218` confirms that cache fix but exposes two intermittent command-exit races.
Both now have deterministic baseline failures and fixed-path regressions:

- A real `POLLIN|POLLHUP` event loses the fast command's final bytes in libghostty.
  The Linux patch drains readable data before EOF; replacing only the library fixes the regression.
- A synchronous daemon read races its socket disappearing before the held-exit callback runs.
  The Linux adapter retires only a confirmed ended, uncovered held lead and preserves live/unresponsive and reconnecting error paths.
  Both text-first and cursor-first exit reads pass; a stopped live daemon keeps its error and lead.

Local validation passes 7,190 core tests with the release's serial command, 650 Linux tests,
Debug/Release builds, strict lint, 12 native GTK scenarios and the deterministic exit regressions.
Real SSH takeover, extended controls, two viewers and a published-v0.43.0 process upgrade also pass.
The local parallel-fixture and overlong-TMPDIR limitations are recorded in `docs/ci-flakes.md`.
The new source still needs exact-commit hosted CI and package verification.
Present a concrete unpublished-tag move gate only after those pass; never silently repoint the existing tag.
