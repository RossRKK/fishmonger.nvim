-- Tours: an agent leads you through files in order. A tour belongs to the
-- session that started it and docks, as a list of its steps, under whichever
-- terminal window shows that session; its first step opens as soon as you can
-- see it, unless you are editing then, when it waits for you. Where you are in
-- it is written to the report file the tour names, for the agent to read:
-- nothing here knows who reads it.
--
-- An agent can also jump you to one place. It opens at once if you can see
-- that agent and aren't editing; otherwise it waits in the same list, after
-- any tour's steps, until you open it.
--
-- Like the task list (fishmonger/tasks.lua) the list follows the terminal
-- WINDOW: switching tabs in that window swaps in the new tab's tour, or closes
-- the list when that session has none.

local list = require("fishmonger.list")

local M = {}

-- Window variable on a list: the terminal window it belongs to.
local LIST_OF = "fishmonger_tour_of"

-- Window variable a list publishes its wanted height in, for a layout manager.
local HEIGHT_VAR = "fishmonger_tour_height"

-- The same two for the note window above a list: the step's note, as markdown.
local NOTE_OF = "fishmonger_tour_note_of"
local NOTE_HEIGHT_VAR = "fishmonger_tour_note_height"

-- A longer note scrolls rather than eat the terminal.
local NOTE_MAX_HEIGHT = 12

local WAITING_NOTE = "The agent pointed here while you were editing. `<CR>` opens it."

local ns = vim.api.nvim_create_namespace("fishmonger_tour")

-- Defined below, in top-down order.
local open_list, open_note, show_note, dismiss, render, go_to, open_entry, entries, in_view, wait
local write_report, step_row, waiting_row, where

-- Whether notes show: one choice for every tour, since it is about the room the panel has.
local notes_shown = true

---@class fishmonger.TourStep
---@field path string absolute
---@field line? integer
---@field description string

---@class fishmonger.TourSpec
---@field id string names this tour in its reports, so a reader tells it from an earlier one
---@field session string
---@field title string
---@field steps fishmonger.TourStep[]
---@field report string the file progress is written to

---@class fishmonger.Tour
---@field spec fishmonger.TourSpec
---@field current? integer the step opened last; nil until one has
---@field visited table<integer, true>
---@field held? true its first step waits for you, since you were editing when it came

---@class fishmonger.Jump
---@field path string absolute
---@field line? integer
---@field col? integer

---@alias fishmonger.TourEntry { step: integer } | { waiting: integer }

-- Each session's tour, by session id.
---@type table<string, fishmonger.Tour>
local tours = {}

-- Each session's jumps waiting for you, oldest first; absent when none wait.
---@type table<string, fishmonger.Jump[]>
local waiting = {}

-- Set by setup(): where the list's inputs come from.
---@type { terminal_windows: fun(tab: integer): integer[], session_of: fun(buf: integer): string?, is_session: fun(session: string): boolean, is_editing: fun(): boolean, open_file: fun(path: string, line?: integer, col?: integer), show_file: fun(path: string, line?: integer, col?: integer), side_var: string? }
local env

--- Wire the list to its inputs. `terminal_windows(tab)` lists a tabpage's
--- terminal windows, `session_of(buf)` names the agent session in a terminal
--- buffer, `is_session(session)` says whether a terminal here runs it,
--- `is_editing()` whether you are working in a file, `open_file(path, line,
--- col)` opens a file in the editor and `show_file` does so leaving focus where
--- it is. `side_var` is the window variable copied from a terminal onto its
--- list, so a layout manager docks it.
---@param opts table
function M.setup(opts)
  env = opts
  local grp = vim.api.nvim_create_augroup("FishmongerTour", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = grp,
    pattern = "FishmongerTabsChanged",
    callback = function(args)
      if args.data and args.data.tab == vim.api.nvim_get_current_tabpage() then
        M.sync()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinClosed", "TabEnter" }, {
    group = grp,
    callback = function()
      vim.schedule(M.sync)
    end,
  })
end

--- Start `spec`'s tour, replacing its session's last one. Returns "" when
--- started, else why not (as text, for a caller over RPC).
---@param spec fishmonger.TourSpec
---@return string
function M.show(spec)
  if #spec.steps == 0 then
    return "a tour with no steps"
  end
  if not env.is_session(spec.session) then
    return ("no terminal in this nvim runs session %s"):format(spec.session)
  end
  tours[spec.session] = { spec = spec, visited = {} }
  write_report(tours[spec.session], "active")
  M.sync()
  return ""
end

