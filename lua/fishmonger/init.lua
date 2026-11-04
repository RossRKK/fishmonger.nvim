-- fishmonger.nvim — tmux-style tab switching for the vertical side terminal.
--
-- One terminal is visible in the side slot at a time; the others stay alive but
-- hidden. Switching is done from terminal-normal mode (enter it with <C-\><C-n>,
-- or the <C-n> map): <C-b>{1-9} switches to (creating on demand) a terminal,
-- <C-b>c opens the next free slot, <C-b>& kills the current terminal (tmux
-- kill-window), and <C-b>.{1-9} renumbers the current terminal to another slot
-- (tmux move-window), and <C-b>m{1-9} carries the current terminal over to
-- workspace N (tmux move-window -t other-session; a config numbers its
-- workspaces via setup({ workspace }), else N is the tabpage number). <C-b>" and
-- <C-b>% split a new shell into a pane, <C-b>x kills a pane, and <C-b> arrows
-- move between panes. <C-t> toggles the side slot.
--
-- Model (the tmux-pane model): the side panel (M.win) lives in the right slot,
-- and <C-b>t opens a terminal in any other window too. Every terminal window
-- shows one of the tabpage's shared tabs; <C-b> acts on the current one, or from
-- the editor on the one used last. Switching tabs swaps which terminal buffer a
-- window shows -- nvim_win_set_buf, never close+reopen. Its size therefore never
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
  -- Which tabpage is workspace N, for <C-b>mN. Nil means the Nth tabpage; a
  -- config that gives its workspaces stable numbers (surviving a close to
  -- their left) passes its own lookup, returning nil for a number not in use.
  ---@type nil|fun(n: integer): integer?
  workspace = nil,
}

-- Resolve the configured width to a column count.
local function want_width()
  local w = config.width
  return type(w) == "function" and w() or w
end

-- Per-tabpage state, keyed by tabpage handle:
--   slots  = slot (1..9) -> { buf = <bufnr>, chan = <job channel> }
--   recent = terms, most recently shown first; the current slot is the first
--            one still in `slots`, so a renumber or a kill needs no bookkeeping
local states = {}

-- Window variable marking the side panel. A layout manager (edgy) filters on it
-- to dock that one window, leaving terminal windows elsewhere alone.
local SIDE = "fishmonger_side"

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
  states[tab] = states[tab] or { slots = {}, recent = {} }
  return states[tab]
end

local function slot_of_term(state, term)
  for slot, t in pairs(state.slots) do
    if t == term then
      return slot
    end
  end
end

