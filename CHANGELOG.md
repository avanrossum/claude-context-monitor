# Changelog

## 1.1.0 - 2026-02-22

### Added

- `--watch [N]` flag for live-updating htop-style display (default: refresh every 5 seconds)
- Flicker-free rendering in watch mode (cursor-home overwrite instead of screen clear)

## 1.0.1 - 2026-02-22

### Fixed

- Context status now correctly shows green after a compact operation instead of staying yellow/red until the next request
- Compacted sessions display "Compacted at [time]" instead of stale token counts

### How it works

Claude Code writes a `compact_boundary` system message and/or `summary` entry to the session JSONL after compaction, but no new assistant message (with updated token counts) appears until the next user request. The monitor now detects these markers and treats the session as freshly compacted.

## 1.0.0 - 2026-02-21

Initial release.

- Monitors active Claude Code sessions for context window usage
- Color-coded status: green (OK), yellow (warning), red (compact now)
- Configurable thresholds (`--warn-at`, `--red-at`, `--context`)
- Session age filtering (`--max-age`)
- Quiet mode (`--quiet`) for cron/scripting use
- macOS notifications (`--notify`, `--alert-life`)
