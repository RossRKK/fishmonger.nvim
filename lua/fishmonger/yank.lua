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

-- How much of a transcript's end to read: transcripts grow to tens of MB.
local TRANSCRIPT_TAIL = 512 * 1024

-- Bytes either side of a join that are looked up in the reply text.
local JOIN_CONTEXT = 20

-- Defined below, in top-down order.
local on_yank, wraps, gap_at, hang_of, drop_indent, is_marked, is_blank, rows_after, write_register
local recent_replies

--- Unwrap yanks in buffers of `filetype` (fishmonger's terminals).
--- `transcript_of(buf)` is the JSONL transcript of the session in `buf`, if any.
---@param filetype string
---@param transcript_of? fun(buf: integer): string?
function M.setup(filetype, transcript_of)
  transcript_of = transcript_of or function() end
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = vim.api.nvim_create_augroup("FishmongerYank", { clear = true }),
    callback = function(args)
      if vim.bo[args.buf].filetype == filetype then
        on_yank(args.buf, transcript_of)
      end
    end,
  })
end

--- The yanked `rows` with Claude's wraps joined and the marks removed.
--- `source` holds the whole buffer row each yanked row came from (a charwise
--- yank's first and last rows are fragments of theirs), `after` the buffer rows
--- following the yank up to the next blank, and `cols` the wrap width. The
--- renderer keeps a wrap's space: at the end of a row that stops short of the
--- edge (where the terminal drops it), or past the indent of the next row when
--- a word ends flush with the edge. So a row that fills `cols` and is followed
--- by one starting at its indent was cut mid-word, and joins without a space.
--- `first_col` is where in its row the yank starts, so a start inside the margin
--- drops the rest.
--- `replies` is the session's recent reply text: a join it settles beats `cols`,
--- which is wrong for rows drawn before the window was resized.
---@param rows string[]
---@param source string[]
---@param after string[]
---@param cols integer
---@param first_col integer
---@param replies? string
---@return string[]
function M.unwrap(rows, source, after, cols, first_col, replies)
  local wrapped = wraps(source, after)
  local out, current, hang = {}, nil, MARGIN
  for i, row in ipairs(rows) do
    local text = row:gsub(MARK, "")
    if current then
      local left, indented = current:gsub("%s+$", ""), drop_indent(text, hang)
      local right = indented:gsub("^%s+", "")
      local fills = vim.fn.strdisplaywidth(source[i - 1]) >= cols
      local gap = right ~= indented and " " or gap_at(left, right, fills, replies)
      current = left .. gap .. right
    elseif wrapped[i] or is_marked(source[i]) then
      local col = i == 1 and first_col or 0
      current = drop_indent(text, math.max(0, MARGIN - col))
      hang = hang_of(source[i])
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

function on_yank(buf, transcript_of)
  local ev = vim.v.event
  local blockwise = ev.regtype:sub(1, 1) == "\22"
  if ev.operator ~= "y" or blockwise or not table.concat(ev.regcontents):find(MARK, 1, true) then
    return
  end
  local first, first_col = unpack(vim.api.nvim_buf_get_mark(buf, "["))
  local last = first + #ev.regcontents - 1
  local source = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local transcript = transcript_of(buf)
  local rows = M.unwrap(
    ev.regcontents,
    source,
    rows_after(buf, last),
    info.width - info.textoff,
    first_col,
    transcript and recent_replies(transcript)
  )
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

--- The gap a wrap join between `left` and `right` gets. Markdown rendering
--- changes the screen's text, so only the bytes either side of the join are
--- looked up in `replies`; when exactly one way of joining is there it wins,
--- and otherwise a row that `fills` the window was cut mid-word.
function gap_at(left, right, fills, replies)
  local tail, head = left:sub(-JOIN_CONTEXT), right:sub(1, JOIN_CONTEXT)
  local joined = replies ~= nil and replies:find(tail .. head, 1, true) ~= nil
  local spaced = replies ~= nil and replies:find(tail .. " " .. head, 1, true) ~= nil
  if joined ~= spaced then
    return joined and "" or " "
  end
  return fills and "" or " "
end

--- The text of the assistant replies near the end of transcript `path`, or nil
--- when it can't be read. A read that starts mid-file starts mid-line, so the
--- first line is skipped then.
function recent_replies(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - TRANSCRIPT_TAIL))
  local lines = vim.split(f:read("*a"), "\n", { plain = true })
  f:close()
  local texts = {}
  for i = size > TRANSCRIPT_TAIL and 2 or 1, #lines do
    local ok, entry = pcall(vim.json.decode, lines[i])
    local content = ok
      and type(entry) == "table"
      and entry.type == "assistant"
      and vim.tbl_get(entry, "message", "content")
    for _, block in ipairs(type(content) == "table" and content or {}) do
      if block.type == "text" then
        texts[#texts + 1] = block.text
      end
    end
  end
  return table.concat(texts, "\n")
end

--- The indent of the rows a paragraph starting with `row` wraps onto: its own,
--- past any list marker, and at least Claude's margin (which holds the bullet).
function hang_of(row)
  local indent = #row:match("^ *")
  local marker = row:match("^[-*+] ", indent + 1) or row:match("^%d+[.)] ", indent + 1) or ""
  return math.max(MARGIN, indent + #marker)
end

--- `text` without its first `width` columns when they are blank; a bullet is
--- not blank, so it stays.
function drop_indent(text, width)
  return text:sub(1, width):match("^ *$") and text:sub(width + 1) or text
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
