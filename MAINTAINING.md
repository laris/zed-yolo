# Maintaining the laris/zed-yolo fork

> **Purpose of this document.** This is the long-term operating manual for the
> `laris/zed-yolo` fork of [zed-industries/zed][upstream]. It documents what we
> carry on top of upstream, how to upgrade to a new upstream version, how to
> verify the result, and how to contribute fixes back. Future maintainers
> (including future-you) should read this end-to-end before any upstream
> bump.

[upstream]: https://github.com/zed-industries/zed

---

## 0. Authoritative operating policy

This fork is maintained from **one local partial clone**:
`/Users/lqiao/dev/codes/zed-yolo`. A full clone of upstream is not needed
for routine upgrades or provider synchronization.

The legacy full clone at
`/Users/lqiao/dev/codes-repos/gh-zed-industries__zed` was removed on
2026-07-01 after its worktree, branches, tags, provider parity, and editor
references were verified. It is not a dependency of this workflow.

The normal checkpoint is the end of upstream's Friday workday. Because this
workstation uses Asia/Shanghai time, run the checkpoint on **Saturday at or
after 16:00 CST**, which safely covers Friday 23:59 in
America/Los_Angeles during daylight-saving time. The assumption that upstream
usually pauses on weekends is only a scheduling heuristic, not a guarantee.
Security fixes, urgent hotfixes, and releases published after the checkpoint
must be handled immediately or at the next checkpoint.

At each checkpoint:

1. Mirror every newly published upstream release tag since the prior
   checkpoint, not only the newest tag.
2. Select the newest non-draft `vX.Y.Z-pre` or `vX.Y.Z` GitHub Release as the
   new `enhanced` baseline. Use GitHub's `published_at` timestamp; do not rely
   on lexicographic tag sorting.
3. Snapshot upstream `main` at the checkpoint and fast-forward the fork's
   `main` to it. `enhanced` remains based on the selected release tag, not on
   the possibly newer `main` snapshot.
4. Rebase and validate the fork-only commits on the selected release tag.
5. Publish only the changed refs to GitHub and then CNB, one explicit ref at a
   time.
6. Prove exact all-head/all-tag parity between `laris/zed-yolo` and CNB
   `zed-yolo`.

Two different guarantees must not be confused:

- **Release coverage:** every upstream release tag published by the checkpoint
  exists on GitHub and CNB with the same tag-object SHA.
- **Provider parity:** every branch and tag currently present in `laris/zed-yolo`
  has the same ref-object SHA in CNB `zed-yolo`.

This policy does **not** claim that CNB continuously mirrors every live
upstream feature branch. CNB is a release-aligned union mirror and may lag
upstream between Friday checkpoints by design. Existing historical upstream
branches can remain on both providers, but routine maintenance neither fetches
nor updates those ephemeral branches.

All commands below assume:

```bash
REPO=/Users/lqiao/dev/codes/zed-yolo
SYNC_TOOLS=/Users/lqiao/.codex/skills/audit-clean-sync-repo/scripts
GH=$SYNC_TOOLS/run_github_proxy.sh
CNB=$SYNC_TOOLS/run_cnb_git_no_keychain.sh
CNB_API=$SYNC_TOOLS/run_cnb_no_proxy.sh
cd "$REPO"
```

- `$GH` is mandatory for every GitHub API, Git, SSH, Cargo/Git dependency, or
  lazy partial-clone fetch; it routes traffic through `127.0.0.1:10808`.
- `$CNB` and `$CNB_API` are mandatory for CNB and always bypass proxies.
- Never read CNB credentials from macOS Keychain. Do not use `cnb-rs` for this
  large repository while its metadata requests return HTTP 403.

---

## 1. Why this fork exists

We maintain a small, focused patch set on top of upstream Zed to:

- **Run an "enhanced YOLO" agent mode** — auto-approve ACP permission requests
  and inject `ZED_YOLO*` env vars so agent-spawned processes inherit
  high-permission defaults. Configured via `settings.json`.
- **Carry a visible build marker** — "Enhanced" suffix in the About-dialog
  title, so we can tell our build apart from the official Preview.
- **Carry a project-manager settings scaffold** — placeholder schema for
  future workspace/agent management UI.
- **Carry CNB cross-build infrastructure** — Linux → macOS compile path for
  CI under cnb.cool. Linux-host cross-builds use `cargo-zigbuild`; macOS hosts
  use an upstream-derived `script/bundle-mac` with the three tracked fork
  modifications in §3.7.
- **Carry a macOS crash-on-quit workaround** — see §3.6 and upstream
  [#57664][i57664]/[#57950][i57950]/[PR #57951][pr57951].

The fork is **personal**. It's not collaboratively maintained. The patch set
exists because upstream either won't accept these changes (YOLO defaults are
intentionally conservative upstream), they are unfinished fork experiments
(the project-manager scaffold), or upstream rejected this exact workaround
while preferring its own eventual fix (the crash-on-quit patch).

[i57664]: https://github.com/zed-industries/zed/issues/57664
[i57950]: https://github.com/zed-industries/zed/issues/57950
[pr57951]: https://github.com/zed-industries/zed/pull/57951

---

## 2. Repository layout

### 2.1 Remotes

| Remote     | URL                                             | Narrow fetch set / purpose                                      |
| ---------- | ----------------------------------------------- | --------------------------------------------------------------- |
| `upstream` | `https://github.com/zed-industries/zed.git`     | Pull-only; `main` plus explicitly selected release tags         |
| `github`   | `git@github.com:laris/zed-yolo.git`             | Maintained public fork; normally fetch only `enhanced`           |
| `cnb`      | `https://cnb.cool/lary.me/zed-yolo.git`         | Private release-aligned union mirror; normally fetch `enhanced`  |

The clone must remain a `blob:none` partial clone. Its normal fetch refspecs
are intentionally narrow:

```text
github:   +refs/heads/enhanced:refs/remotes/github/enhanced
upstream: +refs/heads/main:refs/remotes/upstream/main
cnb:      +refs/heads/enhanced:refs/remotes/cnb/enhanced
```

Release tags are fetched by their full explicit refspec with `--no-tags`.
Never run `git fetch --all`, `git fetch --tags`, `git push --all`,
`git push --tags`, `git push --mirror`, or a blind prune in this repository.

> **Never push to `upstream`.** Upstream contributions go through
> `laris/zed-yolo` branches and a PR to `zed-industries/zed`. See §6.

#### 2.1.1 Why CNB does not show `[blob:none]`

The suffix printed by `git remote -v` is local Git configuration, not a
capability or storage property reported by the remote server. This clone was
created from GitHub with `--filter=blob:none`, and `github` and `upstream` are
configured as promisor remotes:

```text
remote.github.promisor=true
remote.github.partialclonefilter=blob:none
remote.upstream.promisor=true
remote.upstream.partialclonefilter=blob:none
```

Git therefore annotates the fetch lines for those two remotes with
`[blob:none]`. The `cnb` remote intentionally has neither
`remote.cnb.promisor` nor `remote.cnb.partialclonefilter`, so its fetch line
has no suffix. Its narrow `enhanced` fetch refspec is a separate setting.

This asymmetry is intentional:

- GitHub is the source for promised objects and lazy blob hydration, always
  through `$GH` and the required `127.0.0.1:10808` proxy.
- CNB is a normal private mirror destination, always reached through `$CNB`
  without a proxy or macOS Keychain access.
- Partial-clone filters govern fetching; they do not make pushes partial and
  do not describe whether CNB stores complete repository objects. An explicit
  push transfers only objects the destination lacks.
- Before a CNB push, §4.6 materializes the required release delta from GitHub.
  This prevents a CNB-side operation from unexpectedly triggering a lazy
  GitHub fetch under the CNB no-proxy environment.

Do not add CNB promisor/filter keys merely to make `git remote -v` look
symmetrical. Doing so provides no push-size benefit and could make an ordinary
missing-object read contact the private CNB remote unexpectedly.

Verify the intended configuration with:

```bash
git config --get-regexp \
  '^remote\.(github|upstream|cnb)\.(promisor|partialclonefilter)$'
```

The command should print the four GitHub/upstream entries above and no CNB
entry.

### 2.2 Branches we own

| Branch      | Lives on                  | Purpose                                                                 |
| ----------- | ------------------------- | ----------------------------------------------------------------------- |
| `enhanced`  | local + GitHub + CNB      | Rolling fork-only patch set rebased onto the selected Friday release tag |
| `fix/*`     | local + GitHub, temporary | Upstream PR branches based on an explicitly fetched upstream `main`      |
| `main`      | GitHub + CNB              | Fast-forward-only snapshot of upstream `main` at the Friday checkpoint   |

No local `main` branch is required. The partial clone can push
`refs/remotes/upstream/main` directly to the two providers after verifying a
fast-forward. This avoids maintaining a second checkout.

### 2.3 Archival tags

Three immutable tag classes are maintained:

- `vX.Y.Z-pre` or `vX.Y.Z`: the unchanged upstream release tag, mirrored to
  GitHub and CNB with the exact upstream tag-object SHA.
- `enhanced/vX.Y.Z-pre` or `enhanced/vX.Y.Z`: the validated enhanced build
  produced after rebasing onto that upstream release.
- `archive/enhanced/vX.Y.Z-pre-YYYYMMDD-HHMMSS`: a rollback snapshot created
  immediately before rewriting `enhanced` for the next baseline.

The timestamped rollback tag is necessary because an enhanced branch can gain
fixes after its original `enhanced/vX.Y.Z-pre` build tag was published. Never
move the original build tag to include those later fixes.

An `enhanced/*` tag identifies the exact tree that was validated and released;
it is not required to remain an ancestor of the rolling `enhanced` branch
after a later, explicitly authorized history rewrite. Never use enhanced-tag
ancestry to discover the rebase base. Prove that the unchanged upstream
`vX.Y.Z-pre` or `vX.Y.Z` tag is an ancestor of `enhanced`, and use the newest
`archive/enhanced/*` tag when the previous rolling-branch tip is needed.

All three classes are retained on both providers. They answer which upstream
release was used, what was shipped, and what branch state existed immediately
before the next rebase. Compare tag-object SHAs, not only peeled commit SHAs.

> **Don't reuse the upstream tag name for an enhanced build.** A tag named `v1.5.0-pre-enhanced`
> (matching an old branch name) causes Git to emit "refname is ambiguous"
> warnings. Use the namespaces above.

### 2.4 Maintained comparison table

Keep this relationship table stable and obtain volatile SHAs/counts with the
commands in §2.5. Embedding the current `enhanced` SHA in this file would be
self-referential because committing the table changes that SHA.

| Endpoint | Role | Visibility | `main` policy | `enhanced` policy | Required result |
| -------- | ---- | ---------- | ------------- | ----------------- | --------------- |
| Local `/Users/lqiao/dev/codes/zed-yolo` | `blob:none` working clone | local | Cache only `upstream/main` | One checked-out local branch | Local `enhanced` equals both providers after publish |
| `zed-industries/zed` | Read-only source | Public | Live upstream | None | May lead the Friday checkpoint; selected release tags are authoritative baselines |
| `laris/zed-yolo` | Maintained fork | Public | Friday upstream snapshot | Published enhanced branch | Every advertised head/tag equals CNB |
| `lary.me/zed-yolo` | Release-aligned union mirror | Private | Equals GitHub fork | Equals GitHub fork | Every advertised head/tag equals GitHub |

The local clone intentionally has only one local branch and no complete local
tag inventory. Therefore, do **not** use a local-versus-remote `--all` or
`--tags` comparison as the mirror proof. The authoritative proof is
GitHub-remote versus CNB-remote, followed by a focused check of the locally
maintained refs.

### 2.5 Repeatable verification procedure

