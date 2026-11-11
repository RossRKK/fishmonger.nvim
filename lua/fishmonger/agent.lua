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

local coalesce = require("fishmonger.coalesce")

-- state -> how it shows up. `attention` is the whole point of the module: those
-- are the states that mean the agent has stopped and cannot continue without
-- you, and they are what a background workspace needs to be able to shout.
--
-- The glyphs are single-width so a row of them in a tab label costs one column
-- each, and they stay distinguishable at a glance: a filled mark for "wants
-- you", a spinner for "working", a tick for "finished". NOT ✳ for working: that
-- is the glyph Claude Code itself puts in its title when it has FINISHED, so the
-- title-icon fallback (init.lua) shows it meaning "done" -- reusing it here for
-- the opposite state made the two paths contradict each other.
--
-- Working is grey (Comment), not a diagnostic colour: it is the one state that
-- asks nothing of you, so it should recede and leave colour to the states that
-- shout.
M.states = {
  -- Working animates: `frames` is cycled by the spinner timer below while any
  -- agent is in a spinning state; `icon` is the resting frame for consumers
  -- that read the table directly.
  busy = {
    icon = "\xe2\xa0\x8b",
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    hl = "Comment",
    label = "working",
  }, --
  permission = {
    icon = "\xef\x8a\x9c",
    hl = "DiagnosticWarn",
    label = "permission",
    attention = true,
  }, --
  asking = { icon = "\xef\x81\x99", hl = "DiagnosticWarn", label = "question", attention = true }, --
  plan = { icon = "\xef\x80\xa2", hl = "DiagnosticWarn", label = "plan review", attention = true }, --
  asked = { icon = "\xef\x81\x99", hl = "DiagnosticHint", label = "follow-up", attention = true }, --
  idle = { icon = "\xef\x89\x84", hl = "DiagnosticWarn", label = "waiting", attention = true }, --
  done = { icon = "\xef\x80\x8c", hl = "DiagnosticOk", label = "done" }, --
  -- No turn yet since the session started or was cleared: nothing to see, nothing asked.
  new = { icon = "\xef\x84\x8c", hl = "Comment", label = "new" }, --
}

-- Claude Code's /color palette as it draws it, so a tab matches its session's prompt bar.
M.colours = {
  red = "#dc2626",
  blue = "#6a9bcc",
  green = "#16a34a",
  yellow = "#ca8a04",
  purple = "#827dbd",
  cyan = "#0891b2",
  pink = "#c46686",
  orange = "#d97757",
}

--- The highlight group for a session colour, or nil for none or one not in M.colours.
---@param colour string?
---@return string?
function M.colour_hl(colour)
  return M.colours[colour] and ("FishmongerAgent" .. colour:gsub("^%l", string.upper)) or nil
end

local config = {
  -- Where the hook script writes its files. Keep in step with `agent-status`.
  dir = (vim.env.XDG_RUNTIME_DIR or "/tmp") .. "/claude-agents",
  enabled = true,
}

-- session id -> record, as read from disk:
--   { session, state, detail, cwd, pids = {…}, agent_pid, colour? }
-- where `colour` comes from the <agent_pid>.colour claim the launcher wrote.
local sessions = {}

-- session id -> its background tasks in launch order, each
--   { id, description, command, output, started, finished? }
-- where `finished` (epoch seconds) is absent exactly while the task runs.
-- The hook records pid + start time rather than a status: no event marks a
-- task's end, so whether it is still running is read off /proc.
local tasks = {}

-- The running tasks' { pid, pid_start }, which the spinner tick re-checks.
local running = {}

-- The on_change callback given to setup(), kept here so refresh() can repaint
-- through the same path the watcher does.
local notify = function() end

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

--- A process's start time, field 22 of /proc/<pid>/stat, or nil once it has
--- exited. comm (field 2) may contain spaces and ")", so fields are counted
--- from the last ")".
---@param pid integer
---@return integer?
local function start_time(pid)
  local f = io.open("/proc/" .. pid .. "/stat", "r")
  if not f then
    return nil
  end
  local stat = f:read("*a")
  f:close()
  local after_comm = stat:match(".*%) (.*)")
  return after_comm and tonumber(vim.split(after_comm, " ")[20])
end

