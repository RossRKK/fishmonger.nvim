-- fishmonger.nvim — tmux-style tab switching for the vertical side terminal.
--
-- One terminal is visible in the side slot at a time; the others stay alive but
-- hidden. Switching is done from terminal-normal mode (enter it with <C-\><C-n>,
-- or the <C-n> map): <C-b>{1-9} switches to (creating on demand) a terminal,
-- <C-b>c opens the next free slot, <C-b>& kills the current terminal (tmux
-- kill-window), and <C-b>.{1-9} renumbers the current terminal to another slot
-- (tmux move-window). <C-t> toggles the side slot from anywhere.
--
-- Model (the tmux-pane model): a SINGLE side window (M.win) lives in the right
-- slot, and switching tabs swaps which terminal buffer that window shows --
-- nvim_win_set_buf, never close+reopen. The window's size therefore never
-- changes on a switch, so the pty never gets a SIGWINCH and a full-screen TUI
-- (Claude Code) never repaints into a stale geometry -- which is what produced
-- the doubled/off-by-one rows the old hide/show-per-terminal approach caused
-- (each show recreated a window, and edgy resized it from default -> 0.4 mid
-- render). We own the window and spawn terminals directly with jobstart.
--
-- Slots (1..9) are ours. M.slots is the sole slot->buffer mapping. Renumbering is
-- a swap in a table we own. Everything else (the tab strip) keys off the buffer.

local M = {}

local BASE = 1 -- slot 1 is the primary side terminal (<C-t>)
local MAX = 9

-- Defaults, overridable via M.setup(). fishmonger owns its own geometry so it
-- works standalone, but stays adoptable by an external layout manager: the
-- window carries `filetype` as a stable identity a manager like edgy can filter
-- on to take over placement/sizing (see lua/plugins/edgy.lua in this config).
local config = {
  -- Side-window width. A number is columns; a function is re-evaluated on open
  -- and VimResized (so it can track the screen). Default: ~40% biased toward
  -- the editor, but never below 80 so a standard 80-col line always fits.
  width = function()
    return math.max(80, math.floor(vim.o.columns * 0.4))
  end,
  -- Filetype tagged on every terminal buffer/window. fishmonger's own identity;
  -- an external layout manager can filter on it to adopt the window.
  filetype = "fishmonger",
  -- Shell command to spawn in each terminal. Defaults to the user's shell.
  shell = vim.o.shell,
}

-- Resolve the configured width to a column count.
local function want_width()
  local w = config.width
  return type(w) == "function" and w() or w
end

M.current = BASE -- slot currently shown
M.slots = {} -- slot (1..9) -> { buf = <bufnr> }
M.win = nil -- the single side window (shared viewport), or nil when closed

-- The side window if it still exists, else nil (and forget the stale handle).
local function viewport()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    return M.win
  end
  M.win = nil
  return nil
end

-- The tab strip is a window-local winbar (see M.winbar). It's set on the side
-- window and must stay set: a full-screen TUI never repaints into a changed
-- geometry because the winbar is constant (present before any pty job starts,
-- never toggled). It IS re-asserted rather than "set once", because an adopting
-- layout manager (edgy) blanks a panel's winbar synchronously on every buffer
-- swap; apply_winbar re-establishes it after the swap (see M.show). Re-asserting
-- the same value is inert for the pty -- it changes no window geometry.
local function apply_winbar(win)
  vim.wo[win].winbar = "%!v:lua.fishmonger_winbar()"
end

-- Apply the terminal look to the side window. Window-local, so it's set once on
-- the shared window and persists across every buffer swap.
local function style_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  apply_winbar(win)
end

-- Open the shared side window at the far right carrying `buf`, sized to the
-- configured width and pinned with winfixwidth so it holds. An external layout
-- manager (edgy, filtering on config.filetype) may still adopt and re-govern it;
-- fishmonger's own width is the standalone default. Called only when no side
-- window exists (first open, or after <C-t> closed it) -- never on a plain tab
-- switch, which is the whole point.
local function open_viewport(buf)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  style_window(win)
  pcall(vim.api.nvim_win_set_width, win, want_width())
  vim.wo[win].winfixwidth = true
  M.win = win
  return win
end

-- A fresh terminal buffer, tagged with config.filetype *before* it is ever shown
-- so an adopting layout manager (edgy filters on filetype) picks the window up
-- the moment the buffer enters it; setting it afterwards would leave the window
-- a plain middle split until then. No job yet -- start_job does that once the
-- buffer is on screen.
local function make_term_buf()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = config.filetype
  return buf
