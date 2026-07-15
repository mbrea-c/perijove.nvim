-- The lazy kernel client: satisfies the kernel-client contract from the
-- moment the notebook opens, but only BOOTS a kernel (via the injected
-- factory) when the first execute arrives. Opening a notebook must never
-- spawn a jupyter server.

local lazy = require("perijove.client.lazy")
local fake_client = require("tests.fake_client")

-- a factory the spec controls: captures the ready callback so connection
-- completion is explicit
local function env()
  local inner = fake_client.new()
  local factory_calls, ready = 0, nil
  local client = lazy.new(function(cb)
    factory_calls = factory_calls + 1
    ready = function(err)
      cb(err, err == nil and inner or nil)
    end
  end)
  local statuses = {}
  client:attach({
    on_status = function(s)
      table.insert(statuses, s)
    end,
  })
  return client, inner, statuses, function()
    return factory_calls
  end, function(err)
    ready(err)
  end
end

describe("client.lazy", function()
  it("does not touch the factory until the first execute", function()
    local _, _, _, calls = env()
    assert.equal(0, calls())
  end)

  it("boots once, reports starting, then flushes the execute", function()
    local client, inner, statuses, calls, ready = env()
    client:execute("x = 1", { on_done = function() end })
    assert.equal(1, calls())
    assert.same({ "starting" }, statuses)
    assert.equal(0, #inner.executions) -- not connected yet
    ready(nil)
    assert.equal(1, #inner.executions)
    assert.equal("x = 1", inner.executions[1].code)
  end)

  it("forwards kernel statuses from the real client once attached", function()
    local client, inner, statuses, _, ready = env()
    client:execute("x", { on_done = function() end })
    ready(nil)
    inner:push_status("busy")
    assert.same({ "starting", "busy" }, statuses)
  end)

  it("reuses the booted client for later executes", function()
    local client, inner, _, calls, ready = env()
    client:execute("a", { on_done = function() end })
    ready(nil)
    client:execute("b", { on_done = function() end })
    assert.equal(1, calls())
    assert.equal(2, #inner.executions)
  end)

  it("fails the pending execute when boot fails, and can retry", function()
    local client, inner, statuses, calls, ready = env()
    local events = {}
    client:execute("x", {
      on_error = function(ename, evalue)
        table.insert(events, { "error", ename, evalue })
      end,
      on_done = function(reply)
        table.insert(events, { "done", reply.status })
      end,
    })
    ready("no jupyter-server on PATH")
    assert.equal("error", events[1][1])
    assert.truthy(events[1][3]:find("no jupyter-server", 1, true))
    assert.same({ "done", "error" }, events[2])
    assert.equal("dead", statuses[#statuses])
    -- a later run tries the factory again
    client:execute("y", { on_done = function() end })
    assert.equal(2, calls())
  end)

  it("rebase swaps the factory: old client shut down, next run boots anew", function()
    local client, inner, statuses, calls, ready = env()
    client:execute("a", { on_done = function() end })
    ready(nil)
    assert.equal(1, #inner.executions)

    local second = fake_client.new()
    local shutdowns = 0
    inner.shutdown = function()
      shutdowns = shutdowns + 1
    end
    client:rebase(function(cb)
      cb(nil, second)
    end)
    assert.equal(1, shutdowns) -- the old kernel is not left running

    client:execute("b", { on_done = function() end })
    assert.equal(1, calls()) -- the OLD factory is not consulted again
    assert.equal(1, #inner.executions)
    assert.equal("b", second.executions[1].code)
    -- statuses from the new client still reach the attached store
    second:push_status("busy")
    assert.equal("busy", statuses[#statuses])
  end)

  it("forwards interrupt only when a real client exists", function()
    local client, inner, _, _, ready = env()
    client:interrupt() -- nothing to interrupt; must not error
    client:execute("x", { on_done = function() end })
    ready(nil)
    client:interrupt()
    assert.equal(1, inner.interrupts)
  end)
end)
