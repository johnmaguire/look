-- Loaded into the viewer by look.py; keeps its state in _G.Look across reloads.
--
-- The viewer is the only reader and writer of the history file: Neovim runs one
-- request at a time, so appends never interleave across Claude sessions, and the
-- saved text is what the viewer actually displayed.
local prev = _G.Look or {}
local M = {}
local api = vim.api

local src = debug.getinfo(1, "S").source:sub(2)
local st = vim.uv.fs_stat(src)
-- Nanoseconds as a string: two saves in one second must still reload, and the
-- integer is too big for a Lua number
M.mtime = ("%d.%09d"):format(st.mtime.sec, st.mtime.nsec)
M.tour_bufs = prev.tour_bufs or {}
M.hist_path = prev.hist_path or vim.fn.expand("~/.local/state/look/history.jsonl")
-- Comments go back to the Claude session that showed the code. Tags come from
-- look.py: {sid, pid, lstart, dir, label}. file_session: file id -> tag of the
-- last look showing that file; last: tag of the most recent look from any session.
M.file_session = prev.file_session or {}
M.last = prev.last
M.commenting = prev.commenting

-- One spelling per file, computed here for every look and comment alike: a
-- symlinked path and its target are the same file to the user. Not the inode:
-- saving by rename-over gives the file a new one.
local function file_id(path)
  return vim.uv.fs_realpath(path) or path
end

local function retag(file, t)
  M.file_session[file_id(file)] = t
end

local HIST_MAX = 200
local ns_single = api.nvim_create_namespace("look_single")
local ns_tour = api.nvim_create_namespace("look_tour")
api.nvim_set_hl(0, "LookRange", { link = "Visual", default = true })
api.nvim_set_hl(0, "LookNote", { link = "DiagnosticInfo", default = true })

-- Buffers --------------------------------------------------------------------

-- No swapfile: the files are usually open in the user's editor too, and the
-- swap-exists prompt would block the viewer
local function load(file)
  local buf = vim.fn.bufadd(file)
  local st = vim.uv.fs_stat(file)
  local stamp = st and ("%d.%d.%d"):format(st.mtime.sec, st.mtime.nsec, st.size) or ""
  if not api.nvim_buf_is_loaded(buf) then
    vim.bo[buf].swapfile = false
    vim.fn.bufload(buf)
    vim.b[buf].look_stamp = stamp
  elseif vim.b[buf].look_stamp ~= stamp and not vim.bo[buf].modified then
    -- :checktime compares whole seconds, so an edit landing in the same second
    -- the file was loaded goes unseen and ranges resolve against stale text.
    -- The stamp only moves on a reload that worked, so a failed one is retried.
    local ok = api.nvim_buf_call(buf, function()
      return pcall(vim.cmd, "silent edit!")
    end)
    if ok then
      vim.b[buf].look_stamp = stamp
    end
  end
  vim.bo[buf].buflisted = true
  return buf
end

local function clamp(buf, s, e)
  local n = api.nvim_buf_line_count(buf)
  s = math.max(1, math.min(s, n))
  return s, math.max(s, math.min(e, n))
end

local function lines(buf, s, e)
  return api.nvim_buf_get_lines(buf, s - 1, e, false)
end

