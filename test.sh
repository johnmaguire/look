#!/bin/sh
# Self-check against a throwaway headless viewer and history file: ./test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# Two steps: inside one $(...) a failed mktemp would leave T set to the
# current directory, which the trap below deletes
T=$(mktemp -d "${TMPDIR:-/tmp}/look-test.XXXXXX")
T=$(cd "$T" && pwd -P)
export LOOK_SOCK="$T/viewer.sock" LOOK_HISTORY="$T/history.jsonl" LOOK_SESSIONS="$T/sessions"
pid= lp= fake2=
# Stands in for the Claude Code process and conversation the session runs under
sleep 600 & fake=$!
export CLAUDE_PID=$fake CLAUDE_CODE_SESSION_ID=aaaa-0001
trap 'kill $pid $fake $fake2 $lp 2>/dev/null; rm -rf "$T"' EXIT
cd "$T"

start_viewer() {
  nvim --clean --headless --listen "$LOOK_SOCK" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do nvim --server "$LOOK_SOCK" --remote-expr 1 >/dev/null 2>&1 && return; sleep 0.1; done
  echo "FAIL viewer did not start"; exit 1
}
L() { "$here/look.py" "$@"; }
q() { nvim --server "$LOOK_SOCK" --remote-expr "luaeval('$(printf %s "$1" | sed "s/'/''/g")')"; }
check() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got [$2] want [$3]"; exit 1; }; }
here_line() { q 'vim.fn.expand([[%:t]]) .. [[:]] .. vim.fn.line([[.]])'; }
records() { grep -c . "$LOOK_HISTORY"; }
pending() { ls "$LOOK_SESSIONS/$1/pending" | wc -l | tr -d ' '; }
# Wait until a listener holds the lock of the session whose id starts with $1
held() {
  for _ in $(seq 50); do
    set -- "$1" "$(ls -d "$LOOK_SESSIONS/$1"* 2>/dev/null | head -1)"
    [ -n "$2" ] && python3 -c 'import fcntl, sys
f = open(sys.argv[1], "a")
try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit(0)
sys.exit(1)' "$2/lock" && return; sleep 0.1
  done
  echo "FAIL listener did not start"; exit 1
}
# Put the cursor on the history row whose record matches, then press <CR>
enter_row() {
  q "(function()
    vim.cmd([[copen]])
    for i, it in ipairs(vim.fn.getqflist()) do
      local r = it.user_data
      if r.kind == [[$1]] and (r.title == [[$2]] or r.stops[1].note == [[$2]]) then
        vim.api.nvim_win_set_cursor(0, {i, 0})
        vim.api.nvim_feedkeys(vim.keycode([[<CR>]]), [[x]], false)
        return i
      end
    end
  end)()" >/dev/null
}
note_at_cursor() {
  q 'vim.iter(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace([[look_single]]), 0, -1, {details=true})):map(function(m) return m[4].virt_lines and m[4].virt_lines[1][1][1] end):join([[|]])'
}

git init -q .
seq 1 40 | sed 's/^/line /' > fx.txt
printf 'func a() {\n  return 1\n}\n' > other.txt
start_viewer

L fx.txt:10-12 "it's a \"quoted\" note"
check "show" "$(here_line)" "fx.txt:10"
check "show note" "$(note_at_cursor)" ">> it's a \"quoted\" note"
check "where" "$(L --where)" "$T/fx.txt:10"
nvim --server "$LOOK_SOCK" --remote-send ':call cursor(5, 1)<CR>Vj'
check "where selection" "$(L --where)" "$T/fx.txt:5-6"
check "where keeps selection" "$(q 'vim.fn.mode()')" V
nvim --server "$LOOK_SOCK" --remote-send '<Esc>'
L fx.txt:1 "top note"
check "note on line 1 visible" "$(q 'vim.fn.winsaveview().topfill')" 1
L fx.txt "whole file note"
check "note without range" "$(note_at_cursor)" ">> whole file note"
q 'vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {relative=[[editor]], row=1, col=1, width=10, height=3})' >/dev/null
L fx.txt:3
check "look leaves floats alone" "$(q 'vim.api.nvim_win_get_config(0).relative') $(here_line)" " fx.txt:3"

printf 'fx.txt:20-21 first stop\nother.txt:1-3 second stop\n' | L --tour retry path
check "tour current" "$(q 'vim.fn.getqflist({title=0}).title')" "look: retry path"
check "tour stop 1" "$(here_line)" "fx.txt:20"
nvim --server "$LOOK_SOCK" --remote-send ':cnext<CR>'
check "cnext stop 2" "$(here_line)" "other.txt:1"
L fx.txt:30
check "look leaves tour current" "$(q 'vim.fn.getqflist({title=0}).title')" "look: retry path"
check "records" "$(records)" 6

