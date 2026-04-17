# Swarm Config — iOS Walkthrough Debug Team

Used 2026-04-15 for the systematic on-device walkthrough of the Bin Brain iOS app against the live `binbrain_api` server. Captures exactly how the swarm was wired so it can be rebuilt in one command.

## Layout

- **Tmux session:** `binbrain`
- **One window** named `Team`
- **Three panes** in **tiled** layout (not separate windows)

```
+-----------------+-----------------+
|   0.0 Architect |   0.1 Backend   |
|   (binbrain-ios)|   (binbrain)    |
+-----------------+-----------------+
|   0.2 Swift (binbrain-ios)         |
+------------------------------------+
```

Pane 0.0 runs the Architect persona and drives coordination. Panes 0.1 and 0.2 each run their own Claude Code instance in a different working directory.

## Pane assignments

| Pane | CWD | Role | Persona |
|------|-----|------|---------|
| `binbrain:0.0` | `~/Development/binbrain-ios` | Architect / PM | `~/.claude/skills/launch-swarm/assets/personas/TMUX_ARCHITECT_MANAGER.md` (or local `./.swarm/Personas/TMUX_ARCHITECT_MANAGER.md`) |
| `binbrain:0.1` | `~/Development/binbrain/binbrain` | Backend Developer (Python/FastAPI + Docker) | `~/.claude/skills/launch-swarm/assets/personas/TMUX_DEVELOPER.md` |
| `binbrain:0.2` | `~/Development/binbrain-ios` | Swift Developer (iOS/SwiftUI) | `~/.claude/skills/launch-swarm/assets/personas/TMUX_SWIFT_DEVELOPER.md` (or local `./.swarm/Personas/TMUX_SWIFT_DEVELOPER.md`) |

## Guidance attached to all agents

From `~/.claude/skills/launch-swarm/assets/guidance/`:
- `TMUX_TEAM.md` — team coordination conventions + push-don't-poll comm protocol
- `ARCHITECTURE_GUIDELINES.md` — Eskil Steenberg principles
- `WORKING_METHODS.md` — TDD, branch strategy, task file format

## Communication protocol

Agents push `ARCHITECT STATUS:` / `ARCHITECT REQUEST:` / `ARCHITECT BLOCKED:` / `ARCHITECT TASK COMPLETED:` via:

```bash
tmux send-keys -t binbrain:0.0 "ARCHITECT STATUS: <msg>"
tmux send-keys -t binbrain:0.0 Enter
```

Architect replies with `tmux send-keys -t binbrain:0.<N>` followed by Enter. Quiet period convention: `ARCHITECT HOLD: stop pushing for N minutes` when the human needs to type without interruption.

## Task file convention

- iOS tasks: `~/Development/binbrain-ios/.swarm/Prompts/Swift<N>_NNN_slug.md`
- Backend tasks: `~/Development/binbrain/binbrain/.swarm/Prompts/Dev<N>_NNN_slug.md`
- Findings: `~/Development/binbrain-ios/.swarm/Findings/<agent>_<task>_findings.md`
- Architect reports: `~/Development/binbrain-ios/thoughts/shared/agents/architect/<report>.md`

## Walkthrough-specific operating rules

1. **Observational only** — no code changes during the walkthrough. Investigate, report, defer fixes to follow-up prompts.
2. **Human drives the UI on physical device**; agents observe Console.app + server logs and correlate. Subsystem filter: `com.binbrain.app`.
3. **DB baseline:** note the starting state and flag unexpected pre-existing rows.
4. **No restarts / no DB mutations** from agents — including no probe keys beyond an explicit ephemeral one that gets revoked before teardown.

## Rebuild — one-liner

With the `launch-swarm` skill:

```bash
SKILL=$HOME/.claude/skills/launch-swarm
$SKILL/scripts/launch-dev-team.sh \
  --Guidance=$SKILL/assets/guidance/TMUX_TEAM.md \
  --Guidance=$SKILL/assets/guidance/ARCHITECTURE_GUIDELINES.md \
  --Guidance=$SKILL/assets/guidance/WORKING_METHODS.md \
  --Layout=tiled \
  --Architect=claude:opus-4-6@$SKILL/assets/personas/TMUX_ARCHITECT_MANAGER.md \
  --Developer:Backend=claude:opus-4-6@$SKILL/assets/personas/TMUX_DEVELOPER.md \
  --Developer:Swift=claude:opus-4-6@$SKILL/assets/personas/TMUX_SWIFT_DEVELOPER.md \
  ~/Development/binbrain-ios
```

**Adjustments needed for this specific setup:**
- The backend pane must `cd ~/Development/binbrain/binbrain` after launch (not the binbrain-ios worktree). Either:
  - Edit the launched script to change that pane's cwd, or
  - After launch, `tmux send-keys -t binbrain:0.1 "cd ~/Development/binbrain/binbrain" Enter` before onboarding.

- The skill defaults to attaching tmux at the end; if invoked from inside Claude Code this can exit non-zero after a successful launch. That's cosmetic.

## Manual rebuild (if the skill isn't available)

```bash
# 1. Start session
tmux new-session -d -s binbrain -n Team -c ~/Development/binbrain-ios

# 2. Split into 3 tiled panes
tmux split-window -h -t binbrain:Team -c ~/Development/binbrain/binbrain
tmux split-window -v -t binbrain:Team.0 -c ~/Development/binbrain-ios
tmux select-layout -t binbrain:Team tiled

# 3. Launch Claude in each pane
tmux send-keys -t binbrain:0.0 "claude" Enter   # Architect
tmux send-keys -t binbrain:0.1 "claude" Enter   # Backend
tmux send-keys -t binbrain:0.2 "claude" Enter   # Swift

# 4. Attach
tmux attach -t binbrain
```

Then in each pane, dispatch the onboarding message pointing at the persona + guidance + task file. Architect dispatches with `tmux send-keys -t binbrain:0.1 "<onboarding prompt>" Enter` (and `0.2`).

## Known frictions captured during this run

- **Pane stdin interleaving:** when two agents push `ARCHITECT STATUS:` while the human is typing, the human's input gets mangled mid-stream. Workaround: `ARCHITECT HOLD` for N minutes during typing windows.
- **The `launch-swarm` script** ends with `tmux attach`, which fails gracefully when invoked from Claude Code — the session IS created, just the attach step errors. See memory `c7f4bd98`.
- **Subsystem filter gotcha:** Console.app filter for iOS logs must be `com.binbrain.app` (NOT `com.binbrain` — that matches nothing).
- **Physical device + `localhost`** — the device hits `http://10.1.1.205:8000`, the Mac's LAN IP; inside the docker container this shows as source `172.29.0.1` (docker bridge gateway). Not an issue, just surprising in logs.
- **ATS exception domain is hardcoded** in `Info-Debug.plist:13` to `10.1.1.205`. On a different LAN this walkthrough needs a rebuild with the new IP first.
