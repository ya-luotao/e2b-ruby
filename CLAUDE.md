# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Ruby SDK for the E2B sandbox API. The public surface lives under the `E2B` module:

- `E2B::Sandbox` — current API; use this in new code and examples.
- `E2B::Client` — legacy class kept for backward compatibility; do not extend it without need.
- `E2B::Template` — DSL for building custom images.

## Commands

- `bundle exec rake` — runs `rake spec` then `rake rubocop` (the default task). Use this as the gate before commits.
- `bundle exec rake spec` — RSpec only (prefer over bare `rspec` so the bundle is honored).
- `COVERAGE=true bundle exec rake spec` — same run with SimpleCov instrumentation (branch coverage on). Writes an HTML report to `coverage/` and fails if it drops below the floor in `spec/spec_helper.rb` (currently line 80% / branch 58%). Coverage is opt-in so single-file runs aren't failed by the gate; raise the floor as coverage improves.
- `bundle exec rake rubocop` — style + RSpec cops; config in `.rubocop.yml`. Pre-existing waivers live in `.rubocop_todo.yml` — tighten by deleting an entry there and fixing the underlying violations, not by silencing them in the main config.
- `bundle exec rubocop -a` — apply safe autofixes (no `-A`; unsafe corrections are reviewed by hand).
- `bundle exec rake build` — build the gem into `pkg/`.
- `bundle exec rake console` — IRB with `E2B` loaded; auto-configures from `E2B_API_KEY` if set. There is no `bin/console`.
- `bundle exec rake examples` — run every `examples/*.rb` against a real sandbox; requires `E2B_API_KEY`.

There is no CI workflow yet. The local correctness gate is the default `rake` (spec + rubocop).

## Critical invariants — do not silently break

These were fixed in v0.3.4 and are easy to regress when editing `lib/e2b/services/` or `lib/e2b/api/http_client.rb`:

1. **`stdin: false` is the default for `E2B::Services::Commands.run` and friends.** Setting `stdin: true` opens an envd stdin pipe; if the caller never writes to it, envd hangs. Only set `stdin: true` when the caller actually `send_stdin(...)`s on a background process. This default matches the TS/Python SDKs.

2. **All process-output base64 decoding goes through `E2B::Services::EnvdBase64.decode_process_output`.** A direct `Base64.decode64(...)` on `stdout`/`stderr`/`pty` from envd raises `Encoding::CompatibilityError` on multibyte UTF-8 output. Never re-implement decoding in a new service or model — route through `EnvdBase64`.

3. **The `process.Process/Start` streaming RPC must not be retried.** Faraday/HTTP retries on this route cause duplicated process spawns. See the comment in `lib/e2b/services/base_service.rb` (~line 256). Any change to retry policy in `lib/e2b/api/http_client.rb` or `base_service.rb` must preserve this exclusion.

A `/invariants` skill audits these three rules — run it after any change in `lib/e2b/services/` or `lib/e2b/api/`, and before tagging a release.

## Version and CHANGELOG

- Version source of truth: `lib/e2b/version.rb` (`E2B::VERSION`). The gemspec reads it via `require_relative "lib/e2b/version"`. Bump only here.
- `CHANGELOG.md` follows Keep-a-Changelog. New work goes under `[Unreleased]`; promote it to `[X.Y.Z] - YYYY-MM-DD` only at release time.
- Releases are scripted: invoke `/release` (definition in `.claude/commands/release.md`). It stops before `gem push` — the maintainer runs that manually with an OTP.

## Tests

Specs live in `spec/`. HTTP is fully mocked via WebMock — no real network. `spec/spec_helper.rb` calls `E2B.reset_configuration!` around each example to keep global state isolated; preserve that contract when adding specs that touch `E2B.configure`. New WebMock stubs should target the same hostnames the real client hits (`api.e2b.dev` and per-sandbox `*.e2b.dev` envd URLs) — see existing specs for the pattern.

Expect the full suite to take **2–9 minutes** depending on random seed: some streaming/PTY specs use real wall-clock timeouts. Long runs are not hangs. To iterate faster, run a single file (`bundle exec rspec spec/e2b/services/<name>_spec.rb`) or pin a known-fast seed (`--seed 14670`).
