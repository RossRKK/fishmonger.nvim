-- The referenced-files list (fishmonger/files.lua): which files a session's
-- transcript refers to, and the window listing them under a terminal. Its
-- inputs are passed in, so the specs hand it plain tables and temp files.

local assert = require("luassert")

local files = require("fishmonger.files")
local transcript = require("fishmonger.transcript")

local FIXTURE = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
  .. "/fixtures/references.jsonl"

--- A project directory holding `paths` (relative), as empty files.
local function project(paths)
  local root = vim.fs.normalize(vim.fn.tempname())
  for _, path in ipairs(paths) do
    local full = root .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    vim.fn.writefile({}, full)
  end
  return root
end

--- `refs` with paths relative to `cwd` (or its parent), for readable expectations.
local function relative(refs, cwd)
  return vim.tbl_map(function(ref)
    local path = vim.fs.relpath(cwd, ref.path)
      or "../" .. vim.fs.relpath(vim.fs.dirname(cwd), ref.path)
    return { path = path, line = ref.line }
  end, refs)
end

local function text(s)
  return { type = "text", text = s }
end

describe("files.referenced", function()
  local root, cwd

  before_each(function()
    root = project({
      "proj/README.md",
      "proj/lua/app.lua",
      "proj/lua/util.lua",
      "proj/analysis.ipynb",
      "proj/lua/ignored.lua",
      "outside.txt",
    })
    cwd = root .. "/proj"
  end)

  it(
    "lists a transcript's files newest first, each once, at its latest reference's line",
    function()
      local blocks = transcript.recent_assistant_blocks(FIXTURE)

      assert.same({
        { path = "README.md" },
        { path = "lua/app.lua", line = 12 },
        { path = "analysis.ipynb" },
        { path = "lua/util.lua" },
      }, relative(files.referenced(blocks, cwd), cwd))
    end
  )

  for _, case in ipairs({
    {
      "a path in backticks, with line and column",
      "see `lua/app.lua:12:5` here",
      { { path = "lua/app.lua", line = 12 } },
    },
    {
      "a line range, at its first line",
      "lines lua/app.lua:12-30.",
      { { path = "lua/app.lua", line = 12 } },
    },
    { "a name with an extension, in brackets", "(README.md)", { { path = "README.md" } } },
    { "a ./ path", "./lua/util.lua", { { path = "lua/util.lua" } } },
    { "a path out of cwd", "../outside.txt:3", { { path = "../outside.txt", line = 3 } } },
    {
      "several, the later first",
      "lua/app.lua then lua/util.lua:2",
      { { path = "lua/util.lua", line = 2 }, { path = "lua/app.lua" } },
    },
    { "no directory", "lua/ and lua", {} },
    { "no missing file", "lua/missing.lua:4", {} },
    { "no bare name without an extension", "Makefile README", {} },
    { "no URL", "https://example.com/README.md", {} },
  }) do
    it("takes from text " .. case[1], function()
      assert.same(case[3], relative(files.referenced({ text(case[2]) }, cwd), cwd))
    end)
  end

  it("takes an absolute path as it is", function()
    assert.same(
      { { path = root .. "/outside.txt", line = 7 } },
      files.referenced({ text("at " .. root .. "/outside.txt:7") }, cwd)
    )
  end)
end)

describe("referenced-files list", function()
  local root, log, term_win, term_buf, opened

  --- `lines` appended to the transcript as assistant text blocks.
  local function say(...)
    local entries = vim.tbl_map(function(s)
      return vim.json.encode({ type = "assistant", message = { content = { text(s) } } })
    end, { ... })
    vim.fn.writefile(entries, log, "a")
  end

  local function list_under(win)
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.w[w].fishmonger_files_of == win then
        return w
      end
    end
  end

  local function lines(win)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  end

  before_each(function()
    pcall(vim.cmd, "tabonly")
    -- A fresh window: `only` would keep the last spec's focused list, marks and all.
    vim.cmd("new | only")
    root = project({ "a.lua", "b.lua" })
    log = root .. "/session.jsonl"
    vim.fn.writefile({}, log)
    term_win = vim.api.nvim_get_current_win()
    term_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(term_win, term_buf)
    opened = {}
    files.setup({
      terminal_windows = function()
        return vim.api.nvim_win_is_valid(term_win) and { term_win } or {}
      end,
      session_of = function(buf)
        return buf == term_buf and { transcript = log, cwd = root } or nil
      end,
      open_file = function(path, line)
        opened[#opened + 1] = { path = path, line = line }
      end,
    })
  end)

  it("opens under the terminal, focused, one line per file from cwd", function()
    say("edit a.lua:3 and " .. root .. "/b.lua")

    files.toggle(term_win)

    local list = list_under(term_win)
    assert.equals(list, vim.api.nvim_get_current_win())
    assert.same({ "b.lua", "a.lua:3" }, lines(list))
    assert.equals(2, vim.w[list].fishmonger_files_height)
  end)

  it("closes on a second toggle", function()
    files.toggle(term_win)

    files.toggle(term_win)

    assert.is_nil(list_under(term_win))
  end)

  it("opens the file under the cursor at its line", function()
    say("a.lua:3 then b.lua")
    files.toggle(term_win)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)

    assert.same({ { path = root .. "/a.lua", line = 3 } }, opened)
  end)

  it("picks up what the transcript gained at the next sync", function()
    say("a.lua")
    files.toggle(term_win)

    say("b.lua:9")
    files.sync()

    assert.same({ "b.lua:9", "a.lua" }, lines(list_under(term_win)))
  end)

  it("stays open and empty while its terminal shows no agent", function()
    say("a.lua")
    files.toggle(term_win)

    vim.api.nvim_win_set_buf(term_win, vim.api.nvim_create_buf(false, true))
    files.sync()

    assert.same({ "" }, lines(list_under(term_win)))
  end)

  it("closes when its window no longer shows a terminal", function()
    files.toggle(term_win)
    local list = list_under(term_win)
    local closed = term_win
    term_win = -1

    files.sync()

    assert.is_false(vim.api.nvim_win_is_valid(list))
    assert.is_nil(list_under(closed))
  end)
end)
