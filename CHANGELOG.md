# Changelog

All notable changes to the E2B Ruby SDK will be documented in this file.

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

[0.2.0]: https://github.com/ya-luotao/e2b-ruby/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ya-luotao/e2b-ruby/releases/tag/v0.1.0