# Restart, then edit the file so every saved line number is stale
kill $pid; wait $pid 2>/dev/null || true
start_viewer
printf 'new 1\nnew 2\nnew 3\nnew 4\nnew 5\n' | cat - fx.txt > fx.new && mv fx.new fx.txt
echo '{"stops":[42]}' >> "$LOOK_HISTORY"
echo '{"kind":"look","ts":1,"stops":[{"file":"/x","start":1}]}' >> "$LOOK_HISTORY"
L --history >/dev/null
check "history skips malformed records" "$(q 'vim.fn.getqflist({title=0}).title') $(q 'vim.fn.getqflist({size=0}).size')" "look: history 6"
# Stand-in for a plugin that turns inlay hints back on when a file opens
q 'vim.api.nvim_create_autocmd([[FileType]], {callback = function() vim.lsp.inlay_hint.enable(true) end})' >/dev/null
check "history newest first" "$(q 'vim.fn.getqflist()[1].user_data.stops[1].start')" 30

enter_row look "it's a \"quoted\" note"
check "replay re-anchors" "$(here_line)" "fx.txt:15"
check "replay note" "$(note_at_cursor)" ">> it's a \"quoted\" note"
check "enter keeps inlay hints off" "$(q 'vim.lsp.inlay_hint.is_enabled()')" false

L --history >/dev/null
enter_row tour "retry path"
check "replay tour current" "$(q 'vim.fn.getqflist({title=0}).title')" "look: retry path"
check "replay tour stop 1" "$(here_line)" "fx.txt:25"
check "replay tour marks follow code" "$(q 'vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace([[look_tour]]), 0, -1, {})[1][2]')" 24
nvim --server "$LOOK_SOCK" --remote-send ':cnext<CR>'
check "replay tour stop 2" "$(here_line)" "other.txt:1"
# Enter inside the open tour after another edit refreshes that same list
list=$(q 'vim.fn.getqflist({id=0}).id')
printf 'new 0\n' | cat - fx.txt > fx.new && mv fx.new fx.txt
q "(function() vim.cmd([[copen]]); vim.api.nvim_win_set_cursor(0, {1, 0}); vim.api.nvim_feedkeys(vim.keycode([[<CR>]]), [[x]], false) end)()" >/dev/null
check "open tour refreshed in place" "$(q 'vim.fn.getqflist({id=0}).id') $(here_line)" "$list fx.txt:26"
check "open tour row shows new line" "$(q 'vim.api.nvim_buf_get_lines(vim.fn.getqflist({qfbufnr=0}).qfbufnr, 0, 1, false)[1]' | grep -o 'fx.txt:[0-9-]*')" "fx.txt:26-27"

# Saved block gone: open at the old line, flagged
sed -i '' 's/^line 30$/line thirty/' fx.txt
L --history >/dev/null
enter_row look ""
check "changed code at old line" "$(here_line)" "fx.txt:30"
check "changed code flagged" "$(note_at_cursor)" ">> (code changed)"
rm other.txt
L --history >/dev/null
enter_row tour "retry path"
check "missing tour stop skipped" "$(q 'vim.fn.getqflist({size=0}).size')" 1

check "replays not recorded" "$(records)" 8
printf 'a\nreturn nil\nb\nreturn nil\n' > amb.txt
L amb.txt:2 ambiguous
printf 'z\n' | cat - amb.txt > amb.new && mv amb.new amb.txt
L --history >/dev/null
enter_row look ambiguous
check "repeated block flagged, not moved" "$(here_line) $(note_at_cursor)" "amb.txt:2 >> ambiguous (code changed)"
printf '{"truncated": ' >> "$LOOK_HISTORY"
L fx.txt:1
check "damaged tail kept apart" "$(tail -2 "$LOOK_HISTORY" | head -1)" '{"truncated": '
check "append after damaged tail" "$(tail -1 "$LOOK_HISTORY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')" look
L --history >/dev/null
check "history row format" "$(q 'vim.api.nvim_buf_get_lines(vim.fn.getqflist({qfbufnr=0}).qfbufnr, 0, 1, false)[1]' | sed -E 's/^[0-9-]+ [0-9:]+  //; s/ +/ /g; s/^ //')" "$(basename "$T")/fx.txt:1-1"
L fx.txt:3 "to clear"
L --clear >/dev/null
check "clear" "$(q '#vim.api.nvim_buf_get_extmarks(vim.fn.bufnr([[fx.txt]]), -1, 0, -1, {})')" 0
L nope.go:1 2>/dev/null && { echo "FAIL missing file accepted"; exit 1; } || echo "ok   missing file rejected"

