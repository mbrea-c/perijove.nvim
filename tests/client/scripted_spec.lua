-- The scripted kernel client: satisfies the kernel-client contract with
-- canned, timed timelines instead of a real kernel — the store/UI can be
-- developed and demoed with zero protocol code. Time is injected (opts.defer)
-- so these specs pump it by hand; the demo uses vim.defer_fn.

local scripted = require("jotdown.client.scripted")

-- A client wired to a hand-cranked clock. Returns the client, a pump that
-- fires every scheduled step in order, and the recorded kernel statuses.
local function new_env()
  local timers = {}
  local client = scripted.new({
    defer = function(ms, fn)
      table.insert(timers, { ms = ms, fn = fn })
    end,
  })
  local statuses = {}
  client:attach({
    on_status = function(s)
      table.insert(statuses, s)
    end,
  })
  local function pump()
    while #timers > 0 do
      table.remove(timers, 1).fn()
    end
  end
  return client, pump, statuses
end

-- Execution handlers that append tagged events to `events`.
local function collector(events)
  return {
    on_stream = function(name, text)
      table.insert(events, { "stream", name, text })
    end,
    on_result = function(data)
      table.insert(events, { "result", data["text/plain"] })
    end,
    on_display = function(data)
      table.insert(events, { "display", data })
    end,
    on_error = function(ename)
      table.insert(events, { "error", ename })
    end,
    on_done = function(reply)
      table.insert(events, { "done", reply.status, reply.execution_count })
    end,
  }
end

describe("scripted client", function()
  it("plays a happy path: busy, streams, result, done ok, idle", function()
    local client, pump, statuses = new_env()
    local events = {}
    client:execute('print("hi")', collector(events))
    assert.equal("busy", statuses[#statuses]) -- busy immediately, before pumping
    pump()

    local last = events[#events]
    assert.same({ "done", "ok", 1 }, last)
    assert.equal("idle", statuses[#statuses])
    -- at least one stdout chunk, and it precedes the result and the done
    local kinds = {}
    for _, e in ipairs(events) do
      table.insert(kinds, e[1])
    end
    local joined = table.concat(kinds, ",")
    assert.truthy(joined:find("stream"))
    assert.truthy(joined:find("stream.*result.*done"))
  end)

  it("increments the execution count across executes", function()
    local client, pump = new_env()
    local a, b = {}, {}
    client:execute("x = 1", collector(a))
    pump()
    client:execute("y = 2", collector(b))
    pump()
    assert.same({ "done", "ok", 1 }, a[#a])
    assert.same({ "done", "ok", 2 }, b[#b])
  end)

  it("plays an error timeline for code that raises", function()
    local client, pump, statuses = new_env()
    local events = {}
    client:execute('raise ValueError("boom")', collector(events))
    pump()
    assert.same({ "error", "ValueError" }, { events[#events - 1][1], events[#events - 1][2] })
    assert.same({ "done", "error", 1 }, events[#events])
    assert.equal("idle", statuses[#statuses])
  end)

  it("interrupt cancels a slow cell: KeyboardInterrupt, done error, no late steps", function()
    local client, pump, statuses = new_env()
    local events = {}
    client:execute("time.sleep(60)", collector(events))
    client:interrupt()
    pump()

    assert.same({ "error", "KeyboardInterrupt" }, { events[#events - 1][1], events[#events - 1][2] })
    assert.same({ "done", "error", 1 }, events[#events])
    assert.equal("idle", statuses[#statuses])
    -- the cancelled timeline's own steps must not have delivered anything:
    -- nothing before the KeyboardInterrupt except (possibly) nothing at all
    for _, e in ipairs(events) do
      assert.truthy(e[1] == "error" or e[1] == "done")
    end
    -- pumping again delivers nothing new (stale steps are dead, not deferred)
    local n = #events
    pump()
    assert.equal(n, #events)
  end)
end)
