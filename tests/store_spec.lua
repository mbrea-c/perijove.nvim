-- The notebook store: cells, the per-cell execution state machine
-- (idle -> queued -> running -> ok/error), the serial execution queue, and
-- output accumulation — all pure Lua, driven here through a fake client.

local store = require("jotdown.store")
local fake_client = require("tests.fake_client")

local function new_pair()
  local client = fake_client.new()
  local st = store.new(client)
  return st, client
end

describe("store cells", function()
  it("starts empty and inserts cells with stable unique ids", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x = 1" })
    local b = st:insert_cell(2, { type = "markdown", source = "# hi" })
    assert.equal(2, #st.cells)
    assert.equal("code", st.cells[1].type)
    assert.equal("markdown", st.cells[2].type)
    assert.is_not_nil(a)
    assert.truthy(a ~= b)
    assert.equal("idle", st.cells[1].state)
  end)

  it("carries ipynb bookkeeping through insert_cell (outputs, count, meta)", function()
    local st = new_pair()
    local a = st:insert_cell(1, {
      type = "code",
      source = "x",
      execution_count = 4,
      outputs = { { kind = "stream", name = "stdout", text = "old\n" } },
      meta = { id = "code-1", metadata = { collapsed = true } },
    })
    local cell = st:cell(a)
    assert.equal(4, cell.execution_count)
    assert.equal("old\n", cell.outputs[1].text)
    assert.equal("code-1", cell.meta.id)
  end)

  it("looks up cells by id, edits source, deletes, and moves", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "one" })
    local b = st:insert_cell(2, { type = "code", source = "two" })
    st:set_source(a, "one!")
    assert.equal("one!", st:cell(a).source)
    st:move_cell(b, -1)
    assert.equal(b, st.cells[1].id)
    st:delete_cell(b)
    assert.equal(1, #st.cells)
    assert.equal(a, st.cells[1].id)
    assert.is_nil(st:cell(b))
  end)

  it("notifies subscribers on every mutation, until unsubscribed", function()
    local st = new_pair()
    local n = 0
    local unsub = st:subscribe(function()
      n = n + 1
    end)
    local a = st:insert_cell(1, { type = "code", source = "" })
    st:set_source(a, "x")
    assert.truthy(n >= 2)
    local before = n
    unsub()
    st:set_source(a, "y")
    assert.equal(before, n)
  end)
end)