# Comments back to the session that showed the code
sid=$(ls "$LOOK_SESSIONS")
L fx.txt:5-6 "comment me" 2>/dev/null
q '(function() vim.ui.input = function(_, cb) cb([[why line 5?]]) end end)()' >/dev/null
q 'vim.cmd([[5,6LookComment]])' >/dev/null
check "queued while not listening" "$(pending "$sid")" 1
"$here/look.py" --listen > listen1.out
check "listener delivers backlog" "$(head -2 listen1.out)" "look comment on $T/fx.txt:5-6:
why line 5?"
check "comment carries code" "$(sed -n 4p listen1.out)" "$(sed -n 5p fx.txt)"
check "backlog cleared" "$(pending "$sid")" 0
"$here/look.py" --listen > listen2.out & lp=$!
held "$sid"
check "one listener per session" "$("$here/look.py" --listen)" "already listening"
check "no nudge while listening" "$(L fx.txt:7 2>&1)" ""
q 'vim.cmd([[7LookComment]])' >/dev/null
wait $lp
check "live delivery" "$(head -1 listen2.out)" "look comment on $T/fx.txt:7-7:"
# Another conversation looks last, so a missed tag would fall back to it
ln -s fx.txt link.txt
printf 'd\n' > d.txt
CLAUDE_CODE_SESSION_ID=dddd-0004 "$here/look.py" d.txt:1 2>/dev/null
dsid=$(ls "$LOOK_SESSIONS" | grep dddd)
q '(function() vim.cmd([[wincmd p]]); vim.cmd.edit([[link.txt]]); vim.cmd([[2LookComment]]) end)()' >/dev/null
check "symlinked spelling finds the tag" "$(pending "$sid") $(pending "$dsid")" "1 0"
cp fx.txt fx.tmp && mv fx.tmp fx.txt
q '(function() vim.cmd.edit([[fx.txt]]); vim.cmd([[3LookComment]]) end)()' >/dev/null
check "save by rename keeps the tag" "$(pending "$sid") $(pending "$dsid")" "2 0"
"$here/look.py" --listen >/dev/null
TZ=Pacific/Auckland "$here/look.py" fx.txt:4 2>/dev/null
q '(function() vim.cmd.edit([[fx.txt]]); vim.cmd([[4LookComment]]) end)()' >/dev/null
check "session in another time zone is alive" "$(pending "$sid")" 1
"$here/look.py" --listen >/dev/null
seq 1 60 > long.txt
printf 'untagged \377 byte\n' > new.txt
q '(function() vim.cmd.edit([[new.txt]]); vim.cmd([[1LookComment]]); vim.cmd.edit([[long.txt]]); vim.cmd([[1,50LookComment]]) end)()' >/dev/null
check "untagged file goes to the last session" "$(pending "$sid")" 2
"$here/look.py" --listen > listen3.out
check "non-UTF-8 code keeps the comment" "$(grep -c '^why line 5?$' listen3.out)" 2
check "long selection says it was cut" "$(grep -c '^(first 40 of 50 lines)$' listen3.out)" 1
q '(function() _G.Look.commenting = true end)()' >/dev/null
check "look waits for a comment being typed" "$(L fx.txt:3 2>&1 | tail -1)" "the user is writing a comment in the viewer - try again in a moment"
q '(function() _G.Look.commenting = false end)()' >/dev/null
check "quickfix refused" "$(q '(function() vim.cmd([[copen]]); vim.cmd([[1LookComment]]); return vim.fn.execute([[messages]]):match([[from a file window]]) or [[]] end)()')" "from a file window"

# /clear: a new conversation in the same process does not drain the old one's queue
printf 'c\n' > c.txt
CLAUDE_CODE_SESSION_ID=cccc-0003 "$here/look.py" c.txt:1 2>/dev/null
q '(function() vim.cmd([[wincmd p]]); vim.cmd.edit([[fx.txt]]); vim.cmd([[5LookComment]]) end)()' >/dev/null
csid=$(ls "$LOOK_SESSIONS" | grep cccc)
check "comment stays with the conversation that showed the code" "$(pending "$sid") $(pending "$csid")" "1 0"
"$here/look.py" --listen >/dev/null

# Session ends: its listener leaves without taking comments and removes the
# queue; comments on its code are refused, not sent to another session
mkdir "$LOOK_SESSIONS/archive-2025"
"$here/look.py" --listen > listen4.out & lp=$!
held "$sid"
kill $fake; wait $fake 2>/dev/null || true
rc=0; wait $lp || rc=$?
check "listener exits with its session" "$rc $(wc -c < listen4.out | tr -d ' ')" "1 0"
check "ended session's queue removed" "$([ -d "$LOOK_SESSIONS/$sid" ] && echo kept || echo gone)" gone
q '(function() vim.cmd.edit([[fx.txt]]); vim.cmd([[1LookComment]]) end)()' >/dev/null
check "ended session refused" "$(q 'vim.fn.execute([[messages]]):match([[has ended]]) or [[]]')" "has ended"
sleep 600 & fake=$!
export CLAUDE_PID=$fake
L fx.txt:2 2>/dev/null
sid2=$(ls "$LOOK_SESSIONS" | grep "^$fake-")
kill $fake; wait $fake 2>/dev/null || true
sleep 600 & fake2=$!
CLAUDE_PID=$fake2 CLAUDE_CODE_SESSION_ID=bbbb-0002 "$here/look.py" --listen >/dev/null & lp=$!
held "$fake2-"
for _ in $(seq 50); do [ -d "$LOOK_SESSIONS/$sid2" ] || break; sleep 0.1; done
check "session ended without listener swept" "$([ -d "$LOOK_SESSIONS/$sid2" ] && echo kept || echo gone)" gone
check "foreign directory left alone" "$([ -d "$LOOK_SESSIONS/archive-2025" ] && echo kept || echo gone)" kept
kill $fake2; wait $fake2 $lp 2>/dev/null || true
