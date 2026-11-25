-- Referenced files: a list under a terminal (<C-b>f toggles it) of the files
-- its agent's session has read, edited or pointed at, most recent first, each
-- once. <CR> on a line opens that file at the line it was referenced at.
--
-- Sources are the session transcript's assistant messages: file inputs of tool
-- calls (Read, Edit, Write, NotebookEdit, ...) and path[:line] references in
-- the reply text. Only files that exist are listed. Like the task list
-- (fishmonger/tasks.lua) it follows the terminal WINDOW and is re-read on the
-- same events; it stays open, empty, while that window shows no agent.

local list = require("fishmonger.list")
local transcript = require("fishmonger.transcript")

local M = {}

-- Window variable on a list: the terminal window it belongs to.
local LIST_OF = "fishmonger_files_of"

-- Window variable a list publishes its wanted height in, for a layout manager.
local HEIGHT_VAR = "fishmonger_files_height"

-- Tool inputs that name the file a tool works on.
local FILE_INPUTS = { "file_path", "notebook_path" }

-- Defined below, in top-down order.
local open_list, render, transcript_version, display, block_refs, text_refs, parse_ref, absolute, is_file

---@class fishmonger.Session
---@field transcript string the session's JSONL transcript
---@field cwd string the directory its relative paths are from

---@class fishmonger.FileRef
---@field path string absolute
---@field line? integer

-- Set by setup(): where the list's inputs come from.
---@type { terminal_windows: fun(tab: integer): integer[], session_of: fun(buf: integer): fishmonger.Session?, open_file: fun(path: string, line?: integer), side_var: string? }
local env

--- Wire the list to its inputs. `terminal_windows(tab)` lists a tabpage's
--- terminal windows, `session_of(buf)` the agent session in a terminal buffer,
--- `open_file(path, line)` opens a file in the editor. `side_var` is the window
--- variable copied from a terminal onto its list, so a layout manager docks it.
---@param opts table
function M.setup(opts)
  env = opts
  local grp = vim.api.nvim_create_augroup("FishmongerFiles", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = grp,
    pattern = "FishmongerTabsChanged",
    callback = function(args)
      if args.data and args.data.tab == vim.api.nvim_get_current_tabpage() then
        M.sync()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinClosed", "TabEnter" }, {
    group = grp,
    callback = function()
      vim.schedule(M.sync)
    end,
  })
end

--- Open the list under terminal window `term_win` (or under `below`, a window
--- its tab built beneath it) and go to it, or close it if open.
---@param term_win integer
---@param below? integer
function M.toggle(term_win, below)
  local open = list.by_terminal(vim.api.nvim_win_get_tabpage(term_win), LIST_OF)[term_win]
  if open then
    list.close(open, term_win)
    return
  end
  local win = open_list(term_win, below)
  render(win, env.session_of(vim.api.nvim_win_get_buf(term_win)))
  vim.api.nvim_set_current_win(win)
end

--- Bring the current tabpage's lists in line with their terminals' sessions;
--- a list whose window no longer shows a terminal closes.
function M.sync()
  local tab = vim.api.nvim_get_current_tabpage()
  local lists = list.by_terminal(tab, LIST_OF)
  for _, term_win in ipairs(env.terminal_windows(tab)) do
    if lists[term_win] then
      render(lists[term_win], env.session_of(vim.api.nvim_win_get_buf(term_win)))
      lists[term_win] = nil
    end
  end
  for term_win, orphan in pairs(lists) do
    list.close(orphan, term_win)
  end
end

