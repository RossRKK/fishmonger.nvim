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
--
-- All of that is PER NVIM TABPAGE. A tabpage is a workspace (one project), so it
-- gets its own side window and its own slots 1..9, spawned in that tabpage's cwd.
-- Sharing them would be actively wrong: nvim_win_is_valid is true for a window in
-- another tabpage, so a global viewport would make <C-t> in tab 2 focus tab 1's
-- terminal -- i.e. teleport you to the other project.

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
  -- Agent status tracking (lua/fishmonger/agent.lua): `{ dir = <status
  -- directory>, enabled = <bool> }`. Nil takes that module's defaults.
  agent = nil,
  -- How a tabpage's project is named in the agent view. Nil uses the basename
  -- of its cwd; a config that names workspaces itself passes its own.
  ---@type nil|fun(tab: integer): string
  project_name = nil,
}

-- Resolve the configured width to a column count.
local function want_width()
  local w = config.width
  return type(w) == "function" and w() or w
end

-- Per-tabpage state, keyed by tabpage handle:
--   current = slot currently shown
--   slots   = slot (1..9) -> { buf = <bufnr> }
--   win     = the tabpage's single side window (shared viewport), or nil when closed
local states = {}

-- This tabpage's state, created on first use. Entries for tabpages that have
-- since closed are dropped here as well as in the TabClosed handler, which only
-- runs while fishmonger is set up.
local function st(tab)
  for handle in pairs(states) do
    if not vim.api.nvim_tabpage_is_valid(handle) then
      states[handle] = nil
    end
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  states[tab] = states[tab] or { current = BASE, slots = {}, win = nil }
  return states[tab]
end

-- `current`, `slots` and `win` read through to the CURRENT tabpage's state, so
-- the module's public surface is unchanged from when there was only one. Reads
-- only: internals assign through st(), and nothing outside writes these.
setmetatable(M, {
  __index = function(_, key)
    if key == "current" or key == "slots" or key == "win" then
      return st()[key]
    end
  end,
})

-- The current tabpage's side window if it still exists, else nil (and forget the
-- stale handle). Windows never move between tabpages, so a handle stored here is
-- either this tabpage's or dead.
local function viewport()
  local state = st()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return state.win
  end
  state.win = nil
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
  st().win = win
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

