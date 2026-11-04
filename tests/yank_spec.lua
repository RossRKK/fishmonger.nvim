-- Yanking Claude Code's replies out of a terminal (fishmonger/yank.lua). The
-- claude-plugins/line-end-marks mod in the dotfiles ends every real line of a
-- reply with U+200C; Claude still hard-wraps to the terminal width. The rows
-- here are as a 103-column terminal stored them.

local assert = require("luassert")

local yank = require("fishmonger.yank")

local M = "\226\128\140" -- U+200C
local COLS = 103

--- `unwrap` for a yank of whole rows, with nothing after it in the buffer.
local function unwrap(rows, after)
  return yank.unwrap(rows, rows, after or {}, COLS, 0)
end

describe("yank.unwrap", function()
  it("joins a paragraph Claude wrapped, back to its one real line", function()
    local rows = {
      "  Probe paragraph: this is one long markdown paragraph written as a single source line, so Claude has",
      "  to wrap it at least twice at this terminal width, and none of those wrap breaks should carry a",
      "  marker, while the very end of the paragraph should." .. M,
    }

    assert.same({
      "Probe paragraph: this is one long markdown paragraph written as a single source line, so Claude has"
        .. " to wrap it at least twice at this terminal width, and none of those wrap breaks should carry a"
        .. " marker, while the very end of the paragraph should.",
    }, unwrap(rows))
  end)

  it("keeps every real newline, and the blank rows between paragraphs", function()
    local rows = { "  - Short item." .. M, "  - Another." .. M, "", "  Last line." .. M }

    assert.same({ "- Short item.", "- Another.", "", "Last line." }, unwrap(rows))
  end)

  it("drops a list item's hanging indent where it wrapped", function()
    local rows = {
      "  - A list item that is also long enough to wrap onto a second row at this width, so its continuation",
      "    row gets the hanging indent rather than the plain margin." .. M,
    }

    assert.same({
      "- A list item that is also long enough to wrap onto a second row at this width, so its continuation"
        .. " row gets the hanging indent rather than the plain margin.",
    }, unwrap(rows))
  end)

  it("joins a row cut mid-word at the edge without adding a space", function()
    local long = "  " .. ("x"):rep(COLS - 2)

    assert.same({ long:sub(3) .. "yz" }, unwrap({ long, "  yz" .. M }))
  end)

  it("drops Claude's margin from every real line, keeping the bullet and deeper indents", function()
    local rows =
      { "● Opening line." .. M, "  - item" .. M, "    - nested" .. M, "      code indent" .. M }

    assert.same({ "● Opening line.", "- item", "  - nested", "    code indent" }, unwrap(rows))
  end)

  it("drops only what is left of the margin when a charwise yank starts inside it", function()
    local source = { "  - item" .. M, "  next" .. M }

    assert.same(
      { "- item", "next" },
      yank.unwrap({ " - item" .. M, "  next" .. M }, source, {}, COLS, 1)
    )
  end)

  it("leaves rows alone that no mark closes: tool output, tables, rules", function()
    local rows = {
      "● Bash(ls -la)",
      "  ⎿  total 8",
      "     drwxr-xr-x  2 ross users 4096 .",
      "",
      "  ┌───┬───┐",
      "  │ a │ b │",
      "  └───┴───┘",
    }

    assert.same(rows, unwrap(rows))
  end)

  it(
    "joins the yank's last rows when the mark closing their paragraph lies past the yank",
    function()
      local rows = {
        "  first row of a paragraph that Claude wrapped at the terminal edge, and the yank",
        "  stops here",
      }

      local out = yank.unwrap(rows, rows, { "  before the paragraph ends." .. M }, COLS, 0)

      assert.same({
        "first row of a paragraph that Claude wrapped at the terminal edge, and the yank stops here",
      }, out)
    end
  )

  it("decides by the source row, not a charwise yank's fragment of it", function()
    local source = {
      "  Probe paragraph: this is one long markdown paragraph written as a single source line, so Claude has",
      "  to wrap it." .. M,
    }

    local out = yank.unwrap({ "so Claude has", "  to wrap" }, source, {}, COLS, 88)

    assert.same({ "so Claude has to wrap" }, out)
  end)
end)

describe("yank on TextYankPost", function()
  local buf
  before_each(function()
    pcall(vim.cmd, "only")
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "fishmonger"
    yank.setup("fishmonger")
    vim.fn.setreg('"', "")
  end)

  it("puts the unwrapped text in the register a yank wrote", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  a wrapped", "  reply." .. M })

    vim.cmd("normal! ggVjy")

    assert.same({ "a wrapped reply." }, vim.fn.getreg('"', 1, true))
  end)

  it("leaves a yank with no marks in it exactly as it was", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain", "output" })

    vim.cmd("normal! ggVjy")

    assert.same({ "plain", "output" }, vim.fn.getreg('"', 1, true))
  end)

  it("leaves other filetypes' yanks alone", function()
    vim.bo[buf].filetype = "lua"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  a wrapped", "  reply." .. M })

    vim.cmd("normal! ggVjy")

    assert.same({ "  a wrapped", "  reply." .. M }, vim.fn.getreg('"', 1, true))
  end)
end)
