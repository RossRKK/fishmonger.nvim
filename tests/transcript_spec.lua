-- Reading the end of Claude Code's JSONL transcript (fishmonger/transcript.lua).

local assert = require("luassert")

local transcript = require("fishmonger.transcript")

local function write(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  return path
end

local function assistant(...)
  return vim.json.encode({ type = "assistant", message = { content = { ... } } })
end

describe("transcript.recent_assistant_blocks", function()
  it("gives the assistant messages' blocks in order, skipping other entries and bad lines", function()
    local path = write({
      assistant({ type = "text", text = "one" }),
      vim.json.encode({ type = "user", message = { content = { { type = "text", text = "user" } } } }),
      "{not json",
      assistant({ type = "tool_use", name = "Read" }, { type = "text", text = "two" }),
    })

    assert.same({
      { type = "text", text = "one" },
      { type = "tool_use", name = "Read" },
      { type = "text", text = "two" },
    }, transcript.recent_assistant_blocks(path))
  end)

  it("reads only the end of a long transcript, never a line cut in half", function()
    local filler = assistant({ type = "text", text = ("x"):rep(1024) })
    local lines = { assistant({ type = "text", text = "old" }) }
    for _ = 1, 600 do
      lines[#lines + 1] = filler
    end
    lines[#lines + 1] = assistant({ type = "text", text = "new" })

    local blocks = transcript.recent_assistant_blocks(write(lines))

    assert.equals("new", blocks[#blocks].text)
    assert.is_true(#blocks < 600)
    for _, block in ipairs(blocks) do
      assert.not_equals("old", block.text)
    end
  end)

  it("is nil for a transcript that isn't there", function()
    assert.is_nil(transcript.recent_assistant_blocks("/nonexistent/transcript.jsonl"))
  end)
end)
