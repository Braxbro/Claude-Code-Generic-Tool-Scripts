#!/usr/bin/env bash
# multistage-skill.sh [<claude-path>] <skill-file> [flags...] ["prompt"]
# claude-path is optional — auto-detected if omitted or if first arg is not executable.
# Runs a MULTI-SKILL-CONTENT.md file as a staged pipeline using --session-id/--resume.
# Stage bodies are separated by ---NEXT--- and support Claude skill substitution syntax:
#   $ARGUMENTS / ${ARGUMENTS}   — full prompt string
#   $ARGUMENTS[N]               — 0-based argument by index
#   $N / ${N}                   — shorthand for $ARGUMENTS[N]
#   ${CLAUDE_SESSION_ID}        — pipeline session UUID
#   ${CLAUDE_SKILL_DIR}         — directory containing the skill file
#   !`command`                  — shell injection (runs before Claude sees the content)

set -euo pipefail

PERMISSION_FLAGS=(
    "--permission-mode"
    "--dangerously-skip-permissions"
    "--allow-dangerously-skip-permissions"
)

# ── Args ──────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: multistage-skill.sh [<claude-path>] <skill-file> [flags...] [\"prompt\"]" >&2
    exit 1
fi

# Auto-detect claude binary if first arg is not an executable file
if [[ -x "$1" ]]; then
    CLAUDE="$1"
    shift
else
    CLAUDE=$(which claude 2>/dev/null || find /home -name "claude" -path "*/native-binary/claude" 2>/dev/null -print -quit || true)
    if [[ -z "$CLAUDE" ]]; then
        echo "Error: claude binary not found. Pass it as the first argument." >&2
        exit 1
    fi
fi

SKILL_FILE="$1"
shift

if [[ ! -f "$SKILL_FILE" ]]; then
    echo "Error: skill file not found: $SKILL_FILE" >&2
    exit 1
fi

# ── Parse flags and prompt ────────────────────────────────────────────────────

PASSTHROUGH_FLAGS=()
PROMPT=""
DEBUG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --permission-mode|--dangerously-skip-permissions|--allow-dangerously-skip-permissions)
            echo "Error: permission escalation flags are not allowed at invocation. Remove '$1' and try again." >&2
            exit 1
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --*)
            PASSTHROUGH_FLAGS+=("$1")
            shift
            ;;
        *)
            # Treat as prompt (last bare arg wins)
            PROMPT="$1"
            shift
            ;;
    esac
done

# ── Parse frontmatter ─────────────────────────────────────────────────────────

FRONTMATTER=$(awk '/^---$/{if(f){exit}f=1;next} f{print}' "$SKILL_FILE")

fm_get() {
    echo "$FRONTMATTER" | grep -E "^$1:" | head -1 | sed "s/^$1:[[:space:]]*//" | sed "s/[\"']//g" || true
}

FM_MODEL=$(fm_get "model")
FM_EFFORT=$(fm_get "effort")
FM_ADD_DIR=$(fm_get "add-dir")
FM_ALLOWED=$(fm_get "allowed-tools")
FM_DISALLOWED=$(fm_get "disallowed-tools")
FM_BUDGET=$(fm_get "max-budget-usd")
FM_SYSPROMPT=$(fm_get "append-system-prompt")
FM_DEBUG=$(fm_get "debug")
[[ "$FM_DEBUG" == "true" ]] && DEBUG=1

# Denylist check on frontmatter
for flag in "${PERMISSION_FLAGS[@]}"; do
    key="${flag#--}"
    if echo "$FRONTMATTER" | grep -qE "^${key}:"; then
        echo "Error: '${key}' is not allowed in skill files. Permission escalation flags must never appear in pipeline content." >&2
        exit 1
    fi
done

