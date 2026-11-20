# Linux v0.43.0 catch-up and release

Target exact upstream `v0.43.0` (`be92bc63eca595a2955a0dc5c9a2b1e593e31a66`).
Base Linux release: `linux-v0.41.1` (`7f95d856d10df58d1d3964e1416d668aae721708`).
The upstream range is `v0.41.1..v0.43.0` (142 commits).
The 23 later commits on upstream/master are excluded at the user's request.
Preserve all other branches and worktrees.

## Integration rules

- Prefer upstream's portable implementations and remove superseded downstream copies.
- Preserve the GLib main-loop scheduling/hop seams and GTK HUD rendering.
- Keep host effects in Linux adapters and preserve upstream wire shapes.
- Keep `ConfigPathsTests.swift` identical to the selected upstream tag.
- Treat GUI, palette, keymap, control, readback, CLI and bundled skill as one feature surface.
- Do not change shared release notes outside the upstream merge.
- Obtain explicit approval before branch pushes, release tag creation/push, or product divergence.

## Parity inventory

- [x] Merge exact stable tag and reconcile portable downstream fixes.
- [x] Shared model/protocol/CLI changes, state/socket lock inheritance, command quoting, new-session directory and navigation by position.
- [x] Headless agterm-server build, process lifecycle, mailbox, page rows, control and packaging.
- [x] Remote catalog windows, server and GUI origins, catalog receipts, detach/reattach and saved view state.
- [x] Remote session creation, structural actions, restart/terminate/undo/recent, attached-session persistence and page/link forwarding.
- [x] Presenter election, per-pane recipients, migrating asks/pickers/pages, picker session targets and ask/pick deadlines.
- [x] Live scratch persistence and scratch working-directory readback.
- [x] Companion conversion, reparenting, GUI drag/menu actions and control readback.
- [x] Top-level HTML/URL page sessions, restore/recent and remote attach.
- [x] Markdown contained local-link navigation and remote link pages.
- [x] Text/log terminal colors, wrap, diff file navigation and JSONL expansion, GUI/control/readback.
- [x] Session links, local HTTP address routing and link previews.
- [x] Notification badge reset preference and physical-input semantics.
- [x] Checkmark status shape, per-pane active status and folded companion urgency.
- [x] Codex home resolution, hook payload parsing, executable/config permissions and Claude background work status.
- [x] Native rendering/resize/input/teardown against the unchanged Ghostty 1.4 pin and updated zmx patches.
- [x] Linux docs, bundled skill, CI boundary pins, CLI drift and final downstream-boundary audit.

## Platform assessments

- Sparkle, Apple signing/notarization, Homebrew and macOS update chrome belong to the macOS host.
  Linux distribution packages retain their package-manager update mechanism.
- AppKit layout locking, macOS 27 session-host responsibility and launchd jobs have no GTK/systemd equivalent to copy.
  Linux continues to use its native zmx lifecycle.
- Preserve GTK's established window-placement, global-shortcut and hidden-pane GPU limitations.
- Preserve the maintained tar/DEB/RPM/Arch release formats.
  AppImage remains disabled under the existing WebKit helper constraint.

## Validation

- [x] Shared Swift tests with Swift 6.3.2.
- [x] Linux CLI, GTK Debug and Release builds, Linux package tests.
- [x] Strict SwiftLint 0.65.0 and whitespace checks.
- [x] Architecture, core boundary, CLI drift, resources and vendor-cache gates.
- [x] Real isolated GTK/WebKit/control coverage of new and changed features.
- [x] Real SSH/headless-server and multi-instance workflows.
- [x] Full GTK suite and Linux packages, metadata/runtime closure and clean-container installation.
- [x] Review complete downstream diff and protected test equality.
- [x] Commit and push the candidate and merge reviewed PRs #61 and #62 with user approval.
- [x] Inspect exact-commit branch CI for the combined release candidate.
- [x] Prepare and inspect full release notes, artifact set and immutable release-tag gate.
- [x] Verify published artifacts, checksums and attestations after approval.

## Validation commands

```sh
cd agtermCore && swift test --no-parallel
cd ../agterm-linux && swift test && swift build && swift build -c release
cd ..
mise x swiftlint@0.65.0 -- swiftlint lint --strict --quiet
scripts/check-linux-core-boundary.sh v0.43.0
scripts/check-linux-cli-drift.sh
scripts/test-linux-ui.sh
make packages-linux VERSION=0.43.0
scripts/verify-published-linux-release.sh linux-v0.43.0 --require-arch
git diff --check
```

## Environment

The Omarchy host lacks WebKitGTK 6.0.
Mise's Swift 6.3.2 UBI9 fallback cannot load the host's libraries.
Use the CI-pinned `swift:6.3.2-noble` container with the workflow's native dependency list for local validation.
Keep build logs, caches and temporary data on persistent disk under `/mnt/bulk/agterm-catch-up-20261119`.

