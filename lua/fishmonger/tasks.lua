-- Background tasks: a list window under each terminal whose agent has started
-- background commands (Claude Code's run_in_background Bash), one line per
-- task saying what it is, how long it has run and how it went. <CR> on a line
-- opens that task's output in a pane between the terminal and the list.
--
-- The list is a real window, not a float, so it never covers the terminal and
-- ordinary window motions (<C-j> down from the terminal, <C-k> back) reach it.
-- It follows the terminal WINDOW: switching tabs in that window swaps the list
-- to the new tab's agent, or closes it when that agent has no tasks.

local agent = require("fishmonger.agent")

local M = {}

-- Taller lists scroll rather than eat the terminal.
local MAX_HEIGHT = 8

-- Window variable on a list: the terminal window it belongs to.
local LIST_OF = "fishmonger_tasks_of"

local ns = vim.api.nvim_create_namespace("fishmonger_tasks")

-- Defined below, in top-down order.
local COUNTS, last_count, lists_by_terminal, open_list, task_under_cursor, render, row, first_line, status_look, elapsed, tail

-- Set by setup(): where the list's inputs come from.
---@type { terminal_windows: fun(tab: integer): integer[], session_of: fun(buf: integer): string?, tasks_of: fun(session: string): table[], open_output: fun(path: string, below: integer), now: fun(): number, side_var: string? }
local env

--- Wire the list to its inputs. `terminal_windows(tab)` lists a tabpage's
--- terminal windows, `session_of(buf)` names the agent session in a terminal
--- buffer, `tasks_of(session)` gives that session's tasks (as agent.tasks),
--- `open_output(path, below)` opens a task's output under window `below`.
--- `side_var` is the window variable copied from a terminal onto its list, so
--- a layout manager docks the list with the panel. `now` is for tests.
---@param opts table
function M.setup(opts)
  env = vim.tbl_extend("force", { now = os.time }, opts)
  local grp = vim.api.nvim_create_augroup("FishmongerTasks", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = grp,
    pattern = "FishmongerTabsChanged",
    callback = function(args)
      if args.data and args.data.tab == vim.api.nvim_get_current_tabpage() then
        M.sync()
      end
    end,
  })
  -- A list outlives nothing: its terminal window closing takes it along.
  vim.api.nvim_create_autocmd({ "WinClosed", "TabEnter" }, {
    group = grp,
    callback = function()
      vim.schedule(M.sync)
    end,
  })
end

--- Bring the current tabpage's lists in line with its terminals' tasks.
function M.sync()
  local tab = vim.api.nvim_get_current_tabpage()
  local lists = lists_by_terminal(tab)
  for _, term_win in ipairs(env.terminal_windows(tab)) do
    local session = env.session_of(vim.api.nvim_win_get_buf(term_win))
    local tasks = session and env.tasks_of(session) or {}
    -- A zoomed terminal floats, and a split can't hang off a float.
    if #tasks > 0 and vim.api.nvim_win_get_config(term_win).relative == "" then
      render(lists[term_win] or open_list(term_win), session, tasks)
      lists[term_win] = nil
    end
  end
  -- Whatever is left belongs to no terminal with tasks.
  for _, list in pairs(lists) do
    pcall(vim.api.nvim_win_close, list, true)
  end
end

