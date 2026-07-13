-- The Jupyter protocol layer, pure of any transport: message envelopes for
-- the server websocket (v5.3 wire format, channel-tagged frames), and the
-- correlator that routes decoded incoming messages to per-execution handlers
-- by parent_header.msg_id.

local protocol = require("jotdown.protocol")

describe("protocol.envelope", function()
  it("builds a v5.3 message with fresh ids and the channel tag", function()
    local a = protocol.envelope("execute_request", { code = "x = 1" }, { session = "s1", channel = "shell" })
    assert.equal("execute_request", a.header.msg_type)
    assert.equal("s1", a.header.session)
    assert.equal("5.3", a.header.version)
    assert.truthy(#a.header.msg_id > 0)
    assert.equal("shell", a.channel)
    assert.equal("x = 1", a.content.code)
    local b = protocol.envelope("execute_request", { code = "y" }, { session = "s1", channel = "shell" })
    assert.truthy(a.header.msg_id ~= b.header.msg_id)
  end)

  it("survives a JSON round trip with object-typed empty fields", function()
    local env = protocol.envelope("kernel_info_request", {}, { session = "s", channel = "shell" })
    local wire = vim.json.encode(env)
    -- parent_header/metadata must encode as {} not [] or the server rejects
    assert.truthy(wire:find('"parent_header":{}', 1, true))
    assert.truthy(wire:find('"metadata":{}', 1, true))
  end)
end)

---------------------------------------------------------------------------

-- an incoming wire message, as the server would send it
local function msg(channel, msg_type, parent_id, content)
  return {
    channel = channel,
    header = { msg_id = "srv-" .. math.random(1e9), msg_type = msg_type, session = "kernel" },
    parent_header = { msg_id = parent_id },
    content = content,
  }
end

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
    on_error = function(ename, evalue, tb)
      table.insert(events, { "error", ename, evalue, tb })
    end,
    on_done = function(reply)
      table.insert(events, { "done", reply.status, reply.execution_count })
    end,
  }
end

describe("protocol.correlator", function()
  it("routes iopub output messages to the tracked execution", function()
    local corr = protocol.correlator({})
    local events = {}
    corr:track("m1", collector(events))
    corr:ingest(msg("iopub", "stream", "m1", { name = "stdout", text = "hi\n" }))
    corr:ingest(msg("iopub", "execute_result", "m1", { data = { ["text/plain"] = "42" }, metadata = {} }))
    corr:ingest(msg("iopub", "display_data", "m1", { data = { ["image/png"] = "…" }, metadata = {} }))
    corr:ingest(msg("iopub", "error", "m1", { ename = "E", evalue = "v", traceback = { "t" } }))
    assert.same({ "stream", "stdout", "hi\n" }, events[1])
    assert.same({ "result", "42" }, events[2])
    assert.equal("display", events[3][1])
    assert.same({ "error", "E", "v", { "t" } }, events[4])
  end)

  it("fires on_done only after BOTH execute_reply and iopub idle (reply first)", function()
    local corr = protocol.correlator({})
    local events = {}
    corr:track("m1", collector(events))
    corr:ingest(msg("shell", "execute_reply", "m1", { status = "ok", execution_count = 7 }))
    assert.equal(0, #events)
    corr:ingest(msg("iopub", "status", "m1", { execution_state = "idle" }))
    assert.same({ "done", "ok", 7 }, events[1])
  end)

  it("fires on_done only after BOTH, idle first (the other race order)", function()
    local corr = protocol.correlator({})
    local events = {}
    corr:track("m1", collector(events))
    corr:ingest(msg("iopub", "status", "m1", { execution_state = "idle" }))
    assert.equal(0, #events)
    corr:ingest(msg("shell", "execute_reply", "m1", { status = "error", execution_count = 8 }))
    assert.same({ "done", "error", 8 }, events[1])
  end)

  it("untracks after done: late messages for the parent are dropped", function()
    local corr = protocol.correlator({})
    local events = {}
    corr:track("m1", collector(events))
    corr:ingest(msg("shell", "execute_reply", "m1", { status = "ok", execution_count = 1 }))
    corr:ingest(msg("iopub", "status", "m1", { execution_state = "idle" }))
    local n = #events
    corr:ingest(msg("iopub", "stream", "m1", { name = "stdout", text = "late" }))
    assert.equal(n, #events)
  end)

  it("ignores messages with unknown or missing parents", function()
    local corr = protocol.correlator({})
    assert.has_no_error(function()
      corr:ingest(msg("iopub", "stream", "nobody", { name = "stdout", text = "x" }))
      corr:ingest({ channel = "iopub", header = { msg_type = "status" }, content = { execution_state = "busy" } })
    end)
  end)

  it("forwards every kernel status to the kernel-level handler", function()
    local statuses = {}
    local corr = protocol.correlator({
      on_status = function(s)
        table.insert(statuses, s)
      end,
    })
    corr:track("m1", collector({}))
    corr:ingest(msg("iopub", "status", "m1", { execution_state = "busy" }))
    corr:ingest(msg("iopub", "status", "other-parent", { execution_state = "idle" }))
    assert.same({ "busy", "idle" }, statuses)
  end)

  it("keeps two in-flight executions apart", function()
    local corr = protocol.correlator({})
    local a, b = {}, {}
    corr:track("m1", collector(a))
    corr:track("m2", collector(b))
    corr:ingest(msg("iopub", "stream", "m2", { name = "stdout", text = "for b" }))
    corr:ingest(msg("iopub", "stream", "m1", { name = "stdout", text = "for a" }))
    assert.same({ "stream", "stdout", "for a" }, a[1])
    assert.same({ "stream", "stdout", "for b" }, b[1])
  end)
end)

describe("protocol stdin", function()
  it("allows stdin in execute requests (input() prompts are handled)", function()
    assert.is_true(protocol.execute_content("input()").allow_stdin)
  end)

  it("routes input_request to the execution's on_input", function()
    local corr = protocol.correlator({})
    local prompts = {}
    corr:track("e1", {
      on_input = function(prompt, password)
        table.insert(prompts, { prompt, password })
      end,
      on_done = function() end,
    })
    corr:ingest({
      channel = "stdin",
      header = { msg_id = "srv-9", msg_type = "input_request" },
      parent_header = { msg_id = "e1" },
      content = { prompt = "Name: ", password = false },
    })
    assert.same({ { "Name: ", false } }, prompts)
  end)
end)
