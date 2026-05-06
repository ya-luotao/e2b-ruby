---
name: invariants
description: Audit the v0.3.4 correctness invariants of the e2b gem — base64 decode centralization, stdin default, and process.Process/Start no-retry. Use after editing lib/e2b/services/ or lib/e2b/api/, and before tagging a release.
---

# Invariant audit for the e2b gem

You are auditing three correctness invariants that were fixed in v0.3.4. They are easy to regress and there is no CI / linter to catch the regression for us. Run the checks below, report each as PASS or FAIL with the exact offending lines, and stop at the first FAIL only if the user asked for `--fix-first`; otherwise list them all.

## Invariant 1 — Process output base64 decoding is centralized in `E2B::Services::EnvdBase64`

Allowed callsites are inside `lib/e2b/services/envd_base64.rb` itself, plus any code that calls `EnvdBase64.decode_process_output` (the centralized helper). Anything else doing base64 decoding on process output is a regression.

Run:

```sh
# Any direct Base64.decode64 / Base64.urlsafe_decode64 outside the centralized helper
grep -rnE 'Base64\.(decode64|urlsafe_decode64)' lib/ \
  | grep -v 'lib/e2b/services/envd_base64.rb'
```

Empty output → PASS. Any matches → FAIL. For each match, check whether it operates on `stdout` / `stderr` / `pty` data from envd; if so, it must be replaced with `EnvdBase64.decode_process_output(...)`. Decoding of unrelated payloads (auth tokens, etc.) is allowed — call those out as "review needed" rather than failures.

Also confirm coverage from the other side:

```sh
grep -rn 'EnvdBase64\.decode_process_output' lib/ | wc -l
```

This should be ≥ 6 callsites (services and models that emit process output). A sudden drop suggests someone deleted decode paths.

## Invariant 2 — `stdin: false` is the default for `Commands.run` and the long-running variants

The default in `Commands.run` and equivalents must remain `false`. Setting it `true` without a corresponding `send_stdin(...)` causes envd to hang.

Public method signatures span multiple lines, so do not try to filter signatures vs. callsites with regex. Pull every `stdin: <value>` occurrence and classify each by reading the surrounding code:

```sh
# Word-boundary match — excludes `handle_send_stdin:` and similar
grep -rnE '(^|[(, ])stdin: (true|false)\b' lib/ spec/
```

For each match, classify it:

- **Signature default in `lib/e2b/services/`, `lib/e2b/sandbox.rb`, or `lib/e2b/client.rb`** → must be `stdin: false`. `stdin: true` here is a FAIL.
- **Forwarded value in a request body (e.g. `{ stdin: stdin }` or `input: { stdin: encoded }`)** → not a default; ignore.
- **Callsite passing `stdin: true` in `lib/`** → FAIL unless the same code path also calls `send_stdin(...)` on the resulting handle.
- **Callsite passing `stdin: true` in `spec/`** → allowed only if the example explicitly tests stdin behavior (e.g. `it "forwards stdin: true ..."`); otherwise FAIL.
- **Test description strings (the `it "... stdin: true ..."` line itself)** → ignore. The match is in the description, not in code.

Comment lines (`#`) and YARD doc lines mentioning `stdin: true` as documentation are not matches because they will not pass the regex's preceding-character constraint, but if one slips through, ignore it.

## Invariant 3 — `process.Process/Start` is never retried

Any HTTP retry policy (Faraday `:retry` middleware, manual retry loops in `base_service.rb`, etc.) must skip the `process.Process/Start` route. The reason: it is a streaming RPC; a retry would spawn a duplicate process.

Run:

```sh
# Find every retry-related construct
grep -rnE '(faraday-retry|:retry|retry_policy|retry_options|retries|retry_if|retryable\?)' \
  lib/e2b/api/ lib/e2b/services/base_service.rb
```

For each retry construct, verify the path/method-exclusion logic mentions either `process.Process/Start` or `process/Start` (or an equivalent skip). The canonical reference is the comment in `lib/e2b/services/base_service.rb` near line 256 (`# * \`process.Process/Start\` is **never retried**`). If a retry block exists with no such exclusion, FAIL.

Also grep the comment itself to make sure it has not been deleted:

```sh
grep -n 'process\.Process/Start' lib/e2b/services/base_service.rb
```

Missing → FAIL (the documentation guard is gone).

## Reporting

Print a compact summary like:

```
Invariant 1 (EnvdBase64 centralization): PASS  (8 callsites)
Invariant 2 (stdin: false default):       FAIL — lib/e2b/services/commands.rb:42 sets `stdin: true`
Invariant 3 (Process/Start no retry):     PASS
```

If everything passes, end with: "All v0.3.4 invariants intact." If anything fails, end with the suggested fix for each FAIL — do not auto-edit unless the user invoked the skill with `--fix` in `$ARGUMENTS`.