-- Record `term` as the most recently shown, dropping terms that have left.
local function touch(state, term)
  local recent = { term }
  for _, t in ipairs(state.recent) do
    if t ~= term and slot_of_term(state, t) then
      recent[#recent + 1] = t
    end
  end
  state.recent = recent
end

-- The slot of the most recently shown terminal still in this tabpage.
local function current_slot(state)
  for _, term in ipairs(state.recent) do
    local slot = slot_of_term(state, term)
    if slot then
      return slot
    end
  end
end

-- A tabpage's side windows: the panel and any panes split from it.
local function side_windows(tab)
  return vim.tbl_filter(function(win)
    return vim.w[win][SIDE]
  end, vim.api.nvim_tabpage_list_wins(tab))
end

-- A tabpage's side panel, or nil when it is closed.
local function side_of(tab)
  return side_windows(tab)[1]
end

local function viewport()
  return side_of(vim.api.nvim_get_current_tabpage())
end

-- `current`, `slots` and `win` read through to the CURRENT tabpage, so the
-- module's public surface is unchanged from when there was only one. Reads only.
setmetatable(M, {
  __index = function(_, key)
    if key == "current" then
      return current_slot(st())
    elseif key == "slots" then
      return st().slots
    elseif key == "win" then
      return viewport()
    end
  end,
})

-- The tab strip is a window-local winbar (see M.winbar). It's set on the side
-- window and must stay set: a full-screen TUI never repaints into a changed
-- geometry because the winbar is constant (present before any pty job starts,
-- never toggled). It IS re-asserted rather than "set once", because an adopting
-- layout manager (edgy) blanks a panel's winbar synchronously on every buffer
-- swap; apply_winbar re-establishes it after the swap (see M.show). Re-asserting
-- the same value is inert for the pty -- it changes no window geometry.
local function apply_winbar(win)
  vim.api.nvim_set_option_value("winbar", "%!v:lua.fishmonger_winbar()", { scope = "local", win = win })
end

-- Apply the terminal look to a window showing a terminal. :setlocal, so it goes
-- with the terminal: an editor window <C-o>'d back to its file gets its own
-- options back. Re-applied on every swap, which is inert when nothing changes.
local function style_window(win)
  for name, value in pairs({ number = false, relativenumber = false, signcolumn = "no", cursorline = false }) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
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
  vim.w[win][SIDE] = true -- before the buffer, which is what edgy reacts to
  vim.api.nvim_win_set_buf(win, buf)
  style_window(win)
  pcall(vim.api.nvim_win_set_width, win, want_width())
  vim.wo[win].winfixwidth = true
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
-- current window. Re-assert the filetype (jobstart can reset it). <C-k> moves
-- up only to a pane above; with none, the program (Claude Code's kill-line)
-- gets it. Returns the job's channel, which M.send writes to.
local function start_job(buf)
  local chan = vim.fn.jobstart(config.shell, { term = true })
  vim.bo[buf].filetype = config.filetype
  vim.keymap.set("t", "<C-k>", function()
    if vim.fn.winnr("k") ~= vim.fn.winnr() then
      return "<Cmd>lua require('fishmonger').select('k')<CR>"
    end
    return "<C-k>"
  end, { buffer = buf, expr = true })
  return chan
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

-- The windows of `tab` showing one of its terminals, in layout order.
local function terminal_windows(state, tab)
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if slot_of_buf(vim.api.nvim_win_get_buf(win), state) then
      out[#out + 1] = win
    end
  end
  return out
end

local function window_showing(tab, buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

-- The terminal window <C-b> acts on: the current window if it is one, else the
-- one showing the most recently used tab, else the side panel.
local function target_window(state, tab)
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_tabpage(cur) == tab and slot_of_buf(vim.api.nvim_win_get_buf(cur), state) then
    return cur
  end
  local slot = current_slot(state)
  return slot and window_showing(tab, state.slots[slot].buf) or side_of(tab) or terminal_windows(state, tab)[1]
end

-- The slot/terminal a command should act on: the one in the target window.
local function current_target()
  local tab = vim.api.nvim_get_current_tabpage()
  local state = st(tab)
  local win = target_window(state, tab)
  if win then
    return slot_of_buf(vim.api.nvim_win_get_buf(win), state)
  end
end

-- The most recently used terminal that no window of `tab` shows, falling back
-- to slot order for any never shown.
local function hidden_term(state, tab)
  local on_screen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    on_screen[vim.api.nvim_win_get_buf(win)] = true
  end
  for _, term in ipairs(state.recent) do
    if slot_of_term(state, term) and not on_screen[term.buf] then
      return term
    end
  end
  for _, e in ipairs(managed(state)) do
    if not on_screen[e.term.buf] then
      return e.term
    end
  end
end

-- The lowest slot with no terminal in it, or nil when all nine are taken.
local function free_slot(state)
  for i = BASE, MAX do
    if not state.slots[i] then
      return i
    end
  end
end

-- The slot a newly opened terminal window shows: the most recent hidden tab,
-- else the lowest free slot. Nil when all nine are on screen.
local function hidden_slot(state, tab)
  local term = hidden_term(state, tab)
  if term then
    return slot_of_term(state, term)
  end
  return free_slot(state)
end

-- A terminal window with no terminal left to show goes back to the buffer it
-- had before; the side panel never had one, so it closes.
local function fall_back(win, state)
  local alt = vim.api.nvim_win_call(win, function()
    return vim.fn.bufnr("#")
  end)
  if not vim.w[win][SIDE] and vim.api.nvim_buf_is_valid(alt) and not slot_of_buf(alt, state) then
    vim.api.nvim_win_set_buf(win, alt)
  elseif not pcall(vim.api.nvim_win_close, win, true) then
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
  end
end

-- Every window of `tab` showing `buf`, which has just left the tabpage's slots,
-- takes another hidden terminal (tmux kill-window), or falls back without one.
-- Only the current window's replacement becomes the current tab, so a terminal
-- dying elsewhere doesn't move where <C-b> goes.
local function vacate(state, tab, buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local nxt = hidden_term(state, tab)
      if not nxt then
        fall_back(win, state)
      else
        vim.api.nvim_win_set_buf(win, nxt.buf)
        style_window(win)
        if win == vim.api.nvim_get_current_win() then
          touch(state, nxt)
          vim.schedule(function()
            vim.cmd("startinsert")
          end)
        end
      end
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

-- Claude Code's own title glyphs: ✳ when waiting for input, the rest frames of
-- its thinking spinner. A claude with no hook-reported status yet (a fresh
-- instance hasn't run any hook) would otherwise leak these through the fallback
-- below and clash with the icons every reporting agent gets; they carry no
-- information the agent status won't report better, so they are dropped.
local claude_glyphs = {
  ["✳"] = true,
  ["✢"] = true,
  ["✶"] = true,
  ["✻"] = true,
  ["✽"] = true,
  ["·"] = true,
}

--- The status glyph for a terminal: the agent's reported state if one is
--- reporting, else the leading glyph of its OSC title. A glyph recognised as
--- Claude Code's own is dropped instead, so a claude that hasn't reported yet
--- shows no icon rather than a stray one. The raw fallback matters for
--- everything else that isn't a hook-wired agent -- another agent CLI, a long
--- build that sets its own title -- which the tab strip showed before this
--- module existed and should keep showing.
---@param term table?
---@param title string?
---@return string? icon, string? hl
local function status_icon(term, title)
  local status = term_agent(term)
  if status and status.look then
    return status.look.icon, status.look.hl
  end
  local icon = M.title_icon(title)
  if icon and claude_glyphs[icon] then
    return nil
  end
  return icon
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
          current = tab == vim.api.nvim_get_current_tabpage() and e.slot == current_slot(state),
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

--- Re-read the agent status files right now and repaint everything that shows
--- them (statusline, tab labels, FishmongerAgentsChanged consumers). The fs
--- watcher keeps the steady state current; this is the on-demand path for
--- moments the list is about to be looked at -- a greeter coming back into
--- view, regaining focus -- where a missed event must not show stale state.
function M.refresh_agents()
  agent.refresh()
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
    data = { tab = tab, tabs = M.tabs(tab), current = current_slot(states[tab]) },
  })
end

-- Forward declaration: refresh_os_title is defined further down (with the
-- title helpers) but called from show/toggle/kill/setup_exit above it — without
-- this, those compile as global lookups and crash on a nil value.
local refresh_os_title

-- Show the terminal in `slot` in `win`, creating it if the slot is empty; nil
-- opens the side panel for it. A tab already on screen in another window trades
-- places with what `win` shows: a terminal in two windows would have one pty
-- sized for both. `opts.insert` (default true) lands in terminal mode.
local function show_in(win, slot, opts)
  opts = opts or {}
  slot = clamp(slot)

  local tab = vim.api.nvim_get_current_tabpage()
  local state = st(tab)
  local term = state.slots[slot]
  local have_buf = term and vim.api.nvim_buf_is_valid(term.buf)
  local buf = have_buf and term.buf or make_term_buf()

  if not win then
    win = open_viewport(buf)
  else
    -- Same window, same size: a plain tab switch sends the pty no SIGWINCH.
    local elsewhere = have_buf and window_showing(tab, buf)
    local _, mine = slot_of_buf(vim.api.nvim_win_get_buf(win), state)
    vim.api.nvim_win_set_buf(win, buf)
    if elsewhere and elsewhere ~= win and mine then
      vim.api.nvim_win_set_buf(elsewhere, mine.buf)
      style_window(elsewhere)
    end
  end
  style_window(win)
  vim.api.nvim_set_current_win(win)

  if not have_buf then
    -- buf is on screen now, so the pty sizes to this window
    state.slots[slot] = { buf = buf, chan = start_job(buf) }
  end

  touch(state, state.slots[slot])
  vim.schedule(function()
    -- Re-assert the winbars: an adopting layout manager (edgy) blanks them
    -- synchronously on the buffer swap above, so restore them after that settles.
    if vim.api.nvim_tabpage_is_valid(tab) then
      for _, w in ipairs(terminal_windows(state, tab)) do
        apply_winbar(w)
      end
    end
    pcall(vim.cmd, "redrawstatus!")
    emit_tabs_changed()
    if opts.insert ~= false then
      vim.cmd("startinsert")
    end
  end)
end

-- Show the terminal in `slot` in the target window (see target_window),
-- opening the side panel when no terminal window is open.
function M.show(slot, opts)
  local tab = vim.api.nvim_get_current_tabpage()
  show_in(target_window(st(tab), tab), slot, opts)
end

-- Type `text` into the current side terminal (the one <C-t> would show) and
-- land there in terminal mode, WITHOUT a trailing newline: the text is a start
-- on the prompt, not a submitted command, so you finish the line yourself -- a
-- `path:line` reference followed by your comment to the agent, say. Refuses
-- rather than spawning a shell to receive it, since text typed into a terminal
-- that has only just started races the shell's own startup.
function M.send(text)
  local state = st()
  local slot = current_slot(state)
  local term = slot and state.slots[slot]
  if not (term and term.chan and vim.api.nvim_buf_is_valid(term.buf)) then
    vim.notify("no side terminal to send to", vim.log.levels.WARN)
    return false
  end
  M.show(slot)
  vim.api.nvim_chan_send(term.chan, text)
  return true
end

-- <C-t>: toggle the side slot — close its windows if open (buffers stay alive),
-- else re-open showing the current tab.
function M.toggle()
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = side_windows(tab)
  if #wins > 0 then
    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_win_close, win, false)
    end
    return
  end
  local slot = hidden_slot(st(tab), tab)
  if slot then
    show_in(nil, slot)
  end
end

-- <C-b>t: a terminal in the current window, the way :edit opens a file there
-- (<C-o> goes back). It shows the most recent tab not already on screen.
function M.here()
  local tab = vim.api.nvim_get_current_tabpage()
  local state = st(tab)
  local win = vim.api.nvim_get_current_win()
  if slot_of_buf(vim.api.nvim_win_get_buf(win), state) then
    return
  end
  local slot = hidden_slot(state, tab)
  if not slot then
    vim.notify("all " .. MAX .. " terminals are on screen", vim.log.levels.WARN)
    return
  end
  show_in(win, slot)
end

-- <C-b>o: focus the next terminal window (tmux select-pane -t :.+).
function M.cycle()
  local tab = vim.api.nvim_get_current_tabpage()
  local state = st(tab)
  local wins = terminal_windows(state, tab)
  local from = target_window(state, tab)
  for i, win in ipairs(wins) do
    if win == from then
      local nxt = wins[i % #wins + 1]
      vim.api.nvim_set_current_win(nxt)
      touch(state, select(2, slot_of_buf(vim.api.nvim_win_get_buf(nxt), state)))
      pcall(vim.cmd, "redrawstatus!")
      vim.cmd("startinsert")
      return
    end
  end
end

-- <C-b>" / <C-b>%: tmux split-window -- split the target terminal window and
-- start a new shell in the new pane. A pane split from the side panel is a side
-- window too, so a layout manager docks it alongside the panel.
---@param direction "below"|"right"
function M.split(direction)
  local tab = vim.api.nvim_get_current_tabpage()
  local state = st(tab)
  local from = target_window(state, tab)
  local slot = free_slot(state)
  if not from then
    return
  elseif not slot then
    vim.notify("all " .. MAX .. " terminal slots in use", vim.log.levels.WARN)
    return
  end
  -- Open on a placeholder with autocmds off: a layout manager places a window
  -- when a buffer enters it, by which point the side mark must be there.
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(placeholder, false, { split = direction, win = from, noautocmd = true })
  vim.w[win][SIDE] = vim.w[from][SIDE]
  show_in(win, slot)
end

local follow_file -- defined after its caller

-- A background task's output in a pane under `term_win`, or the pane already
-- showing it. The file is drawn into a process-less terminal (nvim_open_term),
-- so its colours render while the pane stays an ordinary buffer: vim motions,
-- search and yank, no pager. It follows while the cursor is on the last line,
-- like any terminal. Not a tab: q closes it. The terminal filetype docks it
-- with its terminal.
---@param path string
---@param term_win integer
function M.open_output(path, term_win)
  local tab = vim.api.nvim_win_get_tabpage(term_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].fishmonger_output == path then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(placeholder, false, { split = "below", win = term_win, noautocmd = true })
  vim.w[win][SIDE] = vim.w[term_win][SIDE]
  local buf = make_term_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].fishmonger_output = path
  vim.api.nvim_win_set_buf(win, buf)
  for name, value in pairs({ number = false, relativenumber = false, signcolumn = "no" }) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  local chan = vim.api.nvim_open_term(buf, {})
  vim.bo[buf].filetype = config.filetype
  local watcher = follow_file(path, function(bytes)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_chan_send(chan, bytes)
    end
  end)
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = watcher.stop })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, desc = "Close the task output" })
  vim.api.nvim_set_current_win(win)
  vim.cmd("normal! G")