## Initial candidate evidence

- Shared package: 6,895 tests in 323 suites pass with Swift 6.3.2.
  Real zmx/fish lifecycle requirements were enabled.
  The subsequent detached-launch option preserves the default path and passes all 33 ZmxSupport tests.
- Linux package: 635 tests in 92 suites pass.
  Debug and Release/WMO builds pass.
  Strict SwiftLint 0.65.0, whitespace, core boundary, CLI drift, vendor caches and deterministic resources pass.
- Real GTK coverage includes contained Markdown navigation/history, JSONL controls, session asks/pickers and deadlines,
  companion conversion/reparenting, per-pane activity, and scratch directory readback.
  A Live scratch's PID and screen survive hiding and relaunch, and session close ends it.
- Real SSH covers 20 headless-origin catalog rows under stock sshd channel limits, operation receipts,
  detach/reattach, terminal/page attachment restoration, attached split/scratch/terminate,
  streamed text search/log append/pause, file-page assets/bridge/state, and loopback HTTP forwarding to a distinct local port.
- A GTK Live origin serves catalog snapshots and create/rename/close receipts over both real SSH and the local transport fixture.
  A background command starts without changing the origin selection, retains its PID when the origin widget realizes,
  and ends with its session.
- All four rebuilt tar/DEB/RPM/Arch artifacts pass metadata, SHA-256 and runtime-closure checks.
  Fresh Ubuntu 24.04 and Fedora 43 containers install the packages with their declared dependencies and execute
  both CLI help and server-installer help.
  The Arch package builds, installs and passes the installed GTK/WebKit scenario.
  The libcurl dependency is declared for every package, and the release container now provisions zstd for Arch extraction.
  The packaged upstream version and server SHA-256 pins match the exact v0.43.0 metadata.
- The expanded GTK run passed 76 of 77 scenarios.
  Its only failure exposed stale GDK Ctrl state when committing Ctrl-Tab from an entry.
  The fix passes the full entry scenario and the separate two-Ctrl/pre-held-Ctrl scenario.
  The final feature-specific GUI scenario additionally proves pointer-drag companion reparenting and selected-disclosure contrast.
  The combined real-SSH acceptance scenario passes two-viewer handoffs, owner loss, pages, mail, history,
  remote session-link previews/clicks, attached restart, palette creation and catalog operations.
  A native origin-window picker also selects the second of several real Live GTK windows over SSH.
- The protected ConfigPaths test equals v0.43.0, and macOS application sources equal the selected tag.
  The unrelated site screenshot and all other worktrees are unchanged.
- The headless server systemd installation was not run on the host.
  Installer tests verify the pinned v0.43.0 archive and refuse tampered bytes before unpacking.

Local validation artifacts live under `/mnt/bulk/agterm-catch-up-20261119`.
The catch-up is complete; final branch CI and publication evidence are recorded below.

## Local integration commits

- `ac92b931`: merge exact upstream v0.43.0 with the GTK parity adapters and portable callback seams.
- `8dc06e03`: declare libcurl in Linux packages and verify the dependency metadata.
- `0676a404`: update exact-tag CI pins and require real headless-server lifecycle coverage.
- `8931f8c4`: provision zstd for Arch package verification.
- `f04e68f4`: use unique short socket-only runtime directories and clean up repeatable real-SSH fixtures.

`origin/master` already points to `be92bc63eca595a2955a0dc5c9a2b1e593e31a66` with approval.
Before this catch-up, `origin/linux-port` pointed to `7f95d856d10df58d1d3964e1416d668aae721708`.
Acceptance fixes were committed as `41bb1a89` and pushed to `origin/linux-port` with user approval.
PR #61 merged as `e876da44`; PR #62 merged as `27d7cdf9`.
Exact-commit hosted CI passed, the user approved publication, and the public artifacts and attestations are verified below.

## Acceptance follow-up

The user's deeper GUI audit found nine Linux adapter gaps after `50cdbbc1`:

- Defer terminal link selection until libghostty releases its callback locks.
- Populate an attached terminal's origin session ID at creation.
- Add companion conversion and reparenting to the row menu.
- Route cross-group companion pointer drops through the shared reparent resolver.
- Resolve Scratch-relative links against Scratch's reported directory.
- Resolve remote link previews with the clicked pane identity.
- Paint selected companion disclosures with the selection foreground.
- Include attached-origin undo records in the palette, refresh arriving receipts, and prefer the newest local or origin close.
- Trust observed Ctrl transitions when GDK's cached modifier state lags the release.

All changes stay in Linux adapters, tests and documentation.
No protocol, keymap format or shared model shape changed.
The existing control commands cover the new row-menu/drop wiring; purely visual disclosure paint needs no extra control command.
The bundled agent skill therefore needs no command/model update.
Host state, live user sessions, the protected shared test, macOS sources and other worktrees are preserved.