--- When a task finished (its output's last write), or nil while it runs. A
--- recycled pid has a different start time, so it doesn't count as the task.
---@param record table the hook's task record
---@param stat table the output file's fs_stat
---@return integer?
local function finished_at(record, stat)
  if start_time(record.pid) == record.pid_start then
    return nil
  end
  return stat.mtime.sec
end

--- A hook task record as a task, or nil when it is unusable (its output gone).
---@param record table?
---@return table?
local function parse_task(record)
  local stat = record and record.output and vim.uv.fs_stat(record.output)
  if not (stat and record.session and record.id) then
    return nil
  end
  return {
    id = record.id,
    description = record.description,
    command = record.command,
    output = record.output,
    started = stat.birthtime.sec + stat.birthtime.nsec / 1e9,
    finished = finished_at(record, stat),
  }
end

--- Re-read every session and task file. Cheap (a handful of small files) and
--- simpler than tracking individual file events, which arrive without reliable
--- names.
local function reload()
  sessions, tasks, running = {}, {}, {}
  local handle = vim.uv.fs_scandir(config.dir)
  if not handle then
    return
  end
  local task_records, claims = {}, {}
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = config.dir .. "/" .. name
    if name:match("%.json$") then
      local record = read_json(path)
      if record and record.session then
        if alive(record) then
          sessions[record.session] = record
        else
          -- Reap it here rather than leaving it for the next session to trip
          -- over: this is the only process that ever notices.
          os.remove(path)
          for _, task_file in
            ipairs(vim.fn.glob(config.dir .. "/" .. record.session .. ".*.task", true, true))
          do
            os.remove(task_file)
          end
        end
      end
    elseif name:match("%.task$") then
      task_records[#task_records + 1] = read_json(path)
    elseif name:match("^%d+%.colour$") then
      claims[tonumber(name:match("^%d+"))] = read_json(path)
    end
  end
  for _, record in pairs(sessions) do
    local claim = claims[tonumber(record.agent_pid)]
    -- A claim left by an earlier process on a reused pid doesn't count.
    if claim and claim.pid_start == start_time(record.agent_pid) then
      record.colour = claim.colour
    end
  end
  for _, record in ipairs(task_records) do
    local task = parse_task(record)
    if task then
      tasks[record.session] = tasks[record.session] or {}
      table.insert(tasks[record.session], task)
      if not task.finished then
        running[#running + 1] = { pid = record.pid, pid_start = record.pid_start }
      end
    end
  end
  for _, list in pairs(tasks) do
    table.sort(list, function(a, b)
      return a.started < b.started
    end)
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

-- The busy spinner: a timer that advances the frame and asks for a repaint, run
-- ONLY while some agent is in a spinning state -- most of the time there is no
-- agent at all, or every agent is blocked or done, and then it costs nothing.
-- `on_tick` is the repaint (wired in setup); it is deliberately not the full
-- on_change pipeline, so a frame advance repaints the strips that draw the icon
-- without re-announcing the fleet to everything else.
local spin = { timer = nil, frame = 1, on_tick = function() end }

local function spinning_somewhere()
  if #running > 0 then
    return true
  end
  for _, record in pairs(sessions) do
    -- Unknown states take the busy look (see M.look), so they spin too.
    local look = M.states[record.state]
    if not look or look.frames then
      return true
    end
  end
  return false
end

--- Advance the spinner a frame. An agent killed mid-turn never writes another
--- file, so without the liveness check its "busy" would spin forever; a task
--- finishing writes none either.
local function tick()
  for _, record in pairs(sessions) do
    if not alive(record) then
      M.refresh()
      return
    end
  end
  for _, probe in ipairs(running) do
    if start_time(probe.pid) ~= probe.pid_start then
      M.refresh()
      return
    end
  end
  spin.frame = spin.frame % #M.states.busy.frames + 1
  spin.on_tick()
end
M._tick, M._spin = tick, spin -- exposed for tests only

--- Start or stop the spinner to match the sessions. Called after every reload:
--- the set of busy agents only changes when the session files do.
local function sync_spinner()
  local want = spinning_somewhere()
  if want and not spin.timer then
    spin.timer = vim.uv.new_timer()
    spin.timer:start(0, 150, coalesce(tick))
  elseif not want and spin.timer then
    spin.timer:stop()
    spin.timer:close()
    spin.timer = nil
  end
end

--- How a state displays: `{ icon, hl, label, attention }`. Unknown states (a
--- newer hook script than this plugin) fall back to the working look rather than
--- disappearing. A state with `frames` answers with the spinner's current one.
---@param state string?
---@return table?
function M.look(state)
  if not state then
    return nil
  end
  local look = M.states[state]
    or { frames = M.states.busy.frames, hl = M.states.busy.hl, label = state }
  if look.frames then
    look = vim.tbl_extend("force", {}, look, { icon = look.frames[spin.frame] })
  end
  return look
end

--- Re-read the status directory right now, synchronously, and repaint. The
--- watcher keeps things current in the steady state; this is for the moments a
--- consumer is about to put the list in front of the user (the popup opening, a
--- greeter coming back into view) and a missed fs event must not be able to
--- show stale state.
function M.refresh()
  reload()
  sync_spinner()
  notify()
end

--- A session's background tasks in launch order: `{ id, description, command,
--- output, started, finished? }`, times in epoch seconds, `finished` absent
--- while the task runs.
---@param session string
---@return table[]
function M.tasks(session)
  return tasks[session] or {}
end

--- Forget a task, finished or not; the task itself is Claude's to stop.
---@param session string
---@param id string
function M.dismiss(session, id)
  os.remove(config.dir .. "/" .. session .. "." .. id .. ".task")
  M.refresh()
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
---@param on_tick? fun() called on each spinner frame; a lighter repaint than
---   on_change (nothing about the fleet changed, only the working icon's frame).
---   Defaults to on_change.
function M.setup(opts, on_change, on_tick)
  config = vim.tbl_extend("force", config, opts or {})
  notify = on_change
  spin.on_tick = on_tick or on_change
  if not config.enabled then
    return
  end
  vim.fn.mkdir(config.dir, "p")
  reload()
  sync_spinner()

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
      sync_spinner()
      on_change()
    end, 50)
  end

  if M._watcher then
    M._watcher:stop()
    M._watcher:close()
  end
  local watcher = vim.uv.new_fs_event()
  if watcher and watcher:start(config.dir, {}, coalesce(refresh)) == 0 then
    M._watcher = watcher
  elseif watcher then
    watcher:close()
  end
end

return M