--- Take you to `args.path` for `args.session`'s agent: now, if you can see
--- that agent and aren't editing, else into its list to wait for you. Returns
--- "opened" or "waiting", else why neither (as text, for a caller over RPC).
---@param args { session: string, path: string, line?: integer, col?: integer }
---@return string
function M.jump(args)
  local jump = { path = args.path, line = args.line, col = args.col }
  local known = env.is_session(args.session)
  if not env.is_editing() and (not known or in_view(args.session)) then
    env.show_file(jump.path, jump.line, jump.col)
    return "opened"
  end
  if not known then
    return ("not opened: you are editing, and no terminal here runs session %s to wait under"):format(
      args.session
    )
  end
  wait(args.session, jump)
  M.sync()
  return "waiting"
end

--- End `session`'s tour, as its agent does; its waiting jumps stay. The report is the agent's to clean up.
---@param args { session: string }
---@return string
function M.finish(args)
  tours[args.session] = nil
  M.sync()
  return ""
end

--- Show or hide the note above every tour's list.
function M.toggle_note()
  notes_shown = not notes_shown
  M.sync()
end

--- Bring the current tabpage's lists and notes in line with its terminals'
--- tours and waiting jumps, opening the first step of a tour seen for the
--- first time unless you are editing.
function M.sync()
  local tab = vim.api.nvim_get_current_tabpage()
  local lists, notes = list.by_terminal(tab, LIST_OF), list.by_terminal(tab, NOTE_OF)
  for _, term_win in ipairs(env.terminal_windows(tab)) do
    local session = env.session_of(vim.api.nvim_win_get_buf(term_win))
    local t = session and tours[session]
    -- A zoomed terminal floats, and a split can't hang off a float.
    if
      session
      and #entries(session) > 0
      and vim.api.nvim_win_get_config(term_win).relative == ""
    then
      local win = lists[term_win] or open_list(term_win)
      lists[term_win] = nil
      if t and not t.current and not t.held then
        if env.is_editing() then
          t.held = true
        else
          go_to(t, 1, env.show_file)
        end
      end
      render(win, session)
      if notes_shown then
        show_note(
          notes[term_win] or open_note(term_win),
          session,
          vim.api.nvim_win_get_cursor(win)[1]
        )
        notes[term_win] = nil
      end
    end
  end
  for _, left in ipairs({ lists, notes }) do
    for term_win, win in pairs(left) do
      list.close(win, term_win)
    end
  end
end

--- A new, empty list window under `term_win`, with its keys.
function open_list(term_win)
  local win =
    list.open(term_win, { of_var = LIST_OF, filetype = "fishmonger-tour", side_var = env.side_var })
  local buf = vim.api.nvim_win_get_buf(win)
  vim.keymap.set("n", "<CR>", function()
    open_entry(vim.b[buf].fishmonger_tour_session, vim.api.nvim_win_get_cursor(win)[1])
    M.sync()
  end, { buffer = buf, desc = "Open this step of the tour" })
  vim.keymap.set("n", "q", function()
    dismiss(vim.b[buf].fishmonger_tour_session)
  end, { buffer = buf, desc = "Dismiss the tour" })
  -- The note shows the step under the cursor, so moving along the list reads ahead.
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = M.sync })
  return win
end

--- A new note window under `term_win`, so above any list already there.
function open_note(term_win)
  local win =
    list.open(term_win, { of_var = NOTE_OF, filetype = "markdown", side_var = env.side_var })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return win
end

--- Show the note of `session`'s list row `n` in window `win`, unless it already does.
--- Each note is a fresh buffer, so a markdown renderer meets it as it enters the window.
---@param win integer
---@param session string
---@param n integer
function show_note(win, session, n)
  local entry = entries(session)[n]
  local t = tours[session]
  local key, text
  if entry.step then
    key, text = ("%s:%d"):format(t.spec.id, entry.step), t.spec.steps[entry.step].description
  else
    key, text = "waiting:" .. where(waiting[session][entry.waiting]), WAITING_NOTE
  end
  if vim.w[win].fishmonger_tour_note ~= key then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "markdown"
    vim.keymap.set("n", "q", function()
      dismiss(session)
    end, { buffer = buf, desc = "Dismiss the tour" })
    vim.api.nvim_win_set_buf(win, buf)
    vim.w[win].fishmonger_tour_note = key
  end
  local rows = vim.api.nvim_win_text_height(win, {}).all
  list.set_height(win, rows, NOTE_HEIGHT_VAR, NOTE_MAX_HEIGHT)
end

--- Dismiss `session`'s list, as you do from it or its note: the tour's report
--- says so, its waiting jumps are dropped and its windows close.
---@param session? string
function dismiss(session)
  local t = session and tours[session]
  if t then
    write_report(t, "dismissed")
    tours[session] = nil
  end
  if session then
    waiting[session] = nil
  end
  M.sync()
end

