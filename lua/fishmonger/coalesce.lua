-- vim.schedule_wrap for libuv callbacks that fire on their own (timers, fs
-- watchers). libuv keeps firing while the main loop is blocked, at a hit-enter
-- prompt say, and schedule_wrap queues one call per fire: a 150ms timer piles up
-- a backlog, and if the callback errors, each Enter runs the next queued call
-- into the next prompt. This queues at most one call; fires while one is
-- pending fold into it. The callback gets no arguments, since the fires it
-- stands for each had their own.

--- `fn`, scheduled onto the main loop with at most one call pending.
---@param fn fun()
---@param schedule? fun(cb: fun()) defaults to vim.schedule; injectable for tests
---@return fun()
return function(fn, schedule)
  local pending = false
  schedule = schedule or vim.schedule
  return function()
    if pending then
      return
    end
    pending = true
    schedule(function()
      -- Cleared before the call, so a call that errors doesn't stop later fires.
      pending = false
      fn()
    end)
  end
end