--- What a task's output says about how it went: pass/fail counts from the last
--- test summary in it, else its last line. Counts are taken from around the
--- final match only, so an earlier run's failures don't stick to a later one.
---@param text string the output's tail
---@return { passed: integer?, failed: integer?, last_line: string? }
function M.summarize(text)
  text = (text:gsub("\27%[[%d;?]*%a", ""))
  local last = 0
  for _, kind in pairs(COUNTS) do
    for _, pattern in ipairs(kind) do
      for pos in text:gmatch("()" .. pattern) do
        last = math.max(last, pos)
      end
    end
  end
  if last == 0 then
    local lines = vim.split(vim.trim(text), "\n")
    return { last_line = vim.trim(lines[#lines]) ~= "" and vim.trim(lines[#lines]) or nil }
  end
  local recent = text:sub(math.max(1, last - 200))
  return { passed = last_count(recent, COUNTS.passed), failed = last_count(recent, COUNTS.failed) }
end

-- How test runners report their totals: pytest, cargo, jest/vitest ("N
-- passed"/"N failed"), mocha ("N passing"/"N failing"), plenary/busted.
COUNTS = {
  passed = { "(%d+) passed", "(%d+) passing", "Success:%s*(%d+)" },
  failed = { "(%d+) failed", "(%d+) failing", "Failed%s*:%s*(%d+)" },
}

--- The count reported last in `text` by any of `patterns`, or nil.
function last_count(text, patterns)
  local best_pos, best
  for _, pattern in ipairs(patterns) do
    for pos, n in text:gmatch("()" .. pattern) do
      if not best_pos or pos > best_pos then
        best_pos, best = pos, tonumber(n)
      end
    end
  end
  return best
end

--- The task lists in `tab`, keyed by their terminal window.
function lists_by_terminal(tab)
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local of = vim.w[win][LIST_OF]
    if of then
      out[of] = win
    end
  end
  return out
end

--- A new, empty list window under `term_win`.
function open_list(term_win)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "fishmonger-tasks"
  -- noautocmd: a layout manager places a window when a buffer enters it, by
  -- which point the side mark must be there (as fishmonger's own panes do).
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(
    placeholder,
    false,
    { split = "below", win = term_win, height = 1, noautocmd = true }
  )
  vim.w[win][LIST_OF] = term_win
  if env.side_var then
    vim.w[win][env.side_var] = vim.w[term_win][env.side_var]
  end
  vim.api.nvim_win_set_buf(win, buf)
  for name, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    winfixheight = true,
    wrap = false,
    winbar = "",
  }) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  vim.keymap.set("n", "<CR>", function()
    local task = task_under_cursor(win)
    if task then
      env.open_output(task.output, term_win)
    end
  end, { buffer = buf, desc = "Open this task's output" })
  vim.keymap.set("n", "x", function()
    local task = task_under_cursor(win)
    if task then
      agent.dismiss(vim.b[buf].fishmonger_session, task.id)
    end
  end, { buffer = buf, desc = "Dismiss this task" })
  return win
end

--- The task on the cursor's line of list `win`.
function task_under_cursor(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return (vim.b[buf].fishmonger_tasks or {})[row]
end

--- Fill list `win` with `tasks`, resizing only when the count changes: every
--- resize also resizes the terminal above, and its program repaints.
function render(win, session, tasks)
  local buf = vim.api.nvim_win_get_buf(win)
  local rows = vim.tbl_map(row, tasks)
  local text = vim.tbl_map(function(r)
    return r.text
  end, rows)
  if not vim.deep_equal(text, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, r in ipairs(rows) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #r.icon, hl_group = r.hl })
  end
  vim.b[buf].fishmonger_session = session
  vim.b[buf].fishmonger_tasks = tasks
  local height = math.min(#tasks, MAX_HEIGHT)
  -- A layout manager that sizes its windows itself (edgy) would undo the resize.
  vim.w[win].fishmonger_tasks_height = height
  if vim.api.nvim_win_get_height(win) ~= height then
    vim.api.nvim_win_set_height(win, height)
  end
end

--- One task's line: `{ text, icon, hl }`.
function row(task)
  local summary = M.summarize(tail(task.output))
  local look = status_look(task, summary)
  local what = first_line(
    type(task.description) == "string" and task.description ~= "" and task.description
      or task.command
  )
  local how = summary.passed and string.format("%d✓ %d✗", summary.passed, summary.failed or 0)
    or summary.last_line
    or ""
  local text = string.format(
    "%s%s · %s",
    agent.glyph_cell(look.icon),
    what,
    elapsed((task.finished or env.now()) - task.started)
  )
  return { text = how ~= "" and text .. " · " .. how or text, icon = look.icon, hl = look.hl }
end

--- `text`'s first line, with … when more was cut: a heredoc command is one row.
function first_line(text)
  local first, rest = text:match("^([^\n]*)\n(.*)$")
  return first and first .. (vim.trim(rest) ~= "" and " …" or "") or text
end

--- How a task's icon looks: the working spinner while it runs, then done or
--- failed by what its output reported (no exit code reaches us).
function status_look(task, summary)
  if not task.finished then
    return agent.look("busy")
  elseif (summary.failed or 0) > 0 then
    return { icon = "✗", hl = "DiagnosticError" }
  end
  return agent.look("done")
end

--- `seconds` as 45s / 1m12s / 1h03m.
function elapsed(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
  end
  return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

--- The last few KB of a file: enough for a summary, cheap however long the run.
function tail(path)
  local f = io.open(path, "r")
  if not f then
    return ""
  end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - 4096))
  local text = f:read("*a") or ""
  f:close()
  return text
end

return M
