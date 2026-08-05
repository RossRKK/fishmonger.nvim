-- Slot bookkeeping in fishmonger/init.lua: which terminal occupies the side panel,
-- which stay alive but hidden, and how renumbering moves them around.
--
-- The module owns a single side window (terms.win) and swaps terminal buffers
-- into it (the tmux-pane model). Headlessly there's no pty, so vim.fn.jobstart is
-- faked to a no-op: the buffer spawn() creates then stays an ordinary buffer,
-- which is all the slot table and slot_of_buf need. The real window management
-- (a botright vsplit and buffer swaps) runs for real -- it works headlessly.

local assert = require("luassert")

--- A fresh fishmonger with a single empty window and no slot state.
--- jobstart is stubbed so spawn() never launches a real shell.
local function fresh_terms()
  -- Keep jobstart's real arity: a nullary stub retrains lua_ls's inferred
  -- signature for the whole config (as the vim.notify stub below notes).
  vim.fn.jobstart = function(cmd, opts) ---@diagnostic disable-line: duplicate-set-field, unused-local
    return 1
  end
  pcall(vim.cmd, "only") -- collapse leftover split windows from a prior test
  package.loaded["fishmonger"] = nil
  return require("fishmonger")
end

--- The occupied slots, sorted.
local function slots_of(terms)
  local out = {}
  for slot in pairs(terms.slots) do
    out[#out + 1] = slot
  end
  table.sort(out)
  return out
end

--- The slot whose buffer is currently in the side window, or nil if the panel is
--- hidden (no window). This is what "shown" means in the single-window model.
local function open_slot(terms)
  if not (terms.win and vim.api.nvim_win_is_valid(terms.win)) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(terms.win)
  for slot, term in pairs(terms.slots) do
    if term.buf == buf then
      return slot
    end
  end
end

--- Whether a slot's terminal buffer is still alive (the tab survives a switch).
local function alive(terms, slot)
  local term = terms.slots[slot]
  return term ~= nil and vim.api.nvim_buf_is_valid(term.buf)
end

describe("terms.show", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  it("creates a terminal in an empty slot and makes it current", function()
    terms.show(3)
    assert.same({ 3 }, slots_of(terms))
    assert.equals(3, terms.current)
    assert.equals(3, open_slot(terms))
  end)

  it("reuses the existing terminal when the slot is shown again", function()
    terms.show(1)
    local first = terms.slots[1]
    terms.show(1)
    assert.equals(first, terms.slots[1])
    assert.equals(1, open_slot(terms))
  end)

  -- tmux-window semantics: switching away swaps the old terminal's buffer out of
  -- the side window rather than killing it, so its tab (and scrollback) survives.
  it("keeps the previous terminal as a hidden tab when switching", function()
    terms.show(1)
    terms.show(2)

    assert.same({ 1, 2 }, slots_of(terms))
    assert.is_true(alive(terms, 1)) -- slot 1 lives on, just not shown
    assert.equals(2, open_slot(terms))
    assert.equals(2, terms.current)
  end)

  -- The window is never recreated on a switch: same handle before and after.
  it("swaps the buffer in place without recreating the window", function()
    terms.show(1)
    local win = terms.win
    terms.show(2)
    assert.equals(win, terms.win)
    assert.equals(terms.slots[2].buf, vim.api.nvim_win_get_buf(terms.win))
  end)

  it("clamps a slot below the first one", function()
    terms.show(0)
    assert.same({ 1 }, slots_of(terms))
    assert.equals(1, terms.current)
  end)

  it("clamps a slot above the last one", function()
    terms.show(99)
    assert.same({ 9 }, slots_of(terms))
    assert.equals(9, terms.current)
  end)
end)

describe("terms.new", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  it("opens the lowest free slot", function()
    terms.new()
    assert.same({ 1 }, slots_of(terms))
    terms.new()
    assert.same({ 1, 2 }, slots_of(terms))
    assert.equals(2, terms.current)
  end)

  it("fills a hole left by a closed terminal", function()
    terms.show(1)
    terms.show(2)
    terms.slots[1] = nil -- as TermClose frees it

    terms.new()
    assert.same({ 1, 2 }, slots_of(terms))
    assert.equals(1, terms.current)
  end)

  it("warns instead of creating a tenth terminal", function()
    for i = 1, 9 do
      terms.show(i)
    end
    assert.equals(9, terms.current)

    local notified
    local notify = vim.notify
    -- Keep vim.notify's real arity: a narrower stub retrains lua_ls's inferred
    -- signature for the whole config.
    vim.notify = function(msg, level, opts) ---@diagnostic disable-line: unused-local
      notified = msg
    end
    local ok, err = pcall(terms.new)
    vim.notify = notify

    assert.is_true(ok, err)
    assert.is_truthy(notified and notified:match("slots in use"))
    assert.equals(9, #slots_of(terms))
    assert.equals(9, terms.current)
  end)
end)

describe("terms.move", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  it("renumbers into an empty slot, freeing the source", function()
    terms.show(1)
    local term = terms.slots[1]

    terms.move(4)
    assert.same({ 4 }, slots_of(terms))
    assert.equals(term, terms.slots[4])
    assert.equals(4, terms.current)
    -- The window/buffer are untouched: the same buffer is still on screen.
    assert.equals(4, open_slot(terms))
  end)

  -- A destination that is already taken must not clobber its terminal.
  it("swaps when the destination is occupied", function()
    terms.show(2)
    local hidden = terms.slots[2]
    terms.show(1)
    local shown = terms.slots[1]

    terms.move(2)
    assert.same({ 1, 2 }, slots_of(terms))
    assert.equals(shown, terms.slots[2])
    assert.equals(hidden, terms.slots[1])
    assert.equals(2, terms.current)
    -- The on-screen buffer didn't change, only its slot label did.
    assert.equals(2, open_slot(terms))
  end)

  it("does nothing when the destination is the current slot", function()
    terms.show(1)
    local term = terms.slots[1]

    terms.move(1)
    assert.same({ 1 }, slots_of(terms))
    assert.equals(term, terms.slots[1])
    assert.equals(1, terms.current)
  end)

  it("does nothing when no terminal is open", function()
    terms.move(3)
    assert.same({}, slots_of(terms))
  end)

  it("clamps the destination slot", function()
    terms.show(1)
    terms.move(99)
    assert.same({ 9 }, slots_of(terms))
    assert.equals(9, terms.current)
  end)
end)

describe("terms.kill", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  -- kill() frees the slot and deletes the shell's buffer. When it's the last one
  -- the side window closes too.
  it("shuts down the open terminal and closes the last window", function()
    terms.show(1)
    local buf = terms.slots[1].buf

    terms.kill()
    assert.same({}, slots_of(terms))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_nil(open_slot(terms))
  end)

  -- Killing the shown terminal when others remain surfaces another tab in the
  -- side window rather than closing it.
  it("surfaces another tab when one remains", function()
    terms.show(1)
    terms.show(2) -- slot 2 shown, slot 1 hidden
    terms.kill() -- kills slot 2

    assert.same({ 1 }, slots_of(terms))
    assert.equals(1, open_slot(terms))
    assert.equals(1, terms.current)
  end)

  it("does nothing when no terminal is open", function()
    terms.kill()
    assert.same({}, slots_of(terms))
  end)
end)

describe("terms.unwrap", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  --- Widths for fragments that are whole buffer lines (the linewise-yank case).
  local function own_widths(lines)
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = vim.fn.strdisplaywidth(line)
    end
    return out
  end

  it("joins a row wrapped at the terminal edge with its continuation", function()
    local lines = { ("x"):rep(80), "tail" }
    assert.same({ ("x"):rep(80) .. "tail" }, terms.unwrap(lines, own_widths(lines), 80))
  end)

  it("keeps the newline after a row narrower than the terminal", function()
    local lines = { "first", "second" }
    assert.same(lines, terms.unwrap(lines, own_widths(lines), 80))
  end)

  it("joins a run of full-width rows into one line", function()
    local a, b = ("a"):rep(80), ("b"):rep(80)
    local lines = { a, b, "tail", "after" }
    assert.same({ a .. b .. "tail", "after" }, terms.unwrap(lines, own_widths(lines), 80))
  end)

  -- A full-width final row may continue beyond the yank, but that continuation
  -- wasn't yanked -- there is nothing to join it to.
  it("never joins past the last yanked line", function()
    local lines = { ("x"):rep(80) }
    assert.same(lines, terms.unwrap(lines, own_widths(lines), 80))
  end)

  -- A charwise yank can start mid-row: the first fragment is narrower than the
  -- terminal even though its source row soft-wraps. The source row's width is
  -- what decides the join.
  it("decides by the source line's width, not the fragment's", function()
    assert.same({ "tail-of-rowtail" }, terms.unwrap({ "tail-of-row", "tail" }, { 80, 4 }, 80))
  end)
end)

describe("terms.joined", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  -- A full-width row is a pty soft-wrap: its continuation follows immediately,
  -- so nothing is inserted at the seam.
  it("joins pty soft-wraps with nothing", function()
    local head = ("x"):rep(80)
    assert.equals(head .. "tail", terms.joined({ head, "tail" }, { 80, 4 }, 80))
  end)

  -- A row narrower than the terminal was word-wrapped by the program itself
  -- (the break replaced a space): join with one space, stripping the
  -- continuation indent the wrapper added.
  it("joins word-wrapped rows with a space, stripping the indent", function()
    assert.equals(
      "nix shell nixpkgs#gnumake -c make test",
      terms.joined({ "nix shell nixpkgs#gnumake -c make", "  test" }, { 33, 6 }, 80)
    )
  end)

  it("trims trailing padding before a word-wrap seam", function()
    assert.equals("one two", terms.joined({ "one   ", "  two" }, { 6, 5 }, 80))
  end)

  it("handles a mix of pty wraps and word wraps", function()
    local full = ("a"):rep(80)
    assert.equals(
      full .. "end then more",
      terms.joined({ full, "end", "  then", "more" }, { 80, 3, 6, 4 }, 80)
    )
  end)

  it("returns a single fragment unchanged", function()
    assert.equals("solo", terms.joined({ "solo" }, { 4 }, 80))
  end)
end)

describe("terms.toggle", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  it("hides the open terminal without dropping its tab", function()
    terms.show(1)
    terms.toggle()

    assert.is_nil(open_slot(terms))
    assert.same({ 1 }, slots_of(terms))
    assert.equals(1, terms.current)
    assert.is_true(alive(terms, 1)) -- buffer kept, just no window
  end)

  it("re-shows the current tab rather than slot 1", function()
    terms.show(1)
    terms.show(3)
    terms.toggle()
    terms.toggle()

    assert.equals(3, open_slot(terms))
    assert.equals(3, terms.current)
  end)

  it("creates the first terminal when none exists", function()
    terms.toggle()
    assert.same({ 1 }, slots_of(terms))
    assert.equals(1, open_slot(terms))
  end)
end)

describe("terms.title_icon", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  it("extracts a leading multibyte status glyph", function()
    assert.equals("✳", terms.title_icon("✳ Refactoring the parser"))
    assert.equals("·", terms.title_icon("· idle"))
  end)

  it("yields nothing for a plain-ASCII title", function()
    assert.is_nil(terms.title_icon("fish /home/user"))
    assert.is_nil(terms.title_icon("nvim .dotfiles ~"))
  end)

  it("yields nothing for an empty or missing title", function()
    assert.is_nil(terms.title_icon(""))
    assert.is_nil(terms.title_icon(nil))
  end)
end)