-- This tabpage's side terminals as a slot-ordered list of { slot, term } pairs,
-- including hidden ones so a tab persists after you switch away from it
-- (tmux-window semantics).
local function managed(state)
  local out = {}
  for slot, term in pairs((state or st()).slots) do
    out[#out + 1] = { slot = slot, term = term }
  end
  table.sort(out, function(a, b)
    return a.slot < b.slot
  end)
  return out
end

local function slot_of_buf(buf, state)
  for _, e in ipairs(managed(state)) do
    if e.term.buf == buf then
      return e.slot, e.term
    end
  end
end

-- Locate `buf` in ANY tabpage's slots, returning its owning state, slot and term.
-- TermClose fires wherever the shell died, which needn't be the tabpage you're
-- looking at (a background build finishing in another project's terminal).
local function owner_of_buf(buf)
  for tab, state in pairs(states) do
    local slot, term = slot_of_buf(buf, state)
    if slot then
      return state, slot, term, tab
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
local function first_alive(state)
  for _, e in ipairs(managed(state)) do
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

-- The pid of the shell a terminal buffer is running. Shared with the agent
-- module, which matches a session's ancestor chain against it.
local function shell_pid(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local ok, jid = pcall(function()
    return vim.b[buf].terminal_job_id
  end)
  if not ok or type(jid) ~= "number" then
    return nil
  end
  local ok2, pid = pcall(vim.fn.jobpid, jid)
  return ok2 and type(pid) == "number" and pid or nil
end

-- Resolve a terminal's shell pid and its controlling-terminal foreground
-- process group (tpgid, field 8 of /proc/<pid>/stat — the fields after the
-- "(comm)" are [1]=state [2]=ppid [3]=pgrp [4]=session [5]=tty_nr [6]=tpgid).
local function term_procs(term)
  local pid = term and shell_pid(term.buf)
  if not pid then
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

-- The OSC title the program in `term` set (b:term_title), or nil.
local function term_title(term)
  if not (term and term.buf and vim.api.nvim_buf_is_valid(term.buf)) then
    return nil
  end
  local ok, title = pcall(function()
    return vim.b[term.buf].term_title
  end)
  if ok and type(title) == "string" and title ~= "" then
    return title
  end
end

-- The leading status glyph of a tab's title, if it has one. Claude Code
-- prefixes its OSC title with a single symbol (✳ while thinking, etc.) that
-- flips with its state; a multibyte first character is taken to be such an
-- icon, while a plain-ASCII title (a shell's "fish /home/…") yields none.
-- A helper for User FishmongerTabsChanged consumers; pure so the tests can
-- pin it.
function M.title_icon(title)
  local first = vim.fn.strcharpart(title or "", 0, 1)
  if first ~= "" and #first > 1 then
    return first
  end
end

local agent = require("fishmonger.agent")

--- The agent status of a terminal: the record the hook wrote, plus its `look`
--- (icon/hl/label/attention). Nil when nothing is reporting from that terminal.
---@param term table?
---@return table?
local function term_agent(term)
  if not (term and term.buf and vim.api.nvim_buf_is_valid(term.buf)) then
    return nil
  end
  local record = agent.for_buf(term.buf, shell_pid)
  if not record then
    return nil
  end
  return vim.tbl_extend("force", record, { look = agent.look(record.state) })
end

--- The status glyph for a terminal: the agent's reported state if one is
--- reporting, else the leading glyph of its OSC title. The fallback matters for
--- everything that isn't a hook-wired agent -- another agent CLI, a long build
--- that sets its own title -- which the tab strip showed before this module
--- existed and should keep showing.
---@param term table?
---@param title string?
---@return string? icon, string? hl
local function status_icon(term, title)
  local status = term_agent(term)
  if status and status.look then
    return status.look.icon, status.look.hl
  end
  return M.title_icon(title)
end

-- A title with its leading status glyph (and the space after it) removed, for
-- somewhere that renders the status itself. Titles without one are returned as
-- they are.
local function strip_icon(title)
  local icon = M.title_icon(title)
  if not icon then
    return title
  end
  return (title:sub(#icon + 1):gsub("^%s+", ""))
end

--- A tabpage's side terminals, in slot order, as
---   { slot = n, title = <b:term_title or nil>, icon = <status glyph or nil>,
---     hl = <highlight for icon>, agent = <status record or nil> }
--- Public so consumers can ask about a tabpage they aren't in --
--- FishmongerTabsChanged says which one changed, and answering "what is every
--- workspace's state" then needs a query, not just the event.
---
--- `icon` is what a tab label or an OS title wants: already resolved from the
--- agent status with the OSC-title glyph as fallback, so a consumer doesn't
--- reimplement that precedence. `agent` is there for the ones that want more
--- than a glyph (the agent view's state name and pending prompt).
---@param tab? integer tabpage handle (default: current)
---@return { slot: integer, title: string?, icon: string?, hl: string?, agent: table? }[]
function M.tabs(tab)
  local state = tab and states[tab] or (tab == nil and st())
  if not state then
    return {} -- a tabpage that has never opened a terminal
  end
  local out = {}
  for _, e in ipairs(managed(state)) do
    local title = term_title(e.term)
    local icon, hl = status_icon(e.term, title)
    out[#out + 1] = {
      slot = e.slot,
      title = title,
      icon = icon,
      hl = hl,
      agent = term_agent(e.term),
    }
  end
  return out
end

--- Every reporting agent across every tabpage, for the agent view (and anything
--- else that wants a fleet-wide answer rather than a per-tabpage one).
---
--- Entries are `{ tab, slot, project, title, state, look, detail, cwd, session,
--- current }`. `title` is the terminal's own OSC title -- what the agent calls
--- what it is doing, which is the only per-terminal identity there is once a
--- workspace has several agents in it. `tab`/`slot` are nil for a session
--- running somewhere fishmonger
--- doesn't manage -- a bare terminal, another nvim -- which is still worth
--- listing (it is still an agent waiting on you) but cannot be jumped to.
---@return table[]
function M.agents()
  local seen, out = {}, {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local state = states[tab]
    for _, e in ipairs(state and managed(state) or {}) do
      local status = term_agent(e.term)
      if status then
        seen[status.session] = true
        out[#out + 1] = {
          tab = tab,
          slot = e.slot,
          project = M.project_name(tab),
          -- Without its leading status glyph: the view draws the state itself,
          -- from a source that knows more than the glyph does, and two status
          -- marks per row that can disagree is worse than one.
          title = strip_icon(term_title(e.term)),
          state = status.state,
          look = status.look,
          detail = status.detail,
          cwd = status.cwd,
          session = status.session,
          current = tab == vim.api.nvim_get_current_tabpage() and e.slot == state.current,
        }
      end
    end
  end
  for _, record in ipairs(agent.all()) do
    if not seen[record.session] then
      out[#out + 1] = {
        project = vim.fn.fnamemodify(record.cwd or "", ":t"),
        state = record.state,
        look = agent.look(record.state),
        detail = record.detail,
        cwd = record.cwd,
        session = record.session,
      }
    end
  end
  -- Whoever is blocked comes first: the list exists to be acted on, and the
  -- entries that need acting on should not be hunted for. Ties keep a stable
  -- order (project, then slot) so the list doesn't reshuffle under the cursor.
  table.sort(out, function(a, b)
    local pa = (a.look and a.look.attention) and 0 or 1
    local pb = (b.look and b.look.attention) and 0 or 1
    if pa ~= pb then
      return pa < pb
    end
    if a.project ~= b.project then
      return (a.project or "") < (b.project or "")
    end
    return (a.slot or 0) < (b.slot or 0)
  end)
  return out
end

--- The display name of a tabpage's project: its tab-local cwd's basename.
--- Overridable via setup({ project_name = fn }) for a config that names
--- workspaces itself.
---@param tab integer
---@return string
function M.project_name(tab)
  if config.project_name then
    return config.project_name(tab)
  end
  return vim.fn.fnamemodify(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab)), ":t")
end

--- Focus an agent: switch to its tabpage and bring its terminal into the side
--- window. The one action the agent view needs, and the reason the view belongs
--- here rather than in a consumer -- crossing tabpages is fishmonger's business.
---@param entry table an entry from M.agents()
function M.focus(entry)
  if not (entry and entry.tab and vim.api.nvim_tabpage_is_valid(entry.tab)) then
    return false
  end
  vim.api.nvim_set_current_tabpage(entry.tab)
  M.show(entry.slot)
  return true
end

-- Announce a tabpage's tab set whenever it (or a tab's title) changes, as a
-- `User FishmongerTabsChanged` autocmd whose data is
--   { tab = <tabpage handle>,
--     tabs = { { slot = n, title = <b:term_title or nil> }, ... },  -- slot order
--     current = <shown slot> }
-- so personal config can compose on top (e.g. bubble the tabs' status glyphs
-- into 'titlestring', or onto the tabpage's label) without fishmonger hardcoding
-- any one policy.
--
-- `tab` matters because terminals in a BACKGROUND tabpage keep running and keep
-- updating their titles: an event is not necessarily about the workspace you are
-- looking at, and a consumer that assumed the current one would paint another
-- project's status onto this one.
local function emit_tabs_changed(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  if not states[tab] then
    return
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "FishmongerTabsChanged",
    data = { tab = tab, tabs = M.tabs(tab), current = states[tab].current },
  })
end

-- Forward declaration: refresh_os_title is defined further down (with the
-- title helpers) but called from show/toggle/kill/setup_exit above it — without
-- this, those compile as global lookups and crash on a nil value.
local refresh_os_title

-- Show the terminal in `slot`, creating it if the slot is empty. Opens the shared
-- side window only if it isn't already open; otherwise just swaps its buffer.
-- `opts.insert` (default true) controls whether we land in terminal mode.
function M.show(slot, opts)
  opts = opts or {}
  slot = clamp(slot)

  local state = st()
  local win = viewport()
  local term = state.slots[slot]
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
    state.slots[slot] = { buf = buf }
  end

  state.current = slot
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
    emit_tabs_changed()
    if opts.insert ~= false then
      vim.cmd("startinsert")
    end
  end)
end

-- <C-t>: toggle the side slot — close the window if open (buffers stay alive),
-- else re-open showing the current tab.
function M.toggle()
  local state = st()
  local win = viewport()
  if win then
    pcall(vim.api.nvim_win_close, win, false)
    state.win = nil
  else
    M.show(state.current or BASE)
  end
end

-- <C-b>c: open the lowest unused slot.
function M.new()
  local state = st()
  for i = BASE, MAX do
    if not state.slots[i] then
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
  local state = st()
  local slot, term = current_target()
  if not slot or not term then
    return
  end
  state.slots[slot] = nil
  local win = viewport()
  if win and vim.api.nvim_win_get_buf(win) == term.buf then
    local nxt = first_alive(state)
    if nxt then
      M.show(nxt)
    else
      pcall(vim.api.nvim_win_close, win, true)
      state.win = nil
    end
  end
  shutdown(term)
  emit_tabs_changed()
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
  local state = st()
  state.slots[source], state.slots[dest] = state.slots[dest], term
  state.current = dest
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
  local name = term_title(term)
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
    local hl = (e.slot == st().current) and "%#TabLineSel#" or "%#TabLine#"
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

  -- Agent statuses arrive from outside nvim entirely (a hook process writing a
  -- file), so they get their own watcher rather than an autocmd. A change is
  -- announced twice on purpose: `FishmongerAgentsChanged` for consumers that
  -- want the fleet-wide list, and the per-tabpage FishmongerTabsChanged that
  -- glyph consumers (tab labels, the OS title) already listen to -- their input
  -- changed even though no terminal did.
  agent.setup(config.agent, function()
    pcall(vim.cmd, "redrawstatus")
    vim.api.nvim_exec_autocmds("User", {
      pattern = "FishmongerAgentsChanged",
      data = { agents = M.agents() },
    })
    for tab in pairs(states) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        emit_tabs_changed(tab)
      end
    end
  end)
  -- term_title changes arrive via TermRequest (Claude Code updates it live,
  -- including its input-needed marker); repaint the winbar and re-bubble the
  -- OS title on those. Defer the bubble: b:term_title is applied after the
  -- TermRequest callback runs, so reading it synchronously sees the old value.
  vim.api.nvim_create_autocmd("TermRequest", {
    group = grp,
    callback = function(args)
      pcall(vim.cmd, "redrawstatus")
      -- Emit for the tabpage owning the buffer whose title changed, not the
      -- current one: a shell in a background workspace still sets titles.
      local _, _, _, tab = owner_of_buf(args.buf)
      vim.schedule(function()
        emit_tabs_changed(tab)
      end)
    end,
  })
  -- Re-evaluate a function width when the screen resizes so the side window keeps
  -- its share. winfixwidth pins it against incidental splits, not VimResized.
  -- Every tabpage's side window is resized, not just the visible one: an unseen
  -- tabpage's window keeps its old width otherwise, and you'd only find out on
  -- switching to it.
  vim.api.nvim_create_autocmd("VimResized", {
    group = grp,
    callback = function()
      local width = want_width()
      for _, state in pairs(states) do
        if state.win and vim.api.nvim_win_is_valid(state.win) then
          pcall(vim.api.nvim_win_set_width, state.win, width)
        end
      end
    end,
  })
  -- Closing a tabpage closes its windows but leaves its terminal buffers alive --
  -- and with the tabpage gone there is no longer any way to reach them. Shut the
  -- shells down with the workspace rather than leaking orphaned ptys.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = grp,
    callback = function()
      local doomed = {}
      for tab, state in pairs(states) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          vim.list_extend(doomed, managed(state))
          states[tab] = nil -- drop before shutdown: deleting the buffers fires
        end -- TermClose, which must not find a dead tabpage's state
      end
      for _, e in ipairs(doomed) do
        shutdown(e.term)
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
    elseif key == "a" then
      -- The agent view (lua/fishmonger/view.lua): every agent in every
      -- workspace, blocked ones first. On the prefix rather than its own ctrl
      -- key because the moment you want it is while sitting in a terminal
      -- waiting on an agent, where the free keys are the ones already routed
      -- through here.
      require("fishmonger.view").popup()
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
    { desc = "Terminal prefix (<C-b>N tab / c new / & kill / . move / a agents)" }
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
      local state, slot, _, tab = owner_of_buf(args.buf)
      if not state or not slot then
        return
      end
      state.slots[slot] = nil
      agent.forget(args.buf) -- its cached shell pid is about to be reused by someone else
      vim.schedule(function()
        local win = state.win
        if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == args.buf then
          local nxt, term = first_alive(state)
          if not nxt then
            pcall(vim.api.nvim_win_close, win, true)
            state.win = nil
          elseif tab == vim.api.nvim_get_current_tabpage() then
            M.show(nxt)
          else
            -- Another tabpage's terminal exited. Its replacement buffer already
            -- exists, so swap it in without focusing -- M.show would drag us into
            -- that tabpage (it sets the current window).
            vim.api.nvim_win_set_buf(win, term.buf)
            state.current = nxt
          end
        end
        -- Clean up the dead buffer ("[Process exited]").
        if vim.api.nvim_buf_is_valid(args.buf) then
          pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
        end
        emit_tabs_changed(tab)
      end)
    end,
  })
end

return M
