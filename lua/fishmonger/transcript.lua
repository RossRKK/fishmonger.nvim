-- Claude Code's JSONL session transcript, read from its end: transcripts grow
-- to tens of MB, and what the readers want is the recent part.

local M = {}

-- How much of a transcript's end to read.
local TAIL = 512 * 1024

--- The content blocks of the assistant messages near the end of transcript
--- `path`, oldest first, or nil when it can't be read. A read that starts
--- mid-file starts mid-line, so the first line is skipped then.
---@param path string
---@return table[]?
function M.recent_assistant_blocks(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - TAIL))
  local lines = vim.split(f:read("*a"), "\n", { plain = true })
  f:close()
  local blocks = {}
  for i = size > TAIL and 2 or 1, #lines do
    local ok, entry = pcall(vim.json.decode, lines[i])
    local content = ok
      and type(entry) == "table"
      and entry.type == "assistant"
      and vim.tbl_get(entry, "message", "content")
    vim.list_extend(blocks, type(content) == "table" and content or {})
  end
  return blocks
end

return M
