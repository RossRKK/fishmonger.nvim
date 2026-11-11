-- The background-task list (fishmonger/tasks.lua): one window under each
-- terminal whose agent has tasks, one line per task, and the output pane it
-- opens. Its inputs (which windows are terminals, whose session runs in them,
-- that session's tasks) are passed in, so the specs hand it plain tables.

local assert = require("luassert")

local tasks_ui = require("fishmonger.tasks")

local NOW = 1000

--- A task as agent.tasks returns it.
local function task(fields)
  return vim.tbl_extend("force", {
    id = "b1",
    description = "Run the tests",
    command = "cargo test",
    output = "/nonexistent/b1.output",
    started = NOW - 72,
  }, fields or {})
end

--- One terminal window (the current one, given a terminal-ish buffer) and a
--- task list wired to it. `by_session` is mutable: tests change it and sync.
local function fixture(by_session)
  pcall(vim.cmd, "tabonly")
  pcall(vim.cmd, "only")
  local term_win = vim.api.nvim_get_current_win()
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local opened = {}
  tasks_ui.setup({
    terminal_windows = function()
      return { term_win }
    end,
    session_of = function(buf)
      return buf == term_buf and "s1" or nil
    end,
    tasks_of = function(session)
      return by_session[session] or {}
    end,
    open_output = function(path, below)
      opened[#opened + 1] = { path = path, below = below }
    end,
    now = function()
      return NOW
    end,
  })
  return term_win, opened
end

--- The task list window under `term_win`, or nil.
local function list_under(term_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].fishmonger_tasks_of == term_win then
      return win
    end
  end
end

local function lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

describe("task list", function()
  it("opens under a terminal whose agent has tasks, one line per task", function()
    local term_win = fixture({ s1 = { task(), task({ id = "b2", description = "Build" }) } })

    tasks_ui.sync()

    local list = assert(list_under(term_win))
    assert.equals(2, #lines(list))
    assert.equals(2, vim.api.nvim_win_get_height(list))
    -- Below the terminal: same column, starting further down.
    local term_pos, list_pos =
      vim.api.nvim_win_get_position(term_win), vim.api.nvim_win_get_position(list)
    assert.equals(term_pos[2], list_pos[2])
    assert.is_true(list_pos[1] > term_pos[1])
  end)

  it("publishes the height it wants, for a layout manager that owns the window's size", function()
    local by_session = { s1 = { task(), task({ id = "b2" }) } }
    local term_win = fixture(by_session)
    tasks_ui.sync()
    local list = list_under(term_win)
    assert.equals(2, vim.w[list].fishmonger_tasks_height)

    by_session.s1 = { task() }
    tasks_ui.sync()

    assert.equals(1, vim.w[list].fishmonger_tasks_height)
  end)

  it("says what each task is and how long it has run", function()
    local term_win = fixture({ s1 = { task() } })

    tasks_ui.sync()

    local line = lines(list_under(term_win))[1]
    assert.truthy(line:find("Run the tests", 1, true))
    assert.truthy(line:find("1m12s", 1, true))
  end)

  it("moves a running task's time on at the next sync", function()
    local term_win = fixture({ s1 = { task() } })
    tasks_ui.sync()

    NOW = NOW + 1
    local ok, err = pcall(tasks_ui.sync)
    NOW = NOW - 1
    assert(ok, err)

    assert.truthy(lines(list_under(term_win))[1]:find("1m13s", 1, true))
  end)

  it("starts every row's text in the same column, whatever its glyph's width", function()
    local done = require("fishmonger.agent").states.done
    local real = done.icon
    done.icon = "⏳"
    local term_win = fixture({ s1 = { task(), task({ id = "b2", finished = NOW }) } })
    local ok, err = pcall(tasks_ui.sync)
    done.icon = real
    assert(ok, err)

    local shown = lines(list_under(term_win))
    local function text_col(line)
      return vim.fn.strdisplaywidth(line:sub(1, line:find("Run the tests", 1, true) - 1))
    end
    assert.truthy(shown[2]:find("⏳", 1, true))
    assert.equals(text_col(shown[1]), text_col(shown[2]))
  end)

  it("falls back to the command for a task without a description", function()
    local term_win = fixture({ s1 = { task({ description = vim.NIL }) } })

    tasks_ui.sync()

    assert.truthy(lines(list_under(term_win))[1]:find("cargo test", 1, true))
  end)

  it("shows a multi-line command (a heredoc) as its first line, marked as cut", function()
    local term_win = fixture({
      s1 = { task({ description = "", command = "cat > run.sh <<'EOF'\necho hi\nEOF" }) },
    })

    tasks_ui.sync()

    local shown = lines(list_under(term_win))
    assert.equals(1, #shown)
    assert.truthy(shown[1]:find("cat > run.sh <<'EOF' …", 1, true))
  end)

  it("keeps the same list window from one sync to the next", function()
    local term_win = fixture({ s1 = { task() } })
    tasks_ui.sync()
    local list = list_under(term_win)

    tasks_ui.sync()

    assert.equals(list, list_under(term_win))
    assert.equals(1, #vim.tbl_filter(function(win)
      return vim.w[win].fishmonger_tasks_of ~= nil
    end, vim.api.nvim_tabpage_list_wins(0)))
  end)

  it("stays away from a terminal whose agent has no tasks", function()
    local term_win = fixture({})

    tasks_ui.sync()

    assert.is_nil(list_under(term_win))
  end)

  it("closes once the last task is dismissed", function()
    local by_session = { s1 = { task() } }
    local term_win = fixture(by_session)
    tasks_ui.sync()

    by_session.s1 = {}
    tasks_ui.sync()

    assert.is_nil(list_under(term_win))
  end)

  it("follows the terminal window's tab: another agent's buffer takes its list away", function()
    local term_win = fixture({ s1 = { task() } })
    tasks_ui.sync()

    vim.api.nvim_win_set_buf(term_win, vim.api.nvim_create_buf(false, true))
    tasks_ui.sync()

    assert.is_nil(list_under(term_win))
  end)

  it("opens the task under the cursor's output above the list", function()
    local term_win, opened =
      fixture({ s1 = { task(), task({ id = "b2", output = "/o/b2.output" }) } })
    tasks_ui.sync()
    local list = list_under(term_win)
    vim.api.nvim_set_current_win(list)
    vim.api.nvim_win_set_cursor(list, { 2, 0 })

    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)

    assert.same({ { path = "/o/b2.output", below = term_win } }, opened)
  end)
end)

describe("task summary", function()
  local cases = {
    { "pytest", "===== 1 failed, 48 passed in 1.20s =====", { passed = 48, failed = 1 } },
    { "cargo", "test result: FAILED. 48 passed; 1 failed; 0 ignored", { passed = 48, failed = 1 } },
    { "jest", "Tests:       1 failed, 48 passed, 49 total", { passed = 48, failed = 1 } },
    { "mocha", "  48 passing (2s)\n  1 failing", { passed = 48, failed = 1 } },
    { "plenary", "Success: \t48\t\nFailed : \t1\t\nErrors : \t0", { passed = 48, failed = 1 } },
    { "all passing", "test result: ok. 12 passed; 0 failed", { passed = 12, failed = 0 } },
  }
  for _, case in ipairs(cases) do
    it("counts " .. case[1] .. "'s results", function()
      local summary = tasks_ui.summarize(case[2])
      assert.same(case[3], { passed = summary.passed, failed = summary.failed })
    end)
  end

  it("takes the last run's counts, not an earlier run's failures", function()
    local summary =
      tasks_ui.summarize("3 passed, 2 failed\n" .. string.rep("log line\n", 40) .. "5 passed\n")
    assert.same({ passed = 5 }, { passed = summary.passed, failed = summary.failed })
  end)

  it("gives the last line, without colour codes, when there are no counts", function()
    local summary = tasks_ui.summarize("compiling\n\27[32mListening on :8080\27[0m\n\n")
    assert.is_nil(summary.passed)
    assert.equals("Listening on :8080", summary.last_line)
  end)
end)
