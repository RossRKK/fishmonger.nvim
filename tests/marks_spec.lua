-- Read/unread marks (fishmonger/agent.lua): how a status shows once you have
-- marked it or visited its terminal, and when the agent's next write voids that.
--
-- The rules are pure functions of a record and a mark. The visit is driven in a
-- child nvim, since only a real main loop enters terminal mode and fires TermEnter.

local assert = require("luassert")

local agent = require("fishmonger.agent")

local tick, circle, question =
  agent.states.done.icon, agent.states.new.icon, agent.states.asked.icon

--- A record as reload() hands it out.
local function record(state, revision)
  return { session = "s1", state = state, revision = revision or "1.000000000" }
end

describe("mark rules", function()
  it("shows a finished turn nobody has seen as a tick", function()
    assert.equals(tick, agent.shown_look(record("done"), nil).icon)
  end)

  it("shows a finished turn read on this write as an empty circle", function()
    local mark = { kind = "read", revision = "1.000000000" }
    assert.equals(circle, agent.shown_look(record("done"), mark).icon)
  end)

  it("shows the tick again once the agent writes a new status", function()
    local mark = { kind = "read", revision = "1.000000000" }
    assert.equals(tick, agent.shown_look(record("done", "2.000000000"), mark).icon)
  end)

  it("shows unread as a question mark until the next write", function()
    local mark = { kind = "unread", revision = "1.000000000" }
    assert.equals(question, agent.shown_look(record("done"), mark).icon)
    assert.is_true(agent.shown_look(record("done"), mark).attention)
    assert.equals(
      agent.states.busy.icon,
      agent.shown_look(record("busy", "2.000000000"), mark).icon
    )
  end)

  it("shows any state marked read as an empty circle", function()
    local mark = { kind = "read", revision = "1.000000000" }
    for state in pairs(agent.states) do
      assert.equals(circle, agent.shown_look(record(state), mark).icon, state)
    end
    assert.equals(circle, agent.shown_look(record("something-new"), mark).icon)
  end)

  it("reads a finished turn when you visit it", function()
    assert.same({ kind = "read", revision = "1.000000000" }, agent.visited(record("done"), nil))
    local stale = { kind = "read", revision = "0.000000000" }
    assert.same({ kind = "read", revision = "1.000000000" }, agent.visited(record("done"), stale))
  end)

  it("leaves anything but an unmarked finished turn as it was on a visit", function()
    local unread = { kind = "unread", revision = "1.000000000" }
    assert.equals(unread, agent.visited(record("done"), unread))
    for _, state in ipairs({ "busy", "asked", "permission", "new" }) do
      assert.is_nil(agent.visited(record(state), nil), state)
    end
  end)
end)

local dir = vim.fn.tempname() .. "/agents"

--- Write a session file the way the hook does (to a temp file, renamed into
--- place), with its mtime set to `mtime` so each write's revision is distinct
--- however coarse the filesystem clock.
---@param fields table
---@param mtime integer
local function write_session(fields, mtime)
  local path = dir .. "/" .. fields.session .. ".json"
  local f = assert(io.open(path .. ".tmp", "w"))
  f:write(vim.json.encode(vim.tbl_extend("force", {
    state = "done",
    detail = "",
    cwd = "/tmp",
    agent_pid = vim.fn.getpid(),
    pids = { vim.fn.getpid() },
  }, fields)))
  f:close()
  assert(vim.uv.fs_utime(path .. ".tmp", mtime, mtime))
  assert(os.rename(path .. ".tmp", path))
end

