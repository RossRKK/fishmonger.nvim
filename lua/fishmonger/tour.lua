-- Tours: an agent leads you through files in order. A tour belongs to the
-- session that started it and docks, as a list of its steps, under whichever
-- terminal window shows that session; its first step opens as soon as you can
-- see it. Where you are in it is written to the report file the tour names,
-- for the agent to read: nothing here knows who reads it.
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

local ns = vim.api.nvim_create_namespace("fishmonger_tour")

-- Defined below, in top-down order.
local open_list, render, go_to, write_report, row

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

-- Each session's tour, by session id.
---@type table<string, fishmonger.Tour>
local tours = {}

-- Set by setup(): where the list's inputs come from.
---@type { terminal_windows: fun(tab: integer): integer[], session_of: fun(buf: integer): string?, is_session: fun(session: string): boolean, open_file: fun(path: string, line?: integer), side_var: string? }
local env

--- Wire the list to its inputs. `terminal_windows(tab)` lists a tabpage's
--- terminal windows, `session_of(buf)` names the agent session in a terminal
--- buffer, `is_session(session)` says whether a terminal here runs it,
--- `open_file(path, line)` opens a file in the editor. `side_var` is the window
--- variable copied from a terminal onto its list, so a layout manager docks it.
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

--- End `session`'s tour, as its agent does. The report is the agent's to clean up.
---@param args { session: string }
---@return string
function M.finish(args)
  tours[args.session] = nil
  M.sync()
  return ""
end

--- Bring the current tabpage's lists in line with its terminals' tours,
--- opening the first step of a tour seen for the first time.
function M.sync()
  local tab = vim.api.nvim_get_current_tabpage()
  local lists = list.by_terminal(tab, LIST_OF)
  for _, term_win in ipairs(env.terminal_windows(tab)) do
    local session = env.session_of(vim.api.nvim_win_get_buf(term_win))
    local t = session and tours[session]
    -- A zoomed terminal floats, and a split can't hang off a float.
    if t and vim.api.nvim_win_get_config(term_win).relative == "" then
      local win = lists[term_win] or open_list(term_win)
      lists[term_win] = nil
      if not t.current then
        go_to(t, 1)
      end
      render(win, t)
    end
  end
  for term_win, win in pairs(lists) do
    list.close(win, term_win)
  end
end

--- A new, empty list window under `term_win`, with its keys.
function open_list(term_win)
  local win =
    list.open(term_win, { of_var = LIST_OF, filetype = "fishmonger-tour", side_var = env.side_var })
  local buf = vim.api.nvim_win_get_buf(win)
  local function shown()
    return tours[vim.b[buf].fishmonger_tour_session]
  end
  vim.keymap.set("n", "<CR>", function()
    local t = shown()
    if t then
      go_to(t, vim.api.nvim_win_get_cursor(win)[1])
      render(win, t)
    end
  end, { buffer = buf, desc = "Open this step of the tour" })
  vim.keymap.set("n", "q", function()
    local t = shown()
    if t then
      write_report(t, "dismissed")
      tours[t.spec.session] = nil
    end
    M.sync()
  end, { buffer = buf, desc = "Dismiss the tour" })
  return win
end

--- Open step `n` of tour `t` and report it.
---@param t fishmonger.Tour
---@param n integer
function go_to(t, n)
  local step = t.spec.steps[n]
  if not step then
    return
  end
  t.current, t.visited[n] = n, true
  write_report(t, "active")
  env.open_file(step.path, step.line)
end

--- Fill list `win` with tour `t`'s steps, its current one marked.
---@param win integer
---@param t fishmonger.Tour
function render(win, t)
  local buf = vim.api.nvim_win_get_buf(win)
  local rows = {}
  for n, step in ipairs(t.spec.steps) do
    rows[n] = row(t, n, step)
  end
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
  vim.b[buf].fishmonger_tour_session = t.spec.session
  vim.wo[win].winbar = " " .. t.spec.title
  list.set_height(win, #rows, HEIGHT_VAR)
end

--- Step `n`'s line: `{ text, icon, hl }`, its icon saying whether it is current, visited or still ahead.
function row(t, n, step)
  local icon, hl = "○", "Comment"
  if n == t.current then
    icon, hl = "●", "DiagnosticOk"
  elseif t.visited[n] then
    icon, hl = "✓", "Comment"
  end
  local where = step.line and ("%s:%d"):format(vim.fn.fnamemodify(step.path, ":~:."), step.line)
    or vim.fn.fnamemodify(step.path, ":~:.")
  local about = step.description:match("^[^\n]*")
  return { text = ("%s %s  %s"):format(icon, where, about), icon = icon, hl = hl }
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