end

-- Hand `on_bytes` the end of the file at `path` (the last few MB: a terminal
-- keeps only `scrollback` lines anyway), then whatever is appended to it.
-- Returns `{ stop = fn }`.
local OUTPUT_TAIL = 4 * 1024 * 1024
function follow_file(path, on_bytes)
  local offset = math.max(0, (vim.uv.fs_stat(path) or { size = 0 }).size - OUTPUT_TAIL)
  local function read_new()
    local stat = vim.uv.fs_stat(path)
    if not stat then
      return
    end
    -- Truncated (a rerun into the same file): start over from the top.
    offset = stat.size < offset and 0 or offset
    if stat.size == offset then
      return
    end
    local fd = vim.uv.fs_open(path, "r", 0)
    if fd then
      local bytes = vim.uv.fs_read(fd, stat.size - offset, offset) or ""
      vim.uv.fs_close(fd)
      offset = offset + #bytes
      on_bytes(bytes)
    end
  end
  read_new()
  local event = vim.uv.new_fs_event()
  event:start(path, {}, vim.schedule_wrap(read_new))
  return {
    stop = function()
      if not event:is_closing() then
        event:stop()
        event:close()
      end
    end,
  }
end

-- <C-b>x: tmux kill-pane -- shut down the target terminal's shell and close its
-- window. The last window can't close, so it takes another tab as after <C-b>&.
function M.kill_pane()
  local tab = vim.api.nvim_get_current_tabpage()
  local state = st(tab)
  local win = target_window(state, tab)
  if not win then
    return
  end
  local slot, term = slot_of_buf(vim.api.nvim_win_get_buf(win), state)
  if not slot then
    return
  end
  state.slots[slot] = nil
  if not pcall(vim.api.nvim_win_close, win, true) then
    vacate(state, tab, term.buf)
  end
  shutdown(term)
  emit_tabs_changed()
