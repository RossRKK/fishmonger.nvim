-- Agent status: what the coding agent in each side terminal is doing, and in
-- particular whether it is BLOCKED ON YOU.
--
-- The tab strip and the OS title used to read this off the OSC title's leading
-- glyph (M.title_icon), which is all a terminal can observe from outside. That
-- glyph only says "thinking / not thinking", and the state worth surfacing from
-- a workspace you are not looking at is a different one: finished is something
-- to get to eventually, a permission prompt is something that has stopped dead
-- until you answer it. Nothing in the terminal byte stream tells those apart.
--
-- So the agent reports it instead. Claude Code hooks (see the `agent-status`
-- script this config ships) write one small JSON file per session into a
-- directory; this module watches it, matches each session to the terminal it is
-- running in, and hands the result to the tab strip, the view, and whatever
-- personal config wants it.
--
-- MATCHING is by pid, not by cwd: the hook records its ancestor chain, and a
-- session belongs to the terminal whose shell pid appears in it. Exact when two
-- agents run in one project, and it needs no wrapper or env var, since the hook
-- is by construction a descendant of the shell that started the agent.

local M = {}

-- state -> how it shows up. `attention` is the whole point of the module: those
-- are the states that mean the agent has stopped and cannot continue without
-- you, and they are what a background workspace needs to be able to shout.
--
-- The glyphs are single-width so a row of them in a tab label costs one column
-- each, and they stay distinguishable at a glance: a filled mark for "wants
-- you", a light one for "working", a tick for "finished".
M.states = {
  busy = { icon = "\xe2\x9c\xb3", hl = "DiagnosticInfo", label = "working" }, -- ✳
  permission = { icon = "\xef\x8a\x9c", hl = "DiagnosticWarn", label = "permission", attention = true }, --
  asking = { icon = "\xef\x81\x99", hl = "DiagnosticWarn", label = "question", attention = true }, --
  plan = { icon = "\xef\x80\xa2", hl = "DiagnosticWarn", label = "plan review", attention = true }, --
  asked = { icon = "\xef\x81\x99", hl = "DiagnosticHint", label = "follow-up", attention = true }, --
  idle = { icon = "\xef\x89\x84", hl = "DiagnosticWarn", label = "waiting", attention = true }, --
  done = { icon = "\xef\x80\x8c", hl = "DiagnosticOk", label = "done" }, --
}

local config = {
  -- Where the hook script writes its files. Keep in step with `agent-status`.
  dir = (vim.env.XDG_RUNTIME_DIR or "/tmp") .. "/claude-agents",
  enabled = true,
}

-- session id -> record, as read from disk:
--   { session, state, detail, cwd, pids = {…}, agent_pid }
local sessions = {}

-- Terminal shell pids, cached per buffer. Resolving one means reading /proc, and
-- the tab strip asks on every repaint; a terminal's pid never changes, so once
-- is enough. Dropped with the buffer in forget().
local pids = {}

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, data)
  return ok and type(decoded) == "table" and decoded or nil
end

--- Is the agent process behind this record still running? A session file
--- outlives its agent when the process is killed rather than exited (no
--- SessionEnd hook), and a dead session left in the list is worse than no list:
--- it reads as a workspace waiting on you forever.
---@param record table
---@return boolean
local function alive(record)
  local pid = tonumber(record.agent_pid)
  return pid ~= nil and vim.uv.fs_stat("/proc/" .. pid) ~= nil
end

--- Re-read every session file. Cheap (a handful of small files) and simpler than
--- tracking individual file events, which arrive without reliable names.
local function reload()
  sessions = {}
  local handle = vim.uv.fs_scandir(config.dir)
  if not handle then
    return
  end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("%.json$") then
      local record = read_json(config.dir .. "/" .. name)
      if record and record.session then
        if alive(record) then
          sessions[record.session] = record
        else
          -- Reap it here rather than leaving it for the next session to trip
          -- over: this is the only process that ever notices.
          os.remove(config.dir .. "/" .. name)
        end
      end
    end
  end
end

--- The shell pid of a terminal buffer, or nil.
---@param buf integer
---@param resolve fun(buf: integer): integer? core's pid lookup
local function term_pid(buf, resolve)
  if pids[buf] == nil then
    pids[buf] = resolve(buf) or false
  end
  return pids[buf] or nil
end

--- Forget a dead terminal buffer's cached pid.
---@param buf integer
function M.forget(buf)
  pids[buf] = nil
end

--- The session running in a terminal buffer, if any.
---@param buf integer
---@param resolve fun(buf: integer): integer?
---@return table? record
function M.for_buf(buf, resolve)
  local pid = term_pid(buf, resolve)
  if not pid then
    return nil
  end
  for _, record in pairs(sessions) do
    for _, candidate in ipairs(record.pids or {}) do
      if candidate == pid then
        return record
      end
    end
  end
end

--- How a state displays: `{ icon, hl, label, attention }`. Unknown states (a
--- newer hook script than this plugin) fall back to the working look rather than
--- disappearing.
---@param state string?
---@return table?
function M.look(state)
  if not state then
    return nil
  end
  return M.states[state] or { icon = "\xe2\x9c\xb3", hl = "DiagnosticInfo", label = state }
end

--- Every known session, live agents only. Terminal-matching is the caller's job
--- (see fishmonger.agents), so this stays usable for sessions running outside
--- any managed terminal.
---@return table[]
function M.all()
  return vim.tbl_values(sessions)
end

--- Start watching the status directory. Idempotent; a missing directory is fine
--- (the first hook creates it, and the poll below picks it up).
---@param opts? table see `config`
---@param on_change fun() called, debounced, whenever the statuses change
function M.setup(opts, on_change)
  config = vim.tbl_extend("force", config, opts or {})
  if not config.enabled then
    return
  end
  vim.fn.mkdir(config.dir, "p")
  reload()

  local timer
  local function refresh()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    -- A single turn writes several files in quick succession (one hook per
    -- event, several agents at once); coalesce them into one repaint.
    timer = vim.defer_fn(function()
      reload()
      on_change()
    end, 50)
  end

  if M._watcher then
    M._watcher:stop()
    M._watcher:close()
  end
  local watcher = vim.uv.new_fs_event()
  if watcher and watcher:start(config.dir, {}, vim.schedule_wrap(refresh)) == 0 then
    M._watcher = watcher
  elseif watcher then
    watcher:close()
  end
end

return M