Run this after every fetch, rebase, publish, or provider-side change.

#### 2.5.1 Establish identity and local state

```bash
REPO=/Users/lqiao/dev/codes/zed-yolo
SYNC_TOOLS=/Users/lqiao/.codex/skills/audit-clean-sync-repo/scripts
GH=$SYNC_TOOLS/run_github_proxy.sh
CNB=$SYNC_TOOLS/run_cnb_git_no_keychain.sh
CNB_API=$SYNC_TOOLS/run_cnb_no_proxy.sh
cd "$REPO"

git status --short --branch
git remote -v
git config --get-regexp \
  '^remote\.(github|upstream|cnb)\.(promisor|partialclonefilter)$'
git config --get-all remote.github.fetch
git config --get-all remote.upstream.fetch
git config --get-all remote.cnb.fetch

$GH gh auth status
$GH gh repo view laris/zed-yolo \
  --json nameWithOwner,visibility,url,defaultBranchRef,isFork,parent
$CNB_API repositories get-by-id --repo lary.me/zed-yolo
```

Expected identities are public GitHub fork `laris/zed-yolo` with parent
`zed-industries/zed`, and active private CNB repository
`lary.me/zed-yolo`. GitHub traffic must use `$GH`; CNB must use `$CNB` or
`$CNB_API` without a proxy or macOS Keychain access.

#### 2.5.2 Enumerate and compare every provider ref

Use `gh api` as the independent GitHub listing and authenticated Git for CNB:

```bash
VERIFY_TMP=$(mktemp -d)
trap 'rm -rf "$VERIFY_TMP"' EXIT

$GH gh api --paginate \
  'repos/laris/zed-yolo/git/matching-refs/heads?per_page=100' \
  --jq '.[] | [.ref, .object.sha] | @tsv' \
  >"$VERIFY_TMP/github-heads"
$GH gh api --paginate \
  'repos/laris/zed-yolo/git/matching-refs/tags?per_page=100' \
  --jq '.[] | [.ref, .object.sha] | @tsv' \
  >"$VERIFY_TMP/github-tags"
cat "$VERIFY_TMP/github-heads" "$VERIFY_TMP/github-tags" |
  LC_ALL=C sort >"$VERIFY_TMP/github-all"

$CNB git ls-remote --heads --tags cnb >"$VERIFY_TMP/cnb-raw"
awk '$2 !~ /\^\{\}$/ {print $2 "\t" $1}' "$VERIFY_TMP/cnb-raw" |
  LC_ALL=C sort >"$VERIFY_TMP/cnb-all"

wc -l "$VERIFY_TMP/github-heads" "$VERIFY_TMP/github-tags"
diff -u "$VERIFY_TMP/github-all" "$VERIFY_TMP/cnb-all"
```

The final `diff` must be empty. GitHub's API returns annotated tag-object SHAs;
CNB's peeled `^{}` lines are excluded so the same objects are compared.

#### 2.5.3 Verify the local maintained refs

```bash
LOCAL_ENHANCED=$(git rev-parse refs/heads/enhanced)
GITHUB_ENHANCED=$(awk '$1 == "refs/heads/enhanced" {print $2}' \
  "$VERIFY_TMP/github-heads")
CNB_ENHANCED=$(awk '$1 == "refs/heads/enhanced" {print $2}' \
  "$VERIFY_TMP/cnb-all")
test "$LOCAL_ENHANCED" = "$GITHUB_ENHANCED"
test "$GITHUB_ENHANCED" = "$CNB_ENHANCED"

GITHUB_MAIN=$(awk '$1 == "refs/heads/main" {print $2}' \
  "$VERIFY_TMP/github-heads")
CNB_MAIN=$(awk '$1 == "refs/heads/main" {print $2}' \
  "$VERIFY_TMP/cnb-all")
test "$GITHUB_MAIN" = "$CNB_MAIN"

# This must be empty at the end of a completed maintenance run.
git status --porcelain=v1
```

Before publishing, a dirty worktree is allowed only when every path is
intentional and reviewed. After publishing, a non-empty status is a failed
completion check.

#### 2.5.4 Measure intentional upstream lag

```bash
OFFICIAL_MAIN=$($GH gh api repos/zed-industries/zed/commits/main --jq .sha)

$GH gh api \
  "repos/zed-industries/zed/compare/$GITHUB_MAIN...$OFFICIAL_MAIN" \
  --jq '{status, ahead_by, behind_by, total_commits}'

$GH gh api \
  "repos/laris/zed-yolo/compare/$OFFICIAL_MAIN...$GITHUB_ENHANCED" \
  --jq '{status, ahead_by, behind_by, merge_base: .merge_base_commit.sha}'
```