describe("store execution", function()
  it("runs a code cell: queued -> running, code handed to the client", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "print(1)" })
    st:run_cell(a)
    assert.equal("running", st:cell(a).state)
    assert.equal("print(1)", client:last().code)
  end)

  it("serializes: a second run queues until the first completes", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "one" })
    local b = st:insert_cell(2, { type = "code", source = "two" })
    st:run_cell(a)
    st:run_cell(b)
    assert.equal("running", st:cell(a).state)
    assert.equal("queued", st:cell(b).state)
    assert.equal(1, #client.executions)

    client.executions[1].handlers.on_done({ status = "ok", execution_count = 1 })
    assert.equal("ok", st:cell(a).state)
    assert.equal(1, st:cell(a).execution_count)
    assert.equal("running", st:cell(b).state)
    assert.equal("two", client.executions[2].code)
  end)

  it("coalesces consecutive same-name stream chunks into one output", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "" })
    st:run_cell(a)
    local h = client:last().handlers
    h.on_stream("stdout", "hel")
    h.on_stream("stdout", "lo\n")
    h.on_stream("stderr", "warn\n")
    h.on_stream("stdout", "again")
    local outs = st:cell(a).outputs
    assert.equal(3, #outs)
    assert.same({ kind = "stream", name = "stdout", text = "hello\n" }, outs[1])
    assert.same({ kind = "stream", name = "stderr", text = "warn\n" }, outs[2])
    assert.same({ kind = "stream", name = "stdout", text = "again" }, outs[3])
  end)

  it("appends results, display data, and errors as outputs", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "" })
    st:run_cell(a)
    local h = client:last().handlers
    h.on_result({ ["text/plain"] = "42" }, {})
    h.on_display({ ["image/png"] = "..." }, {})
    h.on_error("ValueError", "boom", { "tb1", "tb2" })
    local outs = st:cell(a).outputs
    assert.equal("result", outs[1].kind)
    assert.equal("42", outs[1].data["text/plain"])
    assert.equal("display", outs[2].kind)
    assert.equal("error", outs[3].kind)
    assert.equal("ValueError", outs[3].ename)
  end)

  it("clears previous outputs when a cell re-runs", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "" })
    st:run_cell(a)
    client:last().handlers.on_stream("stdout", "old")
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
    st:run_cell(a)
    assert.same({}, st:cell(a).outputs)
  end)

  it("aborts the queue when a cell errors (Jupyter semantics)", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "one" })
    local b = st:insert_cell(2, { type = "code", source = "two" })
    st:run_cell(a)
    st:run_cell(b)
    client.executions[1].handlers.on_error("E", "boom", {})
    client.executions[1].handlers.on_done({ status = "error", execution_count = 1 })
    assert.equal("error", st:cell(a).state)
    assert.equal("idle", st:cell(b).state) -- back out of the queue
    assert.equal(1, #client.executions) -- b never dispatched
  end)

  it("interrupt clears queued cells and reaches the client", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "one" })
    local b = st:insert_cell(2, { type = "code", source = "two" })
    st:run_cell(a)
    st:run_cell(b)
    st:interrupt()
    assert.equal(1, client.interrupts)
    assert.equal("idle", st:cell(b).state)
    -- the running cell settles only when the kernel reports back
    assert.equal("running", st:cell(a).state)
    client.executions[1].handlers.on_done({ status = "error", execution_count = 1 })
    assert.equal("error", st:cell(a).state)
  end)

  it("run_all runs the code cells in document order, skipping markdown", function()
    local st, client = new_pair()
    st:insert_cell(1, { type = "code", source = "one" })
    st:insert_cell(2, { type = "markdown", source = "# doc" })
    st:insert_cell(3, { type = "code", source = "three" })
    st:run_all()
    assert.equal("one", client.executions[1].code)
    client.executions[1].handlers.on_done({ status = "ok", execution_count = 1 })
    assert.equal("three", client.executions[2].code)
    assert.equal(2, #client.executions)
  end)

  it("ignores run requests for markdown cells and busy cells", function()
    local st, client = new_pair()
    local md = st:insert_cell(1, { type = "markdown", source = "# hi" })
    local a = st:insert_cell(2, { type = "code", source = "x" })
    st:run_cell(md)
    assert.equal(0, #client.executions)
    st:run_cell(a)
    st:run_cell(a) -- already running: no double dispatch, no re-queue
    assert.equal(1, #client.executions)
    assert.equal("running", st:cell(a).state)
  end)
end)

describe("store content_rev", function()
  it("bumps on content mutations but not on kernel status", function()
    local st, client = new_pair()
    local r0 = st.content_rev
    client:push_status("busy")
    assert.equal(r0, st.content_rev) -- status is not document content
    local a = st:insert_cell(1, { type = "code", source = "" })
    assert.truthy(st.content_rev > r0)
    local r1 = st.content_rev
    st:set_source(a, "x")
    assert.truthy(st.content_rev > r1)
  end)
end)

describe("store kernel status", function()
  it("tracks status events pushed by the client", function()
    local st, client = new_pair()
    assert.equal("unknown", st.kernel_status)
    local seen
    st:subscribe(function()
      seen = st.kernel_status
    end)
    client:push_status("busy")
    assert.equal("busy", st.kernel_status)
    assert.equal("busy", seen)
    client:push_status("idle")
    assert.equal("idle", st.kernel_status)
  end)
end)