end

-- Start the shell in `buf`, which must already be shown in the current window:
-- jobstart({term=true}) attaches to the current buffer and sizes the pty to the
-- current window. Re-assert the filetype (jobstart can reset it) and pass <C-k>
-- through -- the side terminal is full-height, so <C-k> window-nav is useless
-- here and the running app (e.g. Claude Code) should get the key instead.
local function start_job(buf)
  vim.fn.jobstart(config.shell, { term = true })
  vim.bo[buf].filetype = config.filetype
  vim.keymap.set("t", "<C-k>", "<C-k>", { buffer = buf })
end

-- Kill a terminal's shell by deleting its buffer: that stops the job and fires
-- TermClose, which setup_exit uses to free the slot and surface another tab.
local function shutdown(term)
  if term and term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    vim.api.nvim_buf_delete(term.buf, { force = true })
  end
end

local function clamp(slot)
  return math.max(BASE, math.min(MAX, slot))
end

-- Our side terminals as a slot-ordered list of { slot, term } pairs, including
-- hidden ones so a tab persists after you switch away from it (tmux-window
-- semantics).
local function managed()
  local out = {}
  for slot, term in pairs(M.slots) do
    out[#out + 1] = { slot = slot, term = term }
  end
  table.sort(out, function(a, b)
    return a.slot < b.slot
  end)
  return out
end

local function slot_of_buf(buf)
  for _, e in ipairs(managed()) do
    if e.term.buf == buf then
      return e.slot, e.term
    end
  end
end

-- The slot/terminal currently shown in the side window (nil if none).
local function shown()
  local win = viewport()
  if not win then
    return nil
  end
  return slot_of_buf(vim.api.nvim_win_get_buf(win))
end

-- The slot/terminal a command should act on: the focused terminal if there is
-- one, else whatever occupies the side slot.
local function current_target()
  local slot, term = slot_of_buf(vim.api.nvim_get_current_buf())
  if slot then
    return slot, term
  end
  return shown()
end

-- The first surviving managed terminal (used to pick a replacement when the shown
-- one is killed/exits).
local function first_alive()
  for _, e in ipairs(managed()) do
    if vim.api.nvim_buf_is_valid(e.term.buf) then
      return e.slot, e.term
    end
  end
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

-- Resolve a terminal's shell pid and its controlling-terminal foreground
-- process group (tpgid, field 8 of /proc/<pid>/stat — the fields after the
-- "(comm)" are [1]=state [2]=ppid [3]=pgrp [4]=session [5]=tty_nr [6]=tpgid).
local function term_procs(term)
  if not term or not term.buf or not vim.api.nvim_buf_is_valid(term.buf) then
    return nil
  end
  local ok, jid = pcall(function()
    return vim.b[term.buf].terminal_job_id
  end)
  if not ok or type(jid) ~= "number" then
    return nil
  end
  local ok2, pid = pcall(vim.fn.jobpid, jid)
  if not ok2 or type(pid) ~= "number" then
    return nil
  end
  local stat = read_file("/proc/" .. pid .. "/stat")
  local tpgid
  if stat then
    local after = stat:match("%)%s*(.*)$")
    local fields = after and vim.split(after, " ", { trimempty = true }) or {}
    tpgid = tonumber(fields[6])
  end
  return pid, tpgid
end

-- Show the terminal in `slot`, creating it if the slot is empty. Opens the shared
-- side window only if it isn't already open; otherwise just swaps its buffer.
-- `opts.insert` (default true) controls whether we land in terminal mode.
function M.show(slot, opts)
  opts = opts or {}
  slot = clamp(slot)

  local win = viewport()
  local term = M.slots[slot]
  local have_buf = term and vim.api.nvim_buf_is_valid(term.buf)
  local buf = have_buf and term.buf or make_term_buf()

  if not win then
    -- No side window yet: open one carrying `buf` (edgy adopts it via FT).
    win = open_viewport(buf)
  else
    -- Reuse the side window: just swap its buffer. Same window, same size, so no
    -- resize -- which is the whole point (no SIGWINCH, no torn redraw).
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_current_win(win)

  if not have_buf then
    -- Re-assert the winbar synchronously before sizing the pty: an adopting
    -- layout manager (edgy) blanks it on the buffer swap/focus above, and if
    -- start_job sized the pty to that transiently-taller window, the deferred
    -- reassertion below would shrink the window by one row right after the
    -- TUI's first render -- an off-by-one repaint. The scheduled reassertion
    -- further down stays as a backstop for any later async re-blanking.
    apply_winbar(win)
    start_job(buf) -- buf is on screen now, so the pty sizes to the side window
    M.slots[slot] = { buf = buf }
  end

  M.current = slot
  vim.schedule(function()
    -- Re-assert the winbar: an adopting layout manager (edgy) blanks it
    -- synchronously on the buffer swap above, so restore it after that settles.
    -- Use viewport()'s result, not the `win` captured above: if the side window
    -- was closed and reopened within this tick, `win` is a stale (invalid)
    -- handle while viewport() is the live one.
    local vp = viewport()
    if vp then
      apply_winbar(vp)
    end
    pcall(vim.cmd, "redrawstatus")
    if opts.insert ~= false then
      vim.cmd("startinsert")
    end
  end)
end

-- <C-t>: toggle the side slot — close the window if open (buffers stay alive),
-- else re-open showing the current tab.
function M.toggle()
  local win = viewport()
  if win then
    pcall(vim.api.nvim_win_close, win, false)
    M.win = nil
  else
    M.show(M.current or BASE)
  end
end

-- <C-b>c: open the lowest unused slot.
function M.new()
  for i = BASE, MAX do
    if not M.slots[i] then
      M.show(i)
      return
    end
  end
  vim.notify("all " .. MAX .. " terminal slots in use", vim.log.levels.WARN)
end

-- <C-b>&: kill the current side terminal (tmux kill-window). Unlike <C-t>, which
-- only hides the window, this shuts the shell down. If the killed terminal is the
-- one on screen we bring another tab into the viewport BEFORE deleting its buffer
-- -- deleting the shown buffer would briefly leave a non-terminal buffer in the
-- window, which edgy would eject. TermClose (setup_exit) is a no-op afterward
-- since we've already freed the slot.
function M.kill()
  local slot, term = current_target()
  if not slot or not term then
    return
  end
  M.slots[slot] = nil
  local win = viewport()
  if win and vim.api.nvim_win_get_buf(win) == term.buf then
    local nxt = first_alive()
    if nxt then
      M.show(nxt)
    else
      pcall(vim.api.nvim_win_close, win, true)
      M.win = nil
    end
  end
  shutdown(term)
end

-- <C-b>.{1-9}: renumber the shown side terminal to `dest` (tmux move-window).
-- If `dest` is occupied the two terminals swap slots so neither is clobbered;
-- otherwise the source slot is freed. The shown window/buffer are untouched --
-- only the slot (hence tab label and switch key) changes.
function M.move(dest)
  dest = clamp(dest)
  local source, term = current_target()
  if not source or not term or source == dest then
    return
  end
  M.slots[source], M.slots[dest] = M.slots[dest], term
  M.current = dest
  vim.schedule(function()
    pcall(vim.cmd, "redrawtabline")
  end)
end

local function truncate(s, n)
  if vim.fn.strchars(s) > n then
    return vim.fn.strcharpart(s, 0, n - 1) .. "…"
  end
  return s
end

-- A tab's title: the OSC title the running program set (b:term_title — Claude
-- Code updates this live, including its input-needed marker), falling back to
-- the foreground process name from /proc, then "term".
local function label(slot, term)
  local name
  if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
    local ok, title = pcall(function()
      return vim.b[term.buf].term_title
    end)
    if ok and type(title) == "string" and title ~= "" then
      name = title
    end
  end
  if not name then
    local pid, tpgid = term_procs(term)
    if pid then
      local target = (tpgid and tpgid > 0) and tpgid or pid
      local comm = read_file("/proc/" .. target .. "/comm")
      name = comm and (comm:gsub("%s+$", "")) or nil
    end
  end
  return string.format(" %d:%s ", slot, truncate(name or "term", 24))