end

-- <C-b> arrow: tmux select-pane, reachable from a terminal whose program keeps
-- the ctrl keys (the side terminal passes <C-k> through).
---@param direction "h"|"j"|"k"|"l"
function M.select(direction)
  vim.cmd("wincmd " .. direction)
  local state = st()
  local _, term = slot_of_buf(vim.api.nvim_get_current_buf(), state)
  if term then
    touch(state, term)
    pcall(vim.cmd, "redrawstatus!")
    vim.cmd("startinsert")
  end
end

-- <C-b>c: open the lowest unused slot.
function M.new()
  local slot = free_slot(st())
  if slot then
    M.show(slot)
    return
  end
  vim.notify("all " .. MAX .. " terminal slots in use", vim.log.levels.WARN)
end

-- Zoomed windows, keyed by handle: the placeholder holding the window's place
-- in the layout while it floats, the sizes to put back, and its own winhighlight.
local zooms = {}

-- The editor minus the tabline and statusline/cmdline; zindex under the default
-- 50 so popups (lazygit, the agent view) still land on top.
local function zoom_config()
  local tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local top = tabline and 1 or 0
  local bottom = vim.o.cmdheight + (vim.o.laststatus > 0 and 1 or 0)
  return {
    relative = "editor",
    row = top,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines - top - bottom,
    zindex = 10,
  }