The fork `main` may be behind live upstream between checkpoints, but it must
remain an ancestor (`status: ahead` from upstream's perspective). Divergence
requires manual review. The enhanced branch is expected to diverge: `ahead_by`
is the maintained patch set and `behind_by` is upstream work since its selected
release baseline.

For every newly selected release tag, also run the three-provider tag-object
comparison in §4.8. Record the timestamp, timezone, counts, SHAs, lag, and test
results in §10 and `/Users/lqiao/dev/codes/REPOSITORY_SYNC_STATUS.md`.

---

## 3. The patch set

These are the commits that sit on top of upstream on the `enhanced` branch.
Patch order matters because some patches reference fields/types introduced by
earlier ones. The chronological order is:

| # | Subject                                                          | Crates touched                                                       | Notes                                                                                 |
| - | ---------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 1 | `Add config-backed enhanced YOLO runtime`                        | `agent`, `agent_servers`, `agent_settings`, `agent_ui`, `settings_content` | Adds `EnhancedYoloSettings` to `AgentSettings`; opt-out via `agent.enhanced_yolo`. Includes the all-target test fixtures (folded at the 2026-07-05 compaction) and the codex MCP tool-approval elicitation auto-accept with its wire-shape unit test (folded at the 2026-08-07 compaction). |
| 2 | `Show enhanced marker in About title`                            | `zed`                                                                | Reads `ZED_ENHANCED` / `ZED_ENHANCED_LABEL` env vars (build-time or runtime).         |
| 3 | `Add enhanced project manager settings scaffold`                 | `settings`, `settings_content`, `workspace`                          | Placeholder schema only — no UI yet.                                                  |
| 4 | `Add CNB cross-build infrastructure`                             | `.cnb.yml`, `.cnb/*`, `auto_update`, build scripts                   | Linux-host cross-build via Docker, `script/bundle-mac` mods (§3.7, incl. set-u fixes), and the bundled remote-server lookup in `auto_update` (moved here from patch #1 at the 2026-07-05 compaction). |
| 5 | `crashes: Skip broken minidumper Server::drop on macOS quit`     | `crashes`                                                            | Workaround for [#57664][i57664]; see §3.6. **Remove once the criteria in §3.6 are met.** |

This table lists the core product patches. One consolidated CI commit
(`.github/workflows/build-enhanced.yml`, §11) and one consolidated
documentation commit (this file) also sit above the baseline, and new
release/maintenance commits may accumulate between compactions. Before every
rebase, derive the complete replay set with
`git log --reverse "$PREV^{commit}..enhanced"`; never assume a fixed count.

### 3.1 Enhanced YOLO safety boundary (patch #1)

The settings defaults are intentionally asymmetric:

| Setting | Default | Meaning |
| ------- | ------- | ------- |
| `agent.enhanced_yolo.enabled` | `true` | Enables the enhanced policy. |
| `auto_approve_acp` | `true` | Selects `AllowAlways`, then `AllowOnce`, then another non-reject option. If no allow option exists, the request is not auto-approved. Also auto-accepts `elicitation/create` requests that carry the codex adapter's `codex_approval_kind: "mcp_tool_call"` marker (the `@agentclientprotocol/codex-acp` adapter routes MCP tool approvals through elicitations when the client advertises form-elicitation support, bypassing `session/request_permission`); the injected `persist` select answers `always` → `session` → `once`. Elicitations without the marker, or with extra required fields, stay interactive. |
| `inject_agent_env` | `true` | Adds `ZED_YOLO=1` and `ZED_YOLO_APPROVALS=1` to ACP agent commands without overwriting adapter-supplied values. |
| `disable_agent_sandbox` | `false` | Adds `ZED_YOLO_SANDBOX=1` only when explicitly enabled. The sandbox is not disabled by default. |

Process-level `ZED_YOLO` or `ZED_YOLO_APPROVALS` false-like values disable
auto-approval; true-like values enable it. Keep the explicit reject path and
the no-allow fallback when resolving upstream changes. This is a personal-fork
policy and is not suitable for an upstream-default PR.

The bundled remote-server selection in `auto_update` (searches an explicit
directory, app resources, and the data-dir cache before downloading;
`ZED_ENHANCED_REMOTE_SERVER_REQUIRED` turns a miss into an error) lived in
this patch until the 2026-07-05 compaction moved it into patch #4, where the
rest of the bundling/deployment logic lives.

### 3.2 Enhanced build marker (patch #2)

The About window shows `Enhanced` by default. `ZED_ENHANCED_LABEL` supplies a
custom build-time or runtime label, while a false-like `ZED_ENHANCED` disables
the marker. Preserve both the visible title and copied diagnostic details so a
user can distinguish fork builds in screenshots and bug reports.

### 3.3 Project-manager scaffold (patch #3)

This patch is schema and defaults only. `workspace.project_manager.enabled`
defaults to false, risky migration/auto-expansion options default to false,
and there is no completed persistence path or UI. Do not describe it as a
working project manager. Re-evaluate whether to implement or drop the scaffold
when upstream workspace persistence changes.

### 3.4 Cross-build and bundle integration (patch #4)

This is the largest and most conflict-prone patch. It combines the CNB
pipeline/container, macOS/Linux cross-compilation shims, Mach-O validation,
and bundle integration. Review its net diff by subsystem rather than accepting
a conflict because it still applies mechanically. The source-base comment and
attachment release version in `.cnb.yml` are checkpoint metadata and must be
updated deliberately; see §4.3.2 and §5.2.

The cross-compilation shims all follow one rule: **a build script must gate
macOS behaviour on the compilation target, not on the host.** `#[cfg(target_os
= "macos")]` and `cfg!(target_os = "macos")` inside `build.rs` describe the
machine running the build script, so a Linux host silently skips them. The
fork replaces them with `std::env::var("CARGO_CFG_TARGET_OS") == "macos"` and
lets `xcrun` be answered by the container's shim (§5.4). Files carrying the
shim as of v1.20.0-pre: `crates/gpui_apple/build.rs` (moved by upstream from
`gpui_macos` in v1.16), `crates/media/build.rs` (also honours `SDKROOT`
directly), and — added by the two-stage build work — `crates/zed/build.rs`
(`-ObjC`, weak frameworks, Swift rpath), `crates/cli/build.rs` (deployment
target) and `crates/ui/build.rs` (`macos_sdk_26_or_later`, which selects the
macOS 26 title-bar traffic-light padding). When upstream adds another
`build.rs` with a host-gated macOS branch, extend the shim rather than
accepting a cross-build that quietly differs from the native one.

### 3.5 Fixture completeness (folded into patch #1)

A standalone `agent, agent_ui: Add enhanced_yolo to test fixtures` commit
existed because patch #1 changed `AgentSettings` constructors used by
all-target tests. The 2026-07-05 compaction folded it into patch #1 so the
feature is buildable at every replay step. If a future upstream change again
breaks only test fixtures, amend patch #1 rather than reintroducing a
standalone fixture commit.

### 3.6 The minidumper workaround (patch #5)

Dropping `minidumper`'s `Server` drops the `crash_context::ipc::Server` it
owns, whose `Drop` calls `mach_port_deallocate(mach_task_self(), self.port)`
on a kernel-guarded Mach port (`crash-context/src/mac/ipc.rs`; the same
pattern exists in `AckReceiver::drop`). That raises `EXC_GUARD/INVALID_RIGHT`
and SIGKILLs the crash-handler subprocess on every quit. Symptom: "Zed quit
unexpectedly" dialog despite a clean quit. The call lives in `crash-context`,
not in `minidumper`'s own `src/ipc/*.rs`, so a `minidumper` version bump alone
proves nothing.

The patch leaks the `Server` via `std::mem::forget` on macOS only. The
subprocess exits immediately after, so the kernel reclaims the port — no real
leak in practice.

**Removal criteria:** delete this commit during the next upstream upgrade if:

- PR #57951 (or any equivalent fix) has been merged upstream, **or**
- the `crash-context` version selected by `Cargo.lock` no longer calls
  `mach_port_deallocate` from a `Drop` impl. Verify against the crate that
  the lockfile actually resolves, after `cargo fetch`:
  ```bash
  grep -A1 -E '^name = "(minidumper|crash-context)"$' Cargo.lock
  grep -rn -B4 'mach_port_deallocate' "$(cargo metadata --format-version=1 --offline \
    | jq -r '.packages[] | select(.name == "crash-context") | .manifest_path | sub("Cargo.toml$"; "src")')"
  ```
  Checked 2026-09-14: `v1.20.0-pre` resolves minidumper 0.11.0 → crash-context
  0.8.0, which still has both calls, so the workaround stayed.

### 3.7 Local modifications to `script/bundle-mac`

We carry three categories of edits in the net fork diff owned by patch #4
(`Add CNB cross-build infrastructure`). Blocks A and C originated in that
commit; block B arrived as later standalone set-u fixes that the 2026-07-05
compaction folded into the same patch.

| # | Where (relative to upstream)                | What it does                                                                                                                                                                              |
| - | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A | Block after `rustup target add` (≈line 86)  | Detects whether the host has Xcode's `metal` compiler. If not (Command Line Tools only, or a Linux CNB host), exports the `gpui_platform/runtime_shaders` feature so the build does not try AOT shader compilation. |
| B | The three `cargo build` / `cargo bundle` call sites | Use the `${zed_features[@]+"${zed_features[@]}"}` idiom instead of the plain `"${zed_features[@]}"`. Required because `set -u` (which the script enables) errors on empty-array expansion under bash 3.2 — the bash that ships on the GitHub-hosted `macos-latest` runner. |
| C | New function `copy_enhanced_remote_servers` + call site | Copies pre-built `dist/zed-remote-server-linux-*.gz` (or `target/...`) into `Contents/Resources/remote_servers/` inside the bundled `.app`. Same set-u-safe array expansion as B. |
| D | `-p DIR` option (getopts, `prebuilt_dir` checks, the `if [[ -n "${prebuilt_dir}" ]]` branch around the two `cargo build` calls, the `dsymutil` skip, the trailing cleanup) | Stage 2 of the two-stage build (§5.4, added 2026-09-14): validates and copies prebuilt `zed`/`cli`/`remote_server` into `target/<triple>/release/`, exports `CARGO_BUNDLE_SKIP_BUILD=true` so `cargo bundle` only assembles the `.app`, skips `generate-licenses` and `dsymutil`, and removes the copies afterwards so the next native `cargo build` relinks instead of trusting them. Also makes `-i` skip DMG creation, because upstream's script tries to package the bundle it has just moved into `/Applications`. |

**Tracking discipline:**

- Every time you upgrade upstream, diff our script against the new
  upstream version and confirm A/B/C/D still apply cleanly:
  ```bash
  git diff "$NEW"..enhanced -- script/bundle-mac
  ```
  The diff should be a strict superset of the four blocks above. If
  upstream has refactored the script, you may need to relocate one or
  more blocks during the rebase.
- If upstream **adds the runtime-shader fallback** itself (block A
  becomes redundant), drop block A from our patch.
- If upstream **switches to a newer bash idiom** that doesn't need our
  set-u workaround (block B), drop the workaround.
- Block C (enhanced remote-server embedding) is fork-specific; it stays
  until we move the logic elsewhere.

---

## 4. Upstream upgrade workflow

This is the Friday release ritual. It keeps the working clone small while
making each provider update incremental and independently verifiable.

### 4.1 Pre-flight and prove the starting state

```bash
test -z "$(git status --porcelain=v1)" || {
  echo "Stop: working tree is not clean" >&2
  exit 1
}
test "$(git branch --show-current)" = enhanced || {
  echo "Stop: checkout enhanced first" >&2
  exit 1
}

# Refresh only the maintained fork branch. No tags and no other branches.
$GH git fetch --filter=blob:none --no-tags github \
  +refs/heads/enhanced:refs/remotes/github/enhanced
test "$(git rev-parse enhanced)" = \
  "$(git rev-parse refs/remotes/github/enhanced)" || {
  echo "Stop: local enhanced is not the published branch" >&2
  exit 1
}

# Record leases before changing anything.
OLD_GITHUB_MAIN=$($GH git ls-remote github refs/heads/main | awk '{print $1}')
OLD_GITHUB_ENHANCED=$($GH git ls-remote github refs/heads/enhanced | awk '{print $1}')
OLD_CNB_MAIN=$($CNB git ls-remote cnb refs/heads/main | awk '{print $1}')
OLD_CNB_ENHANCED=$($CNB git ls-remote cnb refs/heads/enhanced | awk '{print $1}')
test "$OLD_GITHUB_MAIN" = "$OLD_CNB_MAIN"
test "$OLD_GITHUB_ENHANCED" = "$OLD_CNB_ENHANCED"

# Prove complete provider parity before beginning.
TMP_REFS=$(mktemp -d)
$GH git ls-remote --heads --tags github | LC_ALL=C sort \
  >"$TMP_REFS/github"
$CNB git ls-remote --heads --tags cnb | LC_ALL=C sort \
  >"$TMP_REFS/cnb"
diff -u "$TMP_REFS/github" "$TMP_REFS/cnb"
```

If the `diff` is non-empty, stop and reconcile the existing mismatch with
explicit refspecs. Do not hide it with `--mirror`, `--all`, force, or prune.

### 4.2 Discover releases and fetch only selected refs

List releases in provider publication order:

```bash
$GH gh api --paginate 'repos/zed-industries/zed/releases?per_page=100' \
  --jq '.[] | select(.draft == false) |
        [.tag_name, .prerelease, .published_at] | @tsv'
```

Use the History table in §10 and the API output to set:

```bash
PREV=v1.9.0-pre       # baseline currently under enhanced
NEW=v1.10.0-pre       # newest release published by the checkpoint

# Include every release published since the previous checkpoint, oldest first.
# This prevents an intermediate preview/final tag from disappearing from the
# GitHub/CNB archive even though enhanced uses only the newest one.
NEW_RELEASE_TAGS=(v1.9.1-pre v1.9.2 v1.10.0-pre)
```

If there is no newly published release, leave `enhanced` unchanged and run
only the `main` snapshot, provider-parity, and ledger steps below.

Fetch upstream `main` and every new release tag explicitly:

```bash
$GH git fetch --filter=blob:none --no-tags upstream \
  +refs/heads/main:refs/remotes/upstream/main

# The initial partial clone has no tags, so fetch PREV explicitly when needed.
git show-ref --verify --quiet "refs/tags/$PREV" ||
  $GH git fetch --filter=blob:none --no-tags upstream \
    "refs/tags/$PREV:refs/tags/$PREV"

for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  $GH git fetch --filter=blob:none --no-tags upstream \
    "refs/tags/$TAG:refs/tags/$TAG"

  UPSTREAM_TAG_SHA=$($GH git ls-remote --tags upstream \
    "refs/tags/$TAG" | awk '$2 !~ /\^\{\}$/ {print $1}')
  test "$(git rev-parse "refs/tags/$TAG")" = "$UPSTREAM_TAG_SHA" || {
    echo "Stop: local tag object differs from upstream: $TAG" >&2
    exit 1
  }
done

git merge-base --is-ancestor "$PREV^{commit}" enhanced || {
  echo "Stop: PREV is not an ancestor of enhanced" >&2
  exit 1
}
git merge-base --is-ancestor "$PREV^{commit}" "$NEW^{commit}" || {
  echo "Stop: release ancestry is not linear; review manually" >&2
  exit 1
}

# Review the exact commits that will be replayed. Do not hard-code a count.
git log --reverse --format='%h %ad %s' --date=short \
  "$PREV^{commit}..enhanced"
```

### 4.3 Create a rollback ref and rebase

The immutable `enhanced/$PREV` build tag may predate later fixes on the same
baseline. Create a unique rollback tag immediately before rewriting:

```bash
ROLLBACK="archive/enhanced/$PREV-$(date +%Y%m%d-%H%M%S)"
git tag -a "$ROLLBACK" enhanced \
  -m "Rollback point before rebasing $PREV to $NEW"

# Publish the rollback ref to both providers before the rebase. The objects are
# already reachable from the current enhanced branch, so these pushes are tiny.
$GH git push github "refs/tags/$ROLLBACK:refs/tags/$ROLLBACK"
$CNB git push cnb "refs/tags/$ROLLBACK:refs/tags/$ROLLBACK"

git rebase --onto "$NEW^{commit}" "$PREV^{commit}" enhanced
```

Resolve conflicts one commit at a time:

```bash
git add -A
git rebase --continue

# Use only when upstream has made that fork patch unnecessary.
git rebase --skip

# Abort restores the branch to the rollback state.
git rebase --abort
```

#### 4.3.1 Conflict patterns we've already seen

| Patch              | File                                              | Conflict pattern                                                                                                 |
| ------------------ | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `enhanced YOLO`    | `crates/agent_servers/src/acp.rs`                 | `use gpui::{…}` import gains a new symbol upstream. Since 2026-09-14 the patch no longer imports `settings::Settings` at module level (it qualifies the single `get_global` call), because a module-level `as _` import reaches upstream's `mod tests` through `use super::*` and turns upstream's own import into an unused-import warning. |
| `enhanced YOLO`    | `crates/agent_settings/src/agent_settings.rs`     | Other authors add fields to `AgentSettings`; preserve `pub enhanced_yolo: EnhancedYoloSettings,`. |
| `test fixtures`    | `crates/agent/src/tool_permissions.rs`, `crates/agent_ui/src/agent_ui.rs` | Preserve our `enhanced_yolo` fixture fields while accepting new upstream fields. |
| `project manager`  | `assets/settings/default.json`, `crates/settings_content/src/workspace.rs`, `crates/workspace/src/workspace_settings.rs` | Upstream adds a workspace setting at the same insertion point (`reveal_if_open` in v1.20.0-pre). Keep both, upstream's field first, in the struct, the `from_settings` constructor, and the defaults JSON. |
| `CNB infra`        | `crates/gpui_apple/build.rs` (was `crates/gpui_macos/build.rs`) | Upstream moved the Metal/cbindgen build script into the new `gpui_apple` crate (v1.16+); Git follows the rename. Keep the fork's runtime `CARGO_CFG_TARGET_OS` gate on `main()` and on the module; take upstream's `find_gpui_crate_dir`, which now resolves `../gpui` itself. Upstream also dropped the `gpui` build-dependency, so the fork no longer touches `gpui_macos/Cargo.toml`; the un-gated `cbindgen` build-dependency now belongs in `gpui_apple/Cargo.toml`. |
| `CNB infra`        | `script/bundle-mac`                               | Upstream changed the two `cargo build` lines to `cargo --config .cargo/bundle-config.toml build …` (v1.20.0-pre). Keep upstream's prefix and re-append the fork's set-u-safe `${zed_features[@]+…}` suffix (§3.7 block B). |
| `CNB infra`        | `.cnb.yml`                                        | Keep fork-owned CI and update the source baseline and release tag to `$NEW`. |

#### 4.3.2 Update version strings inside the CNB patch

After the rebase, inspect every hard-coded occurrence rather than blindly
replacing a version string:

```bash
grep -nF "$PREV" .cnb.yml MAINTAINING.md
git log --format=%H --grep='Add CNB cross-build infrastructure' -n 1 enhanced
```

Update `.cnb.yml` so its source-base comment and attachment-release
`RELEASE_TAG` refer to `$NEW`, then amend the CNB infrastructure commit with an
interactive rebase if those values are intended to remain inside that commit.
`RELEASE_TAG` is consumed by `cnbcool/attachments`; it does not trigger this
pipeline and does not currently equal the Git tag. The established value is
`zed-yolo-$NEW-enhanced`. Review the final result:

```bash
grep -nE 'Source base:|RELEASE_TAG:' .cnb.yml
git diff "$NEW^{commit}..enhanced" -- .cnb.yml .cnb script/bundle-mac
```

### 4.4 Verify before publishing

```bash
git diff --check "$NEW^{commit}..enhanced"
git log --reverse --oneline "$NEW^{commit}..enhanced"

# Run through the GitHub proxy wrapper because Cargo may resolve Git-backed
# dependencies and the partial clone may lazily request promised blobs.
$GH cargo check --workspace --all-targets

# If the host has no Metal toolchain:
$GH cargo check --workspace --all-targets \
  --features gpui_platform/runtime_shaders

$GH script/bundle-mac -d -i aarch64-apple-darwin
open "/Applications/Zed Preview.app"
```

Smoke-test the Enhanced marker, YOLO permission behavior, editing, and clean
quit. Verify whether the minidumper workaround is still required. If any
check fails, do not publish.

Create the immutable enhanced build tag only after validation:

```bash
ENHANCED_TAG="enhanced/$NEW"
git tag -a "$ENHANCED_TAG" enhanced \
  -m "Enhanced build based on upstream $NEW"
```

Never move or reuse an existing upstream, rollback, or enhanced tag.

### 4.5 Publish incrementally to GitHub

First prove that the weekly `main` update is a fast-forward:

```bash
NEW_MAIN=$(git rev-parse refs/remotes/upstream/main)
git merge-base --is-ancestor "$OLD_GITHUB_MAIN" "$NEW_MAIN" || {
  echo "Stop: upstream main was rewritten or the recorded base is wrong" >&2
  exit 1
}
```

Push one explicit ref at a time. Upstream release tags are immutable and must
never be forced. Only `enhanced` is rewritten, protected by an exact lease:

```bash
$GH git push github \
  "$NEW_MAIN:refs/heads/main"

for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  $GH git push github "refs/tags/$TAG:refs/tags/$TAG"
done

$GH git push \
  --force-with-lease="refs/heads/enhanced:$OLD_GITHUB_ENHANCED" \
  github refs/heads/enhanced:refs/heads/enhanced

$GH git push github \
  "refs/tags/$ENHANCED_TAG:refs/tags/$ENHANCED_TAG"
```

### 4.6 Materialize only the delta needed by CNB

A `blob:none` clone may know a commit and tree without storing every blob.
CNB traffic cannot use the GitHub proxy, so all promised objects needed for
the CNB update must be materialized first under `$GH`.

The following helper enumerates only objects reachable from the new ref but
not from the old CNB ref, then requests every missing object in one batched
fetch. This is the same command Git runs internally for a lazy fetch, except
that all OIDs are passed on stdin at once instead of one fetch per object
(the earlier `git cat-file --batch-check` loop did one round trip per blob and
needed >10 minutes for a single week of upstream delta; the batched form
fetched the 2,267 blobs of a five-week delta in 11 seconds). A bare OID is a
valid refspec, and GitHub serves blob wants for partial clones; `--filter`
does not drop explicitly wanted blobs:

```bash
hydrate_delta() {
  INCLUDE=$1
  EXCLUDE=$2
  REMOTE=${3:-upstream}   # github for fork-only commits, upstream otherwise

  MISSING=$(mktemp)
  git rev-list --objects --missing=print "$INCLUDE" "^$EXCLUDE" |
    awk '/^\?/ {print substr($1, 2)}' >"$MISSING"
  echo "missing objects for $INCLUDE: $(wc -l <"$MISSING")"

  if [ -s "$MISSING" ]; then
    split -l 2000 "$MISSING" "$MISSING.chunk."
    for CHUNK in "$MISSING".chunk.*; do
      $GH git -c fetch.negotiationAlgorithm=noop fetch \
        --no-tags --no-write-fetch-head --recurse-submodules=no \
        --filter=blob:none --stdin "$REMOTE" <"$CHUNK"
    done
  fi

  if git rev-list --objects --missing=print "$INCLUDE" "^$EXCLUDE" |
       grep -q '^?'; then
    echo "Stop: promised objects are still missing for $INCLUDE" >&2
    return 1
  fi
}

hydrate_delta "$NEW_MAIN" "$OLD_CNB_MAIN"
hydrate_delta refs/heads/enhanced "$OLD_CNB_ENHANCED" github
for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  hydrate_delta "refs/tags/$TAG" "$OLD_CNB_MAIN"
done
```

Run the `$NEW` hydration **before** the rebase as well: the checkout of the new
baseline then needs no lazy fetches at all, which also removes the mid-rebase
`fetch-pack` disconnects seen at earlier checkpoints.

This is the step that makes the partial-clone bridge reliable: GitHub supplies
only the missing release delta through the proxy, then CNB receives that same
small delta without ever contacting GitHub during the CNB push.

Never run `git log -G`, `-S`, or `-p` across an upstream range in this clone:
every blob in the range is lazily fetched one at a time and the command can
run for hours. Use `git diff --stat A B -- <paths>`, `git show REV:<path>`, or
`git log -- <path>` (no content search) instead.

### 4.7 Publish the same explicit refs to CNB

```bash
$CNB git push cnb "$NEW_MAIN:refs/heads/main"

for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  $CNB git push cnb "refs/tags/$TAG:refs/tags/$TAG"
done

$CNB git push \
  --force-with-lease="refs/heads/enhanced:$OLD_CNB_ENHANCED" \
  cnb refs/heads/enhanced:refs/heads/enhanced

$CNB git push cnb \
  "refs/tags/$ENHANCED_TAG:refs/tags/$ENHANCED_TAG"
```

Do not combine these into one bulk push. Small independent pushes isolate
provider errors and let CNB reuse objects accepted by earlier steps.

### 4.8 Prove release coverage and full provider parity

```bash
for TAG in "${NEW_RELEASE_TAGS[@]}"; do
  UP=$($GH git ls-remote --tags upstream "refs/tags/$TAG" |
    awk '$2 !~ /\^\{\}$/ {print $1}')
  FORK=$($GH git ls-remote --tags github "refs/tags/$TAG" |
    awk '$2 !~ /\^\{\}$/ {print $1}')
  MIRROR=$($CNB git ls-remote --tags cnb "refs/tags/$TAG" |
    awk '$2 !~ /\^\{\}$/ {print $1}')
  test "$UP" = "$FORK" && test "$FORK" = "$MIRROR" || {
    echo "Stop: release tag mismatch: $TAG" >&2
    exit 1
  }
done

$GH git ls-remote --heads --tags github | LC_ALL=C sort \
  >"$TMP_REFS/github.final"
$CNB git ls-remote --heads --tags cnb | LC_ALL=C sort \
  >"$TMP_REFS/cnb.final"
diff -u "$TMP_REFS/github.final" "$TMP_REFS/cnb.final"

$CNB_API repositories get-by-id --repo lary.me/zed-yolo
rm -rf "$TMP_REFS"
```

An empty final `diff` is the synchronization proof. Append a row to §10 with
the checkpoint time and timezone, `PREV`, `NEW`, upstream/fork/CNB SHAs, every
mirrored release tag, test results, and any dropped or modified patch.

Keep all `enhanced/*` and `archive/enhanced/*` tags. Cleanup is limited to
ordinary build outputs (`cargo clean` when appropriate), never history refs.

---

## 5. Build & install

### 5.1 macOS host (typical local build)

```bash
# Debug build — faster, larger binary, fine for daily use
script/bundle-mac -d -i aarch64-apple-darwin
# → installs to /Applications/Zed Preview.app

# Release build — slow, optimized
script/bundle-mac aarch64-apple-darwin
# → .app at target/aarch64-apple-darwin/release/dmg/Zed Preview.app
# Then manually:
rm -rf ~/Applications/Zed\ Preview.app
cp -R "target/aarch64-apple-darwin/release/dmg/Zed Preview.app" ~/Applications/
```

Known script quirks (do not "fix" without understanding):

- `script/bundle-mac -d -i` exits non-zero because of a trailing `gzip` on
  `release/remote_server` even in debug mode. The install completes before
  this step.
- `script/bundle-mac` (release) exits non-zero unless `dmg-license` is
  globally installed via npm. The `.app` and `.dmg` are produced before this
  step.

### 5.2 Linux-host cross-build (CNB)

Driven by `.cnb.yml` + `.cnb/Dockerfile.zed-macos`. The current `$: vscode`
definition is a manually started CNB workspace build; there is no Git-tag
trigger in this file. The pipeline produces unsigned macOS Mach-O binaries;
signing/notarization happens later locally (§5.4 stage 2) or in a rcodesign
stage.

The image (`ghcr.io/rust-cross/cargo-zigbuild` base) pins Rust 1.97.1, the
MacOSX26.1 SDK from `joseluisq/macosx-sdks`, `cargo-about` and the Zed
`cargo-bundle`, and adds an `xcrun` shim that answers `--show-sdk-path` and
`--show-sdk-version` from `$SDKROOT`. Since 2026-09-14 Darwin targets are
compiled and linked by Debian clang + LLVM `ld64.lld` through the
`aarch64-apple-darwin-clang{,++}` wrappers (selected via
`CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER`, `CC_/CXX_/AR_aarch64_apple_darwin`),
not by zig; `cargo zigbuild` remains only for the Linux remote-server targets.
`.cnb/run-zed-build-step.sh build` picks `cargo build` or `cargo zigbuild`
from the target triple. The Darwin link additionally needs Apple's compiler-rt
archive mounted into the container (§5.4); the CNB pipeline does not provide
it yet, so its Darwin link step fails on `__isPlatformVersionAtLeast` until a
CNB secret or asset supplies the file.

The `RELEASE_TAG` value names the CNB attachment release populated by
`cnbcool/attachments`. Keep its established `zed-yolo-$NEW-enhanced` form in
sync with the selected preview or final baseline. Do not assume it is the Git
tag `enhanced/<NEW>` unless the CNB pipeline is explicitly redesigned and
slash-containing attachment tags are tested. See §4.3.2.

### 5.3 Parallel installs

| Path                              | Purpose                                                  |
| --------------------------------- | -------------------------------------------------------- |
| `~/Applications/Zed Preview.app`  | "Stable" install — replace only after the new build has been smoke-tested. |
| `/Applications/Zed Preview.app`   | "Test target" — overwrite freely while iterating.        |

Both share the bundle identifier `dev.zed.Zed-Preview`, so macOS may
arbitrate `zed://` URL handling. For predictable URL routing, use Finder →
right-click → Get Info → "Open with" → choose the preferred app → "Change All".

### 5.4 Two-stage build: Linux cross-compile, macOS finish

Added 2026-09-14. Compilation (the part that takes ~2.5 h on the GitHub macOS
runner, or the better part of an hour on the 8-core laptop) runs inside the
CNB cross-build container on a many-core x86_64 Linux Docker host; only
bundling, signing and installation run on the Mac. Everything is driven from
the Mac by `script/cross-build-remote`; the pieces are:

| Piece | Runs on | Does |
| ----- | ------- | ---- |
| `.cnb/Dockerfile.zed-macos` | Linux (once) | The cross toolchain image; §5.2. |
| `.cnb/cross-build-macos.sh` | Linux, per build | Runs the container as root with named volumes for the cargo registry, cargo git, sccache and `target/`; bind-mounts the checkout at `/workspace` and Apple's compiler-rt at `/opt/compiler-rt/`; executes `run-zed-build-step.sh` `macho-smoke` → `generate-licenses` → `metadata` → `build … zed-cli` → `build … remote-server` → `package … all`; chowns `dist/` back. Output: `dist/zed-yolo-v<ver>-aarch64-apple-darwin-<yyyymmdd>-g<sha8>.tar.zst` (+ `.sha256`, `.build.json`) containing `zed`, `cli`, `remote_server`. |
| `script/cross-build-remote` | Mac | Stage 1: shallow-fetches the commit by full SHA on the Linux host (Git runs inside the image; the host's Git may be too old), runs the driver, streams the package back over the same SSH path and checks its SHA-256. Stage 2: extracts it and calls `script/bundle-mac -p`. |
| `script/bundle-mac -p DIR` | Mac | §3.7 block D: validates the Mach-O load commands, copies the three binaries into `target/aarch64-apple-darwin/release/`, sets `CARGO_BUNDLE_SKIP_BUILD=true` so `cargo bundle` only assembles the `.app`, then runs upstream's unchanged tail: `Document.icns`, dugite `git`, provisioning profile, ad-hoc `codesign` with entitlements, `-i` install or DMG, remote-server gzip. `dsymutil` is skipped (the object files live on the Linux host); `strip -x` still runs for non-`-i` builds. |

The build scripts' host-vs-target shims (§3.4) and the un-gated `cbindgen`
build-dependency in `crates/gpui_apple/Cargo.toml` are what make the
cross-built binaries equivalent to native ones; without them the Linux build
silently drops `-ObjC`, the weak frameworks and the SDK-26 title-bar layout.

#### 5.4.1 One-time setup

On the Linux host you need Docker usable by your user and outbound access to
GitHub, `static.crates.io`, `ghcr.io`, `ziglang.org` and `deb.debian.org`.
The host kernel does not matter (validated on CentOS 7 / kernel 3.10 with
Docker 26.1); the image is Debian trixie and brings its own glibc. Budget
~9 GB for the image, ~30 GB for the `target` volume and up to 80 GB for
sccache.

```bash
# The SSH prefix that reaches the Linux host and runs its arguments there.
# Two hops are fine; the key for the second hop may live on the first host.
export ZED_CROSS_SSH='ssh -o BatchMode=yes nano ssh -o BatchMode=yes -i ~/.ssh/id_ed25519.bjnbulab2025.pri laris@10.75.71.58'

# 1. Build the image (~10 min; self-contained, needs no build context).
$ZED_CROSS_SSH 'mkdir -p ~/zed-yolo-cross && cat > ~/zed-yolo-cross/Dockerfile.zed-macos' \
  < .cnb/Dockerfile.zed-macos
$ZED_CROSS_SSH 'cd ~/zed-yolo-cross && docker build -t zed-yolo-macos-cross -f Dockerfile.zed-macos .'

# 2. Ship the arm64 slice of Xcode's Darwin compiler-rt (248 KB). It provides
#    __isPlatformVersionAtLeast, which every Objective-C `@available` check
#    (webrtc-sys) calls; Rust's compiler_builtins does not, Apple's clang links
#    it natively, and Apple's licence keeps it out of the image and the repo.
lipo -thin arm64 "$(dirname "$(xcrun --find clang)")/../lib/clang/"*/lib/darwin/libclang_rt.osx.a \
  -output /tmp/libclang_rt.osx.a
$ZED_CROSS_SSH 'mkdir -p ~/.cache/zed-yolo-cross && cat > ~/.cache/zed-yolo-cross/libclang_rt.osx.a' \
  < /tmp/libclang_rt.osx.a
```

When the tool shell is zsh (the agent harness), spell the prefix out literally
in commands instead of `$ZED_CROSS_SSH …`: zsh does not word-split an unquoted
variable. Bash scripts, including `script/cross-build-remote`, are unaffected.

#### 5.4.2 Every build

```bash
# The commit must be reachable on GitHub (enhanced, a wip/* branch, or a tag);
# the Linux host fetches it by SHA and nothing but commands leave the Mac.
$GH git push github 'refs/heads/wip/<topic>:refs/heads/wip/<topic>'   # if not on enhanced yet

$GH script/cross-build-remote                 # stage 1 + stage 2, installs /Applications/Zed Preview.app
ZED_CROSS_STAGE=1 $GH script/cross-build-remote   # only fetch the package into dist/
BUNDLE_ARGS='' ZED_CROSS_STAGE=2 $GH script/cross-build-remote   # only bundle the newest dist/ package, producing the DMG
```

`$GH` is required on the Mac side because `script/bundle-mac` downloads the
dugite `git` binary from GitHub. Delete a `wip/*` branch from GitHub (and mirror
or delete it on CNB) once its commits are on `enhanced`; §2.5's parity proof
lists it otherwise.

Then smoke-test as in §4.4 and, if the build replaces the daily install,
follow §5.3. `codesign --verify --deep --strict`, `otool -l | grep -A4
LC_BUILD_VERSION` (platform 1 = macOS, minos 11.0, sdk 26.1),
`Contents/MacOS/zed --system-specs` (loads every framework and runs the static
constructors without opening a window) and a clean quit without a new
`~/Library/Logs/DiagnosticReports/Zed*` report are the checks that distinguish
a healthy cross-built app from a merely linkable one.

Two constraints when the smoke test runs from an agent session hosted by Zed
itself:

- Zed's single-instance lock is a per-user TCP port derived from the release
  channel (`crates/zed/src/zed/mac_only_instance.rs`), not from the data
  dir, so a second Preview instance always hands off with "zed is already
  running" — `--user-data-dir` does not isolate it. A window-level test of a
  new build needs the hosting Zed to be quit first, by the operator.
- Never quit or kill Zed by name or bundle id (`osascript … "Zed Preview"`,
  `pkill -f zed`, `killall`); every build shares them and the command reaches
  the hosting IDE. Stop test processes by PID only, and do not `-i`-install
  over the bundle a running instance was launched from (check
  `ps -axo pid,comm | grep MacOS/zed`).

Measured on 2026-09-14 (r740-09: 2× Xeon Silver 4216, 64 threads, 125 GiB;
cold volumes): image build 10 min; first stage 1 ≈ 20 min compile + 6 min
link for `zed`+`cli`, 15 min more for `remote_server` (`build.json` reports
1,272 s for the whole Darwin build with warm dependencies); an incremental
relink after a build-script change ≈ 6 min; the 108 MB package crossed the two
SSH hops in about a minute; stage 2 took 15 s with `-i` and 50 s with the DMG.
Compare with 3 h 28 min for the same tag's `bundle_mac_aarch64` job on the
GitHub runner.

#### 5.4.3 Why the toolchain looks the way it does

Every line below cost one failed build; keep them until the cause is gone.

| Symptom | Cause | Where it is handled |
| ------- | ----- | ------------------- |
| `zig cc`: `failed to create path 'z' in local cache directory: Unexpected` | zig ≥ 0.14 uses `statx(2)` for its cache; kernel 3.10 returns `ENOSYS`, which zig reports as `Unexpected`. | Darwin uses clang + `ld64.lld` (Dockerfile); zig only for Linux targets. |
| zig 0.14/0.15: `zig installation bug: unable to parse SDK version` | SDK 26 version string. | Same. |
| zig ≤ 0.13: `undefined symbol: section$end$__DATA$_CTOR0_ISIZE_FN` | zig's Mach-O linker gained `section$start/end` (used by `ctor 1.0`) only in 0.14. | Same. |
| `aws-lc-sys`: `#error "NEON and crypto extensions should be statically available."` | C compiler defaults to a generic arm64 CPU; rustc assumes `apple-m1`. | Wrapper passes `-mcpu=apple-m1`. |
| C++ against SDK headers: `non-defining declaration of enumeration with a fixed underlying type …` | Non-Apple clang promotes `-Welaborated-enum-base` to an error in `CF_ENUM`. | `aarch64-apple-darwin-clang++` passes `-Wno-elaborated-enum-base`. |
| `gpui_apple` build script: `unresolved import cbindgen` | Cargo evaluates `[target.'cfg(target_os = "macos")'.build-dependencies]` against the build host. | Un-gated `[build-dependencies]` in `crates/gpui_apple/Cargo.toml`. |
| `ld64.lld: undefined symbol: __isPlatformVersionAtLeast` | compiler-rt builtin behind `@available`; rustc passes `-nodefaultlibs`, so clang never adds `libclang_rt.osx.a`; Rust's `compiler_builtins` lacks it. | Wrapper appends the mounted `/opt/compiler-rt/libclang_rt.osx.a` on link steps. |
| `ld64.lld: relocation BRANCH26 is out of range … references core::…` in `__ctor_private` | lld only inserts arm64 branch thunks inside `__TEXT,__text`; `zed`'s `__text` is ~220 MB (> 128 MiB `bl` reach) and `ctor` code sits in `__TEXT,__text_startup`. Apple's ld64 uses branch islands. | Wrapper passes `-Wl,-rename_section,__TEXT,__text_startup,__TEXT,__text`. |
| `fatal: couldn't find remote ref <short sha>` on the Linux host | Fetching by object id needs the full 40-hex id. | `script/cross-build-remote` resolves `^{commit}`. |
| Package tarball owned by root on the Linux host | Container runs as root like the CNB runner. | Driver chowns `dist/` and `assets/` back on exit. |

---

## 6. Contributing fixes back to upstream

When we find a fix that's useful beyond our fork (e.g., the minidumper
workaround), we open a PR to `zed-industries/zed`. **Never PR our YOLO/scaffold
patches** — they're intentional fork-only changes upstream won't accept.

### 6.1 Workflow

```bash
# Fetch only live upstream main; no local main branch is needed.
$GH git fetch --filter=blob:none --no-tags upstream \
  +refs/heads/main:refs/remotes/upstream/main

# Branch off upstream main (NOT off enhanced)
git switch -c fix/<short-description> refs/remotes/upstream/main

# Cherry-pick the relevant commit(s) from enhanced
git cherry-pick <sha>

# Verify
$GH cargo check --workspace --all-targets

# Push the explicit branch to our fork.
$GH git push -u github \
  refs/heads/fix/<short-description>:refs/heads/fix/<short-description>

# Exact provider parity includes temporary PR branches. Materialize the branch
# delta as described in §4.6, then mirror the same explicit ref to CNB.
OLD_CNB_MAIN=$($CNB git ls-remote cnb refs/heads/main | awk '{print $1}')
hydrate_delta refs/heads/fix/<short-description> "$OLD_CNB_MAIN"
$CNB git push cnb \
  refs/heads/fix/<short-description>:refs/heads/fix/<short-description>

# Open the PR with the PR template populated
$GH gh pr create --repo zed-industries/zed \
  --base main \
  --head laris:fix/<short-description> \
  --title "<crate>: <imperative-summary>" \
  --body "$(cat <<'EOF'
## Summary
<why this exists>

Closes #<analysis-issue>
Fixes #<bug-issue-if-applicable>

Self-Review Checklist:

- [x] I've reviewed my own diff for quality, security, and reliability
- [x] Unsafe blocks (if any) have justifying comments
- [x] The content is consistent with the UI/UX checklist
- [x] Tests cover the new/changed behavior
- [x] Performance impact has been considered and is acceptable

Release Notes:

- Fixed/Added/Improved …
EOF
)"
```

### 6.2 PR hygiene rules (from upstream CLAUDE.md)

- **PR title:** clear, imperative, correctly capitalized. No conventional-commit
  prefixes (`fix:`, `feat:`). No trailing punctuation. Optionally prefix with a
  crate name when one crate is the clear scope (`crashes: Skip broken …`).
- **Release Notes:** mandatory final section. Single bullet:
  `- Fixed/Added/Improved …` for user-facing changes, or `- N/A` for
  docs-only/non-user-facing.

### 6.3 Closing the loop after merge

When upstream merges your PR:

1. **Verify the change is in the next selected upstream release tag** before
   assuming the fork no longer needs the patch.
2. **At the next upgrade**, the rebase should detect the commit already
   exists upstream and skip it (or you `git rebase --skip` when prompted).
3. **Delete the `fix/` branch:**
   ```bash
   git branch -d fix/<short-description>
   $GH git push github :refs/heads/fix/<short-description>
   $CNB git push cnb :refs/heads/fix/<short-description>
   ```
4. **Update §3 of this doc** — remove the row for the now-upstream patch.

---

## 7. Troubleshooting

### 7.1 "refname is ambiguous"

You have a branch and a tag with the same name (e.g., from older versioned
branches). Disambiguate explicitly:

```bash
git log refs/heads/<name>    # branch
git log refs/tags/<name>     # tag
```

Long-term fix: don't create overlapping names. Our convention (§2.3) avoids
this.

### 7.2 Rebase conflict in a file you don't recognize

```bash
# Look at what the patch was supposed to do
git log -p <patch-sha> -- <file>

# Look at what upstream did
git log v<PREV> v<NEW> -- <file>

# Read the conflicting hunks in context
git diff
```

If you can't make sense of the conflict in 10 minutes, `git rebase --abort`
and ask before retrying.

### 7.3 `cargo check --all-targets` fails after rebase but `cargo check` passes

This usually means a test fixture is missing a new field added by one of our
patches (the symptom that produced patch #5). Look at the error — it'll name
the struct and missing field — and update the corresponding fixture in the
patch that introduced the field.

### 7.4 Build hangs on `cargo install cargo-bundle …`

`script/bundle-mac` tries to install a forked `cargo-bundle`. If your
network blocks GitHub clones or the install hangs, run it manually first:

```bash
$GH cargo install cargo-bundle \
  --git https://github.com/zed-industries/cargo-bundle.git \
  --branch zed-deploy
```

Then re-run `script/bundle-mac`.

### 7.5 "Zed quit unexpectedly" comes back

Means patch #5 (minidumper workaround) isn't in the build (or the rebase
dropped it). Verify:

```bash
git log --grep='Skip broken minidumper' enhanced
```

Should print exactly one commit. If zero, cherry-pick it back from the
archive tag:

```bash
git log --oneline --grep='Skip broken minidumper' enhanced/<PREV>
git cherry-pick <matching-patch-sha>
# or from the open PR branch:
git cherry-pick fix/crash-server-mach-port-on-macos-quit
```

---

## 8. When to revisit this guide

Re-read §1 and §3 if any of these become true:

1. **Upstream lands an equivalent fix or upgrades minidumper** → drop patch #5
   at the next upgrade and delete §3.6. PR #57951 itself was rejected, so do
   not wait for that exact PR to merge.
2. **You add another collaborator** who pulls from `laris/zed-yolo:enhanced` →
   replace the single-owner rebase workflow with merge-based maintenance and
   document the migration here.
3. **Patch set grows past ~15 commits** → execute the compaction plan in §12.3
   at the next scheduled baseline rebase; do not rewrite the published branch
   merely for cosmetic cleanup between checkpoints. (Executed 2026-07-05:
   17 commits → 7; and 2026-08-07: 15 commits → 7.)
4. **A patch becomes irrelevant** (upstream removes the code it touches) →
   drop the patch, document the removal here.
5. **macOS introduces a new bundle identifier convention** → revisit §5.3.

---

## 9. Quick reference (Friday checkpoint)

```bash
# 1. Discover every release since the last checkpoint.
$GH gh api --paginate 'repos/zed-industries/zed/releases?per_page=100' \
  --jq '.[] | select(.draft == false) |
        [.tag_name, .prerelease, .published_at] | @tsv'

# 2. Fetch only upstream main and the selected release tags.
$GH git fetch --filter=blob:none --no-tags upstream \
  +refs/heads/main:refs/remotes/upstream/main
$GH git fetch --filter=blob:none --no-tags upstream \
  refs/tags/<NEW>:refs/tags/<NEW>

# 3. Inspect, archive, hydrate the new baseline's blobs (§4.6), rebase, test.
git log --reverse --oneline '<PREV>^{commit}..enhanced'
git tag -a archive/enhanced/<PREV>-YYYYMMDD-HHMMSS enhanced \
  -m 'Pre-rebase rollback'
hydrate_delta '<NEW>^{commit}' <OLD_CNB_MAIN>
git rebase --onto '<NEW>^{commit}' '<PREV>^{commit}' enhanced
$GH cargo check --workspace --all-targets
$GH script/bundle-mac -d -i aarch64-apple-darwin
git tag -a enhanced/<NEW> enhanced -m 'Validated enhanced build'

# 4. Publish explicit refs to GitHub, hydrate only their delta (§4.6), then
# publish the same explicit refs to CNB. Use the exact leases captured in §4.1.
$GH git push github refs/remotes/upstream/main:refs/heads/main
$GH git push --force-with-lease=<lease> \
  github refs/heads/enhanced:refs/heads/enhanced
$CNB git push cnb refs/remotes/upstream/main:refs/heads/main
$CNB git push --force-with-lease=<lease> \
  cnb refs/heads/enhanced:refs/heads/enhanced

# 5. Full provider proof; output must be empty.
$GH git ls-remote --heads --tags github | LC_ALL=C sort > /tmp/zed.github.refs
$CNB git ls-remote --heads --tags cnb | LC_ALL=C sort > /tmp/zed.cnb.refs
diff -u /tmp/zed.github.refs /tmp/zed.cnb.refs
```

---

## 10. History

| Date       | From          | To             | Notes                                                                                                |
| ---------- | ------------- | -------------- | ---------------------------------------------------------------------------------------------------- |
| 2026-09-14 | `v1.15.0-pre` | `v1.20.0-pre`  | Mirrored all 18 releases published 2026-08-12…09-09 (`v1.15.0`, `v1.16.0-pre`, `v1.16.1-pre`, `v1.15.1`, `v1.16.1`, `v1.17.0-pre`, `v1.17.1-pre`, `v1.16.2`, `v1.17.2-pre`, `v1.16.3`, `v1.17.2`, `v1.18.0-pre`, `v1.19.0-pre`, `v1.18.0`, `v1.19.1-pre`, `v1.18.1`, `v1.19.2`, `v1.20.0-pre`); `v1.20.0-pre` is the newest by `published_at` (24 s after `v1.19.2`), new 1.20 line → non-linear ancestry (merge-base on upstream `main`, 473 commits behind the new tag, 1 PREV-only) passed manual review. Rollback tag `archive/enhanced/v1.15.0-pre-20260914-005305`. 9-commit stack (no compaction). Conflicts in patch #3 (upstream's `reveal_if_open` at the scaffold's insertion points, kept both) and patch #4 (`gpui_macos/build.rs` renamed upstream to `gpui_apple/build.rs`, `bundle-mac` gained `--config .cargo/bundle-config.toml`; see §4.3.1). Patch #1 amended to qualify its one `Settings::get_global` call instead of importing the trait, which had made upstream's `mod tests` import an unused-import warning. Toolchain moved to Rust 1.97.1; `cargo check --workspace --all-targets --features gpui_platform/runtime_shaders` clean (Metal Toolchain still absent locally). minidumper 0.11.0 → crash-context 0.8.0 still calls `mach_port_deallocate` in `Server::drop` → **patch #5 kept**, §3.6 corrected. Batched promised-object hydration (§4.6) fetched the 2,267-blob delta in 11 s. Release published by GitHub Actions from `enhanced/v1.20.0-pre` (all 8 assets; `bundle_mac_aarch64` took 3 h 28 min). Mirrored release tags also queued 18 runs of upstream's `release.yml` in the fork; force-cancelled (§11.1). Follow-up on `enhanced` the same day: the two-stage Linux-cross-compile/macOS-finish build (§5.4), validated end-to-end on `mtbc-r740-09` (CentOS 7, Docker) except for a window-level session, which the operator runs. |
| 2026-08-07 | `v1.14.1-pre` | `v1.15.0-pre`  | Mirrored `v1.14.2-pre`, `v1.13.2`, `v1.14.2`, and `v1.15.0-pre` (published 2026-08-02/05). Executed the §12.3 compaction on the old baseline first: **15 commits → 7**, proven tree-identical to `archive/enhanced/v1.14.1-pre-20260807-211019` — the codex elicitation auto-accept folded into patch #1, the Linux aarch64 CI job folded into the consolidated CI commit, and five per-checkpoint history commits folded into the docs commit. Rebase onto `v1.15.0-pre` applied with zero conflicts (new 1.15 line → non-linear ancestry, merge-base on upstream `main`, 96 commits behind the new tag; the 3 PREV-only commits are 1.14-branch bumps/cherry-picks). Two transient local Git faults (a lazy-blob `fetch-pack` disconnect and an `index.lock` collision that interrupted a pick mid-step, leaving the minidumper patch staged) were recovered by committing the identical staged patch with `-C` and continuing; the net fork diff stayed byte-identical at 25 files, +2924/−54. minidumper still 0.9.0 → workaround kept. Verified with `--features gpui_platform/runtime_shaders`. Release published by GitHub Actions from tag `enhanced/v1.15.0-pre`. |
| 2026-07-30 | `v1.12.0-pre` | `v1.14.1-pre`  | Mirrored `v1.12.0`, `v1.13.0-pre`, `v1.13.1-pre`, `v1.12.1`, `v1.13.1`, and `v1.14.1-pre` (published 2026-07-23…29; upstream published no `v1.14.0-pre`). `v1.14.1-pre` is the newest release by `published_at`; new 1.14 line → non-linear ancestry (merge-base on upstream `main`, 281 commits behind the new tag) passed manual review. One conflict in patch #4: upstream switched `gpui_macos`'s `cbindgen` build-dependency to a workspace dep; kept the fork's un-gated `[build-dependencies]` without the `gpui` build-dep (fork `build.rs` reads gpui *sources* for cbindgen instead of linking it) while adopting `cbindgen.workspace = true`. Remaining 13 commits incl. the codex elicitation auto-accept applied cleanly; its unit test re-ran green. minidumper still 0.9.0 → workaround kept. Verified with `--features gpui_platform/runtime_shaders`. Release published by GitHub Actions from tag `enhanced/v1.14.1-pre`. Stack is now 15 commits — execute the §12.3 compaction at the next baseline rebase. |
| 2026-07-18 | `v1.12.0-pre` | `v1.12.0-pre`  | Fork fix, no baseline change: extended patch #1 so enhanced YOLO also auto-accepts codex MCP tool-approval **elicitations**. The new `@agentclientprotocol/codex-acp` adapter (successor to `zed-industries/codex-acp`) forwards codex MCP tool approvals as ACP `elicitation/create` with an injected "Approval scope" `persist` select whenever the client advertises form elicitation — bypassing `session/request_permission` and therefore the existing auto-approver. Detection keys on `_meta.codex_approval_kind == "mcp_tool_call"`; answers the most persistent scope (`always` → `session` → `once`); unmarked elicitations and forms with extra required fields remain interactive. Unit test covers the adapter wire shape. Published as re-spin tag `enhanced/v1.12.0-pre.2` per §11.4. |
| 2026-07-17 | `v1.11.3-pre` | `v1.12.0-pre`  | Mirrored `v1.11.3` and `v1.12.0-pre` (both published 2026-07-15). `v1.12.0-pre` is the newest release by `published_at`; new 1.12 minor line, so the §4.2 ancestry check was non-linear (11 PREV-only 1.11-branch bumps/cherry-picks; merge-base on upstream `main`, 150 commits behind the new tag) and passed manual review. Rebase of the 11-commit stack applied with zero conflicts; no compaction (under the §8 threshold). minidumper still 0.9.0 → workaround kept. Verified with `--features gpui_platform/runtime_shaders` (local Metal Toolchain still missing). Release build started by GitHub Actions from tag `enhanced/v1.12.0-pre`; artifacts retrieved by the operator from the published release. |
| 2026-07-13 | `v1.11.1-pre` | `v1.11.3-pre`  | Mirrored `v1.10.2`, `v1.11.2-pre`, `v1.10.3`, and `v1.11.3-pre` (published 2026-07-10/13). `v1.11.3-pre` is the newest release by `published_at` and stays on the same 1.11 release branch as the previous baseline, so the §4.2 ancestry check was linear (6 upstream commits). Rebase of the 10-commit stack applied with zero conflicts; no compaction (under the §8 threshold). minidumper still 0.9.0 → workaround kept. Verified with `--features gpui_platform/runtime_shaders` (local Metal Toolchain still missing). Release build started by GitHub Actions from tag `enhanced/v1.11.3-pre`; artifacts retrieved by the operator from the published release. |
| 2026-07-10 | `v1.10.0-pre` | `v1.11.1-pre`  | Mirrored `v1.10.0`, `v1.11.0-pre`, `v1.11.1-pre`, and `v1.10.1` (all published 2026-07-08/09). `v1.10.1` has the newest `published_at` by 8 minutes, but the baseline moved to the newest preview `v1.11.1-pre` (a 1.10-line patch final would move the feature baseline backward; explicit operator selection). No compaction: the 9-commit stack is under the §8 threshold. Rebase applied with zero conflicts (148 upstream commits since the shared merge-base, incl. 4 on the 1.11 release branch). minidumper still 0.9.0 → workaround kept. Verified with `--features gpui_platform/runtime_shaders` (local Metal Toolchain still missing). Release with all eight §11.3 asset files (first tag build to include `zed-remote-server-linux-aarch64.gz`) published by GitHub Actions from tag `enhanced/v1.11.1-pre`. |
| 2026-07-05 | `v1.9.0-pre`  | `v1.10.0-pre`  | Mirrored `v1.9.0` and `v1.10.0-pre` (both published 2026-07-01, after the prior checkpoint). Executed the §12.3 compaction on the old baseline first: 17 commits → 7 (fixtures folded into patch #1; set-u fixes and the `auto_update` bundled-server hunks moved into patch #4; one consolidated CI commit; one consolidated docs commit), proven tree-identical to `archive/enhanced/v1.9.0-pre-20260705-212649`. Rebase onto `v1.10.0-pre` applied with zero conflicts (111 upstream commits since the shared merge-base; the two preview tags sit on separate release branches, so the §4.2 linear-ancestry check required manual review). minidumper still 0.9.0 → workaround kept. Local Metal Toolchain component still missing → verified with `--features gpui_platform/runtime_shaders`. macOS/Linux artifacts built and released by GitHub Actions from tag `enhanced/v1.10.0-pre`. |
| 2026-07-02 | `v1.9.0-pre`  | `v1.9.0-pre`   | Audited the complete replay history and net fork diff. Documented stable invariants, immutable-tag semantics, provider-retirement verification, CI cost, and the next-rebase compaction plan. No product source or upstream baseline changed. |
| 2026-07-02 | `v1.9.0-pre`  | `v1.9.0-pre`   | Unified the maintained names as GitHub `laris/zed-yolo` and private CNB `lary.me/zed-yolo` without fetching a newer upstream baseline. Reused CNB's complete GitHub-matching ref inventory and updated only `enhanced`. Deleted predecessor `zed-upstream` after proving that it preserved no unique reachable Git refs, releases, or assets. The delete clients reported HTTP 412/403, but subsequent official metadata and Git checks both confirmed `Repository Not Found`. |
| 2026-07-01 | `v1.9.0-pre`  | `v1.9.0-pre`   | Adopted the one-partial-clone Friday checkpoint policy, explicit-ref incremental GitHub/CNB publishing, promised-object hydration, and exact remote-to-remote parity proof. No source rebase in this documentation-only change. |
| 2026-06-27 | `v1.5.3-pre`  | `v1.9.0-pre`   | 624 upstream commits. Conflicts only in patch #1 (acp.rs imports + 2 fn sites; agent_settings.rs and settings_content/agent.rs vs upstream's new `sandbox_permissions`). Patches #2/#5/#6 auto-merged cleanly despite heavy churn (crashes.rs +89/−90, zed.rs +262/−21). PR #57951 confirmed **rejected** (CLA + maintainer prefers upstream minidumper fix), minidumper still 0.9 → **patch #6 kept**. Hit local "missing Metal Toolchain" — verified with `--features gpui_platform/runtime_shaders` (now documented in §4.4). |
| 2026-05-29 | `v1.5.0-pre`  | `v1.5.3-pre`   | 3 patch releases. Refactored CI into `build-enhanced.yml` with parallel mac + linux jobs and tag-driven GitHub Release publishing. Added §3.7 and §11. |
| 2026-05-23 | `v1.4.1-pre`  | `v1.5.0-pre`   | 135 upstream commits. One conflict in `acp.rs` imports. Added patch #6 (minidumper workaround) here. |
| 2026-05-22 | `v1.2.1-pre`  | `v1.4.1-pre`   | 333 upstream commits. Test fixtures needed `enhanced_yolo` field (patch #5 added).                   |
| (earlier)  | `v1.1.5-pre`  | `v1.2.1-pre`   | Pre-Option-B layout — branch-per-version.                                                            |
| 2026-05-28 | n/a           | n/a            | Migrated to Option B (single rolling `enhanced` branch + archival tags). Wrote this document.        |

Append a new row at every upgrade.

---

## 11. GitHub Actions release workflow

The fork ships releases via `.github/workflows/build-enhanced.yml` running
on `laris/zed-yolo`. It is **not** a copy of upstream's `release.yml` — upstream's
file is generated from `xtask::workflows::release`, uses Namespace.so
runners, code-signing certs, and ~10 secrets we don't have. We use a
purpose-built, smaller workflow on GitHub-hosted runners.

### 11.1 Triggers

| Event                         | What happens                                                            |
| ----------------------------- | ----------------------------------------------------------------------- |
| Push to `enhanced` branch     | All build jobs run; artifacts uploaded to the workflow run only.        |
| Push of `enhanced/v*` tag     | All build jobs run; **GitHub Release is created** with the artifacts.   |
| `workflow_dispatch` (manual)  | Same as branch push; choose `release` or `dev` profile. No release.     |

Mirroring upstream release tags (§4.5) also fires **upstream's own**
`.github/workflows/release.yml` in the fork, once per tag. Those runs need
Namespace runners and secrets the fork lacks, so they sit `queued` forever and
clutter the Actions list. `gh run cancel` does not remove a run that never
obtained a runner; use the force-cancel endpoint instead (observed 2026-09-14,
18 runs):

```bash
for ID in $($GH gh run list --repo laris/zed-yolo --limit 40 \
    --json databaseId,workflowName,status \
    --jq '.[] | select(.workflowName == "release" and .status != "completed") | .databaseId'); do
  $GH gh api -X POST "repos/laris/zed-yolo/actions/runs/${ID}/force-cancel"
done
```

Disabling that workflow in the fork (`$GH gh workflow disable release --repo
laris/zed-yolo`) would stop the runs at the source; it has not been done
because it is a repository-settings change outside the Git history.

### 11.2 Jobs

| Job                                       | Runner          | Builds                                              | Approx time |
| ----------------------------------------- | --------------- | --------------------------------------------------- | ----------- |
| `bundle_mac_aarch64`                      | `macos-latest`  | `Zed-Preview.app`, `Zed-aarch64.dmg`, `zed-remote-server-macos-aarch64.gz` | 30–210 min (cache-dependent; ~155 min observed cold after the v1.10 bump, 208 min after the v1.20 bump) |
| `bundle_linux_remote_server_x86_64`       | `ubuntu-latest` | `zed-remote-server-linux-x86_64.gz` (musl, static)  | 5–15 min    |
| `bundle_linux_remote_server_aarch64`      | `ubuntu-24.04-arm` | `zed-remote-server-linux-aarch64.gz` (musl, static) | 5–15 min    |
| `publish_release`                         | `ubuntu-latest` | GitHub Release (tag push only)                      | 1–2 min     |

### 11.3 Release artifacts

When an `enhanced/v*` tag is pushed, `publish_release` creates the matching
GitHub Release under `https://github.com/laris/zed-yolo/releases/tag/<tag>` with:

- `Zed-Preview-aarch64.tar.gz` + `.sha256` — the macOS `.app`, tarred (preserves
  ad-hoc signature, resource forks, symlinks).
- `Zed-aarch64.dmg` — the same `.app` distributed as a DMG.
- `zed-remote-server-macos-aarch64.gz` — gzipped binary for use as remote
  server on a macOS aarch64 host.
- `zed-remote-server-linux-x86_64.gz` + `.sha256` — gzipped statically-linked
  musl binary, runs on any glibc or musl Linux x86_64 host.
- `zed-remote-server-linux-aarch64.gz` + `.sha256` — same, for Linux aarch64
  hosts (added 2026-07-06; appended post-publication to `enhanced/v1.10.0-pre`).

Assets may be **appended** to an already-published release only when they are
built from a tree identical to the released tag (prove it:
`git diff <tag>..enhanced -- ':(exclude).github' ':(exclude)MAINTAINING.md'`
must be empty). Never replace or delete an existing asset; that breaks the
immutability expectation just like moving the tag would.

An `enhanced/vX.Y.Z-pre` build and its `-pre.N` re-spins are marked
**prerelease**. An `enhanced/vX.Y.Z` build based on an upstream final release
is not. Keep this conditional behavior aligned with upstream's release
classification.

Release notes are **auto-generated** from commit history between the previous
and current tag via `gh release create --generate-notes`.

### 11.4 Failure policy

`publish_release` **fails loudly** if a release with the same tag already
exists. Tags should be treated as immutable.

If the build fails after the immutable tag has been pushed:

1. Inspect the failure in the workflow run.
2. Fix the source code or the workflow.
3. Do **not** delete or move the published tag. Create a new validated re-spin
   tag and mirror it to both providers:
   ```bash
   git tag -a enhanced/vX.Y.Z-pre.2 enhanced -m 'Validated re-spin 2'
   $GH git push github \
     refs/tags/enhanced/vX.Y.Z-pre.2:refs/tags/enhanced/vX.Y.Z-pre.2
   $CNB git push cnb \
     refs/tags/enhanced/vX.Y.Z-pre.2:refs/tags/enhanced/vX.Y.Z-pre.2
   ```
4. Re-run the provider parity proof from §4.8.

### 11.5 Reusing upstream scripts

The workflow calls upstream-derived shell scripts that we have customized.
Each rebase, diff them against the new upstream to confirm our local mods
still apply:

```bash
git diff "$NEW"..enhanced -- script/bundle-mac
```

See §3.7 for what blocks live in `script/bundle-mac`. If upstream renames or
reorganizes a script, the rebase will likely conflict; resolve the conflict
to preserve the three blocks.

### 11.6 Secrets we don't (yet) have

Adding any of the following enables features currently disabled in CI:

| Secret                            | Enables                                              |
| --------------------------------- | ---------------------------------------------------- |
| `MACOS_CERTIFICATE` + password    | Developer-ID code signing (replaces ad-hoc)          |
| `APPLE_NOTARIZATION_KEY` + id + issuer | Apple notarization (no Gatekeeper warning)      |
| `SENTRY_AUTH_TOKEN`               | Upload debug symbols + minidumps to Sentry           |
| `ZED_CLIENT_CHECKSUM_SEED`        | Match upstream's binary self-update integrity hash   |

`script/bundle-mac` picks these up automatically when present (no workflow
changes needed). Store them as repository secrets in `laris/zed-yolo` settings.

### 11.7 Build minutes

`laris/zed-yolo` is public, so standard GitHub-hosted macOS and Linux runners
are not billed under GitHub's current public-repository policy. They remain
subject to GitHub usage policy, queueing, concurrency, and service limits; do
not describe the capacity itself as unlimited.

---

## 12. Lessons from the fork history

This section records the design conclusions that are easy to lose when only
the current tree is examined. The 2026-07-05 compaction reduced the replay
stack from 17 commits to 7, but new commits accumulate between compactions,
so always derive the live replay list instead of trusting a stored count:

```bash
PREV=v1.10.0-pre
git log --reverse --format='%h %ad %s' --date=short \
  "$PREV^{commit}..enhanced"
git rev-list --count "$PREV^{commit}..enhanced"
git diff --stat "$PREV^{commit}..enhanced"
```

### 12.1 Invariants that define a healthy fork

| Concern | Invariant | Authoritative proof |
| ------- | --------- | ------------------- |
| Selected baseline | The selected unchanged upstream release tag is an ancestor of `enhanced`. | `git merge-base --is-ancestor "$PREV^{commit}" enhanced` |
| Checkpoint `main` | GitHub and CNB contain the same fast-forward snapshot of upstream `main`; it may be newer than the selected release baseline. | Compare `refs/heads/main` on both providers and prove the old checkpoint is its ancestor before updating. |
| Rolling patch branch | Local, GitHub, and CNB `enhanced` are identical after publication. | Exact SHA comparison with a force-with-lease for any rebase. |
| Release coverage | Every upstream release published by the checkpoint exists unchanged on both maintained providers. | Compare tag-object SHAs across upstream, GitHub, and CNB. |
| Provider parity | Every advertised GitHub fork head and tag has the same ref-object SHA in CNB. | The remote-to-remote comparison in §2.5.2; the intentionally sparse local clone is not the inventory authority. |
| Published artifacts | Upstream, enhanced-build, and rollback tags are immutable. | Reject any operation that would move an existing tag. |
| Network boundary | GitHub uses `$GH`; CNB uses `$CNB`/`$CNB_API` without proxy or Keychain access. | Inspect the exact wrapper used for every network command. |

Do not call a maintenance run complete when only the local branch is clean or
only the two `enhanced` SHAs match. The all-ref provider proof is a separate
invariant.

### 12.2 What the history taught us

| Observation | Durable lesson | Maintenance consequence |
| ----------- | -------------- | ----------------------- |
| Early branch-per-version maintenance created overlapping names and cleanup pressure. | Keep one rolling branch and use namespaced immutable tags for release and rollback identity. | Never recreate version branches or reuse a tag name as a branch. |
| The YOLO setting compiled before all-target fixtures were updated. | A product patch is incomplete until test-only constructors and fixtures compile. | Keep `cargo check --workspace --all-targets` mandatory; the standalone fixture commit was folded into patch #1 on 2026-07-05. |
| The YOLO commit also added bundled remote-server selection in `auto_update`. | Commit titles and actual ownership can drift as experiments grow. | Done 2026-07-05: the `auto_update` hunks moved into the bundling patch; keep the YOLO commit focused on policy. |
| Bash 3.2 with `set -u` rejected empty-array expansion in the macOS bundle script. | CI scripts must be validated on the oldest shell actually used by a runner. | Preserve the set-u-safe expansions until upstream removes the need. |
| The first GitHub workflow and its timeout tweak were later replaced entirely. | Intermediate CI implementations add rebase work without preserving useful final behavior. | Collapse the surviving workflow into one commit during scheduled compaction. |
| A `blob:none` clone could enumerate commits while lacking blobs needed by CNB. | Object discovery and object availability are different states. | Hydrate only the new reachable delta through GitHub before starting a no-proxy CNB push. |
| The local partial clone intentionally lacks the complete branch/tag inventory. | Local-versus-remote parity can report thousands of false differences. | Compare GitHub directly with CNB, then separately verify the few locally maintained refs. |
| GitHub could rename in place, while CNB required migration/reuse of another repository. | Provider identity changes are provider-specific workflows, not ordinary Git remote edits. | Verify target availability and contents before changing local URLs. |
| CNB delete clients reported HTTP 412/403, but later API and Git reads both returned not found. | A mutation response is evidence, not the final state. Errors can leave the outcome unknown. | Always perform read-after-mutation checks against both provider metadata and Git transport. |
| The retired CNB repository had no unique Git refs/releases/assets but did have five build logs. | Git parity does not preserve provider-side records. | Inventory and explicitly accept the loss of releases, assets, issues, builds, and logs before deletion. |
| Documentation-only pushes to `enhanced` run the current build workflow. | Operational notes have real CI cost. | Batch related documentation updates and consider a reviewed `paths-ignore` rule for `MAINTAINING.md`. |
| The guide once called the modified bundler “unchanged” and treated an attachment variable as a tag trigger. | Operational documentation must be checked against executable files, not only earlier prose. | During each review, grep hard-coded versions/triggers and compare claims with `.cnb.yml`, workflows, and scripts. |
| Per-object lazy fetches made hydration take longer than the rebase itself, and `git log -G` over an upstream range never finished. | In a `blob:none` clone, object *discovery* is cheap but every content read is a network round trip unless batched. | Hydrate with one `git fetch --stdin` of all missing OIDs (§4.6) before the rebase; never content-search across upstream ranges. |
| The minidumper "removal criterion" pointed at the wrong crate; a version bump looked like a fix. | Record the exact file and symbol that a workaround exists for, in the crate that actually contains it. | §3.6 names `crash-context/src/mac/ipc.rs`; verify against the lockfile's resolved crate, not the name in the criterion. |
| The CNB cross-build had compiled for months but its Darwin binaries had never been run; three build scripts silently dropped macOS behaviour on a Linux host. | `cfg!(target_os)` in `build.rs` means the host. A cross-build is only validated by running its output. | Gate on `CARGO_CFG_TARGET_OS` (§3.4) and keep the stage-2 smoke test in §5.4 part of every toolchain change. |
| zig could not be used on the CentOS 7 build host at any version: ≥ 0.14 needs `statx(2)`, ≤ 0.13 lacks `section$start/end`. | A toolchain pinned to one host kernel is fragile; LLVM's own Mach-O linker plus Apple's compiler-rt slice reproduces Apple's link closely with plain glibc binaries. | §5.4.3 lists every link-time trap and its fix; re-check them when clang/lld or the SDK moves. |
| A smoke test quit "Zed Preview" by application name from inside a Zed-hosted agent session, killing the session. | Every Zed build shares bundle id, process name and the per-user instance port. | Test binaries by PID with `--system-specs`; window-level tests are the operator's (§5.4.2). |

### 12.3 Compaction plan (executed 2026-07-05 and 2026-08-07; template for future runs)

This plan has been executed twice — at the 2026-07-05 checkpoint (v1.9.0-pre →
v1.10.0-pre, 17 commits → 7) and at the 2026-08-07 checkpoint (v1.14.1-pre →
v1.15.0-pre, 15 commits → 7). Both times the stack was rebuilt on the **old**
baseline, proven tree-identical to the rollback tag, and only then rebased onto
the new baseline. Each run restores the same seven-commit shape: the five
product patches of §3 plus one consolidated CI commit and one consolidated
documentation commit; new work accumulates on top until the §8 threshold is
reached again. Do not compact between checkpoints: that would create an extra
published-history rewrite with no upstream benefit. At the next scheduled
baseline rewrite:

1. Publish the normal timestamped rollback tag to both providers first.
2. Save the current ordered commit list and net diff, then start an interactive
   rebase on the current `$PREV` before moving to `$NEW`.
3. Fold `agent, agent_ui: Add enhanced_yolo to test fixtures` into
   `Add config-backed enhanced YOLO runtime`, because the fixtures are part of
   that feature's completeness. Move that commit's bundled remote-server
   selection hunks in `auto_update` into the bundling group.
4. Keep the product marker, project-manager scaffold, and minidumper workaround
   independently droppable.
5. Fold both `script/bundle-mac` set-u fixes into the CNB/bundling patch. If
   conflicts remain expensive, split that large patch into (a) CNB
   runner/container files, (b) cross-compilation source shims, and (c) bundle
   integration, with each resulting commit buildable.
6. Replace the initial GitHub Actions workflow, its timeout tweak, and the
   later replacement/refinement commits with one commit containing only the
   final `.github/workflows/build-enhanced.yml` behavior.
7. Split mixed workflow/documentation commits, then consolidate the
   `MAINTAINING.md` history into one documentation commit. Preserve the
   operational chronology in §10 before squashing commits.
8. Before changing the baseline, prove compaction did not change the tree:
   ```bash
   git diff --exit-code "$ROLLBACK^{tree}" enhanced^{tree}
   ```
9. Rebase the compact stack onto `$NEW`, run §4.4, inspect `git range-diff`
   between the archived and new series, and publish with the leases captured
   in §4.1.

Never rewrite the immutable upstream, enhanced-build, or archive tags as part
of compaction. A smaller replay stack is valuable only if the final behavior,
audit log, and rollback path remain intact.

### 12.4 Provider rename and retirement runbook

For any future provider rename, migration, or deletion:

1. Record repository identity, visibility, default branch, fork parent,
   current remote URLs, and complete head/tag snapshots.
2. For GitHub, verify the target name is unused and use `gh repo rename`; then
   verify the fork relationship and update the local remote, API paths,
   release URLs, secrets documentation, and ledgers. Do not rely indefinitely
   on GitHub's old-name redirect.
3. For CNB, assume the slug cannot be renamed in place. Reuse or create the
   destination, synchronize explicit refs, and prove destination parity before
   retiring the source.
4. Prove every source ref is preserved. Exact ref equality is simplest; if a
   rolling branch advanced, prove the old tip is an ancestor of the active tip
   or retain it under an immutable archive tag.
5. Audit data outside Git: Git LFS objects, releases and attachments, generic
   assets, issues/PRs, repository settings, build records/logs, packages, and
   webhooks. State explicitly which records will migrate and which will be
   discarded.
6. Perform the authorized mutation, then poll both the provider API and Git
   URL. Treat any disagreement or client error as **unknown**, not success or
   failure, until repeated reads reach one terminal state.
7. Update `MAINTAINING.md` and `REPOSITORY_SYNC_STATUS.md`, then rerun the full
   active-provider parity proof.

Advertised-ref parity proves preservation of all objects reachable from those
refs. It does not prove preservation of unreachable server objects or
provider-owned metadata.

### 12.5 Documentation and CI discipline

- Keep volatile SHAs and counts in the external synchronization ledger or
  command output; embedding the current branch SHA in this tracked file is
  self-referential.
- Record decisions and observed failure modes here, but keep raw build logs
  and temporary ref snapshots outside Git unless they are needed as durable
  evidence.
- Batch documentation changes when practical. Do not force-push merely to
  reduce documentation commit count; use the scheduled compaction in §12.3.
- If `paths-ignore: [MAINTAINING.md]` is added to the enhanced-branch trigger,
  validate that workflow-file changes and enhanced tags still run all required
  build and release jobs.