describe("marks on live sessions", function()
  local changes

  before_each(function()
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
    package.loaded["fishmonger.agent"] = nil
    agent = require("fishmonger.agent")
    changes = 0
    agent.setup({ dir = dir }, function()
      changes = changes + 1
    end)
  end)

  it("holds a mark until the session's file is written again", function()
    write_session({ session = "s1" }, 1000)
    agent.refresh()
    agent.mark("s1", "read")
    assert.equals(circle, agent.look_of(agent.all()[1]).icon)

    write_session({ session = "s1" }, 1001)
    agent.refresh()
    assert.equals(tick, agent.look_of(agent.all()[1]).icon)
  end)

  it("repaints on a mark, and on a visit only when it changes something", function()
    write_session({ session = "s1" }, 1000)
    agent.refresh()
    local before = changes
    agent.visit("s1")
    assert.equals(before + 1, changes)
    agent.visit("s1")
    assert.equals(before + 1, changes)
    agent.mark("s1", "unread")
    assert.equals(before + 2, changes)
  end)

  it("forgets a mark once its session ends", function()
    write_session({ session = "s1" }, 1000)
    agent.refresh()
    agent.mark("s1", "unread")
    os.remove(dir .. "/s1.json")
    agent.refresh()
    write_session({ session = "s1" }, 1000) -- same revision, so only a kept mark would show
    agent.refresh()
    assert.equals(tick, agent.look_of(agent.all()[1]).icon)
  end)
end)

describe("visiting an agent's terminal", function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local child

  --- Run `code` in the child nvim with `...` as its arguments.
  local function lua(code, ...)
    return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
  end

  --- The status glyph of the child's first tabpage's terminal.
  local function icon()
    return lua("return require('fishmonger').tabs(_G.tab1)[1].icon")
  end

  before_each(function()
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
    child = vim.fn.jobstart(
      { "nvim", "--embed", "--headless", "-u", root .. "/tests/minimal_init.lua" },
      { rpc = true }
    )
    -- Terminal 1 starts in tabpage 1 from tabpage 2, as a workspace restore does,
    -- and its session reports a finished turn.
    lua(
      [[
      local dir = ...
      require("fishmonger").setup({ agent = { dir = dir }, shell = "sleep 60" })
      _G.tab1 = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      _G.tab2 = vim.api.nvim_get_current_tabpage()
      require("fishmonger").show(1, { tab = _G.tab1 })
      ]],
      dir
    )
    local pid = lua([[
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buftype == "terminal" then
          return vim.fn.jobpid(vim.b[buf].terminal_job_id)
        end
      end
    ]])
    write_session({ session = "s1", agent_pid = pid, pids = { pid } }, 1000)
    lua("require('fishmonger').refresh_agents()")
  end)

  after_each(function()
    vim.fn.jobstop(child)
  end)

  it("keeps the tick through a restore that passes through the terminal's window", function()
    assert.equals(tick, icon())
    -- The restore's current-tabpage path: the terminal's window is entered and
    -- left again without terminal mode.
    lua([[
      vim.api.nvim_set_current_tabpage(_G.tab1)
      local editor = vim.api.nvim_get_current_win()
      require("fishmonger").show(1, { insert = false })
      vim.api.nvim_set_current_win(editor)
    ]])
    assert.are_not.equals("t", lua("return vim.api.nvim_get_mode().mode"))
    assert.equals(tick, icon())
  end)

  it("demotes the tick to an empty circle once you go to the agent", function()
    -- Told when terminal mode is entered, rather than guessing how long it takes.
    lua([[
      vim.api.nvim_create_autocmd("TermEnter", { once = true, callback = function()
        local parent = vim.tbl_filter(function(chan)
          return chan.stream == "stdio"
        end, vim.api.nvim_list_chans())[1]
        vim.rpcnotify(parent.id, "nvim_set_var", "child_entered", true)
      end })
      require("fishmonger").focus({ tab = _G.tab1, slot = 1 })
    ]])
    assert.is_true(vim.wait(5000, function()
      return vim.g.child_entered == true
    end))
    vim.g.child_entered = nil
    assert.equals(circle, icon())
  end)

  it("marks the current terminal's agent unread with <C-b>u and read with <C-b>r", function()
    local function press(keys)
      lua(
        [[
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(..., true, false, true), "mx", false)
        ]],
        keys
      )
    end
    lua([[
      require("fishmonger").setup_keymaps()
      vim.api.nvim_set_current_tabpage(_G.tab1)
    ]])
    press("<C-b>u")
    assert.equals(question, icon())
    press("<C-b>r")
    assert.equals(circle, icon())
    -- The same prefix serves terminal mode, where the agent is usually being watched.
    assert.equals(1, lua("return vim.fn.maparg('<C-b>', 't', false, true).callback and 1 or 0"))
  end)
end)
