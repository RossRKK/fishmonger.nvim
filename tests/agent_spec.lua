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

  it("stops spinning for a busy agent that dies without writing again", function()
    local agent = fresh_agent()
    local proc = vim.system({ "sleep", "60" })
    write_session("killed", { state = "busy", agent_pid = proc.pid })
    reload(agent)
    assert.equals(1, #agent.all())
    assert.is_not_nil(agent._spin.timer)

    proc:kill(9)
    proc:wait()
    agent._tick()

    assert.equals(0, #agent.all())
    assert.is_nil(agent._spin.timer)
    assert.equals(0, vim.fn.filereadable(dir .. "/killed.json"))
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

  --- Write the launcher's colour claim for `pid`, started at `pid_start`.
  local function write_claim(pid, colour, pid_start)
    local f = assert(io.open(("%s/%d.colour"):format(dir, pid), "w"))
    f:write(vim.json.encode({ colour = colour, pid_start = pid_start }))
    f:close()
  end

  local function start_time(pid)
    local stat = assert(io.open("/proc/" .. pid .. "/stat")):read("*a")
    return tonumber(vim.split(stat:match(".*%) (.*)"), " ")[20])
  end

  it("takes a session's colour from the claim its agent process made", function()
    local agent = fresh_agent()
    write_session("s1", {})
    write_claim(vim.fn.getpid(), "red", start_time(vim.fn.getpid()))
    reload(agent)

    assert.equals("red", agent.all()[1].colour)
    assert.equals("FishmongerAgentRed", agent.colour_hl(agent.all()[1].colour))
  end)

  it("ignores a claim an earlier process left on the same pid", function()
    local agent = fresh_agent()
    write_session("s1", {})
    write_claim(vim.fn.getpid(), "red", start_time(vim.fn.getpid()) - 1)
    reload(agent)

    assert.is_nil(agent.all()[1].colour)
  end)

  it("has no highlight for no colour or one it doesn't know", function()
    local agent = fresh_agent()
    assert.is_nil(agent.colour_hl(nil))
    assert.is_nil(agent.colour_hl("mauve"))
  end)

  it("gives every state a look, and unknown states a fallback", function()
    local agent = fresh_agent()
    assert.is_true(agent.look("permission").attention)
    assert.is_nil(agent.look("busy").attention)
    assert.is_nil(agent.look("done").attention)
    -- A session with no turn yet neither spins nor asks for you.
    assert.is_nil(agent.look("new").attention)
    assert.is_nil(agent.look("new").frames)
    -- A newer hook script than this plugin: still renders, just generically.
    assert.is_not_nil(agent.look("something-new").icon)
    assert.is_nil(agent.look(nil))
  end)

  it("gives a wide glyph and a narrow one slots of equal display width", function()
    local agent = fresh_agent()
    assert.equals("⏳", agent.glyph_cell("⏳"))
    assert.equals("✓ ", agent.glyph_cell("✓"))
    for state in pairs(agent.states) do
      assert.equals(2, vim.fn.strdisplaywidth(agent.glyph_cell(agent.look(state).icon)), state)
    end
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

  it("colours a row's title in its session's colour", function()
    with_agents({
      entry("proj", "busy", { title = "calm-otter", colour_hl = "FishmongerAgentRed" }),
    }, function(view)
      view.popup()
      local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
      local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
      vim.api.nvim_win_close(0, true)
      local coloured = vim.tbl_filter(function(m)
        return m[4].hl_group == "FishmongerAgentRed"
      end, marks)
      assert.equals(1, #coloured)
      assert.equals("calm-otter", line:sub(coloured[1][3] + 1, coloured[1][4].end_col))
    end)
  end)

  it("lines columns up after a wide glyph, and sizes the popup by display width", function()
    local wide = { icon = "⏳", hl = "Comment", label = "working" }
    with_agents({
      entry("proj", "done", { look = wide, detail = "a longer detail than the other row's" }),
      entry("proj", "done"),
    }, function(view)
      view.popup()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local width = vim.api.nvim_win_get_width(0)
      vim.api.nvim_win_close(0, true)
      local function project_col(line)
        return vim.fn.strdisplaywidth(line:sub(1, line:find("proj", 1, true) - 1))
      end
      assert.equals(project_col(lines[2]), project_col(lines[1]))
      assert.equals(vim.fn.strdisplaywidth(lines[1]) + 2, width)
    end)
  end)

  it("wipes the popup's buffer when it closes", function()
    with_agents({ entry("a", "busy") }, function(view)
      local before = #vim.api.nvim_list_bufs()
      view.popup()
      assert.equals("fishmonger_agents", vim.bo.filetype)
      vim.api.nvim_win_close(0, true)
      assert.equals(before, #vim.api.nvim_list_bufs())
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

--- A process's start time (field 22 of /proc/<pid>/stat), as the hook records it.
local function start_time(pid)
  local f = assert(io.open("/proc/" .. pid .. "/stat"))
  local stat = f:read("*a")
  f:close()
  return tonumber(vim.split(stat:match(".*%) (.*)"), " ")[20])
end

--- Write a task file as the hook would, with its output file created now.
---@return string output path
local function write_task(session, id, fields)
  local output = dir .. "/" .. id .. ".output"
  assert(io.open(output, "w")):close()
  local record = vim.tbl_extend("force", {
    session = session,
    id = id,
    description = "Run " .. id,
    command = "make " .. id,
    output = output,
    pid = 2 ^ 30,
    pid_start = 1,
  }, fields or {})
  local f = assert(io.open(dir .. "/" .. session .. "." .. id .. ".task", "w"))
  f:write(vim.json.encode(record))
  f:close()
  return output
end

--- A live stand-in for a background task: its pid and start time as the hook records them.
local function running_task()
  local proc = vim.system({ "sleep", "60" })
  return proc, { pid = proc.pid, pid_start = start_time(proc.pid) }
end

describe("agent background tasks", function()
  it("lists a session's tasks in launch order, with what each one is", function()
    local agent = fresh_agent()
    write_session("s1", {})
    local first = write_task("s1", "b1", { description = "Run the tests", command = "cargo test" })
    write_task("s1", "b2")
    reload(agent)

    local tasks = agent.tasks("s1")
    assert.same(
      { "b1", "b2" },
      vim.tbl_map(function(t)
        return t.id
      end, tasks)
    )
    assert.equals("Run the tests", tasks[1].description)
    assert.equals("cargo test", tasks[1].command)
    assert.equals(first, tasks[1].output)
  end)

  it("treats a task as running only while its pid still has the recorded start time", function()
    local agent = fresh_agent()
    write_session("s1", {})
    local proc, live = running_task()
    write_task("s1", "live", live)
    write_task("s1", "reused", { pid = live.pid, pid_start = live.pid_start - 1 })
    reload(agent)

    local tasks = agent.tasks("s1")
    assert.is_nil(tasks[1].finished)
    assert.is_number(tasks[2].finished)
    proc:kill(9)
    proc:wait()
  end)

  it("notices a task finishing, though no file changes when it does", function()
    local agent = fresh_agent()
    write_session("s1", { state = "done" })
    local proc, live = running_task()
    write_task("s1", "b1", live)
    local changes = 0
    agent.setup({ dir = dir }, function()
      changes = changes + 1
    end)
    assert.is_not_nil(agent._spin.timer)

    proc:kill(9)
    proc:wait()
    agent._tick()

    assert.is_number(agent.tasks("s1")[1].finished)
    assert.equals(1, changes)
    assert.is_nil(agent._spin.timer)
  end)

  it("forgets a dismissed task", function()
    local agent = fresh_agent()
    write_session("s1", {})
    write_task("s1", "b1")
    reload(agent)

    agent.dismiss("s1", "b1")

    assert.same({}, agent.tasks("s1"))
    assert.equals(0, vim.fn.filereadable(dir .. "/s1.b1.task"))
  end)

  it("reaps a dead session's tasks with it", function()
    local agent = fresh_agent()
    write_session("dead", { agent_pid = 2 ^ 30 })
    write_task("dead", "b1")
    reload(agent)

    assert.equals(0, vim.fn.filereadable(dir .. "/dead.b1.task"))
  end)
end)

describe("agent spinner", function()
  it("queues one tick, not one per fire, while the main loop is blocked", function()
    -- The timer and scheduler are faked so the spec fires the timer by hand and
    -- drains the queue when it chooses, as a hit-enter prompt would leave it.
    local agent = fresh_agent()
    write_session("s1", { state = "busy" })
    local fire, queue = nil, {}
    local real_timer, real_schedule = vim.uv.new_timer, vim.schedule
    vim.uv.new_timer = function() ---@diagnostic disable-line: duplicate-set-field
      return {
        start = function(_, _, _, cb)
          fire = cb
        end,
        stop = function() end,
        close = function() end,
      }
    end
    vim.schedule = function(cb) ---@diagnostic disable-line: duplicate-set-field
      queue[#queue + 1] = cb
    end
    local ticks = 0
    local ok, err = pcall(function()
      agent.setup({ dir = dir }, function() end, function()
        ticks = ticks + 1
        error("repaint failed")
      end)
      for _ = 1, 10 do
        fire()
      end
    end)
    vim.uv.new_timer, vim.schedule = real_timer, real_schedule
    assert(ok, err)

    assert.equals(1, #queue)
    assert.has_error(table.remove(queue))
    assert.equals(1, ticks)
    -- The erroring tick didn't wedge the spinner: the next fire queues again.
    fire()
    assert.equals(1, #queue)
  end)
end)