end

-- Float the window itself rather than open a second one on its buffer: it keeps
-- its handle, buffer swaps and winbar, and a terminal keeps a single pty size.
local function zoom(win)
  local sizes = vim.fn.winrestcmd()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  zooms[win] = {
    placeholder = vim.api.nvim_open_win(buf, false, { split = "right", win = win }),
    sizes = sizes,
    winhighlight = vim.wo[win].winhighlight,
  }
  vim.api.nvim_win_set_config(win, zoom_config())
  vim.wo[win].winhighlight = "NormalFloat:Normal"
end

local function unzoom(win)
  local z = zooms[win]
  zooms[win] = nil
  if vim.api.nvim_win_is_valid(z.placeholder) then
    vim.api.nvim_win_set_config(win, { split = "left", win = z.placeholder })
    vim.api.nvim_win_close(z.placeholder, true)
  else
    vim.api.nvim_win_set_config(win, { split = "right", win = -1 }) -- someone closed it
  end
  vim.cmd(z.sizes)
  vim.wo[win].winhighlight = z.winhighlight
end

-- <C-b>z: tmux zoom -- the current window fills the screen; again puts it back.
-- Entering another window also puts it back (see setup).
function M.zoom()
  local win = vim.api.nvim_get_current_win()
  if zooms[win] then
    unzoom(win)
  elseif vim.api.nvim_win_get_config(win).relative == "" then
    zoom(win)
  end
  vim.api.nvim_set_current_win(win)
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
  vacate(state, vim.api.nvim_get_current_tabpage(), term.buf)
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
  vim.schedule(function()
    pcall(vim.cmd, "redrawtabline")
  end)