end

-- The tmux-style tab strip, as a window-local winbar on the side window. Because
-- it's the winbar of fishmonger's own window it spans exactly that window -- no
-- screen-column math, and no commandeering the global tabline. The active tab is
-- highlighted; the trailing TabLineFill extends to the window's right edge. Each
-- label is a mouse-click target routing to fishmonger_tab_click.
function M.winbar()
  local tabs = {}
  for _, e in ipairs(managed()) do
    local lbl = label(e.slot, e.term)
    local hl = (e.slot == M.current) and "%#TabLineSel#" or "%#TabLine#"
    tabs[#tabs + 1] = string.format("%%%d@v:lua.fishmonger_tab_click@%s%s%%X", e.slot, hl, lbl)
  end
  return table.concat(tabs) .. "%#TabLineFill#"
end

_G.fishmonger_winbar = M.winbar
_G.fishmonger_tab_click = function(slot)
  -- Defer so nvim's own mouse-click/window handling finishes before we juggle
  -- terminal windows (a synchronous show() here races it and scrambles the layout).
  vim.schedule(function()
    M.show(slot)
  end)
end

-- Merge caller options and install fishmonger's global autocmds. Idempotent.
-- The winbar itself is per-window (set in style_window), so there is no global
-- tabline to turn on: this only wires the repaint-on-title-change and the
-- width-follows-screen behaviour.
function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})

  local grp = vim.api.nvim_create_augroup("Fishmonger", { clear = true })
  -- term_title changes arrive via TermRequest (Claude Code updates it live,
  -- including its input-needed marker); repaint the winbar on those.
  vim.api.nvim_create_autocmd("TermRequest", {
    group = grp,
    callback = function()
      pcall(vim.cmd, "redrawstatus")
    end,
  })
  -- Re-evaluate a function width when the screen resizes so the side window keeps
  -- its share. winfixwidth pins it against incidental splits, not VimResized.
  vim.api.nvim_create_autocmd("VimResized", {
    group = grp,
    callback = function()
      local win = viewport()
      if win then
        pcall(vim.api.nvim_win_set_width, win, want_width())
      end
    end,
  })
