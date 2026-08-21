-- The agent view: every agent across every workspace, and one keypress to get
-- to any of them.
--
-- The point is cross-workspace. Inside one tabpage the tab strip already tells
-- you what its terminals are doing; what it cannot tell you is that the agent in
-- the project two tabpages over has been sitting on a permission prompt for ten
-- minutes. Blocked agents sort to the top (fishmonger.agents()), each row is
-- labelled with the key that jumps to it, and jumping means switching tabpage
-- AND surfacing that terminal in the side window -- from the row to typing an
-- answer, in one keystroke.
--
-- Two renderings over one model, because the same list is wanted in two places:
--
--   M.items()  the rows as data (icon, text chunks, an action), for embedding in
--              something else -- the workspace greeter's dashboard here.
--   M.popup()  a self-contained floating window, for when you want it on demand
--              from wherever you are.
--
-- Both are pure consumers of fishmonger.agents(); adding a third rendering means
-- adding no state.

local M = {}

local fishmonger = require("fishmonger")

-- Keys handed out to rows, in order. Home row first: the list is meant to be
-- used without looking at it. Digits are deliberately absent -- <C-b>N already
-- means "slot N" everywhere else, and reusing digits for "row N" would make the
-- same key mean two different terminals.
local KEYS = "asdfghjkl;qwertyuiop"