end

-- <C-b>m: carry the current side terminal into another tabpage (tmux
-- move-window -t <session>). The live buffer is what moves -- the shell, its
-- job and its scrollback are untouched -- so a Claude Code conversation that
-- has wandered into another worktree can be filed under that worktree's
-- workspace and reviewed from there without switching tabpages every time.
--
-- The process itself does NOT follow: its cwd stays wherever it was launched,
-- and fishmonger makes no attempt to tell it otherwise. The terminal takes the
-- lowest free slot in `dest` (never clobbering one there), the source viewport
-- is repaired exactly as after a kill, and we follow the terminal so it lands
-- on screen. The side windows share one width, so the pty sees no resize.
--
-- `dest` is a tabpage HANDLE; the keymap goes through M.transfer_pick.
function M.transfer(dest)
  if not (dest and vim.api.nvim_tabpage_is_valid(dest)) then
    return false
  end
  local source_tab = vim.api.nvim_get_current_tabpage()
  if dest == source_tab then
    return false
  end
  local source = st()
  local slot, term = current_target()
  if not slot or not term then
    return false
  end

  local target = st(dest)
  local free = free_slot(target)
  if not free then
    vim.notify("all " .. MAX .. " terminal slots in use there", vim.log.levels.WARN)
    return false
  end

  -- Detach from the source first: if it is the one on screen, surface another
  -- tab (or close the panel) BEFORE the buffer leaves, as M.kill does, so the
  -- window never shows a non-terminal buffer for an adopting layout manager to
  -- eject.
  source.slots[slot] = nil
  vacate(source, source_tab, term.buf)
  emit_tabs_changed(source_tab)

  target.slots[free] = term
  vim.api.nvim_set_current_tabpage(dest)
  M.show(free) -- opens dest's panel if it was closed; else swaps the buffer in
  return true
end

-- <C-b>mN: M.transfer to workspace N -- config.workspace's numbering, else the
-- Nth tabpage. Says so rather than doing nothing when there is no workspace N,
-- and is a quiet no-op for the workspace you are already in.
function M.transfer_to(n)
  local dest
  if config.workspace then
    dest = config.workspace(n)
  else
    dest = vim.api.nvim_list_tabpages()[n]
  end
  if not (dest and vim.api.nvim_tabpage_is_valid(dest)) then
    vim.notify("no workspace " .. n, vim.log.levels.WARN)
    return false
  end
  return M.transfer(dest)
end

