-- fishmonger/coalesce.lua: libuv callbacks that fire while the main loop is
-- busy queue at most one call. The scheduler is a fake queue the spec drains by
-- hand, standing in for the main loop coming back.

local assert = require("luassert")
local coalesce = require("fishmonger.coalesce")

--- A scheduler that only queues, and a way to run what it queued.
local function fake_loop()
  local queue = {}
  local loop = { queue = queue }
  function loop.schedule(cb)
    queue[#queue + 1] = cb
  end
  function loop.drain()
    local batch = vim.list_slice(queue)
    for i = #queue, 1, -1 do
      queue[i] = nil
    end
    for _, cb in ipairs(batch) do
      cb()
    end
  end
  return loop
end

describe("coalesce", function()
  it("queues one call however often the source fires while the loop is busy", function()
    local loop, calls = fake_loop(), 0
    local fire = coalesce(function()
      calls = calls + 1
    end, loop.schedule)

    for _ = 1, 20 do
      fire()
    end
    assert.equals(1, #loop.queue)

    loop.drain()
    assert.equals(1, calls)
  end)

  it("queues again once the pending call has run", function()
    local loop, calls = fake_loop(), 0
    local fire = coalesce(function()
      calls = calls + 1
    end, loop.schedule)

    fire()
    loop.drain()
    fire()
    fire()
    assert.equals(1, #loop.queue)
    loop.drain()
    assert.equals(2, calls)
  end)

  it("raises a call's error and still queues the next fire", function()
    local loop = fake_loop()
    local fire = coalesce(function()
      error("render failed")
    end, loop.schedule)

    fire()
    fire()
    assert.has_error(loop.drain, nil)
    assert.equals(0, #loop.queue)
    fire()
    fire()
    assert.equals(1, #loop.queue)
  end)
end)
