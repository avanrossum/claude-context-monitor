#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Claude Code Context Monitor
# Checks active Claude Code sessions for context window usage
# and alerts when approaching auto-compaction threshold.
#
# Usage: ./claude-context-monitor.sh [--warn-at 70] [--max-age 24] [--context 200]
#   --warn-at   Percentage threshold for warning (default: 70)
#   --red-at    Percentage threshold for red alert (default: 85)
#   --max-age   Only check sessions modified within N hours (default: 24)
#   --context   Context window size in K tokens (default: 200)
#   --quiet     Only output if warnings found
#   --notify    Show macOS notification for warnings
#   --alert-life N  Number of seconds to show the alert (default: 5)
#   --watch [N]  Live-updating display, refresh every N seconds (default: 5)
# ──────────────────────────────────────────────────────────────

WARN_AT=70
RED_AT=85
MAX_AGE_HOURS=24
QUIET=false
NOTIFY=false
ALERT_LIFE=5
CONTEXT_K=200  # Context window in K tokens (200 = 200K)
WATCH=false
WATCH_INTERVAL=5

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --warn-at)   WARN_AT="$2"; shift 2 ;;
    --red-at)    RED_AT="$2"; shift 2 ;;
    --max-age)   MAX_AGE_HOURS="$2"; shift 2 ;;
    --context)   CONTEXT_K="$2"; shift 2 ;;
    --quiet)     QUIET=true; shift ;;
    --notify)    NOTIFY=true; shift ;;
    --alert-life) ALERT_LIFE="$2"; shift 2 ;;
    --watch)
      WATCH=true; shift
      # Optional interval argument (next arg if it's a number)
      if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
        WATCH_INTERVAL="$1"; shift
      fi
      ;;
    *)           shift ;;
  esac
done

CONTEXT_WINDOW=$((CONTEXT_K * 1000))

CLAUDE_DIR="$HOME/.claude/projects"

if [ ! -d "$CLAUDE_DIR" ]; then
  echo "No Claude Code projects found at $CLAUDE_DIR"
  exit 0
fi