-- Choose the destination tabpage for M.transfer by project name
-- (M.project_name, so a config that names workspaces by repo + worktree gets
-- those names). The current tabpage is left out -- there is nowhere to move
-- within it -- and with no other tabpage at all we say so instead of opening
-- an empty chooser. Bails early if nothing is open to move.
function M.transfer_pick()
  local slot = current_target()
  if not slot then
    return
  end
  local current = vim.api.nvim_get_current_tabpage()
  local choices = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= current then
      choices[#choices + 1] = { tab = tab, name = M.project_name(tab) }
    end
  end
  if #choices == 0 then
    vim.notify("no other workspace to move the terminal to", vim.log.levels.WARN)
    return
  end
  vim.ui.select(choices, {
    prompt = "Move terminal to workspace",
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if choice then
      M.transfer(choice.tab)
    end
  end)
end

local function truncate(s, n)
  if vim.fn.strchars(s) > n then
    return vim.fn.strcharpart(s, 0, n - 1) .. "…"
  end
  return s
end

-- A tab's title text: the OSC title the running program set (b:term_title —
-- Claude Code updates this live), falling back to the foreground process name
-- from /proc, then "term". WITHOUT its leading status glyph: the strip renders
-- the status itself (see M.winbar), so the raw glyph in the title would double
-- it. Escaped because it lands in a winbar %-expression verbatim.
local function tab_name(term)
  local name = term_title(term)
  if not name then
    local pid, tpgid = term_procs(term)
    if pid then
      local target = (tpgid and tpgid > 0) and tpgid or pid
      local comm = read_file("/proc/" .. target .. "/comm")
      name = comm and (comm:gsub("%s+$", "")) or nil
    end
  end
  return (truncate(strip_icon(name or "term"), 24):gsub("%%", "%%%%"))
end

-- The highlight group for a status icon on the tab strip: the state's colour
-- (its look hl, e.g. DiagnosticWarn) over the tab's own background, which
-- differs between the active tab and the rest. Re-derived on every repaint
-- rather than cached, so it follows colorscheme changes for free.
local function icon_hl(hl, base)
  local name = "Fishmonger" .. base .. hl:gsub("%W", "")
  vim.api.nvim_set_hl(0, name, {
    fg = vim.api.nvim_get_hl(0, { name = hl, link = false }).fg,
    bg = vim.api.nvim_get_hl(0, { name = base, link = false }).bg,
  })
  return name
end

-- The tmux-style tab strip, as a window-local winbar on each terminal window.
-- Because it's that window's winbar it spans exactly that window -- no
-- screen-column math, and no commandeering the global tabline. The window's own
-- tab is highlighted (dimmer when <C-b> targets another window), tabs on screen
-- in another window are marked, and the trailing TabLineFill extends to the
-- window's right edge. Each label is a mouse-click target routing to
-- fishmonger_tab_click.
--
-- Each tab shows its terminal's status icon in that state's colour -- the same
-- icon-and-highlight the agent view resolves (agent state first, OSC-title
-- glyph as fallback). A terminal with no status to show (a plain shell) gets no
-- icon at all rather than a placeholder.
function M.winbar()
  local win = vim.g.statusline_winid
  if not (win and vim.api.nvim_win_is_valid(win)) then
    win = vim.api.nvim_get_current_win()
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local state = st(tab)
  local own = vim.api.nvim_win_get_buf(win)
  local own_hl = target_window(state, tab) == win and "TabLineSel" or "FishmongerTabSelNC"
  local tabs = {}
  for _, e in ipairs(managed(state)) do
    local base = "TabLine"
    if e.term.buf == own then
      base = own_hl
    elseif window_showing(tab, e.term.buf) then
      base = "FishmongerTabElsewhere"
    end
    local icon, hl = status_icon(e.term, term_title(e.term))
    local status = ""
    if icon and hl then
      status = ("%%#%s#%s%%#%s# "):format(icon_hl(hl, base), icon, base)
    elseif icon then
      status = icon .. " "
    end
    local lbl = (" %d:%s%s "):format(e.slot, status, tab_name(e.term))
    tabs[#tabs + 1] = ("%%%d@v:lua.fishmonger_tab_click@%%#%s#%s%%X"):format(e.slot, base, lbl)
  end
  return table.concat(tabs) .. "%#TabLineFill#"
end

-- Overridable defaults (a colorscheme or config setting them wins).
local function default_highlights()
  vim.api.nvim_set_hl(0, "FishmongerTabSelNC", { link = "StatusLineNC", default = true })
  vim.api.nvim_set_hl(0, "FishmongerTabElsewhere", { link = "TabLineFill", default = true })
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

  default_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = grp, callback = default_highlights })

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
  end, function()
    -- A spinner frame advance is not a state change: repaint the strips that
    -- draw the icon (the winbar, and the tab labels via FishmongerTabsChanged)
    -- without announcing FishmongerAgentsChanged -- consumers that re-render a
    -- whole view on that would fight the cursor several times a second for a
    -- frame nobody is blocked on. Consumers that can repaint cheaply (or know
    -- when it's safe) get their own event instead.
    pcall(vim.cmd, "redrawstatus")
    vim.api.nvim_exec_autocmds("User", { pattern = "FishmongerAgentsTick" })
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
      for tab in pairs(states) do
        local win = vim.api.nvim_tabpage_is_valid(tab) and side_of(tab)
        if win and not zooms[win] then
          pcall(vim.api.nvim_win_set_width, win, width)
        end
      end
      for win in pairs(zooms) do
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_config(win, zoom_config())
        end
      end
    end,
  })
  -- Entering a terminal window makes its tab the current one, which is what
  -- sends <C-b> from the editor back to the window you were last in.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = grp,
    callback = function()
      local state = states[vim.api.nvim_get_current_tabpage()]
      local _, term = state and slot_of_buf(vim.api.nvim_get_current_buf(), state)
      if term then
        touch(state, term)
      end
      pcall(vim.cmd, "redrawstatus!")
    end,
  })
  -- tmux unzooms on selecting another pane; here that's entering another split
  -- (gf, <C-h>), which would otherwise land in a window hidden under the zoom.
  -- Popups are floats too, and leave it be.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = grp,
    callback = function()
      local entered = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_config(entered).relative ~= "" then
        return
      end
      local tab = vim.api.nvim_get_current_tabpage()
      for win in pairs(zooms) do
        if win ~= entered and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab then
          unzoom(win)
        end
      end
    end,
  })
  -- A zoomed window closed while floating (<C-t> on the side panel, :q) takes
  -- its placeholder with it. Deferred: windows can't close inside WinClosed.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(args)
      local z = zooms[tonumber(args.match)]
      zooms[tonumber(args.match)] = nil
      if z then
        vim.schedule(function()
          pcall(vim.api.nvim_win_close, z.placeholder, true)
        end)
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

