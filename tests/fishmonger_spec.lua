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
  pcall(vim.cmd, "tabonly") -- drop leftover tabpages (state is per-tabpage)
  pcall(vim.cmd, "only") -- collapse leftover split windows from a prior test
  vim.w.fishmonger_side = nil -- the survivor may have been the side panel
  vim.wo.winfixwidth = false
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

  it("starts a new terminal with the shell it is shown with, and only a new one", function()
    local started = {}
    vim.fn.jobstart = function(cmd, opts) ---@diagnostic disable-line: duplicate-set-field, unused-local
      started[#started + 1] = cmd
      return 1
    end
    terms.setup({ shell = "fish" })
    terms.show(1, { shell = { "fish", "-C", "claude" } })
    terms.show(1, { shell = "other" }) -- already running: nothing new starts
    terms.show(2)

    assert.same({ { "fish", "-C", "claude" }, "fish" }, started)
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

  -- The marker is the contract a layout manager (edgy) docks the panel by.
  it("marks the side panel with w:fishmonger_side", function()
    local editor = vim.api.nvim_get_current_win()
    terms.show(1)
    assert.is_true(vim.w[terms.win].fishmonger_side)
    assert.is_nil(vim.w[editor].fishmonger_side)
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

-- Zoom (tmux resize-pane -Z): the current window floats over the whole tabpage.
describe("terms.zoom", function()
  local terms

  --- Whether the side window is currently floated over the tabpage.
  local function zoomed()
    return vim.api.nvim_win_get_config(terms.win).relative ~= ""
  end

  before_each(function()
    terms = fresh_terms()
    terms.setup({})
    vim.o.showtabline = 2
    vim.o.laststatus = 3
    vim.o.cmdheight = 1
  end)

  after_each(function()
    -- :only can't run from a float, which every zoomed test leaves us in.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        vim.api.nvim_win_close(win, true)
      end
    end
  end)

  it("fills the editor below the tabline and above the statusline", function()
    terms.show(1)
    terms.zoom()

    local cfg = vim.api.nvim_win_get_config(terms.win)
    assert.same({ "editor", 1, 0 }, { cfg.relative, cfg.row, cfg.col })
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(terms.win))
    assert.equals(vim.o.lines - 3, vim.api.nvim_win_get_height(terms.win))
  end)

  it("keeps the same window, so tabs switch inside the zoom", function()
    terms.show(1)
    local win = terms.win
    terms.zoom()
    terms.show(2)

    assert.equals(win, terms.win)
    assert.equals(2, open_slot(terms))
    assert.is_true(zoomed())
  end)

  it("docks the window back on a second zoom", function()
    terms.show(1)
    local win = terms.win
    terms.zoom()
    terms.zoom()

    assert.equals(win, terms.win)
    assert.is_false(zoomed())
    assert.same("row", vim.fn.winlayout()[1]) -- back beside the editor
  end)

  it("zooms whichever window is current, editor included", function()
    local editor = vim.api.nvim_get_current_win()
    terms.show(1)
    vim.api.nvim_set_current_win(editor)
    terms.zoom()

    assert.equals("editor", vim.api.nvim_win_get_config(editor).relative)
    assert.is_false(zoomed()) -- the side panel stays docked
  end)

  it("puts a window back where it was in the layout, at its old size", function()
    vim.o.columns = 200 -- headless is 80 wide: the side panel alone would fill it
    local left = vim.api.nvim_get_current_win()
    vim.cmd("vsplit | split") -- a column of two beside `left`
    local top = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(top, 5)
    terms.show(1)
    local layout, sizes = vim.fn.winlayout(), vim.fn.winrestcmd()

    vim.api.nvim_set_current_win(top)
    terms.zoom()
    terms.zoom()

    assert.same(layout, vim.fn.winlayout())
    assert.equals(sizes, vim.fn.winrestcmd())
    assert.equals(1, #vim.tbl_filter(function(w)
      return w == left
    end, vim.api.nvim_tabpage_list_wins(0)))
  end)

  it("docks when another split is entered", function()
    local editor = vim.api.nvim_get_current_win()
    terms.show(1)
    terms.zoom()
    vim.api.nvim_set_current_win(editor)

    assert.is_false(zoomed())
  end)

  it("stays zoomed when a popup float is entered", function()
    terms.show(1)
    terms.zoom()
    local popup = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      row = 5,
      col = 5,
      width = 10,
      height = 5,
    })

    assert.is_true(zoomed())
    vim.api.nvim_win_close(popup, true)
  end)

  it("refits the screen on VimResized", function()
    terms.show(1)
    terms.zoom()
    vim.o.columns = vim.o.columns + 10
    vim.api.nvim_exec_autocmds("VimResized", {})

    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(terms.win))
    assert.is_true(zoomed())
  end)
