# multistage-skill.sh

A shell script for running Claude Code multi-stage pipelines with real session continuity. Each stage runs as a separate `claude --print` invocation, but all stages share the same session via `--session-id` / `--resume`, giving the model genuine context accumulation and cache hits across stages.

## Why

Claude Code skills run in a single prompt. For complex tasks, this means the model has to do retrieval and reasoning in the same pass — and it tends to anchor early. Splitting the work into stages lets each stage do one thing well, and the `--resume` mechanism means the next stage sees the previous stage's output as cached context rather than re-paying input token costs.

This is cheaper than spawning separate agents for each stage and significantly better than trying to fit everything into one prompt.

## Installation

Copy `multistage-skill.sh` to somewhere on your system. Requires:
- `bash` 4.4+
- `python3` (for stage splitting and argument substitution)
- `perl` (for shell injection support)
- A Claude Code binary (auto-detected or passed explicitly)

## Usage

```bash
bash multistage-skill.sh [<claude-path>] <skill-file> [flags...] ["prompt"]
```

- **`claude-path`** — optional; auto-detected via `which claude` or a search for the VSCode extension binary if omitted
- **`skill-file`** — path to a `MULTI-SKILL-CONTENT.md` file (see format below)
- **`flags`** — any supported CLI flags (see below); permission escalation flags are blocked
- **`"prompt"`** — the initial prompt, passed as a quoted string

### Examples

```bash
# Auto-detect claude binary
bash multistage-skill.sh my-pipeline/MULTI-SKILL-CONTENT.md "my prompt"

# Explicit binary path
bash multistage-skill.sh /path/to/claude my-pipeline/MULTI-SKILL-CONTENT.md "my prompt"

# With debug output (shows all stage outputs, not just final)
bash multistage-skill.sh my-pipeline/MULTI-SKILL-CONTENT.md --debug "my prompt"

# With a model override
bash multistage-skill.sh my-pipeline/MULTI-SKILL-CONTENT.md --model haiku "my prompt"
```

## Skill File Format

Skill files are Markdown with YAML frontmatter. Stages are separated by `---NEXT---` on its own line.

The frontmatter is patterned after Claude Code's `SKILL.md` format but this file is **not** a `SKILL.md` — Claude Code will not recognize or invoke it as a skill directly. It is only consumed by `multistage-skill.sh`. If you want it accessible as a slash command, pair it with a `SKILL.md` wrapper (see [Integrating with Claude Code Skills](#integrating-with-claude-code-skills)).

```markdown
---
name: "my-pipeline"
model: "haiku"
---

Stage 1 instructions. Use $ARGUMENTS for the full prompt.

---NEXT---

Stage 2 instructions. Previous stage output is in context — no need to restate it.

---NEXT---

Stage 3 instructions. All prior context is available.
```

### Frontmatter Fields

| Field | Description |
|-------|-------------|
| `name` | Display name (informational only) |
| `model` | Model alias: `haiku`, `sonnet`, `opus` |
| `effort` | Effort level: `low`, `medium`, `high`, `max` |
| `add-dir` | Additional directory to allow tool access to |
| `allowed-tools` | Comma-separated tool allowlist |
| `disallowed-tools` | Comma-separated tool denylist |
| `max-budget-usd` | Maximum spend cap for the pipeline |
| `append-system-prompt` | Extra system prompt injected into all stages |
| `debug` | Set to `true` to enable debug output by default |

**Security:** `permission-mode`, `dangerously-skip-permissions`, and `allow-dangerously-skip-permissions` are blocked — the script will error loudly if they appear in frontmatter or as CLI flags.

### Argument Substitution

The following substitutions are applied to the full skill body before stage splitting:

| Variable | Value |
|----------|-------|
| `$ARGUMENTS` or `${ARGUMENTS}` | Full prompt string |
| `$ARGUMENTS[N]` | 0-based word from prompt (e.g. `$ARGUMENTS[0]` = first word) |
| `$N` or `${N}` | Shorthand for `$ARGUMENTS[N]` |
| `${CLAUDE_SESSION_ID}` | UUID for this pipeline run |
| `${CLAUDE_SKILL_DIR}` | Directory containing the skill file |

If `$ARGUMENTS` does not appear anywhere in the body, the prompt is automatically appended to the first stage as `ARGUMENTS: <prompt>`.

### Shell Injection

Backtick commands prefixed with `!` are executed before Claude sees the content:

```markdown
The current git branch is: !`git rev-parse --abbrev-ref HEAD`
```

The command output replaces the `!`...`` construct in the stage body.

## Integrating with Claude Code Skills

To expose a multi-stage pipeline as a Claude Code slash command, create a `SKILL.md` wrapper alongside the `MULTI-SKILL-CONTENT.md`:

```markdown
---
name: "my-pipeline"
description: "What this pipeline does."
argument-hint: "<description of input>"
---

Run this command from the workspace root in the background and wait for the task notification:

\```
bash _agent/scripts/multistage-skill.sh "${CLAUDE_SKILL_DIR}/MULTI-SKILL-CONTENT.md" "$ARGUMENTS"
\```
```

The `${CLAUDE_SKILL_DIR}` variable is resolved by Claude Code before the skill runs, pointing to the directory containing the `SKILL.md` file.

## Debug Mode

Pass `--debug` at invocation (or set `debug: true` in frontmatter) to print all stage outputs labeled:

```
--- Stage 1 ---
<stage 1 output>

--- Stage 2 ---
<stage 2 output>
```

Without `--debug`, only the final stage output is printed.

## Design Notes

### Why `--session-id` / `--resume`?

Each `--print` invocation normally starts a fresh session. Using `--session-id` on the first stage and `--resume` on subsequent stages keeps all stages in the same conversation. This means:

- The model accumulates context across stages without re-paying input costs
- Output tokens from stage N become cached input for stage N+1 (input price, not output price)
- The full pipeline is visible as a single resumable session in the Claude Code UI

### Why stage boundaries?

Splitting retrieval from reasoning prevents the model from anchoring on early conclusions. A stage that only searches doesn't commit to a design; a stage that only designs doesn't second-guess its candidates. The fork forces sequentiality — each stage inherits a clean, committed prior.

### Subagent identity

If your pipeline stages invoke skills (e.g. `/search-doc`), tell the model it is a subagent running the pipeline — otherwise it may see other skills for its task in its context and invoke them recursively. Add a line like:

```
You are running as a subagent executing the <name> pipeline. Do not invoke /<name> or related skills — you are those stages.
```
