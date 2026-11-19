---
name: look
description: Put the code under discussion on screen in the user's Neovim viewer - highlighted ranges with notes, guided tours through a diff or code flow, and "what am I looking at". Use whenever explaining, walking through, or answering questions about specific code - a diff, a function, "why does this do X", "walk me through the change", "how does this flow", "what calls this" - and whenever the user says /look, "show me", or refers to code they are looking at ("this", "here").
argument-hint: "[file[:start[-end]] [note]]"
---

The user reads code in a viewer (a Neovide window on `/tmp/look.sock`) instead of
excerpts in chat. There they can jump to definitions and wander, so put the code
there rather than pasting it. The script launches the viewer if needed.

```sh
L=~/.claude/skills/look/look.py
```

## One spot: `$L file:START-END "note"`

Highlights the range, centers it, and shows the note above it. Use it right
before each point you make about specific code, so the screen matches what you
are saying.

- Tightest range that makes the point, not the whole function.
- The note is one short line: the takeaway, not a repeat of your explanation.
- Still name `file:line` in chat so the reply makes sense later.

## Several spots in order: a tour

For walking through a diff, a request path, or anything with more than two
stops, send them in one tour instead of firing looks in sequence:

```sh
$L --tour "retry path" <<'EOF'
internal/conn.go:42-58 entry: Reconnect is called on every read error
internal/conn.go:90-97 backoff resets here, which is why it spins
internal/dial.go:12-20 the dial that actually fails
EOF
```

Each stop is highlighted with `[n/total] note` above it and listed in the
quickfix window. The user steps with `]q` / `[q` (or `:cnext`) at their own pace.
After code changes, Enter on any row re-finds every stop (`]q` alone keeps the
old positions).
In chat, number your explanation to match the stops. For a diff, one stop per
hunk worth discussing, in reading order (caller before callee), not file order.

## What is the user looking at: `$L --where`

When they say "this", "here", or asks about code without naming it, run this
first. It prints `file:line`, or `file:start-end` for a visual selection.

## Comments from the user

The user can comment on code in the viewer (`:LookComment`, on a line or a
visual selection); the comment comes back to the session that showed that code,
or for code no look showed, to the session whose look came last. For that the
session needs a listener. Only the main conversation runs one: a subagent shares
the session and its listener would take the user's comments, so a subagent
never runs `--listen`.

- After your first look or tour in a session (or whenever `look.py` prints
  "no listener for this session"), start `$L --listen` with the Bash tool's
  `run_in_background`. Don't start one in a session that never used look.
- When it exits with `look comment on FILE:START-END:` lines, start a new
  listener in the background **first**, then answer each comment in chat. Each
  comment includes the code the user saw; the file may have changed since.
- "already listening" means one is running: nothing to do. An exit with no
  output means the session is ending: ignore it.
- A look that fails with "the user is writing a comment" was not shown: try
  again in a few seconds; if it still fails, carry on in chat.

## History

Every look and tour is saved to `~/.local/state/look/history.jsonl` (written
only by the viewer), so the user can find old references after restarts with
`:LookHistory` or `$L --history`. Enter on a row re-shows that look or reopens
that tour, finding the saved code even if it has moved; if the code changed,
the note says "(code changed)". Point the user at history when they ask about
something shown earlier instead of re-deriving it.

## Other

- `$L --clear` removes highlights.
- If the script fails, mention it once and carry on in chat.
- `LOOK_SOCK`, `LOOK_HISTORY` and `LOOK_SESSIONS` (absolute paths) override the socket, history file and session directory. `test.sh` checks the script against a
  throwaway headless viewer; run it after changing `look.py` or `look.lua`.