local function same(buf, s, text)
  local got = lines(buf, s, s + #text - 1)
  if #got ~= #text then
    return false
  end
  for i, l in ipairs(text) do
    if got[i] ~= l then
      return false
    end
  end
  return true
end

-- Find where a saved range is now: at its old line, or wherever the whole
-- saved block appears exactly once. A block found several times (a lone "}",
-- "return nil") could be any of them, so it opens at the old line, flagged.
-- Returns buf, s, e, changed - or nil when the file is gone.
local function resolve(stop)
  if vim.fn.filereadable(stop.file) == 0 then
    return nil
  end
  local buf = load(stop.file)
  if not stop.start then
    return buf, nil, nil, false
  end
  local text = stop.text
  if not text or #text == 0 then
    local s, e = clamp(buf, stop.start, stop["end"])
    return buf, s, e, false
  end
  if same(buf, stop.start, text) then
    return buf, stop.start, stop["end"], false
  end
  local found
  for i = 1, api.nvim_buf_line_count(buf) - #text + 1 do
    if same(buf, i, text) then
      if found then
        found = nil
        break
      end
      found = i
    end
  end
  if found then
    return buf, found, found + #text - 1, false
  end
  local s, e = clamp(buf, stop.start, stop["end"])
  return buf, s, e, true
end

-- Display ----------------------------------------------------------------------

-- s = nil: note only, above line 1, for a look at a whole file
local function mark(buf, ns, s, e, note)
  if not s and note == "" then
    return
  end
  api.nvim_buf_set_extmark(buf, ns, (s or 1) - 1, 0, {
    end_row = (e or 1) - 1,
    line_hl_group = s and "LookRange" or nil,
    virt_lines = note ~= "" and { { { ">> " .. note, "LookNote" } } } or nil,
    virt_lines_above = true,
  })
end

-- Show files only in an ordinary window: not the quickfix list, a float, a
-- help or terminal window, or one pinned with 'winfixbuf'
local function code_win()
  local function ok(w)
    return api.nvim_win_get_config(w).relative == ""
      and vim.bo[api.nvim_win_get_buf(w)].buftype == ""
      and not vim.wo[w].winfixbuf
  end
  local cands = { api.nvim_get_current_win(), vim.fn.win_getid(vim.fn.winnr("#")) }
  vim.list_extend(cands, api.nvim_tabpage_list_wins(0))
  for _, w in ipairs(cands) do
    if w ~= 0 and ok(w) then
      api.nvim_set_current_win(w)
      return
    end
  end
  vim.cmd("botright new")
end

local function center(s, e)
  api.nvim_win_set_cursor(0, { s, 0 })
  -- Keep the note line above s visible, and the whole range when it fits
  local h = api.nvim_win_get_height(0)
  local top = (e - s + 2 < h) and math.max(1, math.floor((s + e) / 2) - math.floor(h / 2)) or s
  top = math.max(1, math.min(top, s - 1))
  -- A note above line 1 is filler before the first line, shown only with topfill
  vim.fn.winrestview({ topline = top, topfill = (top == 1 and s == 1) and 1 or 0, lnum = s })
end

local function show_single(buf, s, e, note)
  for _, b in ipairs(api.nvim_list_bufs()) do
    api.nvim_buf_clear_namespace(b, ns_single, 0, -1)
  end
  code_win()
  api.nvim_win_set_buf(0, buf)
  mark(buf, ns_single, s, e, note)
  center(s or 1, e or 1)
end

local function open_list()
  vim.cmd("botright copen 6")
  vim.cmd.wincmd("p")
end

-- stops: { {buf, s, e, note, idx} } already resolved, idx into rec.stops.
-- Items carry the resolved position, so ]q, the list rows and the marks agree.
-- list_id: refresh that quickfix list in place (Enter inside an open tour);
-- otherwise the tour gets a new list.
local function show_tour(rec, stops, first, list_id)
  for b in pairs(M.tour_bufs) do
    if api.nvim_buf_is_valid(b) then
      api.nvim_buf_clear_namespace(b, ns_tour, 0, -1)
    end
  end
  M.tour_bufs = {}
  if #stops == 0 then
    if list_id then
      vim.fn.setqflist({}, "r", { id = list_id, items = {} })
    end
    vim.notify("look: every file in this tour is gone", vim.log.levels.WARN)
    return
  end
  local items = {}
  for i, st in ipairs(stops) do
    M.tour_bufs[st.buf] = true
    retag(rec.stops[st.idx].file, rec.session)
    mark(st.buf, ns_tour, st.s, st.e, ("[%d/%d] %s"):format(i, #stops, st.note))
    items[i] = { bufnr = st.buf, lnum = st.s, end_lnum = st.e, text = st.note, user_data = st.idx }
  end
  local what = {
    title = "look: " .. rec.title,
    items = items,
    context = { look = "tour", rec = rec },
    quickfixtextfunc = "v:lua.LookQftf",
  }
  if list_id then
    what.id = list_id
    vim.fn.setqflist({}, "r", what)
  else
    vim.fn.setqflist({}, " ", what)
  end
  code_win()
  vim.cmd("silent " .. (first or 1) .. "cc")
  center(stops[first or 1].s, stops[first or 1].e)
  open_list()
end

-- History file -------------------------------------------------------------------

-- Returns an error string, or nil.
local function append(rec)
  pcall(vim.fn.mkdir, vim.fs.dirname(M.hist_path), "p")
  -- A crash mid-write leaves a line without its newline; start a fresh line
  -- so this record is not glued onto it
  local prefix = ""
  local r = io.open(M.hist_path, "rb")
  if r then
    if r:seek("end") > 0 then
      r:seek("end", -1)
      if r:read(1) ~= "\n" then
        prefix = "\n"
      end
    end
    r:close()
  end
  local f, err = io.open(M.hist_path, "a")
  if not f then
    return err
  end
  local wok, werr = f:write(prefix .. vim.json.encode(rec) .. "\n")
  local cok, cerr = f:close()
  if not wok or not cok then
    return werr or cerr
  end
end

local function valid(rec)
  if type(rec) ~= "table" or type(rec.stops) ~= "table" or #rec.stops == 0 then
    return false
  end
  for _, st in ipairs(rec.stops) do
    if type(st) ~= "table" or type(st.file) ~= "string"
      or (st.start ~= nil and (type(st.start) ~= "number" or type(st["end"]) ~= "number"))
      or (st.text ~= nil and type(st.text) ~= "table") then
      return false
    end
  end
  return true
end

-- shortcut: reads the whole file each time; rotate it if it ever gets slow
local function read_history()
  local recs = {}
  local f = io.open(M.hist_path, "r")
  if not f then
    return recs
  end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and valid(rec) then
      recs[#recs + 1] = rec
    end
  end
  f:close()
  return recs
end

-- Commands from look.py ----------------------------------------------------------

function M.show(a)
  local buf = load(a.file)
  local s, e
  if a.start then
    s, e = clamp(buf, a.start, a["end"])
  end
  show_single(buf, s, e, a.note)
  retag(a.file, a.session)
  M.last = a.session or M.last
  local err = append({
    ts = os.time(),
    kind = "look",
    session = a.session,
    stops = { { file = a.file, start = s, ["end"] = e, note = a.note, text = s and lines(buf, s, e) or nil } },
  })
  return err and ("ok; history not saved: " .. err) or "ok"
end

function M.tour(a)
  local stops, saved = {}, {}
  for i, st in ipairs(a.stops) do
    local buf = load(st.file)
    local s, e = clamp(buf, st.start, st["end"])
    saved[i] = { file = st.file, start = s, ["end"] = e, note = st.note, text = lines(buf, s, e) }
    stops[i] = { buf = buf, s = s, e = e, note = st.note, idx = i }
  end
  local rec = { ts = os.time(), kind = "tour", title = a.title, session = a.session, stops = saved }
  M.last = a.session or M.last
  show_tour(rec, stops)
  local err = append(rec)
  return err and ("ok; history not saved: " .. err) or "ok"
end

function M.history()
  local recs = read_history()
  if #recs == 0 then
    vim.notify("look: no history yet")
    return "no history"
  end
  local items = {}
  for i = #recs, math.max(1, #recs - HIST_MAX + 1), -1 do
    local rec, st = recs[i], recs[i].stops[1]
    items[#items + 1] = { filename = st.file, lnum = st.start or 1, text = st.note or "", user_data = rec }
  end
  vim.fn.setqflist({}, " ", {
    title = "look: history",
    items = items,
    context = { look = "history" },
    quickfixtextfunc = "v:lua.LookQftf",
  })
  vim.cmd("botright copen 10")
  return "ok"
end

function M.clear()
  for _, b in ipairs(api.nvim_list_bufs()) do
    api.nvim_buf_clear_namespace(b, ns_single, 0, -1)
    api.nvim_buf_clear_namespace(b, ns_tour, 0, -1)
  end
  return "ok"
end

function M.where()
  local win = api.nvim_get_current_win()
  if vim.bo.buftype == "quickfix" then
    win = vim.fn.win_getid(vim.fn.winnr("#"))
  end
  local buf = api.nvim_win_get_buf(win)
  local name = api.nvim_buf_get_name(buf)
  local cur = api.nvim_win_get_cursor(win)[1]
  if win == api.nvim_get_current_win() and vim.fn.mode():match("^[vV\22]") then
    local v = vim.fn.line("v")
    return ("%s:%d-%d"):format(name, math.min(v, cur), math.max(v, cur))
  end
  return ("%s:%d"):format(name, cur)
end

-- Comments -------------------------------------------------------------------

-- Same process and start time as when it tagged the look: a reused pid is not
-- it. Both sides format the start in UTC, so the viewer's time zone can differ.
local function alive(t)
  if type(t) ~= "table" or type(t.pid) ~= "number" or type(t.dir) ~= "string"
    or type(t.lstart) ~= "string" or t.lstart == "" or not vim.uv.fs_stat(t.dir .. "/pending") then
    return false
  end
  local r = vim.system({ "ps", "-o", "lstart=", "-p", tostring(t.pid) }, { env = { LC_ALL = "C", TZ = "UTC" }, text = true }):wait()
  return vim.trim(r.stdout or "") == t.lstart
end

local function deliver(c, t)
  local dir = t.dir
  local name = ("%d-%d.json"):format(os.time(), vim.uv.hrtime())
  local tmp = dir .. "/." .. name
  local f = io.open(tmp, "w")
  -- Written beside pending/ and renamed in, so the listener never reads half a comment
  if not (f and f:write(vim.json.encode(c)) and f:close() and os.rename(tmp, dir .. "/pending/" .. name)) then
    vim.fn.setreg("c", c.text)
    vim.notify("look: could not queue the comment (text is in register c)", vim.log.levels.ERROR)
    return
  end
  local label = tostring(t.label)
  vim.notify("look: queued for " .. label)
  vim.defer_fn(function()
    if vim.uv.fs_stat(dir .. "/pending/" .. name) then
      vim.notify("look: " .. label .. " has not picked it up yet - the session is busy or not listening")
    else
      vim.notify("look: delivered to " .. label)
    end
  end, 1500)
end

-- :[range]LookComment - everything about the target is fixed before the prompt,
-- so a look arriving while the user types cannot redirect the comment
function M.comment(opts)
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or api.nvim_buf_get_name(buf) == "" then
    vim.notify("look: comment from a file window", vim.log.levels.WARN)
    return
  end
  local file = vim.uv.fs_realpath(api.nvim_buf_get_name(buf)) or api.nvim_buf_get_name(buf)
  local s, e = opts.line1, opts.line2
  local code = lines(buf, s, math.min(e, s + 39))
  local t = M.file_session[file_id(file)]
  local who = "the session that showed this"
  if not t then
    t, who = M.last, "the last session that showed code"
  end
  if not t then
    vim.notify("look: no Claude session has shown code here yet", vim.log.levels.WARN)
    return
  end
  local label = type(t) == "table" and tostring(t.label) or "?"
  -- Never redirect to another session: the comment is about what this one said
  if not alive(t) then
    vim.notify(("look: %s (%s) has ended"):format(who, label), vim.log.levels.WARN)
    return
  end
  -- look.py checks this before sending keys, which would cancel the prompt.
  -- shortcut: a look whose check ran just before the prompt opened can still
  -- cancel it (milliseconds); move the check into the same RPC if that bites.
  M.commenting = true
  vim.ui.input({ prompt = "comment for " .. label .. ": " }, function(text)
    -- The module may have been reloaded while the prompt was open
    _G.Look.commenting = false
    if not text or text == "" then
      return
    end
    local c = { file = file, start = s, ["end"] = e, code = code, text = text }
    if not alive(t) then
      vim.fn.setreg("c", text)
      vim.notify(("look: %s (%s) ended while you typed; the text is in register c"):format(who, label), vim.log.levels.WARN)
      return
    end
    deliver(c, t)
  end)
end

-- Quickfix window --------------------------------------------------------------

local function flag(note, changed)
  note = note or ""
  if not changed then
    return note
  end
  return note == "" and "(code changed)" or note .. " (code changed)"
end

-- first: index into rec.stops to land on; list_id: see show_tour
local function replay(rec, first, list_id)
  if rec.kind == "tour" then
    local stops, pos = {}, 1
    for i, st in ipairs(rec.stops) do
      local buf, s, e, changed = resolve(st)
      if buf then
        stops[#stops + 1] = { buf = buf, s = s, e = e, note = flag(st.note, changed), idx = i }
        if i == first then
          pos = #stops
        end
      else
        vim.notify("look: skipped missing " .. st.file)
      end
    end
    show_tour(rec, stops, pos, list_id)
    if #stops > 0 then
      M.last = rec.session or M.last
    end
    return
  end
  local st = rec.stops[1]
  local buf, s, e, changed = resolve(st)
  if not buf then
    vim.notify("look: file is gone: " .. st.file, vim.log.levels.WARN)
    return
  end
  show_single(buf, s, e, flag(st.note, changed))
  retag(st.file, rec.session)
  M.last = rec.session or M.last
end

-- <CR> in the quickfix window: look lists replay their saved record, resolved
-- against the list and row under the cursor now; other lists keep Neovim's <CR>
function M.qf_enter()
  local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
  local get = info.loclist == 1 and function(w) return vim.fn.getloclist(0, w) end or vim.fn.getqflist
  local ctx = get({ context = 0 }).context
  local row = vim.fn.line(".")
  if type(ctx) ~= "table" or (ctx.look ~= "history" and ctx.look ~= "tour") then
    api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
    return
  end
  local item = get({ idx = row, items = 0 }).items[1]
  if ctx.look == "history" then
    replay(item.user_data)
  else
    -- Re-resolve the whole tour so marks, rows and ]q follow edits made since
    -- it opened, refreshing this list rather than stacking a copy
    replay(ctx.rec, item.user_data, get({ id = 0 }).id)
  end
end

function _G.LookQftf(info)
  local get = info.quickfix == 1 and vim.fn.getqflist or function(w) return vim.fn.getloclist(info.winid, w) end
  local l = get({ id = info.id, items = 0, context = 0 })
  local out = {}
  for i = info.start_idx, info.end_idx do
    local it = l.items[i]
    local file, s, e, label
    if l.context.look == "history" then
      local rec = it.user_data
      local st = rec.stops[1]
      file, s, e = st.file, st.start, st["end"]
      label = os.date("%m-%d %H:%M", rec.ts) .. "  "
        .. (rec.kind == "tour" and ("tour: %s (%d stops)"):format(rec.title, #rec.stops) or (st.note or ""))
    else
      -- Tour rows show where the stop resolved to, and any "(code changed)"
      file, s, e = api.nvim_buf_get_name(it.bufnr), it.lnum, it.end_lnum
      label = ("[%d/%d] %s"):format(i, #l.items, it.text)
    end
    local root = vim.fs.root(file, ".git")
    local path = root and vim.fs.basename(root) .. "/" .. file:sub(#root + 2) or vim.fn.fnamemodify(file, ":~")
    local where = s and ("%s:%d-%d"):format(path, s, e) or path
    out[#out + 1] = ("%-60s  %s"):format(label, where)
  end
  return out
end

-- Entry point ----------------------------------------------------------------------

-- Every way in (look.py, Enter in a list, :LookHistory) goes through here.
-- Files change under the viewer as Claude edits them: reload from disk so
-- ranges land on current code. Inlay hints are off because Nvim 0.12 places
-- stale hints past the end of a shortened line and the error loops a
-- hit-enter prompt that blocks the socket. Plugins such as go.nvim enable them
-- globally, and again when opening a file lazy-loads them, hence the second call.
function M.guard(fn, ...)
  vim.cmd("silent! checktime")
  vim.lsp.inlay_hint.enable(false)
  local out = fn(...)
  vim.lsp.inlay_hint.enable(false)
  return out
end

function M.run(a)
  if a.hist then
    M.hist_path = a.hist
  end
  return M.guard(M[a.cmd], a)
end

local group = api.nvim_create_augroup("look", { clear = true })
api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "qf",
  callback = function(ev)
    vim.keymap.set("n", "<CR>", function() _G.Look.guard(_G.Look.qf_enter) end, { buffer = ev.buf })
  end,
})
api.nvim_create_user_command("LookHistory", function()
  _G.Look.guard(_G.Look.history)
end, {})
api.nvim_create_user_command("LookClear", M.clear, {})
api.nvim_create_user_command("LookComment", function(o) _G.Look.comment(o) end, { range = true })

_G.Look = M
return M