--- Open `session`'s list row `n`, as you asked for it: a step is reported, a
--- waiting jump leaves the list.
---@param session? string
---@param n integer
function open_entry(session, n)
  local entry = session and entries(session)[n]
  if not entry then
    return
  end
  if entry.step then
    go_to(tours[session], entry.step, env.open_file)
    return
  end
  local jump = table.remove(waiting[session], entry.waiting)
  if #waiting[session] == 0 then
    waiting[session] = nil
  end
  env.open_file(jump.path, jump.line, jump.col)
end

--- Open step `n` of tour `t` with `open` and report it.
---@param t fishmonger.Tour
---@param n integer
---@param open fun(path: string, line?: integer)
function go_to(t, n, open)
  local step = t.spec.steps[n]
  t.current, t.visited[n] = n, true
  write_report(t, "active")
  open(step.path, step.line)
end

--- `session`'s list rows, in order: its tour's steps, then the jumps waiting.
---@param session string
---@return fishmonger.TourEntry[]
function entries(session)
  local rows = {}
  for n in ipairs(tours[session] and tours[session].spec.steps or {}) do
    rows[#rows + 1] = { step = n }
  end
  for n in ipairs(waiting[session] or {}) do
    rows[#rows + 1] = { waiting = n }
  end
  return rows
end

--- Whether a terminal on the current tabpage shows `session`, where you can see it.
---@param session string
---@return boolean
function in_view(session)
  return vim.iter(env.terminal_windows(vim.api.nvim_get_current_tabpage())):any(function(win)
    return env.session_of(vim.api.nvim_win_get_buf(win)) == session
  end)
end

--- Add `jump` to `session`'s waiting ones, last; a place already waiting moves there rather than repeat.
---@param session string
---@param jump fishmonger.Jump
function wait(session, jump)
  local kept = vim.tbl_filter(function(j)
    return where(j) ~= where(jump)
  end, waiting[session] or {})
  kept[#kept + 1] = jump
  waiting[session] = kept
end

--- Fill list `win` with `session`'s rows: its tour's steps, the current one marked, then its waiting jumps.
---@param win integer
---@param session string
function render(win, session)
  local buf = vim.api.nvim_win_get_buf(win)
  local t = tours[session]
  local rows = vim.tbl_map(function(entry)
    return entry.step and step_row(t, entry.step) or waiting_row(waiting[session][entry.waiting])
  end, entries(session))
  list.set_lines(
    win,
    vim.tbl_map(function(r)
      return r.text
    end, rows)
  )
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for n, r in ipairs(rows) do
    vim.api.nvim_buf_set_extmark(buf, ns, n - 1, 0, { end_col = #r.icon, hl_group = r.hl })
  end
  vim.b[buf].fishmonger_tour_session = session
  -- The cursor goes to each step as it opens, and the note with it; in between it is yours to move.
  local opened = t and t.current and ("%s:%d"):format(t.spec.id, t.current)
  if opened and vim.b[buf].fishmonger_tour_opened ~= opened then
    vim.b[buf].fishmonger_tour_opened = opened
    vim.api.nvim_win_set_cursor(win, { t.current, 0 })
  end
  vim.wo[win].winbar = " " .. (t and t.spec.title or "Waiting for you")
  list.set_height(win, #rows, HEIGHT_VAR)
end

--- Step `n`'s line: `{ text, icon, hl }`, its icon saying whether it is current, visited or still ahead.
function step_row(t, n)
  local icon, hl = "○", "Comment"
  if n == t.current then
    icon, hl = "●", "DiagnosticOk"
  elseif t.visited[n] then
    icon, hl = "✓", "Comment"
  end
  return { text = ("%s %s"):format(icon, where(t.spec.steps[n])), icon = icon, hl = hl }
end

--- A waiting jump's line, as `step_row`'s.
---@param jump fishmonger.Jump
function waiting_row(jump)
  local icon = "↪"
  return { text = ("%s %s"):format(icon, where(jump)), icon = icon, hl = "DiagnosticWarn" }
end

--- `place` as `path[:line]`, the path from the cwd or home where it can be.
---@param place { path: string, line?: integer }
---@return string
function where(place)
  local path = vim.fn.fnamemodify(place.path, ":~:.")
  return place.line and ("%s:%d"):format(path, place.line) or path
end

--- Write where tour `t` stands, as `status`, to its report file.
---@param t fishmonger.Tour
---@param status "active"|"dismissed"
function write_report(t, status)
  local visited = vim.tbl_keys(t.visited)
  table.sort(visited)
  local path = t.spec.report
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({
    vim.json.encode({
      id = t.spec.id,
      status = status,
      current = t.current,
      visited = visited,
    }),
  }, path)
end

return M
