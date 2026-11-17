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

--- A new, empty list window under `term_win`, holding a buffer of `opts.filetype`
--- and marked `opts.of_var` = `term_win`. `opts.side_var` is copied from the
--- terminal, so a layout manager docks the list with the panel.
---@param term_win integer
---@param opts { of_var: string, filetype: string, side_var: string? }
---@return integer win
function M.open(term_win, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype
  -- noautocmd: a layout manager places a window when a buffer enters it, by
  -- which point the side mark must be there (as fishmonger's own panes do).
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(
    placeholder,
    false,
    { split = "below", win = term_win, height = 1, noautocmd = true }
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

--- Replace list `win`'s lines with `text`, leaving an unchanged buffer untouched.
---@param win integer
---@param text string[]
function M.set_lines(win, text)
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.deep_equal(text, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  end
end

--- Size list `win` to `rows` (within 1..MAX_HEIGHT), resizing only when that
--- changes: every resize also resizes the terminal above, and its program
--- repaints. The height is also published in window variable `height_var`,
--- since a layout manager that sizes its windows itself (edgy) would undo it.
---@param win integer
---@param rows integer
---@param height_var string
function M.set_height(win, rows, height_var)
  local height = math.max(1, math.min(rows, MAX_HEIGHT))
  vim.w[win][height_var] = height
  if vim.api.nvim_win_get_height(win) ~= height then
    vim.api.nvim_win_set_height(win, height)
  end
end

return M
