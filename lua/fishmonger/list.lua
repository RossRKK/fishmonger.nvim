-- A list window docked under a terminal window, as the background-task and
-- referenced-file lists are. A real window, not a float, so it never covers
-- the terminal and ordinary window motions (<C-j>, <C-k>) reach it.

local M = {}

-- Taller lists scroll rather than eat the terminal.
local MAX_HEIGHT = 8

--- The lists in `tab` marked with window variable `of_var`, keyed by their terminal window.
---@param tab integer
---@param of_var string
---@return table<integer, integer>
function M.by_terminal(tab, of_var)
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local of = vim.w[win][of_var]
    if of then
      out[of] = win
    end
  end
  return out
end

--- A new, empty list window under `opts.below` (default `term_win`), holding a
--- buffer of `opts.filetype` and marked `opts.of_var` = `term_win`.
--- `opts.side_var` is copied from the terminal, so the list counts as the panel's.
---@param term_win integer
---@param opts { of_var: string, filetype: string, side_var: string?, below: integer? }
---@return integer win
function M.open(term_win, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype
  -- Its lines are the list's own; only set_lines writes them.
  vim.bo[buf].modifiable = false
  -- noautocmd: a layout manager places a window when a buffer enters it, by
  -- which point the side mark must be there (as fishmonger's own panes do).
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(
    placeholder,
    false,
    { split = "below", win = opts.below or term_win, height = 1, noautocmd = true }
  )
  vim.w[win][opts.of_var] = term_win
  if opts.side_var then
    vim.w[win][opts.side_var] = vim.w[term_win][opts.side_var]
  end
  vim.api.nvim_win_set_buf(win, buf)
  for name, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    winfixheight = true,
    wrap = false,
    winbar = "",
  }) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  return win
end

--- Close list `win` with the rows it frees going to terminal window `term_win`: Vim
--- hands them to the window above (an agent chat's pinned prompt) and 'equalalways'
--- re-balances the rest, so every other window gets back the height it had.
---@param win integer
---@param term_win integer
function M.close(win, term_win)
  local heights = {}
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if other ~= win and other ~= term_win then
      heights[other] = vim.api.nvim_win_get_height(other)
    end
  end
  pcall(vim.api.nvim_win_close, win, true)
  for other, height in pairs(heights) do
    if vim.api.nvim_win_is_valid(other) and vim.api.nvim_win_get_height(other) ~= height then
      vim.api.nvim_win_set_height(other, height)
    end
  end
end

--- Replace list `win`'s lines with `text`, leaving an unchanged buffer untouched.
---@param win integer
---@param text string[]
function M.set_lines(win, text)
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.deep_equal(text, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    vim.bo[buf].modifiable = false
  end
end

--- Size list `win` to `rows` (within 1..`max`, default MAX_HEIGHT), resizing only when that
--- changes: every resize also resizes the terminal above, and its program
--- repaints. The height is also published in window variable `height_var`,
--- since a layout manager that sizes its windows itself (edgy) would undo it.
---@param win integer
---@param rows integer
---@param height_var string
---@param max? integer
function M.set_height(win, rows, height_var, max)
  local height = math.max(1, math.min(rows, max or MAX_HEIGHT))
  vim.w[win][height_var] = height
  if vim.api.nvim_win_get_height(win) ~= height then
    vim.api.nvim_win_set_height(win, height)
  end
end

return M
