# Changelog

All notable changes to the E2B Ruby SDK will be documented in this file.

## [0.3.2] - 2026-04-30

### Fixed

- **`parse_exit_code` silently mapping non-zero statuses to 0** — `EnvdHttpClient#parse_exit_code` previously returned `0` for any unparseable status string containing the digit `"0"`, causing commands that failed with messages like `"code: 100"` to look successful and skip raising `CommandExitError`. Fallback now always returns `1`.
- **`Sandbox#process_sandbox_data` clobbering attributes** — partial API responses that omit `alias`, `clientID`, `cpuCount`, `memoryMB`, `metadata`, `startedAt`, or `endAt` no longer overwrite previously-known values with `nil`.
- **`parse_time` crashing on non-string timestamps** — `Sandbox#parse_time` and the `parse_time`/`parse_modified_time` helpers in `Models::SandboxInfo`, `Models::TemplateLogEntry`, and `Models::EntryInfo` now also rescue `TypeError`, surviving malformed numeric or hash values.
- **`Filesystem#exists?` swallowing all `E2BError` subclasses** — only `NotFoundError` is treated as "does not exist"; auth and network errors now propagate.
- **Streaming RPC retries replaying side-effecting requests** — `EnvdHttpClient#handle_streaming_rpc` no longer retries through `with_retry` once any event has been delivered to the caller. Previously, a mid-stream connection drop on `process.Process/Start` could spawn a second process and replay output to the user's `on_stdout` callback.
- **Encoding fix in `create_connect_envelope`** is now covered by tests (UTF-8 multibyte, large bodies).
- **Plain-JSON fallback when Connect protocol returns 415** is now exercised by tests.
- **`examples/claude_code_runner.rb`** — replaced calls to non-existent `sandbox.filesystem` accessor with `sandbox.files`, and `entry[:name]` hash access with the `EntryInfo#name` accessor.

### Changed

- **`Sandbox#connect` (instance method) is deprecated** — emits a deprecation warning and points users to `#resume`. The class method `Sandbox.connect(id, ...)` is unchanged. The instance method only resumed the current sandbox, but its name collided with the class method's "connect to a sandbox by ID" semantics.
- **`Sandbox.list` YARD return type** corrected from `Array<Hash>` to `SandboxPaginator`.
- **`Sandbox.kill` and `Sandbox#kill` idempotency** is now documented in YARD; behavior is unchanged (returns `true` whether the sandbox was running or already gone).

### Internal

- Replaced per-RPC `OpenStruct` allocation in the unary RPC code path with a `Struct` (`EnvdHttpClient::RpcResponse`). Drops the `ostruct` gemspec dependency and reduces allocation cost.
- Added `spec/e2b/services/envd_http_client_spec.rb` with 13 tests covering `parse_exit_code`, `decode_base64`, `create_connect_envelope` (including the recent Encoding fix), and `parse_connect_stream`.

## [0.3.1] - 2026-03-20

### Added