--- The rows, as data. Each is
---   { key, icon, hl, project, title, state, detail, entry, action }
--- where `action` focuses the agent (switch tabpage + show its terminal) and is
--- absent for a session fishmonger doesn't manage and so cannot reach.
---@return table[]
function M.items()
  local rows = {}
  for i, entry in ipairs(fishmonger.agents()) do
    local key = vim.fn.strcharpart(KEYS, i - 1, 1)
    rows[#rows + 1] = {
      key = key ~= "" and key or nil,
      icon = entry.look and entry.look.icon or "\xe2\x80\xa2",
      hl = entry.look and entry.look.hl,
      project = entry.project,
      -- The terminal's own title, which is how the agent describes what it is
      -- doing -- and the only way to tell two agents in one project apart.
      -- Dropped when it is just the project name again (a plain shell's title,
      -- or an agent that hasn't named its task yet), which would read as the
      -- project being printed twice.
      title = entry.title ~= "" and entry.title ~= entry.project and entry.title or nil,
      state = entry.look and entry.look.label or entry.state,
      -- The pending question or the tail of the last answer: what the agent
      -- wants, in the row, so you can triage without visiting each one.
      detail = entry.detail ~= "" and entry.detail or nil,
      entry = entry,
      action = entry.tab and function()
        fishmonger.focus(entry)
      end or nil,
    }
  end
  return rows
end

--- Are any agents blocked on you right now? For a consumer deciding whether the
--- view is worth showing at all.
---@return boolean
function M.attention()
  for _, entry in ipairs(fishmonger.agents()) do
    if entry.look and entry.look.attention then
      return true
    end
  end
  return false
end

local function truncate(s, n)
  if vim.fn.strchars(s) > n then
    return vim.fn.strcharpart(s, 0, n - 1) .. "\xe2\x80\xa6"
  end
  return s
end

--- Pad `s` to display width `w`. By DISPLAY width, not %-Ns: the cells hold
--- multibyte glyphs and project names, and string.format counts bytes, which
--- would stagger every column after them.
---@param s string
---@param w integer
---@return string
local function pad(s, w)
  return s .. (" "):rep(math.max(0, w - vim.fn.strdisplaywidth(s)))
end

--- The lines and highlight spans for a set of rows, plus the width they need.
--- Pure, so the popup can re-run it when the agents change under it.
---
--- Rendered as a table -- key · glyph · project · title · what it wants --
--- with each column padded to its widest cell across ALL rows, so the columns
--- line up down the list instead of each row's title starting wherever its
--- project name ends. A column nobody fills (no titles, say) takes no width.
---@param rows table[]
---@return string[] lines, table[] highlights, integer width
local function layout(rows)
  local project_w, title_w = 0, 0
  for _, row in ipairs(rows) do
    project_w = math.max(project_w, vim.fn.strdisplaywidth(row.project or "?"))
    title_w = math.max(title_w, vim.fn.strdisplaywidth(truncate(row.title or "", 28)))
  end
  local width = 0
  local lines, highlights = {}, {}
  for i, row in ipairs(rows) do
    local cells = {
      row.key or " ",
      row.icon,
      pad(row.project or "?", project_w),
    }
    if title_w > 0 then
      cells[#cells + 1] = pad(truncate(row.title or "", 28), title_w)
    end
    cells[#cells + 1] = truncate(row.detail or row.state or "", 60)
    local line = ("  " .. table.concat(cells, "  ")):gsub("%s+$", "")
    lines[#lines + 1] = line
    width = math.max(width, vim.fn.strchars(line) + 2)
    -- Colour the glyph by state, and the key by "this is what you press".
    highlights[#highlights + 1] = { i - 1, 2, 3, "Special" }
    if row.hl then
      highlights[#highlights + 1] = { i - 1, 5, 5 + #row.icon, row.hl }
    end
  end
  return lines, highlights, width
end

--- The floating-window rendering: the same rows, on demand, from anywhere.
--- The row's key jumps to it and closes the window; so does <CR> on the line the
--- cursor is on. q/<Esc> dismiss. Repaints itself while open: an agent flipping
--- from working to blocked is exactly what this list is for, and it would
--- otherwise show the state from the moment it opened.
function M.popup()
  -- The user is about to read this list; a missed fs event must not be able to
  -- show yesterday's state, so re-read the files rather than trust the cache.
  require("fishmonger.agent").refresh()
  local rows = M.items()
  if #rows == 0 then
    vim.notify("no agents running", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "fishmonger_agents"
  local ns = vim.api.nvim_create_namespace("fishmonger_agents")
  local win

  -- (Re)fill the buffer and size the window to fit. Called at open and again on
  -- every agents change while the popup is up.
  local function render()
    local lines, highlights, width = layout(rows)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, hl in ipairs(highlights) do
      pcall(
        vim.api.nvim_buf_set_extmark,
        buf,
        ns,
        hl[1],
        hl[2],
        { end_col = hl[3], hl_group = hl[4] }
      )
    end
    local config = {
      relative = "editor",
      width = math.min(width, vim.o.columns - 4),
      height = #lines,
      row = math.floor((vim.o.lines - #lines) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = "rounded",
      title = " agents ",
      title_pos = "center",
    }
    if win then
      vim.api.nvim_win_set_config(win, config)
    else
      win = vim.api.nvim_open_win(buf, true, config)
      vim.wo[win].cursorline = true
    end
  end
  render()

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  -- Focus AFTER closing, always: focus() switches tabpage, and a float left open
  -- over the destination steals the keys you switched over there to type.
  local function pick(row)
    close()
    if row and row.action then
      row.action()
    end
  end

  -- Keys are bound by POSITION, not to a row captured at open: a repaint can
  -- reorder the list (blocked agents sort to the top), and a key must always do
  -- what the visible line next to it says.
  for i = 1, vim.fn.strchars(KEYS) do
    vim.keymap.set("n", vim.fn.strcharpart(KEYS, i - 1, 1), function()
      local row = rows[i]
      if row and row.key then
        pick(row)
      end
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "<CR>", function()
    pick(rows[vim.api.nvim_win_get_cursor(win)[1]])
  end, { buffer = buf, nowait = true })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true })
  end
  -- Leaving the window is a dismissal too: it's a chooser, not a panel.
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })

  -- Live repaint: the whole point of the list is agents changing state on their
  -- own, so it cannot freeze at open time. The autocmd dies with the buffer
  -- (buffer-scoped scratch buffer, wiped on close).
  vim.api.nvim_create_autocmd("User", {
    pattern = "FishmongerAgentsChanged",
    callback = function()
      if not (vim.api.nvim_buf_is_valid(buf) and win and vim.api.nvim_win_is_valid(win)) then
        return true -- popup is gone; drop the listener
      end
      rows = M.items()
      if #rows == 0 then
        close()
        return true
      end
      render()
    end,
  })
end

return M
