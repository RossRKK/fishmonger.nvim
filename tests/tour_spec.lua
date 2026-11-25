-- The tour list (fishmonger/tour.lua): an agent's tour of files, docked under
-- the terminal its session runs in, and the progress it reports back. Its
-- inputs are passed in, so the specs hand it plain tables and temp files.

local assert = require("luassert")

local tour = require("fishmonger.tour")

--- One terminal window (the current one) running session `s1`, and a tour list
--- wired to it. Returns the window and the files opened, in order.
local function fixture()
  pcall(vim.cmd, "tabonly")
  pcall(vim.cmd, "only")
  local term_win = vim.api.nvim_get_current_win()
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local opened = {}
  tour.setup({
    terminal_windows = function()
      return { term_win }
    end,
    session_of = function(buf)
      return buf == term_buf and "s1" or nil
    end,
    is_session = function(session)
      return session == "s1" or session == "s2"
    end,
    open_file = function(path, line)
      opened[#opened + 1] = { path = path, line = line }
    end,
  })
  return term_win, opened
end

--- A tour for `session` of `n` steps, reporting to a fresh temp file.
local function spec(session, n)
  local steps = {}
  for i = 1, n do
    steps[i] = { path = "/src/step" .. i .. ".lua", line = i * 10, description = "Step " .. i }
  end
  return {
    id = "toolu_" .. session,
    session = session,
    title = "Auth flow",
    steps = steps,
    report = vim.fn.tempname() .. "/claude-tour/" .. session .. ".json",
  }
end

--- The window under `term_win` marked with window variable `of_var`, or nil.
local function marked(of_var, term_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win][of_var] == term_win then
      return win
    end
  end
end

local function list_under(term_win)
  return marked("fishmonger_tour_of", term_win)
end

local function note_under(term_win)
  return marked("fishmonger_tour_note_of", term_win)
end

local function lines(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function report(s)
  return vim.json.decode(table.concat(vim.fn.readfile(s.report), "\n"))
end

--- Press `keys` in list `win`, as typed there.
local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

describe("tour list", function()
  after_each(function()
    tour.finish({ session = "s1" })
    tour.finish({ session = "s2" })
  end)

  it("docks under its session's terminal and opens the first step at once", function()
    local term_win, opened = fixture()
    local s = spec("s1", 3)

    assert.equals("", tour.show(s))

    local list = assert(list_under(term_win))
    assert.equals(3, #lines(list))
    assert.equals("● /src/step1.lua:10", lines(list)[1])
    assert.same({ { path = "/src/step1.lua", line = 10 } }, opened)
    assert.same({ id = "toolu_s1", status = "active", current = 1, visited = { 1 } }, report(s))
    -- Focus stays where it was: the tour shows itself, it doesn't take the keyboard.
    assert.equals(term_win, vim.api.nvim_get_current_win())
  end)

  it("opens the step under the cursor and reports where you are", function()
    local term_win, opened = fixture()
    local s = spec("s1", 3)
    tour.show(s)
    local list = list_under(term_win)

    vim.api.nvim_set_current_win(list)
    vim.api.nvim_win_set_cursor(list, { 3, 0 })
    press(list, "<CR>")

    assert.same({ path = "/src/step3.lua", line = 30 }, opened[#opened])
    assert.same({ id = "toolu_s1", status = "active", current = 3, visited = { 1, 3 } }, report(s))
  end)

  it("marks the current step and those you have visited", function()
    local term_win = fixture()
    tour.show(spec("s1", 3))

    local rows = lines(list_under(term_win))

    assert.equals("●", vim.fn.strcharpart(rows[1], 0, 1))
    assert.equals("○", vim.fn.strcharpart(rows[2], 0, 1))
  end)

  it("can't be typed in", function()
    local term_win = fixture()
    tour.show(spec("s1", 2))

    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(list_under(term_win))].modifiable)
  end)

  it("shows the current step's note as markdown, read-only, between terminal and list", function()
    local term_win = fixture()
    tour.show(spec("s1", 2))

    local note = assert(note_under(term_win))
    local buf = vim.api.nvim_win_get_buf(note)
    assert.same({ "Step 1" }, lines(note))
    assert.equals("markdown", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
    local term_row, note_row, list_row =
      vim.api.nvim_win_get_position(term_win)[1],
      vim.api.nvim_win_get_position(note)[1],
      vim.api.nvim_win_get_position(list_under(term_win))[1]
    assert.is_true(term_row < note_row and note_row < list_row)
  end)

  it("shows the note of the step under the list's cursor", function()
    local term_win = fixture()
    tour.show(spec("s1", 3))
    local list = list_under(term_win)

    vim.api.nvim_set_current_win(list)
    vim.api.nvim_win_set_cursor(list, { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(list) })

    assert.same({ "Step 3" }, lines(note_under(term_win)))
  end)

  it("toggles the note away and back, the list staying", function()
    local term_win = fixture()
    tour.show(spec("s1", 2))

    tour.toggle_note()
    assert.is_nil(note_under(term_win))
    assert.is_not_nil(list_under(term_win))

    tour.toggle_note()
    assert.same({ "Step 1" }, lines(note_under(term_win)))
  end)

  it("is dismissed with q from its note too", function()
    local term_win = fixture()
    local s = spec("s1", 2)
    tour.show(s)

    press(note_under(term_win), "q")

    assert.is_nil(note_under(term_win))
    assert.equals("dismissed", report(s).status)
  end)

  it("is dismissed with q: the list closes and the report says so", function()
    local term_win = fixture()
    local s = spec("s1", 2)
    tour.show(s)

    press(list_under(term_win), "q")

    assert.is_nil(list_under(term_win))
    assert.equals("dismissed", report(s).status)
  end)

  it("closes when the agent ends it, leaving the report to the agent", function()
    local term_win = fixture()
    local s = spec("s1", 2)
    tour.show(s)

    assert.equals("", tour.finish({ session = "s1" }))

    assert.is_nil(list_under(term_win))
    assert.equals("active", report(s).status)
  end)

  it("replaces the session's tour with a newer one", function()
    local term_win, opened = fixture()
    tour.show(spec("s1", 3))
    local newer = vim.tbl_extend("force", spec("s1", 1), { id = "toolu_newer" })

    tour.show(newer)

    assert.equals(1, #lines(list_under(term_win)))
    assert.equals(2, #opened)
    assert.equals("toolu_newer", report(newer).id)
  end)

  it("waits, unopened, while its session's terminal isn't shown", function()
    local term_win, opened = fixture()
    local s = spec("s2", 2)

    assert.equals("", tour.show(s))

    assert.is_nil(list_under(term_win))
    assert.same({}, opened)
    local r = report(s)
    assert.is_nil(r.current)
    assert.same({}, r.visited)
  end)

  it("refuses a session no terminal here runs, and a tour without steps", function()
    fixture()

    assert.truthy(tour.show(spec("elsewhere", 1)):find("elsewhere", 1, true))
    assert.truthy(tour.show(spec("s1", 0)):find("no steps", 1, true))
  end)
end)
