-- Agent status (fishmonger/agent.lua) and the view built on it
-- (fishmonger/view.lua): reading the hook's status files, matching a session to
-- the terminal it runs in, and the ordering the view depends on.
--
-- The hook script is not run here -- it is a shell script whose contract is the
-- JSON it writes, so the specs write that JSON directly. Process liveness is
-- real, though: a record's agent_pid is checked against /proc, so the live cases
-- claim this nvim's own pid and the dead one claims a pid that cannot exist.

local assert = require("luassert")

local dir = vim.fn.tempname() .. "/agents"

--- A fresh agent module watching an empty status directory.
local function fresh_agent()
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  package.loaded["fishmonger.agent"] = nil
  local agent = require("fishmonger.agent")
  agent.setup({ dir = dir }, function() end)
  return agent
end

--- Write a session file as the hook would.
---@param session string
---@param fields table
local function write_session(session, fields)
  local record = vim.tbl_extend("force", {
    session = session,
    state = "busy",
    detail = "",
    cwd = "/tmp",
    -- This nvim: alive, so the record survives the liveness check.
    agent_pid = vim.fn.getpid(),
    pids = { vim.fn.getpid() },
  }, fields)
  local f = assert(io.open(dir .. "/" .. session .. ".json", "w"))
  f:write(vim.json.encode(record))
  f:close()
end

--- Re-read the directory synchronously. setup()'s watcher is debounced and
--- async; the specs want the answer now.
local function reload(agent)
  agent.setup({ dir = dir }, function() end)
end

describe("agent status", function()
  it("reads a session file and looks up its state", function()
    local agent = fresh_agent()
    write_session("s1", { state = "permission", detail = "needs Bash" })
    reload(agent)

    local all = agent.all()
    assert.equals(1, #all)
    assert.equals("permission", all[1].state)
    assert.equals("needs Bash", all[1].detail)
  end)

  it("drops a session whose agent process is gone", function()
    local agent = fresh_agent()
    -- Above the pid ceiling, so it cannot be a live process.
    write_session("dead", { agent_pid = 2 ^ 30 })
    reload(agent)

    assert.equals(0, #agent.all())
    -- And reaps the file, so it isn't re-read forever.
    assert.equals(0, vim.fn.filereadable(dir .. "/dead.json"))
  end)

  it("matches a session to the terminal whose shell pid is in its chain", function()
    local agent = fresh_agent()
    write_session("mine", { pids = { 4242, 99, 1 } })
    reload(agent)

    -- for_buf takes the pid resolver as an argument (core owns /proc access),
    -- so the fake here is just "this buffer's shell is 4242".
    local record = agent.for_buf(1, function()
      return 4242
    end)
    assert.is_not_nil(record)
    assert.equals("mine", record.session)

    agent.forget(1) -- else the pid cache answers for the next lookup
    assert.is_nil(agent.for_buf(1, function()
      return 5555
    end))
  end)

  it("gives every state a look, and unknown states a fallback", function()
    local agent = fresh_agent()
    assert.is_true(agent.look("permission").attention)
    assert.is_nil(agent.look("busy").attention)
    assert.is_nil(agent.look("done").attention)
    -- A newer hook script than this plugin: still renders, just generically.
    assert.is_not_nil(agent.look("something-new").icon)
    assert.is_nil(agent.look(nil))
  end)
end)

describe("agent view", function()
  --- Fake the fleet-wide query the view is a pure function of.
  local function with_agents(entries, fn)
    package.loaded["fishmonger.view"] = nil
    local fishmonger = require("fishmonger")
    local real = fishmonger.agents
    fishmonger.agents = function() ---@diagnostic disable-line: duplicate-set-field
      return entries
    end
    local ok, err = pcall(fn, require("fishmonger.view"))
    fishmonger.agents = real
    assert(ok, err)
  end

  local function entry(project, state, extra)
    local agent = require("fishmonger.agent")
    return vim.tbl_extend("force", {
      tab = 1,
      slot = 1,
      project = project,
      state = state,
      look = agent.look(state),
      detail = "",
    }, extra or {})
  end

  it("hands out a jump key per row", function()
    with_agents({ entry("a", "busy"), entry("b", "done") }, function(view)
      local rows = view.items()
      assert.equals("a", rows[1].key)
      assert.equals("s", rows[2].key)
      assert.is_function(rows[1].action)
    end)
  end)

  it("gives no jump key to a session outside any managed terminal", function()
    -- Built by hand rather than via entry(): "unattached" is the ABSENCE of
    -- tab/slot, and tbl_extend cannot express removing a key.
    local unattached =
      { project = "loose", state = "done", look = require("fishmonger.agent").look("done") }
    with_agents({ unattached }, function(view)
      local rows = view.items()
      assert.equals(1, #rows)
      assert.is_nil(rows[1].action)
    end)
  end)

  it("carries the terminal title, unless it just repeats the project", function()
    with_agents({
      entry("proj", "busy", { title = "reviewing the parser" }),
      entry("proj", "busy", { title = "proj" }),
    }, function(view)
      local rows = view.items()
      assert.equals("reviewing the parser", rows[1].title)
      assert.is_nil(rows[2].title)
    end)
  end)

  it("reports whether anything is blocked", function()
    with_agents({ entry("a", "busy"), entry("b", "done") }, function(view)
      assert.is_false(view.attention())
    end)
    with_agents({ entry("a", "busy"), entry("b", "permission") }, function(view)
      assert.is_true(view.attention())
    end)
  end)
end)

describe("agents across tabpages", function()
  it("sorts the blocked ones first", function()
    -- M.agents' own sort, exercised through the real function with faked
    -- statuses: the ordering is the promise the view and the greeter rest on.
    package.loaded["fishmonger"] = nil
    package.loaded["fishmonger.agent"] = nil
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
    vim.fn.jobstart = function(cmd, opts) ---@diagnostic disable-line: duplicate-set-field, unused-local
      return 1
    end
    pcall(vim.cmd, "tabonly")
    pcall(vim.cmd, "only")

    local fishmonger = require("fishmonger")
    fishmonger.setup({ agent = { dir = dir } })
    write_session("busy-one", { state = "busy", cwd = "/tmp/zzz" })
    write_session("blocked", { state = "permission", cwd = "/tmp/aaa" })
    require("fishmonger.agent").setup({ dir = dir }, function() end)

    local out = fishmonger.agents()
    assert.equals(2, #out)
    -- Blocked first even though its project sorts later and neither is attached
    -- to a terminal here.
    assert.equals("permission", out[1].state)
    assert.equals("busy", out[2].state)
  end)
end)
