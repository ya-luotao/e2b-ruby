---
description: Cut a new gem release — bump version, update CHANGELOG, tag, build, and draft a GitHub release. Stops before `gem push` (manual OTP).
argument-hint: patch | minor | major | <explicit-version> [--dry-run]
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Release the gem

You are cutting a new release of the `e2b` Ruby gem. Argument: `$ARGUMENTS`.

The final `gem push` step is **NOT** automated — the maintainer runs it manually with an OTP. Your job ends at "GitHub release published; here is the command to run."

## Preconditions — fail loudly if any of these are wrong

Run these in one batch and abort if any fail:

1. Current branch is `main` (`git rev-parse --abbrev-ref HEAD`).
2. Working tree is clean (`git status --porcelain` returns empty).
3. Local is synced with origin (`git fetch && git status -sb` shows `## main...origin/main` with no `ahead`/`behind`).
4. Last run of `bundle exec rake` is green — run it now and abort on failure. (`rake` here is spec-only; there is no rubocop task.)

If the user passed `--dry-run`, do everything below **except** git commit, push, tag, and `gh release create`. Print the planned diff instead.

## Step 1 — Determine the new version

Read current version from `lib/e2b/version.rb` (the `VERSION = '...'` constant is the source of truth; the gemspec reads it via `require_relative "lib/e2b/version"`).

Resolve the requested version:
- `patch` → bump the last segment (e.g. `0.3.2` → `0.3.3`).
- `minor` → bump middle, reset patch (`0.3.2` → `0.4.0`).
- `major` → bump first, reset rest (`0.3.2` → `1.0.0`).
- Explicit `X.Y.Z` → use as-is after a semver sanity check.

Show the proposed version and the commits since the last tag:

```
git describe --tags --abbrev=0                     # last tag, e.g. v0.3.2
git log <last-tag>..HEAD --oneline --no-merges     # commits to include
```

## Step 2 — Version bumps

Edit these files. Use `Edit`, not `sed`.

1. **`lib/e2b/version.rb`** — replace the `VERSION` string. This is the only source of truth; `e2b.gemspec` reads it.
2. **`README.md`** — currently the install snippets do **not** carry a version pin (just `gem 'e2b'` and `gem install e2b`). Confirm with `grep -nE "(gem 'e2b'|gem install e2b|gem \"e2b\")" README.md` — only edit if a future pin like `~> X.Y.Z` or `-v X.Y.Z` has been added.

There is no plugin manifest, no `skills/` tree, and no committed `CLAUDE.md` in this repo, so no other version sites need updating.

## Step 3 — CHANGELOG

Open `CHANGELOG.md`. The file follows Keep-a-Changelog and prior releases use a leading `## [Unreleased]` section that gets promoted on release.

1. Promote `## [Unreleased]` content into a new `## [X.Y.Z] - YYYY-MM-DD` section (use today's date, UTC).
2. Leave a fresh empty `## [Unreleased]` section at the top.
3. Use subsections `### Added`, `### Changed`, `### Fixed`, `### Removed`, `### Internal` as applicable (prior releases use `### Internal` for refactors). If `[Unreleased]` was empty, synthesize entries from `git log <last-tag>..HEAD`, grouping by commit message intent.

Keep entries terse and user-facing — describe what gem consumers can now do or no longer do, not internal refactors (use `### Internal` for those).

## Step 4 — Validate

Run in this order, abort on failure:

```
bundle exec rake            # spec
bundle exec rake build      # produces pkg/e2b-X.Y.Z.gem
```

Confirm the built gem filename matches the new version. (Note: `*.gem` and `pkg/` are gitignored, so the built artifact is never committed — don't try to stage it.)

## Step 5 — Commit, tag, push

Match the commit convention used by prior releases (see `git show v0.3.2` for reference):

```
Release X.Y.Z

<short 1–3 line summary of what's in this release; point to CHANGELOG for the full set>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Stage explicitly — not `git add -A` — to keep gitignored artifacts out:

```
git add lib/e2b/version.rb CHANGELOG.md
# Add README.md only if Step 2.2 modified it.
git commit -m "$(cat <<'EOF'
...
EOF
)"
git push origin main
```

Then tag and push the tag:

```
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

## Step 6 — GitHub release

Draft the release body from the new CHANGELOG section. Shape:

```markdown
### Added
- ...
### Changed
- ...
### Fixed
- ...

### What's changed
- #NN <title> — @author

**Full Changelog**: https://github.com/ya-luotao/e2b-ruby/compare/v<prev>...vX.Y.Z

---

\`\`\`
gem install e2b -v X.Y.Z
\`\`\`
```

Generate the "What's changed" list from merged PRs since the last tag:

```
gh pr list --repo ya-luotao/e2b-ruby \
  --state merged --search "merged:>=<last-tag-date>" \
  --json number,title,author
```

Create the release:

```
gh release create vX.Y.Z --repo ya-luotao/e2b-ruby \
  --title "vX.Y.Z" --notes-file <tmpfile>
```

Mark it latest only if it is (for hotfixes to older minor lines, pass `--latest=false`).

## Step 7 — Hand off to the maintainer

Stop here. Print the exact command the user needs to run:

```
gem push pkg/e2b-X.Y.Z.gem
```

Remind them they need their RubyGems OTP. **Do not** attempt `gem push` yourself.

## What to report back

A terse summary:
- New version
- Files changed (count)
- Commit SHA + tag name
- GitHub release URL
- The `gem push` command to run

That's it — no trailing recap of the workflow.
