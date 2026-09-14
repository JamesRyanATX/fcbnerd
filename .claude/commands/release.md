---
description: Cut a new fcbnerd release (bump version, tag, publish, verify Homebrew)
argument-hint: major|minor|patch
allowed-tools: Bash(git:*), Bash(gh:*), Bash(swift:*), Bash(brew:*), Bash(curl:*), Bash(shasum:*), Read, Edit
---

Release a new version of fcbnerd. Bump: `$ARGUMENTS`

Pushing a `vX.Y.Z` tag is the whole release mechanism:
`.github/workflows/release.yml` tests, publishes a GitHub Release with a
universal binary, and commits a regenerated formula to
JamesRyanATX/homebrew-tap, whose `test.yml` then installs and tests it. This
command prepares that tag, pushes it, and checks every stage of the pipeline.

## 1. Check the input

`$ARGUMENTS` must be exactly `major`, `minor` or `patch`. If it's anything
else or empty, stop and show: `usage: /release major|minor|patch`.

## 2. Preflight: stop on any failure

- `git status --porcelain` must be empty.
- The current branch must be `main`.
- `git fetch origin --tags`, then `main` must equal `origin/main`. If it's
  behind or has diverged, stop. If it's only ahead, those commits ship in
  this release; list them in the confirmation.
- CI must be green for HEAD:
  `gh run list --workflow ci.yml --commit "$(git rev-parse HEAD)" --json status,conclusion`.
  If the run is in progress, wait for it with `gh run watch`. If there is no
  run (HEAD not pushed yet), rely on the local test run below.
- `swift test` must pass.

## 3. Work out the version

- The current version is the string in `let version = "X.Y.Z"` in
  `Sources/fcbnerd/main.swift`.
- It must match the latest tag (`git describe --tags --abbrev=0`, without the
  `v`). If not, stop and report both values.
- Bump it: `major` → `X+1.0.0`, `minor` → `X.Y+1.0`, `patch` → `X.Y.Z+1`.
- The new tag `vNEW` must not already exist, locally or on origin
  (`git ls-remote --tags origin vNEW`).

## 4. Confirm

Show the user:
- the current and new version,
- `git log --oneline vCURRENT..HEAD` (the commits being released),
- a warning if that list is empty.

Then use AskUserQuestion to confirm before changing anything. A pushed tag
triggers a public release, so don't skip this step.

## 5. Bump, commit, tag, push

1. Change `let version = "CURRENT"` to `let version = "NEW"` in
   `Sources/fcbnerd/main.swift`.
2. `swift build`, then check `.build/debug/fcbnerd --version` prints NEW.
3. `git commit -am "Release vNEW"`, ending the message with the session's
   attribution lines.
4. `git tag -a vNEW -m "fcbnerd NEW"`
5. `git push origin main`, then `git push origin vNEW`. Don't use `-u`: the
   user's global git config already sets upstreams, and `-u` creates a
   duplicate that breaks later pushes.

## 6. Watch the pipeline

1. **Release run:** find the run triggered by the tag,
   `gh run list --workflow release.yml --json databaseId,headBranch,status --limit 5`,
   taking the entry whose `headBranch` is `vNEW`. It can take a few seconds
   to appear, so retry. Watch it with
   `gh run watch <id> --exit-status --interval 15`, running in the
   background.
2. **Release assets:** `gh release view vNEW` must list
   `fcbnerd-NEW-macos-universal.tar.gz` and its `.sha256`.
3. **Formula:** in JamesRyanATX/homebrew-tap, the latest commit must be
   `fcbnerd NEW`, and `Formula/fcbnerd.rb` must reference vNEW
   (`gh api repos/JamesRyanATX/homebrew-tap/contents/Formula/fcbnerd.rb --jq .content | base64 -d`).
4. **Tap test:** find the JamesRyanATX/homebrew-tap `test.yml` run for that
   commit and watch it the same way.
5. **Local install:**
   `git -C "$(brew --repo jamesryanatx/tap)" pull`, then
   `brew upgrade jamesryanatx/tap/fcbnerd` (or `brew install` if it isn't
   installed), then check `fcbnerd --version` prints NEW.

## 7. Report

Report the new version, the release URL, and the result of each stage in
step 6.

If a stage fails:
- Show the failing step's log (`gh run view <id> --log-failed`).
- Don't delete or move the tag, and don't force-push, without asking. After
  fixing a workflow problem on `main`, you can republish the same tag with
  `gh workflow run release.yml -f tag=vNEW`.
