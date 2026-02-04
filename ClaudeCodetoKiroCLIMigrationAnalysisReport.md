# Claude Code to Kiro CLI Migration Analysis Report

This document records the migration from [claudecode-telegram](https://github.com/hanxiao/claudecode-telegram) to kiro-telegram.

## Migration Overview

The original project `claudecode-telegram` was a Telegram bot bridge for Claude Code. This project has been migrated and adapted to work with Kiro CLI.

## Feature Comparison

| Feature | Claude Code | Kiro CLI |
|---------|-------------|----------|
| Startup Command | `claude --dangerously-skip-permissions` | `kiro-cli chat --trust-all-tools` |
| Session Resume | `--resume {session_id}` | `--resume` / `--resume-picker` |
| Config Directory | `~/.claude/` | `~/.kiro/` |
| tmux Session Name | `claude` | `kiro` |
| Hook Configuration | `settings.json` | Agent config file |
| Response Capture | Read transcript.jsonl | tmux capture-pane |
| Ralph Loop | ✅ Supported | ❌ Not supported |

## Key Changes

### 1. tmux Session Management
- Session name changed from `claude` to `kiro`
- State files moved from `~/.claude/` to `~/.kiro/`

### 2. Startup Command
- Changed from `claude --dangerously-skip-permissions` to `kiro-cli chat --trust-all-tools`
- Added `--agent telegram-bridge` parameter for Agent configuration

### 3. Session Resume
- Claude Code: `--resume {session_id}` for direct session ID specification
- Kiro CLI: `--resume` for most recent, `--resume-picker` for interactive selection

### 4. Hook Mechanism
- Claude Code: Configured in `~/.claude/settings.json`
- Kiro CLI: Configured in Agent JSON file (`~/.kiro/agents/telegram-bridge.json`)

### 5. Response Capture
- Claude Code: Read from `transcript.jsonl` file
- Kiro CLI: Use `tmux capture-pane` to capture terminal output

### 6. Removed Features
- Ralph Loop functionality is not available in Kiro CLI
- `/continue_` command replaced with `/resume`
- No longer reads `~/.claude/history.jsonl` for session listing

## Migration Checklist

When migrating from Claude Code version:

- [ ] Stop the original Claude Code Bridge
- [ ] Install Kiro Agent config to `~/.kiro/agents/`
- [ ] Install Hook script to `~/.kiro/hooks/`
- [ ] Update Bot Token in Hook script
- [ ] Create new tmux session `kiro`
- [ ] Start Kiro CLI with `--agent telegram-bridge`
- [ ] Update Telegram Webhook URL (if tunnel URL changed)

## Known Limitations

1. **Ralph Loop not supported**: Kiro CLI doesn't have Ralph Loop feature like Claude Code
2. **Session ID direct resume**: `--resume {session_id}` not supported, use `--resume-picker` for interactive selection
3. **Response capture method**: Uses tmux capture-pane instead of reading transcript file
4. **Session history list**: Doesn't read `~/.claude/history.jsonl`, uses Kiro's built-in session management

## Original Project

This project is based on [claudecode-telegram](https://github.com/hanxiao/claudecode-telegram) by Han Xiao.

## License

MIT
