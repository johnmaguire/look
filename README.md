# look

A Claude Code skill that puts the code under discussion on screen instead of
pasting excerpts into chat. Claude highlights ranges with a one-line note,
walks you through a diff or code flow as a tour, and can ask what you are
looking at.

The viewer is a dedicated Neovide window (a separate app you can Cmd+Tab to),
driven over a Neovim socket. Claude launches it when needed.

## Requirements

- macOS, [Neovide](https://neovide.dev), Neovim 0.11+ (for `]q` / `[q`)
- Python 3
- `nvim` on the PATH of a non-interactive login shell: Neovide starts it that
  way, so set PATH in `~/.zprofile`, not only `~/.zshrc`

## Install

```sh
git clone git@github.com:johnmaguire/look.git ~/src/look
ln -s ~/src/look ~/.claude/skills/look
```

## Use

Ask Claude about code ("walk me through this change", "show me where X
happens"), or run `/look`. In the viewer:

- `]q` / `[q` step through a tour.
- `:LookHistory` lists every look and tour, newest first. Enter re-shows one and
  finds the code again if it moved. If the code changed, the note says
  "(code changed)".
- `:LookComment` (on a line, or `:'<,'>LookComment` on a selection) sends a
  comment to the Claude session that showed that code (for code no look
  showed, the session whose look came last). Claude answers in its terminal.
  If the session is busy, the comment waits and arrives when it is free.
- `:LookClear` removes highlights.

History is kept in `~/.local/state/look/history.jsonl`, and per-session
comment queues in `~/.local/state/look/sessions/`. `LOOK_SOCK` (default
`/tmp/look.sock`), `LOOK_HISTORY` and `LOOK_SESSIONS` override those paths.

## Development

`./test.sh` runs the script against a throwaway headless Neovim with its own
socket and history file.