end

-- Global toggle so <C-t> summons/hides the side terminal from anywhere.
-- Called once from terminal.lua.
function M.setup_keymaps()
  vim.keymap.set({ "n", "t" }, "<C-t>", M.toggle, { desc = "Toggle side terminal" })
  -- <C-b> as a single tmux-style prefix, bound globally in normal + terminal
  -- mode. A single complete mapping fires immediately, then getcharstr() blocks
  -- for the follow-up key. Separate <C-b>1.. maps instead race the mapping
  -- timeout in terminal mode -- a digit pressed a beat late leaks to the shell.
  -- Global so it works from the live terminal and the editor (to summon a tab
  -- when the panel is closed). In normal mode an unrecognised follow-up key
  -- falls through to the builtin <C-b> (page back) plus that key, so paging
  -- still works — just one keystroke later than stock.
  local function tab_prefix()
    local ok, key = pcall(vim.fn.getcharstr)
    if not ok or key == "" then
      return
    end
    if key:match("^[1-9]$") then
      M.show(tonumber(key))
    elseif key == "c" then
      M.new()
    elseif key == "&" then
      M.kill()
    elseif key == "." then
      -- tmux move-window: the next keystroke is the destination slot.
      local ok2, dest = pcall(vim.fn.getcharstr)
      if ok2 and dest:match("^[1-9]$") then
        M.move(tonumber(dest))
      end
    elseif vim.api.nvim_get_mode().mode:sub(1, 1) == "n" then
      -- Not one of ours: replay the raw <C-b> + key unmapped ("n") so the
      -- builtin scroll-back (and whatever the key does) still happens.
      local cb = vim.api.nvim_replace_termcodes("<C-b>", true, false, true)
      vim.api.nvim_feedkeys(cb .. key, "n", false)
    end
  end
  vim.keymap.set(
    { "n", "t" },
    "<C-b>",
    tab_prefix,
    { desc = "Terminal prefix (<C-b>N tab / <C-b>c new / <C-b>& kill / <C-b>. move)" }
  )
end

-- When a managed terminal's shell exits, free its slot and — if it was the one on
-- screen — swap another open tab into the shared window; if it was the last, the
-- side window is closed. Called once from terminal.lua. A kill via M.kill has
-- already freed the slot, so this is then a no-op for that buffer.
function M.setup_exit()
  vim.api.nvim_create_autocmd("TermClose", {
    group = vim.api.nvim_create_augroup("TermExit", { clear = true }),
    callback = function(args)
      local slot = slot_of_buf(args.buf)
      if not slot then
        return
      end
      M.slots[slot] = nil
      vim.schedule(function()
        local win = viewport()
        if win and vim.api.nvim_win_get_buf(win) == args.buf then
          local nxt = first_alive()
          if nxt then
            M.show(nxt)
          else
            pcall(vim.api.nvim_win_close, win, true)
            M.win = nil
          end
        end
        -- Clean up the dead buffer ("[Process exited]").
        if vim.api.nvim_buf_is_valid(args.buf) then
          pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
        end
      end)
    end,
  })
end

return M