# Build frontmatter-derived CLI args
FM_ARGS=()
[[ -n "$FM_MODEL" ]]     && FM_ARGS+=("--model" "$FM_MODEL")
[[ -n "$FM_EFFORT" ]]    && FM_ARGS+=("--effort" "$FM_EFFORT")
[[ -n "$FM_ADD_DIR" ]]   && FM_ARGS+=("--add-dir" "$FM_ADD_DIR")
[[ -n "$FM_ALLOWED" ]]   && FM_ARGS+=("--allowed-tools" "$FM_ALLOWED")
[[ -n "$FM_DISALLOWED" ]] && FM_ARGS+=("--disallowed-tools" "$FM_DISALLOWED")
[[ -n "$FM_BUDGET" ]]    && FM_ARGS+=("--max-budget-usd" "$FM_BUDGET")
[[ -n "$FM_SYSPROMPT" ]] && FM_ARGS+=("--append-system-prompt" "$FM_SYSPROMPT")

# ── Parse stages ──────────────────────────────────────────────────────────────

SID=$(python3 -c "import uuid; print(uuid.uuid4())")

# Extract body (everything after closing ---)
BODY=$(awk '/^---$/{n++; if(n==2){found=1; next}} found{print}' "$SKILL_FILE")

# Argument substitution on full body before slicing
SKILL_DIR=$(dirname "$(realpath "$SKILL_FILE")")
read -r -a ARGS <<< "$PROMPT"

# If $ARGUMENTS not referenced anywhere in body, append prompt to first stage
if [[ -n "$PROMPT" && "$BODY" != *'$ARGUMENTS'* ]]; then
    BODY="$BODY"$'\n\nARGUMENTS: '"$PROMPT"
fi

# Shell injection: !`command` → replaced with command output
BODY=$(echo "$BODY" | perl -pe 's/!`([^`]*)`/`$1`/ge')

# $ARGUMENTS[N] before $ARGUMENTS to avoid partial match (0-based)
# Use python3 here — avoids sed injection from special chars in val, and handles literal brackets
for i in "${!ARGS[@]}"; do
    val="${ARGS[$i]}"
    BODY=$(printf '%s' "$BODY" | python3 -c "
import sys
content = sys.stdin.read()
needle = '\$ARGUMENTS[$i]'
sys.stdout.write(content.replace(needle, sys.argv[1]))
" "$val")
done

# $ARGUMENTS / ${ARGUMENTS} — full prompt
BODY="${BODY//\$ARGUMENTS/$PROMPT}"
BODY="${BODY//\$\{ARGUMENTS\}/$PROMPT}"

# $N / ${N} shorthand (0-based)
for i in "${!ARGS[@]}"; do
    BODY="${BODY//\$$i/${ARGS[$i]}}"
    BODY="${BODY//\$\{$i\}/${ARGS[$i]}}"
done

# Special vars
BODY="${BODY//\$\{CLAUDE_SESSION_ID\}/$SID}"
BODY="${BODY//\$\{CLAUDE_SKILL_DIR\}/$SKILL_DIR}"

# Split on ---NEXT---
mapfile -d $'\x00' -t STAGES < <(
    printf '%s' "$BODY" | python3 -c "
import sys
content = sys.stdin.read()
parts = content.split('\n---NEXT---\n')
for p in parts:
    sys.stdout.buffer.write(p.encode() + b'\x00')
"
)

if [[ ${#STAGES[@]} -eq 0 ]]; then
    echo "Error: no stages found in skill file." >&2
    exit 1
fi

# ── Run pipeline ──────────────────────────────────────────────────────────────

for i in "${!STAGES[@]}"; do
    stage="${STAGES[$i]}"

    # Strip leading/trailing whitespace
    stage=$(echo "$stage" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba}')

    if [[ $i -eq 0 ]]; then
        OUTPUT=$("$CLAUDE" --print --session-id "$SID" "${FM_ARGS[@]}" "${PASSTHROUGH_FLAGS[@]}" "$stage")
    else
        OUTPUT=$("$CLAUDE" --print --resume "$SID" "${FM_ARGS[@]}" "${PASSTHROUGH_FLAGS[@]}" "$stage")
    fi

    if [[ "$DEBUG" -eq 1 ]]; then
        echo "--- Stage $((i + 1)) ---"
        echo "$OUTPUT"
        echo
    fi
done

if [[ "$DEBUG" -eq 0 ]]; then
    printf '%s\n' "$OUTPUT"
fi