-- Called once from terminal.lua.
function M.setup_keymaps()
  -- Normal mode only: programs in the terminal own their ctrl keys.
  vim.keymap.set("n", "<C-t>", M.toggle, { desc = "Toggle side terminal" })
  -- <C-b> as a single tmux-style prefix, bound globally in normal + terminal
  -- mode. A single complete mapping fires immediately, then getcharstr() blocks
  -- for the follow-up key. Separate <C-b>1.. maps instead race the mapping
  -- timeout in terminal mode -- a digit pressed a beat late leaks to the shell.
  -- Global so it works from the live terminal and the editor (to summon a tab
  -- when the panel is closed). In normal mode an unrecognised follow-up key
  -- falls through to the builtin <C-b> (page back) plus that key, so paging
  -- still works — just one keystroke later than stock.
  local arrows = {}
  for lhs, direction in pairs({ ["<Left>"] = "h", ["<Down>"] = "j", ["<Up>"] = "k", ["<Right>"] = "l" }) do
    arrows[vim.api.nvim_replace_termcodes(lhs, true, false, true)] = direction
  end
  local function tab_prefix()
    local ok, key = pcall(vim.fn.getcharstr)
    if not ok or key == "" then
      return
    end
    if key:match("^[1-9]$") then
      M.show(tonumber(key))
    elseif key == "c" then
      M.new()
    elseif key == "t" then
      M.here()
    elseif key == "o" then
      M.cycle()
    elseif key == "a" then
      -- The agent view (lua/fishmonger/view.lua): every agent in every
      -- workspace, blocked ones first. On the prefix rather than its own ctrl
      -- key because the moment you want it is while sitting in a terminal
      -- waiting on an agent, where the free keys are the ones already routed
      -- through here.
      require("fishmonger.view").popup()
    elseif key == "z" then
      M.zoom()
    elseif key == '"' then
      M.split("below")
    elseif key == "%" then
      M.split("right")
    elseif key == "x" then
      M.kill_pane()
    elseif arrows[key] then
      M.select(arrows[key])
    elseif key == "&" then
      M.kill()
    elseif key == "." then
      -- tmux move-window: the next keystroke is the destination slot.
      local ok2, dest = pcall(vim.fn.getcharstr)
      if ok2 and dest:match("^[1-9]$") then
        M.move(tonumber(dest))
      end
    elseif key == "m" then
      -- Carry the terminal to workspace N, like "." takes a slot: the next
      -- keystroke is the destination's number, as its label shows it.
      local ok2, dest = pcall(vim.fn.getcharstr)
      if ok2 and dest:match("^[1-9]$") then
        M.transfer_to(tonumber(dest))
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
    {
      desc = 'Terminal prefix (<C-b>N tab / c new / t here / " % split / x kill pane / arrows select pane / o next window / z zoom / & kill / . move / mN to workspace / a agents)',
    }
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
        if vim.api.nvim_tabpage_is_valid(tab) then
          vacate(state, tab, args.buf)
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
