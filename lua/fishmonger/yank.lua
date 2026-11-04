-- Yanks of Claude Code's replies come back as the lines Claude wrote, not the
-- rows it hard-wrapped them into. The line-end-marks mod (in the dotfiles'
-- claude-plugins) ends every real line Claude draws with an invisible U+200C,
-- so in the terminal's text a wrap and a newline look different.
--
-- A row is a wrap when it is unmarked and a marked row closes its paragraph
-- before the next blank row. Rows no mark closes -- tool output, tables, rules,
-- anything not drawn from a reply -- are left exactly as they were.

local M = {}

local MARK = "\226\128\140" -- U+200C

-- The blank columns Claude draws left of a reply's rows (the bullet's, on its first).
local MARGIN = 2

-- Defined below, in top-down order.
local on_yank, wraps, drop_margin, is_marked, is_blank, rows_after, write_register

--- Unwrap yanks in buffers of `filetype` (fishmonger's terminals).
---@param filetype string
function M.setup(filetype)
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = vim.api.nvim_create_augroup("FishmongerYank", { clear = true }),
    callback = function(args)
      if vim.bo[args.buf].filetype == filetype then
        on_yank(args.buf)
      end
    end,
  })
end

--- The yanked `rows` with Claude's wraps joined and the marks removed.
--- `source` holds the whole buffer row each yanked row came from (a charwise
--- yank's first and last rows are fragments of theirs), `after` the buffer rows
--- following the yank up to the next blank, and `cols` the wrap width: a row
--- that fills it was cut mid-word, so it joins without a space. `first_col` is
--- where in its row the yank starts, so a start inside the margin drops the rest.
---@param rows string[]
---@param source string[]
---@param after string[]
---@param cols integer
---@param first_col integer
---@return string[]
function M.unwrap(rows, source, after, cols, first_col)
  local wrapped = wraps(source, after)
  local out, current = {}, nil
  for i, row in ipairs(rows) do
    local text = row:gsub(MARK, "")
    if current then
      local gap = vim.fn.strdisplaywidth(source[i - 1]) >= cols and "" or " "
      current = current:gsub("%s+$", "") .. gap .. text:gsub("^%s+", "")
    elseif wrapped[i] or is_marked(source[i]) then
      current = drop_margin(text, i == 1 and first_col or 0)
    else
      current = text
    end
    if not wrapped[i] or i == #rows then
      out[#out + 1] = current
      current = nil
    end
  end
  return out
end

function on_yank(buf)
  local ev = vim.v.event
  local blockwise = ev.regtype:sub(1, 1) == "\22"
  if ev.operator ~= "y" or blockwise or not table.concat(ev.regcontents):find(MARK, 1, true) then
    return
  end
  local first, first_col = unpack(vim.api.nvim_buf_get_mark(buf, "["))
  local last = first + #ev.regcontents - 1
  local source = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local rows =
    M.unwrap(ev.regcontents, source, rows_after(buf, last), info.width - info.textoff, first_col)
  write_register(ev.regname, rows, ev.regtype)
end

--- Whether each source row is a wrap: unmarked, with a marked row closing its
--- paragraph further down (in `source`, or in `after` past the yank).
function wraps(source, after)
  local closed = vim.iter(after):any(is_marked)
  local out = {}
  for i = #source, 1, -1 do
    local row = source[i]
    out[i] = closed and not is_marked(row) and not is_blank(row)
    if is_blank(row) then
      closed = false
    elseif is_marked(row) then
      closed = true
    end
  end
  return out
end

--- `text` without the part of Claude's blank margin it holds, given that it
--- starts at column `col` of its row; a bullet is not blank, so it stays.
function drop_margin(text, col)
  local held = math.max(0, MARGIN - col)
  return text:sub(1, held):match("^ *$") and text:sub(held + 1) or text
end

function is_marked(row)
  return row:gsub("%s+$", ""):sub(-#MARK) == MARK
end

function is_blank(row)
  return row:match("^%s*$") ~= nil
end

--- The buffer rows after row `last`, up to the next blank one: where a yank that
--- stops mid-paragraph finds the mark that closes it.
function rows_after(buf, last)
  local out = {}
  for _, row in ipairs(vim.api.nvim_buf_get_lines(buf, last, last + 200, false)) do
    if is_blank(row) then
      break
    end
    out[#out + 1] = row
  end
  return out
end

--- Replace what the yank wrote. setreg doesn't sync the system clipboard the way
--- the yank itself did under 'clipboard', so mirror it there too.
function write_register(name, rows, regtype)
  vim.fn.setreg(name == "" and '"' or name, rows, regtype)
  if name ~= "" then
    return
  end
  local mirrors = { unnamed = "*", unnamedplus = "+" }
  for _, clipboard in ipairs(vim.opt.clipboard:get()) do
    if mirrors[clipboard] then
      vim.fn.setreg(mirrors[clipboard], rows, regtype)
    end
  end
end

return M