end)

-- Terminal windows outside the side panel share the tabpage's one set of tabs.
describe("terminal windows", function()
  local terms, editor, file

  --- The slot a window shows, or nil when it shows something else.
  local function slot_in(win)
    local buf = vim.api.nvim_win_get_buf(win)
    for slot, term in pairs(terms.slots) do
      if term.buf == buf then
        return slot
      end
    end
  end

  before_each(function()
    terms = fresh_terms()
    editor = vim.api.nvim_get_current_win()
    file = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file, "fishmonger-spec-file-" .. file)
    vim.api.nvim_win_set_buf(editor, file)
  end)

  it("opens a terminal in the current window, back to the file with <C-o>", function()
    terms.here()

    assert.equals(1, slot_in(editor))
    assert.is_nil(terms.win) -- no side panel was opened
    vim.cmd('execute "normal! \\<C-o>"')
    assert.equals(file, vim.api.nvim_win_get_buf(editor))
  end)

  it("gives the editor window its own options back after the terminal", function()
    vim.wo[editor].number = true
    terms.here()
    assert.is_false(vim.wo[editor].number)

    vim.api.nvim_win_set_buf(editor, file)
    assert.is_true(vim.wo[editor].number)
  end)

  it("opens the most recent tab not already on screen", function()
    terms.show(1)
    terms.show(2) -- side shows 2; 1 is the most recent hidden tab
    vim.api.nvim_set_current_win(editor)
    terms.here()

    assert.equals(1, slot_in(editor))
    assert.equals(2, slot_in(terms.win))
  end)

  it("does nothing in a window already showing a terminal", function()
    terms.show(1)
    terms.here()
    assert.same({ 1 }, slots_of(terms))
  end)

  it("sends <C-b>N from the editor to the terminal window used last", function()
    terms.show(1) -- side panel
    vim.api.nvim_set_current_win(editor)
    terms.here() -- editor shows 2, and was used last
    local side = terms.win
    vim.cmd("split") -- a plain window: not a terminal
    vim.api.nvim_win_set_buf(0, file)
    terms.show(3)

    assert.equals(3, slot_in(editor))
    assert.equals(1, slot_in(side))
  end)

  it("swaps two windows' tabs when picking one shown in the other", function()
    terms.show(1)
    vim.api.nvim_set_current_win(editor)
    terms.here() -- editor 2, side 1
    terms.show(1)

    assert.equals(1, slot_in(editor))
    assert.equals(2, slot_in(terms.win))
  end)

  it("moves focus to the next terminal window", function()
    terms.show(1)
    vim.api.nvim_set_current_win(editor)
    terms.here()
    terms.cycle()

    assert.equals(terms.win, vim.api.nvim_get_current_win())
    assert.equals(1, terms.current)
  end)

  it("puts the file back when the last terminal there is killed", function()
    terms.here()
    terms.kill()

    assert.same({}, slots_of(terms))
    assert.equals(file, vim.api.nvim_win_get_buf(editor))
  end)

  it("marks the target's tab, the other window's dimmer, and tabs shown elsewhere", function()
    terms.setup({})
    terms.show(1)
    local side = terms.win
    vim.api.nvim_set_current_win(editor)
    terms.here() -- editor 2 (target), side 1

    local function strip(win)
      vim.g.statusline_winid = win -- as nvim sets it while drawing that winbar
      return terms.winbar()
    end
    assert.truthy(strip(editor):find("%#TabLineSel# 2:", 1, true))
    assert.truthy(strip(editor):find("%#FishmongerTabElsewhere# 1:", 1, true))
    assert.truthy(strip(side):find("%#FishmongerTabSelNC# 1:", 1, true))
  end)

  it("colours a tab's name in its agent's session colour", function()
    local agent = require("fishmonger.agent")
    local real = agent.for_buf
    agent.for_buf = function() ---@diagnostic disable-line: duplicate-set-field
      return { session = "s1", state = "done", colour = "red" }
    end
    terms.setup({})
    terms.show(1)
    vim.g.statusline_winid = terms.win
    local strip = terms.winbar()
    agent.for_buf = real

    assert.truthy(strip:find("%#FishmongerTabLineSelFishmongerAgentRed#", 1, true))
  end)
