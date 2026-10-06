---
name: catch-up-and-release
description: Guide maintenance of the agterm-linux fork from upstream discovery through parity work and a verified Linux release. Use when asked to catch up, sync, or merge from umputun/agterm; audit or restore Linux feature parity; prepare, publish, rebuild, or verify a linux-vX.Y.Z release or Linux revision; or continue fork maintenance after a new upstream release.
---

# Catch Up and Release

Maintain `melonamin/agterm-linux` as a close Linux port of `umputun/agterm`.
Drive the workflow, show evidence at each checkpoint, and pause only at the consequential gates defined below.

## Preserve the Fork Contract

- Treat root `AGENTS.md` as authoritative, then read `README.md` and `ARCHITECTURE.md` before changing code.
- Keep `master` as the upstream-tracking branch and `linux-port` as the maintained downstream branch.
- Preserve upstream behavior and protocol shapes wherever Linux permits.
- Keep `agtermCore/` host-free and upstream-compatible.
- Put GTK/libadwaita, Glibc, Linux CLI, packaging, and platform-adapter work in Linux-owned paths.
- Prefer upstream shared implementations over downstream copies. Remove carried fixes once upstream contains them.
- Never make a downstream edit to `agtermCore/Tests/agtermCoreTests/ConfigPathsTests.swift`. If upstream changes it, accept the upstream file unchanged and verify there is no Linux-only diff.
- Never include unrelated worktree files. In particular, leave `site/_screenshot.png` alone unless the user explicitly selects it.
- Do not update `CHANGELOG.md` during ordinary parity work. Consider it only after entering the release phase.
- Treat `.claude/rules/release.md` as inherited macOS guidance. For Linux releases, the root fork policy, `README.md`, and `.github/workflows/release-linux.yml` take precedence.

## Use These Approval Gates

Continue autonomously through inspection, merging, implementation, testing, commits requested by the user, and review fixes.
Stop and obtain explicit approval immediately before:

1. pushing an updated `master` or `linux-port` branch;
2. any force-push or remote tag move;
3. creating or pushing a Linux release tag;
4. publishing user-authored release text or making a product/UX divergence from upstream.

Show the exact commits, refs, command, and validation state at each gate.
Never use a blind force push; use a narrowly scoped `--force-with-lease` only after approval.
Never move a tag once a GitHub release has been published from it.

## Phase 1: Establish Facts

Run all path-sensitive commands from the absolute repository root.
Do not assume the current branch, remote ownership, latest version, or a clean worktree.

1. Inspect `git status --short --branch`, branches, worktrees, remotes, tags, and recent commits.
2. Fetch `upstream` and `origin`, including tags, without mutating local branches.
3. Query GitHub with an explicit repository every time. Bare `gh repo view` may resolve to upstream:
   - upstream: `--repo umputun/agterm`
   - fork: `--repo melonamin/agterm-linux`
4. Identify:
   - the newest upstream stable tag reachable from `upstream/master`;
   - the newest upstream tag already contained in `linux-port`;
   - the newest `linux-v*` tag and fork release;
   - whether upstream has commits after the proposed release tag;
   - local commits or user changes that need preservation.
5. Read every matching file under `.claude/rules/` before touching its subsystem.

If the requested target is ambiguous, recommend the newest stable upstream release.
If `upstream/master` contains post-tag commits, ask whether to catch up to the exact release or to rolling master; do not silently ship unreleased upstream commits.

## Phase 2: Prepare the Toolchain

Derive tool versions from the Linux CI and release workflows rather than the host defaults.
The current pins are Swift 6.3.2 and SwiftLint 0.65.0.

Install and invoke them with mise:

```sh
mise install swift@6.3.2 swiftlint@0.65.0
mise x swift@6.3.2 -- swift --version
mise x swiftlint@0.65.0 -- swiftlint version
```

Also verify the native dependencies documented by `README.md`, `scripts/setup-linux.sh`, and the workflows.
Do not silently run privileged package installation.
If dependencies are missing, tell the user exactly how to install them for the detected distribution.
For Ubuntu 24.04, use the workflow package lists as the source of truth; release packaging additionally needs nFPM, linuxdeploy, its GTK plugin, ImageMagick, RPM tools, and cpio.

## Phase 3: Synchronize Upstream

Use the branch model documented in `README.md`:

1. Check that switching branches will not overwrite user changes. Do not stash, discard, or relocate them without approval.
2. Switch to `master` and fast-forward it to the chosen upstream commit. Use `upstream/master` for rolling parity or the exact upstream tag for a tag-bounded release.
3. Confirm the resulting `master` contains no downstream-only commit.
4. Present the branch push gate before updating `origin/master`.
5. Switch to `linux-port`, update it from `origin/linux-port` with `--ff-only`, then merge `master` with a normal merge commit when one is needed.
6. Resolve shared-core conflicts toward upstream unless a carried fix remains portable, necessary, and intentionally upstreamable.
7. Confirm the selected upstream tag is an ancestor of `linux-port` and the protected test file has no downstream diff.

If a portable core fix belongs upstream, isolate it on a dedicated upstream-PR branch with no Linux-only changes.
Keep local fork documentation, such as Linux or zsh requirements, out of that upstream branch.

## Phase 4: Build a Parity Inventory

Compare the last incorporated upstream tag with the target using commit logs, name-status diffs, and the upstream changelog.
Classify every meaningful upstream change into one of these buckets:

- shared host-free behavior to inherit directly;
- shared protocol, model, persistence, or CLI behavior needing Linux adapter work;
- user-visible macOS behavior needing a native GTK/libadwaita equivalent;
- macOS-only behavior with a documented Linux exemption;
- documentation, bundled agent-skill, CI, packaging, or release work.

Turn the inventory into a checked plan under `docs/plans/` when the catch-up spans multiple features.
Record the upstream range, exclusions, integration rules, validation commands, and platform limitations.
Move it to `docs/plans/completed/` only after all required work passes.

For each user-visible capability, audit all applicable surfaces:

1. shared model/controller behavior;
2. GTK GUI, action palette, menus, and keymap;
3. control protocol and dispatcher;
4. Linux-local `agtermctl` arguments and output;
5. control read-back for mutable state;
6. unit, CLI, integration, and realistic runtime coverage;
7. `plugins/agterm/skills/agterm/` and user-facing documentation.

Explicitly record why any surface is inapplicable.

## Phase 5: Restore Linux Parity

- Implement pure decisions, validation, response shapes, and static catalogs in `agtermCore` only when they are portable and upstream-compatible.
- Keep GTK objects, processes, windows, libghostty, and C-boundary glue in the Linux app.
- Copy C strings into Swift-owned values before crossing actors, queues, or callbacks.
- Keep GUI actions and the control channel synchronized. A state mutation also needs observable read-back.
- Use native GTK/libadwaita behavior and document real Wayland or toolkit constraints instead of fabricating parity.
- Update the bundled agent skill under `plugins/agterm/skills/agterm/` whenever commands, arguments,
  keymaps, or the window/workspace/session/pane model changes.
- Validate maintainer, reviewer, and Copilot suggestions before implementing them. Reproduce the claimed issue and check per-platform types or APIs; do not accept comments merely because they sound plausible.
- Keep commits narrow and reviewable. Do not mix upstream synchronization, unrelated cleanup, parity features, and release-pipeline fixes when they can be separated.

## Phase 6: Validate the Candidate

Start with fast gates and expand in proportion to the touched surface.
Use the repository scripts and workflows as the final source of truth.

```sh
cd agtermCore && mise x swift@6.3.2 -- swift test
mise x swiftlint@0.65.0 -- swiftlint lint --strict --quiet
scripts/setup-linux.sh
cd agterm-linux && mise x swift@6.3.2 -- swift build --product agtermctl-linux
cd agterm-linux && mise x swift@6.3.2 -- swift build --product AgtermLinux
cd agterm-linux && mise x swift@6.3.2 -- swift build -c release
git diff --check
```

Adapt the pinned versions if CI changes them.
Add focused control round trips and runtime checks from the parity inventory.
For visual acceptance, launch a development instance with a temporary `AGTERM_STATE_DIR` and separate control socket, then hand it to the user without driving their live state.

Before declaring parity complete:

- inspect the full downstream diff from the target upstream commit;
- verify Linux-only changes stay in approved boundaries;
- verify the protected test file has no downstream changes;
- run branch CI and inspect actual failing logs rather than relying only on check summaries;
- recheck unresolved maintainer review threads when the work belongs to a PR.

## Phase 7: Commit and Push

Before the push gate, report:

- target upstream version and merge commit;
- parity commits and deliberate exemptions;
- exact test, lint, build, manual, and CI results;
- current worktree status and explicitly excluded files;
- commits that will update each remote ref.

After approval, push the named branch normally.
If history was deliberately rewritten and the user approved it, fetch first and use `--force-with-lease` against the observed remote object.
Wait for Linux branch CI to finish and fix failures before release tagging.

## Phase 8: Prepare the Linux Release

Linux releases mirror the upstream version and use `linux-vX.Y.Z` tags from `linux-port`.
If Linux-only fixes must ship after that tag has been published and before the next upstream version,
use the next immutable `linux-vX.Y.Z+linux.N` revision tag.
Never move, replace, or delete the published upstream-matched tag to reissue it.

1. Confirm the release commit is already on `origin/linux-port`.
2. Confirm branch CI is green for that exact commit.
3. Confirm the proposed tag does not already exist locally or on `origin` and no fork release uses it.
4. Fetch the matching upstream GitHub release body with
   `gh release view vX.Y.Z --repo umputun/agterm --json body --jq .body`.
   Use the upstream release as the primary source and fall back to its matching `CHANGELOG.md` section only when the release body has no product notes.
5. Copy the upstream notes that describe shared or Linux-relevant product features and fixes faithfully.
   Omit macOS-only signing, notarization, Homebrew, DMG, and installation boilerplate, and omit any product item explicitly exempted by the Linux parity inventory.
6. Append a distinct `## Linux` section covering Linux-port fixes and platform adaptations, artifact formats, compatibility, verification, and the exact source commit.
   Do not mix downstream notes into the copied upstream section or describe an unverified feature as supported.
   Put curated Linux highlights in `packaging/linux/release-notes/vX.Y.Z.md` or, for a revision, `packaging/linux/release-notes/vX.Y.Z+linux.N.md`; do not add them to the shared `CHANGELOG.md`.
7. Generate and inspect the complete body with `scripts/write-linux-release-notes.sh` before the release gate.
   Confirm its upstream notes match `vX.Y.Z`, including when the release tag is a `+linux.N` revision.
8. Review Linux-specific README, packaging metadata, workflow pins, artifact names, compatibility claims, and generated release notes.
9. Build and verify the package set locally when the required tools are available:

```sh
make packages-linux VERSION=X.Y.Z
```

10. Present the release gate with the exact tag, commit, complete release notes, expected artifacts, and green checks.

After approval:

```sh
git tag -a linux-vX.Y.Z -m "agterm-linux vX.Y.Z"
git push origin linux-vX.Y.Z
```

The tag push must trigger `.github/workflows/release-linux.yml`; do not use the inherited macOS `scripts/release.sh`.

## Phase 9: Monitor and Verify Publication

Stay with the release until the workflow reaches a terminal state.
Use explicit fork targeting in all `gh` commands.

On success, verify:

- the GitHub release points to the intended tag and commit;
- tar, DEB, RPM, GTK-bundled AppImage, and consolidated SHA-256 files exist;
- downloaded artifacts pass `sha256sum --check`;
- GitHub attestations verify against `melonamin/agterm-linux`;
- archive/package metadata and runtime-library closure pass `scripts/verify-linux-packages.sh` or equivalent download checks;
- DEB and RPM install and execute `agtermctl --help` in clean compatible containers when a container runtime is available;
- the AppImage extracts and its bundled GTK4, libadwaita, libghostty, Swift runtime, resources, and CLI are present.

Report the public release URL, workflow run URL, tag object, source commit, artifact names, checksum result, and attestation result.

## Recover a Failed Release Safely

First determine whether the failure is reproducible without changing the tagged source.
Rerun the existing tag with `workflow_dispatch` when only infrastructure was transient.

If source or workflow fixes are required:

1. fix, validate, commit, and push `linux-port` through the normal push gate;
2. confirm no GitHub release was published from the failed tag;
3. show the old tag object, new commit, and exact lease-protected tag update;
4. obtain explicit approval before moving the remote tag.

Never move a published release tag.
Prefer a new version if any artifact or release became public or downstream users may have fetched the old tag.

## Finish with an Evidence-Based Handoff

Lead with the outcome.
Include the upstream range, parity status, platform exemptions, commits, pushed refs, release/tag/run URLs, validation evidence, and remaining work.
Mention protected or unrelated files that were intentionally left untouched when relevant.