# ── Main scan function ──────────────────────────────────────
run_scan() {
  # Find session files modified within MAX_AGE_HOURS
  # Exclude subagent files - only check main session files
  MAX_AGE_MINS=$((MAX_AGE_HOURS * 60))

  # Use a temp file to collect results (avoids subshell variable scoping issues)
  TMPFILE=$(mktemp)
  trap "rm -f $TMPFILE $TMPFILE.lines" RETURN

  find "$CLAUDE_DIR" -maxdepth 2 -name "*.jsonl" -not -path "*/subagents/*" -mmin -"$MAX_AGE_MINS" 2>/dev/null | sort -u | while IFS= read -r session_file; do
    [ -z "$session_file" ] && continue

    # Extract project name from the encoded directory path
    project_dir=$(basename "$(dirname "$session_file")")
    friendly_name=$(echo "$project_dir" | sed -E 's/^-Users-[^-]+-[^-]+-//' | sed 's/-/ /g')
    if [ ${#friendly_name} -gt 30 ]; then
      friendly_name="${friendly_name:0:27}..."
    fi

    # Get file modification time
    mod_time=$(stat -f "%Sm" -t "%H:%M" "$session_file" 2>/dev/null || echo "?")

    # Parse JSONL and find the last assistant message's total input tokens
    # Also detect if a compact_boundary event occurred after the last token data
    result=$(python3 -c "
import json, sys
from datetime import datetime, timezone

last_total = 0
max_total = 0
msg_count = 0
compacted_since_last = False
compact_time = ''

try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                d = json.loads(line.strip())
            except:
                continue
            if d.get('type') == 'assistant':
                msg = d.get('message', {})
                usage = msg.get('usage', {})
                inp = usage.get('input_tokens', 0)
                cache_create = usage.get('cache_creation_input_tokens', 0)
                cache_read = usage.get('cache_read_input_tokens', 0)
                total = inp + cache_create + cache_read
                if total > 0:
                    last_total = total
                    msg_count += 1
                    compacted_since_last = False
                if total > max_total:
                    max_total = total
            elif d.get('type') == 'system' and d.get('subtype') == 'compact_boundary':
                compacted_since_last = True
                ts = d.get('timestamp', '')
                if ts:
                    try:
                        dt = datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone()
                        compact_time = dt.strftime('%H:%M')
                    except:
                        pass
            elif d.get('type') == 'summary':
                compacted_since_last = True
except Exception as e:
    print('0|0|0|0|', file=sys.stderr)
    print('0|0|0|0|')
    sys.exit(0)

print(f'{last_total}|{max_total}|{msg_count}|{1 if compacted_since_last else 0}|{compact_time}')
" "$session_file" 2>/dev/null)

    last_tokens=$(echo "$result" | cut -d'|' -f1)
    peak_tokens=$(echo "$result" | cut -d'|' -f2)
    msg_count=$(echo "$result" | cut -d'|' -f3)
    just_compacted=$(echo "$result" | cut -d'|' -f4)
    compact_time=$(echo "$result" | cut -d'|' -f5)

    # Skip sessions with no meaningful data
    if [ "$last_tokens" -eq 0 ] 2>/dev/null; then
      continue
    fi

    # Determine status and format output
    if [ "$just_compacted" -eq 1 ] 2>/dev/null; then
      status="🟢 Compacted"
      if [ -n "$compact_time" ]; then
        detail="Compacted at $compact_time"
      else
        detail="Compacted at $mod_time"
      fi

      if $QUIET; then
        continue
      fi

      printf "%-32s  %s  %s\n" \
        "$friendly_name" "$status" "$detail" >> "$TMPFILE.lines"
    else
      last_pct=$((last_tokens * 100 / CONTEXT_WINDOW))
      peak_pct=$((peak_tokens * 100 / CONTEXT_WINDOW))

      last_k=$(python3 -c "print(f'{$last_tokens/1000:.1f}K')")
      peak_k=$(python3 -c "print(f'{$peak_tokens/1000:.1f}K')")

      if [ "$last_pct" -ge "$RED_AT" ]; then
        status="🔴 COMPACT NOW"
        echo "WARN" >> "$TMPFILE"
      elif [ "$last_pct" -ge "$WARN_AT" ]; then
        status="🟡 Getting close"
        echo "WARN" >> "$TMPFILE"
      else
        status="🟢 OK"
      fi

      if $QUIET && [ "$last_pct" -lt "$WARN_AT" ]; then
        continue
      fi

      printf "%-32s  %s  Current: %6s (%2d%%)  Peak: %6s (%2d%%)  Msgs: %d  [%s]\n" \
        "$friendly_name" "$status" "$last_k" "$last_pct" "$peak_k" "$peak_pct" "$msg_count" "$mod_time" >> "$TMPFILE.lines"
    fi

  done

  # Count warnings
  WARNINGS=$(wc -l < "$TMPFILE" 2>/dev/null | tr -d ' ')
  WARNINGS=${WARNINGS:-0}

  # Print results
  if [ -f "$TMPFILE.lines" ]; then
    if ! $QUIET; then
      echo "═══ Claude Code Context Monitor ═══"
      echo "Context window: ${CONTEXT_K}K tokens  |  Red Alert: ${RED_AT}%  |  Warning: ${WARN_AT}%"
      printf "Filter: Sessions modified in last %sh" "$MAX_AGE_HOURS"
      if $WATCH; then
        printf "  |  Refreshing every ${WATCH_INTERVAL}s  |  $(date '+%H:%M:%S')"
      fi
      echo -e "\n"
    fi
    cat "$TMPFILE.lines"

    if ! $QUIET && ! $WATCH; then
      echo ""
      echo "Tip: Run /compact in Claude Code before auto-compaction to preserve memory"
    fi
  elif ! $QUIET; then
    echo "═══ Claude Code Context Monitor ═══"
    echo "No active sessions found (modified within ${MAX_AGE_HOURS}h)"
    echo "Try increasing --max-age to see older projects."
  fi

  # macOS notification for warnings
  if $NOTIFY && [ "$WARNINGS" -gt 0 ]; then
    if [ "$WARNINGS" -eq 1 ]; then
      msg="1 Claude Code session is approaching context limit"
    else
      msg="$WARNINGS Claude Code sessions are approaching context limit. \nThis alert will close in $ALERT_LIFE seconds."
    fi
    osascript -e "display alert \"$msg\" giving up after $ALERT_LIFE" >/dev/null 2>&1
  fi

  return $([ "$WARNINGS" -gt 0 ] && echo 1 || echo 0)
}

# ── Run ─────────────────────────────────────────────────────
if $WATCH; then
  # Hide cursor, restore on exit
  printf '\033[?25l'
  trap "printf '\033[?25h\n'; exit 0" INT EXIT
  # Clear screen once on first draw
  printf '\033[2J'
  while true; do
    # Move cursor to top-left, overwrite in place
    printf '\033[H'
    run_scan
    # Clear any leftover lines from previous (longer) output
    printf '\033[J'
    sleep "$WATCH_INTERVAL"
  done
else
  run_scan
  exit $?
fi