--- The existing files `blocks` (a transcript's assistant content blocks,
--- oldest first) refer to, most recent first and each once, at the line its
--- most recent reference gave. Relative paths are taken from `cwd`.
---@param blocks table[]
---@param cwd string
---@return fishmonger.FileRef[]
function M.referenced(blocks, cwd)
  local refs = {}
  for _, block in ipairs(blocks) do
    vim.list_extend(refs, block_refs(block))
  end
  local seen, out = {}, {}
  for i = #refs, 1, -1 do
    local path = absolute(refs[i].path, cwd)
    if not seen[path] then
      seen[path] = true
      if is_file(path) then
        out[#out + 1] = { path = path, line = refs[i].line }
      end
    end
  end
  return out
end

--- A new, empty list window under `below` (default `term_win`), with its keys.
function open_list(term_win, below)
  local win = list.open(
    term_win,
    { of_var = LIST_OF, filetype = "fishmonger-files", side_var = env.side_var, below = below }
  )
  local buf = vim.api.nvim_win_get_buf(win)
  vim.keymap.set("n", "<CR>", function()
    local ref = (vim.b[buf].fishmonger_files or {})[vim.api.nvim_win_get_cursor(win)[1]]
    if ref then
      env.open_file(ref.path, ref.line)
    end
  end, { buffer = buf, desc = "Open this file in the editor" })
  vim.keymap.set("n", "q", function()
    list.close(win, term_win)
  end, { buffer = buf, desc = "Close the referenced-files list" })
  -- Text written after the session's last event reaches no event; looking at the list catches it.
  vim.api.nvim_create_autocmd("BufEnter", { buffer = buf, callback = M.sync })
  return win
end

--- Fill list `win` from `session`'s transcript, unless it hasn't changed since the last fill.
---@param win integer
---@param session? fishmonger.Session
function render(win, session)
  local buf = vim.api.nvim_win_get_buf(win)
  local version = session and transcript_version(session.transcript)
  if version and version == vim.b[buf].fishmonger_files_version then
    return
  end
  local refs = session
      and M.referenced(transcript.recent_assistant_blocks(session.transcript) or {}, session.cwd)
    or {}
  vim.b[buf].fishmonger_files_version = version
  vim.b[buf].fishmonger_files = refs
  list.set_lines(
    win,
    vim.tbl_map(function(ref)
      return display(ref, session.cwd)
    end, refs)
  )
  list.set_height(win, #refs, HEIGHT_VAR)
end

--- Which write of transcript `path` is on disk, or nil when it isn't.
---@param path string
---@return string?
function transcript_version(path)
  local stat = vim.uv.fs_stat(path)
  return stat and ("%s:%d:%d.%09d"):format(path, stat.size, stat.mtime.sec, stat.mtime.nsec)
end

--- `ref` as a list line: its path from `cwd` (else from ~), and its line.
function display(ref, cwd)
  local path = vim.fs.relpath(cwd, ref.path) or vim.fn.fnamemodify(ref.path, ":~")
  return ref.line and ("%s:%d"):format(path, ref.line) or path
end

--- The file references in one content block, in order: `{ path, line? }`, path as written.
---@param block table
---@return { path: string, line: integer? }[]
function block_refs(block)
  if block.type == "text" and type(block.text) == "string" then
    return text_refs(block.text)
  end
  local input = block.type == "tool_use" and type(block.input) == "table" and block.input or {}
  local refs = {}
  for _, key in ipairs(FILE_INPUTS) do
    if type(input[key]) == "string" then
      -- Read's offset is the line it started reading at.
      refs[#refs + 1] = { path = input[key], line = tonumber(input.offset) }
    end
  end
  return refs
end

--- The path[:line] references in reply text, in order.
function text_refs(text)
  local refs = {}
  for token in text:gmatch("[%w_%.%-/~+@:]+") do
    refs[#refs + 1] = parse_ref(token)
  end
  return refs
end

--- `token` as a reference, or nil when it doesn't look like a path: one needs
--- a directory or an extension. Of `:12:5` or `:12-30` only the first line counts.
function parse_ref(token)
  token = token:gsub("[.:]+$", "")
  local path, line = token:match("^(.-):(%d+)")
  path = path or token
  if path:find("/", 1, true) or path:find("%.%a%w*$") then
    return { path = path, line = tonumber(line) }
  end
end

--- `path` made absolute against `cwd`, with ~ expanded and . and .. resolved.
function absolute(path, cwd)
  if path:match("^[/~]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(cwd, path))
end

function is_file(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

return M