end)

-- Panes (tmux split-window / kill-pane / select-pane): more terminal windows,
-- each showing one of the tabpage's shared tabs.
describe("panes", function()
  local terms, editor, file

  --- The slot a window shows, or nil when it shows something else.
  local function slot_in(win)
    local buf = vim.api.nvim_win_get_buf(win)
    for slot, term in pairs(terms.slots) do
      if term.buf == buf then
        return slot
      end
    end
  end

  before_each(function()
    terms = fresh_terms()
    editor = vim.api.nvim_get_current_win()
    file = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file, "fishmonger-spec-pane-" .. file)
    vim.api.nvim_win_set_buf(editor, file)
  end)

  it("splits the side panel below into a new shell that is a side window too", function()
    terms.show(1)
    local side = terms.win
    terms.split("below")
    local pane = vim.api.nvim_get_current_win()

    assert.are_not.equals(side, pane)
    assert.same({ 1, 2 }, slots_of(terms))
    assert.equals(1, slot_in(side))
    assert.equals(2, slot_in(pane))
    assert.equals(2, terms.current)
    assert.is_true(vim.w[pane].fishmonger_side)
    local above, below = vim.api.nvim_win_get_position(side), vim.api.nvim_win_get_position(pane)
    assert.equals(above[2], below[2])
    assert.is_true(below[1] > above[1])
  end)

  -- A layout manager (edgy) places a window when a buffer enters it, so the
  -- side mark has to be there already or the pane is evicted from the column.
  it("marks a side pane before its terminal enters it", function()
    terms.show(1)
    local marked
    vim.api.nvim_create_autocmd("BufWinEnter", {
      once = true,
      callback = function()
        marked = vim.w.fishmonger_side
      end,
    })
    terms.split("below")
    assert.is_true(marked)
  end)

  it("splits an editor-area terminal to the right without docking it", function()
    terms.here()
    terms.split("right")
    local pane = vim.api.nvim_get_current_win()

    assert.equals(1, slot_in(editor))
    assert.equals(2, slot_in(pane))
    assert.is_nil(vim.w[pane].fishmonger_side)
    local left, right = vim.api.nvim_win_get_position(editor), vim.api.nvim_win_get_position(pane)
    assert.equals(left[1], right[1])
    assert.is_true(right[2] > left[2])
  end)

  it("warns and opens no window when every slot is taken", function()
    for i = 1, 9 do
      terms.show(i)
    end
    local warned
    vim.notify = function(msg)
      warned = msg
    end ---@diagnostic disable-line: duplicate-set-field
    local before = #vim.api.nvim_tabpage_list_wins(0)

    terms.split("below")

    assert.matches("all 9 terminal slots in use", warned)
    assert.equals(before, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("kills a pane's shell and closes its window, leaving the other pane", function()
    terms.show(1)
    local side = terms.win
    terms.split("below")
    local pane = vim.api.nvim_get_current_win()
    local buf = terms.slots[2].buf

    terms.kill_pane()

    assert.same({ 1 }, slots_of(terms))
    assert.is_false(vim.api.nvim_win_is_valid(pane))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.equals(1, slot_in(side))
  end)

  it("keeps the last window, back on its file, when killing the pane in it", function()
    terms.here()
    terms.kill_pane()

    assert.same({}, slots_of(terms))
    assert.is_true(vim.api.nvim_win_is_valid(editor))
    assert.equals(file, vim.api.nvim_win_get_buf(editor))
  end)

  it("hides every side pane on toggle, keeping their tabs", function()
    terms.show(1)
    terms.split("below")
    terms.toggle()

    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
    assert.same({ 1, 2 }, slots_of(terms))
    assert.is_true(alive(terms, 1) and alive(terms, 2))
  end)

  it("moves to the pane in a direction", function()
    terms.show(1)
    local side = terms.win
    terms.split("below")
    terms.select("k")

    assert.equals(side, vim.api.nvim_get_current_win())
    assert.equals(1, terms.current)
  end)

  it("moves <C-k> up to the pane above, else gives it to the program", function()
    terms.show(1)
    local side = terms.win
    terms.split("below")
    local function ctrl_k()
      return vim.fn.maparg("<C-k>", "t", false, true).callback()
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(ctrl_k(), true, false, true), "x", false)
    assert.equals(side, vim.api.nvim_get_current_win())
    assert.equals(1, terms.current)
    assert.equals("<C-k>", ctrl_k())
  end)

  it("reads the pane keys after <C-b>", function()
    terms.setup_keymaps()
    terms.show(1)
    vim.cmd("stopinsert")
    local function press(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    press('<C-b>"')
    assert.same({ 1, 2 }, slots_of(terms))
    vim.cmd("stopinsert")
    press("<C-b><Up>")
    assert.equals(1, terms.current)
    vim.cmd("stopinsert")
    press("<C-b>x")
    assert.same({ 2 }, slots_of(terms))
  end)
end)

describe("terms.send", function()
  local terms, sent, real_chan_send

  before_each(function()
    terms = fresh_terms()
    -- Distinct channel per terminal, so a test can tell which one was written.
    local next_chan = 100
    vim.fn.jobstart = function(cmd, opts) ---@diagnostic disable-line: duplicate-set-field, unused-local
      next_chan = next_chan + 1
      return next_chan
    end
    sent = {}
    real_chan_send = vim.api.nvim_chan_send
    vim.api.nvim_chan_send = function(chan, data) ---@diagnostic disable-line: duplicate-set-field
      sent[#sent + 1] = { chan = chan, data = data }
    end
  end)

  after_each(function()
    vim.api.nvim_chan_send = real_chan_send
  end)

  it("types into the current terminal without submitting, and shows it", function()
    terms.show(1)
    terms.show(2)
    terms.toggle() -- hidden: send still targets the current tab and re-shows it

    assert.is_true(terms.send("lua/a.lua:12 "))
    assert.same({ { chan = 102, data = "lua/a.lua:12 " } }, sent)
    assert.equals(2, open_slot(terms))
  end)

  it("follows the terminal through a renumber", function()
    terms.show(1)
    terms.move(4)

    terms.send("x")
    assert.same({ { chan = 101, data = "x" } }, sent)
  end)

  it("refuses rather than spawning a terminal when none exists", function()
    local warned
    local real_notify = vim.notify
    vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
      warned = level == vim.log.levels.WARN and msg
    end
    local ok = terms.send("x")
    vim.notify = real_notify

    assert.is_false(ok)
    assert.same({}, sent)
    assert.same({}, slots_of(terms))
    assert.truthy(warned)
  end)
end)

-- A tabpage is a workspace: slots, the shown tab and the side window are all
-- per-tabpage, and terms.slots/current/win report the CURRENT tabpage's.
describe("per-tabpage state", function()
  local terms

  before_each(function()
    terms = fresh_terms()
  end)

  after_each(function()
    pcall(vim.cmd, "tabonly")
  end)

  it("gives a new tabpage its own empty slots", function()
    terms.show(1)
    local first = terms.slots[1].buf

    vim.cmd("tabnew")
    assert.same({}, slots_of(terms))

    terms.show(1)
    assert.are_not.equals(first, terms.slots[1].buf)
  end)

  it("keeps each tabpage's terminals when switching between them", function()
    terms.show(1)
    local a = terms.slots[1].buf
    vim.cmd("tabnew")
    terms.show(1)
    local b = terms.slots[1].buf

    vim.cmd("tabprevious")
    assert.equals(a, terms.slots[1].buf)
    vim.cmd("tabnext")
    assert.equals(b, terms.slots[1].buf)
  end)

  -- The regression that made tabpages unusable: nvim_win_is_valid is true for a
  -- window in another tabpage, so a shared viewport made toggle/show focus the
  -- OTHER tabpage's terminal -- teleporting you out of the project you were in.
  it("opens its own side window instead of focusing another tabpage's", function()
    terms.show(1)
    local other_win = terms.win

    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    terms.toggle()

    assert.equals(tab, vim.api.nvim_get_current_tabpage())
    assert.are_not.equals(other_win, terms.win)
    assert.equals(tab, vim.api.nvim_win_get_tabpage(terms.win))
  end)

  -- Closing a tabpage closes its windows, but its terminal buffers would outlive
  -- it with nothing left to reach them by -- so the shells go with the workspace.
  -- terms.tabs(tab) is what lets config paint another workspace's status onto its
  -- tabpage label, so it must answer for a tabpage you are not in -- and must not
  -- silently answer about the current one for a tabpage with no terminals.
  it("reports a given tabpage's terminals", function()
    terms.show(1)
    local first = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local second = vim.api.nvim_get_current_tabpage()
    terms.show(1)
    terms.show(2)

    assert.same(
      { 1 },
      vim.tbl_map(function(t)
        return t.slot
      end, terms.tabs(first))
    )
    assert.same(
      { 1, 2 },
      vim.tbl_map(function(t)
        return t.slot
      end, terms.tabs(second))
    )

    vim.cmd("tabnew")
    assert.same({}, terms.tabs(vim.api.nvim_get_current_tabpage()))
  end)

  it("shuts down a closed tabpage's terminals", function()
    terms.setup({})
    vim.cmd("tabnew")
    terms.show(1)
    terms.show(2)
    local bufs = { terms.slots[1].buf, terms.slots[2].buf }

    vim.cmd("tabclose")
    for _, buf in ipairs(bufs) do
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end
  end)
end)

-- Carrying a live terminal to another tabpage (tmux move-window -t). The buffer
-- is the identity: the same bufnr must turn up in the destination's slots, and
-- the source must be left as if that tab had been killed.
describe("terms.transfer", function()
  local terms

  before_each(function()
    terms = fresh_terms()
    vim.notify = function(msg, level) end ---@diagnostic disable-line: duplicate-set-field, unused-local
  end)

  --- Open a second tabpage and return { source, dest } handles, ending in source.
  local function two_tabs()
    local source = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local dest = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(source)
    return source, dest
  end

  it("moves the shown terminal's buffer into the destination and follows it", function()
    local source, dest = two_tabs()
    terms.show(2)
    local buf = terms.slots[2].buf

    assert.is_true(terms.transfer(dest))

    assert.equals(dest, vim.api.nvim_get_current_tabpage())
    assert.same({ 1 }, slots_of(terms)) -- lowest free slot there, not slot 2
    assert.equals(buf, terms.slots[1].buf)
    assert.equals(1, open_slot(terms))
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    vim.api.nvim_set_current_tabpage(source)
    assert.same({}, slots_of(terms))
    assert.is_nil(terms.win)
  end)

  it("surfaces another source tab when one remains", function()
    local source, dest = two_tabs()
    terms.show(1)
    terms.show(2)
    local moved = terms.slots[2].buf

    terms.transfer(dest)

    vim.api.nvim_set_current_tabpage(source)
    assert.same({ 1 }, slots_of(terms))
    assert.equals(1, open_slot(terms))
    assert.are_not.equals(moved, terms.slots[1].buf)
  end)

  it("takes the lowest free slot without clobbering the destination's tabs", function()
    local source, dest = two_tabs()
    vim.api.nvim_set_current_tabpage(dest)
    terms.show(1)
    terms.show(3)
    local kept1, kept3 = terms.slots[1].buf, terms.slots[3].buf
    vim.api.nvim_set_current_tabpage(source)
    terms.show(1)
    local moved = terms.slots[1].buf

    terms.transfer(dest)

    assert.same({ 1, 2, 3 }, slots_of(terms))
    assert.equals(kept1, terms.slots[1].buf)
    assert.equals(moved, terms.slots[2].buf)
    assert.equals(kept3, terms.slots[3].buf)
    assert.equals(2, open_slot(terms))
  end)

  it("refuses the current tabpage, an invalid tabpage, and an empty panel", function()
    local _, dest = two_tabs()
    assert.is_false(terms.transfer(dest)) -- nothing open to move
    terms.show(1)
    assert.is_false(terms.transfer(vim.api.nvim_get_current_tabpage()))
    assert.is_false(terms.transfer(nil))
    assert.is_false(terms.transfer(99999))
    assert.same({ 1 }, slots_of(terms))
  end)

  it("picks the destination by project name, leaving the current tabpage out", function()
    local source, dest = two_tabs()
    terms.setup({
      project_name = function(tab)
        return tab == dest and "repo-y" or "repo-x"
      end,
    })
    terms.show(1)
    local buf = terms.slots[1].buf
    local offered
    vim.ui.select = function(items, opts, on_choice) ---@diagnostic disable-line: duplicate-set-field
      offered = {}
      for _, item in ipairs(items) do
        offered[#offered + 1] = opts.format_item(item)
      end
      on_choice(items[1])
    end

    terms.transfer_pick()

    assert.same({ "repo-y" }, offered)
    assert.equals(dest, vim.api.nvim_get_current_tabpage())
    assert.equals(buf, terms.slots[1].buf)
  end)

  it("warns instead of opening a picker when there is no other tabpage", function()
    terms.show(1)
    local warned
    vim.notify = function(msg)
      warned = msg
    end ---@diagnostic disable-line: duplicate-set-field
    local opened = false
    vim.ui.select = function()
      opened = true
    end ---@diagnostic disable-line: duplicate-set-field

    terms.transfer_pick()

    assert.matches("no other workspace", warned)
    assert.is_false(opened)
  end)

  it("sends to workspace N through the configured numbering", function()
    local source, dest = two_tabs()
    terms.setup({
      workspace = function(n)
        return n == 7 and dest or nil
      end,
    })
    terms.show(1)
    local buf = terms.slots[1].buf

    assert.is_true(terms.transfer_to(7))

    assert.equals(dest, vim.api.nvim_get_current_tabpage())
    assert.equals(buf, terms.slots[1].buf)
    vim.api.nvim_set_current_tabpage(source)
    assert.same({}, slots_of(terms))
  end)

  it("takes N as the tabpage number without a configured numbering", function()
    local _, dest = two_tabs()
    terms.show(1)
    assert.is_true(terms.transfer_to(2))
    assert.equals(dest, vim.api.nvim_get_current_tabpage())
  end)

  it("warns and moves nothing when there is no workspace N", function()
    local source = two_tabs()
    terms.setup({
      workspace = function()
        return nil
      end,
    })
    terms.show(1)
    local warned
    vim.notify = function(msg)
      warned = msg
    end ---@diagnostic disable-line: duplicate-set-field

    assert.is_false(terms.transfer_to(2))

    assert.matches("no workspace 2", warned)
    assert.equals(source, vim.api.nvim_get_current_tabpage())
    assert.same({ 1 }, slots_of(terms))
  end)

  it("reads the workspace number after <C-b>m", function()
    local _, dest = two_tabs()
    terms.setup_keymaps()
    terms.show(1)
    local buf = terms.slots[1].buf
    vim.cmd("stopinsert")

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-b>m2", true, false, true), "x", false)

    assert.equals(dest, vim.api.nvim_get_current_tabpage())
    assert.equals(buf, terms.slots[1].buf)
  end)

  it("warns and leaves both tabpages alone when the destination is full", function()
    local source, dest = two_tabs()
    vim.api.nvim_set_current_tabpage(dest)
    for i = 1, 9 do
      terms.show(i)
    end
    vim.api.nvim_set_current_tabpage(source)
    terms.show(1)
    local warned
    vim.notify = function(msg)
      warned = msg
    end ---@diagnostic disable-line: duplicate-set-field

    assert.is_false(terms.transfer(dest))

    assert.matches("in use", warned)
    assert.equals(source, vim.api.nvim_get_current_tabpage())
    assert.same({ 1 }, slots_of(terms))
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

describe("terms.open_output", function()
  local terms, output
  before_each(function()
    terms = fresh_terms()
    terms.show(1)
    output = vim.fn.tempname()
  end)

  --- Append `text` to the task's output file, as the task would.
  local function append(text)
    local f = assert(io.open(output, "a"))
    f:write(text)
    f:close()
  end

  --- The pane's visible text, once nvim has drawn what was sent to it.
  local function pane_text(pane, expect)
    local buf = vim.api.nvim_win_get_buf(pane)
    local text
    vim.wait(2000, function()
      text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      return text:find(expect, 1, true) ~= nil
    end)
    return text
  end

  it("shows the output in a pane below its terminal, docked with it and not a tab", function()
    append("line one\n")
    local term_win = terms.win

    terms.open_output(output, term_win)

    local pane = vim.api.nvim_get_current_win()
    assert.are_not.equal(term_win, pane)
    assert.is_true(vim.api.nvim_win_get_position(pane)[1] > vim.api.nvim_win_get_position(term_win)[1])
    assert.truthy(pane_text(pane, "line one"):find("line one", 1, true))
    assert.is_true(vim.w[pane].fishmonger_side)
    assert.same({ 1 }, slots_of(terms))
  end)

  it("lands in normal mode, so the output is navigated like any buffer", function()
    append("line one\n")

    terms.open_output(output, terms.win)

    assert.equals("nt", vim.api.nvim_get_mode().mode)
  end)

  it("keeps up with output appended after it opened", function()
    append("line one\n")
    terms.open_output(output, terms.win)
    local pane = vim.api.nvim_get_current_win()

    append("line two\n")

    assert.truthy(pane_text(pane, "line two"):find("line two", 1, true))
  end)

  it("puts each line of output on its own row", function()
    append("line one\nline two\n")

    terms.open_output(output, terms.win)

    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    pane_text(vim.api.nvim_get_current_win(), "line two")
    local rows = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
    assert.same({ "line one", "line two" }, rows)
  end)

  it("closes on q", function()
    append("line one\n")
    local term_win = terms.win
    terms.open_output(output, term_win)
    local pane = vim.api.nvim_get_current_win()

    vim.api.nvim_feedkeys("q", "x", false)

    assert.is_false(vim.api.nvim_win_is_valid(pane))
    assert.is_true(vim.api.nvim_win_is_valid(term_win))
  end)

  it("goes back to the pane already showing that output rather than opening another", function()
    append("line one\n")
    local term_win = terms.win
    terms.open_output(output, term_win)
    local pane = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(term_win)
    local windows = #vim.api.nvim_tabpage_list_wins(0)

    terms.open_output(output, term_win)

    assert.equals(pane, vim.api.nvim_get_current_win())
    assert.equals(windows, #vim.api.nvim_tabpage_list_wins(0))
  end)
end)