- **`Commands#close_stdin`** — close stdin on a running process, mirroring the existing `Pty#close_stdin`. Needed for bidirectional stdin/stdout protocols (e.g., Claude Code's stream-json mode) where the caller must signal end-of-input.

## [0.3.0] - 2026-03-13

Full parity with the official E2B Python/JS SDKs.

### Added

- **Access token authentication** — `access_token:` parameter alongside API keys for bearer auth
- **Template builder** — programmatic `Template` class with `from_image`, `from_dockerfile`, `copy`, `run_cmd`, `set_envs`, `pip_install`, `npm_install`, `apt_install`, `git_clone`, and more
- **Template builds** — `Template.build`, `Template.build_in_background`, `Template.wait_for_build_finish` with log streaming
- **Template tags** — `Template.assign_tags`, `Template.remove_tags`, `Template.get_tags`
- **Dockerfile parser** — parse Dockerfiles into template builder instructions
- **Snapshot management** — `create_snapshot`, `list_snapshots`, `delete_snapshot` on both `Sandbox` and `Client`
- **Sandbox pagination** — `SandboxPaginator` and `SnapshotPaginator` with cursor-based `next_items` / `has_next?`
- **Sandbox lifecycle options** — `secure:`, `allow_internet_access:`, `network:`, `lifecycle:`, `auto_pause:` parameters
- **MCP gateway support** — automatic MCP template selection and gateway startup with `mcp:` parameter
- **Live streaming** — background commands and PTYs use `LiveEventStream` for real-time `on_stdout`/`on_stderr`/`on_data` callbacks
- **File URL signing** — `download_url` and `upload_url` accept `use_signature_expiration:` for secured sandboxes
- **User auth propagation** — per-user `Authorization: Basic` headers threaded through filesystem, command, and PTY RPCs
- **Ready command helpers** — `E2B.wait_for_port`, `wait_for_url`, `wait_for_process`, `wait_for_file`, `wait_for_timeout`
- **Build logger** — `E2B.default_build_logger` with level filtering and elapsed-time formatting
- New models: `BuildInfo`, `BuildStatusReason`, `SnapshotInfo`, `TemplateBuildStatusResponse`, `TemplateLogEntry`, `TemplateTag`, `TemplateTagInfo`
- New error types: `BuildError`, `FileUploadError`

### Changed

- **Default sandbox timeout** changed from 1 hour to 5 minutes (matching official SDKs)
- **`Sandbox.connect`** now always uses the `/connect` endpoint (previously used GET for no-timeout case)
- **`Sandbox.list`** returns a `SandboxPaginator` instead of a raw array
- **Filesystem `read`** supports `format:` parameter (`"text"`, `"bytes"`, `"stream"`)
- **Filesystem `write`** returns `WriteInfo` instead of boolean
- **Recursive directory watching** gated by envd version with clear error message
- **Legacy envd compatibility** — default username automatically applied for envd < 0.4.0
- `HttpClient` supports `detailed:` responses with headers, `delete` accepts `body:`, debug mode routes to localhost

### Fixed

- **Shell injection in MCP gateway** — config JSON is now shell-escaped via `Shellwords.shellescape`

### Internal

- Extracted `SandboxHelpers` module to deduplicate shared logic between `Sandbox` and `Client`
- Extracted `LiveStreamable` module to deduplicate live-stream handle builder between `Commands` and `Pty`
- Removed unused `headers:` parameter from `handle_rpc_response`

## [0.2.0] - 2026-03-12

First public release on RubyGems. Aligned with official E2B Python/JS SDKs.

### Added

- **Sandbox class methods** (`Sandbox.create`, `.connect`, `.list`, `.kill`) matching official SDK pattern
- **CommandHandle** for background process management with `wait`, `kill`, `send_stdin`, `disconnect`
- **CommandResult** value object with `stdout`, `stderr`, `exit_code`, `success?`
- **PTY service** (`sandbox.pty`) for interactive terminal sessions - `create`, `connect`, `send_stdin`, `kill`, `resize`, `close_stdin`
- **Git service** (`sandbox.git`) with 19 methods - `clone`, `init`, `status`, `branches`, `add`, `commit`, `push`, `pull`, `reset`, `restore`, `create_branch`, `checkout_branch`, `delete_branch`, `remote_add`, `remote_get`, `set_config`, `get_config`, `configure_user`, `dangerously_authenticate`
- **GitStatus** and **GitBranches** data structures with query methods (`clean?`, `has_staged?`, `has_untracked?`, etc.)
- **Directory watching** via `WatchHandle` with polling-based `get_new_events` and `stop`
- **EntryInfo** model with proper filesystem metadata (`name`, `type`, `path`, `size`, `mode`, `permissions`, `owner`, `group`, `modified_time`, `symlink_target`)
- **FilesystemEvent** model with typed events (`CREATE`, `WRITE`, `REMOVE`, `RENAME`, `CHMOD`)
- Snapshot support (`sandbox.create_snapshot`)
- New error types: `CommandExitError`, `InvalidArgumentError`, `NotEnoughSpaceError`, `TemplateError`, `GitAuthError`, `GitUpstreamError`
- Configuration support for `E2B_ACCESS_TOKEN`, `E2B_DOMAIN`, `E2B_DEBUG` environment variables

### Changed

- **Filesystem service rewritten** - uses proper envd RPC (`Stat`, `ListDir`, `MakeDir`, `Move`, `Remove`) and REST multipart upload instead of shell commands (`ls -la`, `base64 -d`, `test -e`)
- **Commands service** now uses `/bin/bash -l -c` (matching official SDK), raises `CommandExitError` on non-zero exit codes, returns `CommandHandle` for background mode
- **Base service** cleaned up - removed Rails-specific logging, extracted retry logic
- **Sandbox timeout** now in seconds (was milliseconds) to match official API
- `Client` class simplified as backward-compatible wrapper around `Sandbox` class methods

## [0.1.0] - 2026-01-12

Initial development version (not published to RubyGems).

### Added

- Basic sandbox lifecycle (create, connect, kill, pause, resume)
- Command execution via Connect RPC with streaming support
- File read via REST, file write via shell commands
- Faraday-based HTTP client for E2B management API
- Connect RPC binary envelope parsing

[0.3.1]: https://github.com/ya-luotao/e2b-ruby/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/ya-luotao/e2b-ruby/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ya-luotao/e2b-ruby/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ya-luotao/e2b-ruby/releases/tag/v0.1.0