Final acceptance logs and package artifacts are under `/mnt/bulk/agterm-catch-up-20261119/acceptance-final-*`.
The 6,895 shared tests remain applicable because this follow-up changes no shared code.
Before the two PR merges, the Linux package passed all 635 tests, Debug/Release builds, strict lint, CLI drift and boundary checks.
The tar/DEB/RPM payload was rebuilt after the fixes; the matching Arch package builds, installs and passes its real GTK scenario.
The host's systemd user-service installation remains unexecuted.

## Open PR review

All three open fork PRs were inspected at their exact current heads.
PR #61 (`83c478772968bdda48faba99ffdb291681615f2d`) is recommended for merge:
637 Linux tests and strict lint pass in an isolated checkout, and a real GTK status hook finds a private
`~/.local/bin` helper while the current branch fails that same lookup.
PR #62 (`50e8ee67dd2238a04b766497ba83afd0141fc0f0`) is recommended for merge:
both ImageMagick 6 and 7 render all seven icon sizes with transparent corners, visual inspection passes,
and the PR's actual tar/DEB/RPM build and verification scripts pass.
PR #1 remains the explicitly unmerged Linux-port tracking draft.
The user subsequently approved both merges; their patches are now on `linux-port`.
No review comment or PR edit was posted.

## Combined release validation

Both approved PRs are merged and the v0.43.0 upstream and Linux release notes are committed in the repository.
The combined branch passes all 637 Linux tests, Release builds, strict lint, boundary and CLI drift checks.
The real-SSH two-viewer scenario also passes after both merges.
Tar, DEB, RPM and Arch packages pass payload and runtime checks; clean Ubuntu and Fedora installs execute the CLI.

The first hosted branch run failed only in `CodexStatusHookTests` because the Swift container lacked `jq`.
Removing `jq` locally reproduces the same 22 issues across 26 tests; restoring it passes all 26 tests.
Both CI test environments now install the hook's Linux JSON dependency, matching the release workflow.
DEB, RPM and Arch packages also declare `jq`, and package verification requires that declaration.
Tar users' documented runtime requirements include it.
All 77 GUI scenarios and hosted branch CI pass for source commit `9e140da63ef790a5b20f54088e61f8b6b31f9206`.

## Published release

The user approved publication and requested credits for every contributor.
Release: https://github.com/melonamin/agterm-linux/releases/tag/linux-v0.43.0
Source commit: `9e140da63ef790a5b20f54088e61f8b6b31f9206`.
Annotated tag object: `872dd30047992d332a0f26388e7cc73fd0f070c5`.
The release preserves exact upstream v0.43.0 and excludes later upstream commits.

Branch CI: https://github.com/melonamin/agterm-linux/actions/runs/44655644889
Release workflow: https://github.com/melonamin/agterm-linux/actions/runs/44661694738
Both runs completed successfully.
The release run passes 6,895 shared tests, 637 Linux tests, 9 required bundled-runtime lifecycle tests,
all 77 GTK GUI scenarios, lint, boundary checks, and Debug/Release builds.

The published assets are:

- `agterm-linux-v0.43.0-x86_64.tar.gz`
- `agterm-linux-v0.43.0-x86_64.deb`
- `agterm-linux-v0.43.0-x86_64.rpm`
- `agterm-linux-bin-0.43.0-1-x86_64.pkg.tar.zst`
- `agterm-linux-v0.43.0-SHA256SUMS`

All five assets were downloaded independently from the public release.
The checksum manifest passes for all four packages, and GitHub build-provenance attestations verify for all five assets.
Downloaded payloads pass package metadata, declared dependencies and runtime-library closure checks.
The tar payload records the expected source commit.
Fresh Ubuntu 24.04 and Fedora 43 containers install the public DEB/RPM, execute CLI and server-installer help,
and run the installed Codex hook through question detection, background-event suppression and foreground status.
The publication job also builds, installs and exercises the exact Arch package before publishing it.

The public release body credits every GitHub author in `linux-v0.41.1..linux-v0.43.0`:
@umputun, @melonamin, @alexandru-savinov, @valeronm, @arogulin, @fAntel, @maxshevelev,
@vnazarenko, @NaikSoftware, @nkt, @pySilver, @Romancha, @bot-rogerthat, @sysradium and @megabyde.
Recorded Claude Opus 5.5 co-author credit is also acknowledged.
The published body was read back and checked against the complete prepared notes and contributor inventory.

AUR publication skipped because `AUR_SSH_PRIVATE_KEY` is not configured.
The verified Arch package is available directly from the GitHub release.
AppImage and host systemd installation retain the limitations documented above.
The protected shared test, unrelated screenshot, host sessions and other worktrees remain unchanged.

Final publication evidence is under `/mnt/bulk/agterm-catch-up-20261119/published-*`.
