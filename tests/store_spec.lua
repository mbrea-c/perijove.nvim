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

describe("store cell type", function()
  it("flips code to markdown, clearing execution artifacts", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x", meta = { id = "keep-me" } })
    st:run_cell(a)
    client:last().handlers.on_stream("stdout", "out\n")
    client:last().handlers.on_done({ status = "ok", execution_count = 7 })

    st:set_type(a, "markdown")
    local cell = st:cell(a)
    assert.equal("markdown", cell.type)
    assert.equal("x", cell.source) -- source survives
    assert.equal(0, #cell.outputs)
    assert.is_nil(cell.execution_count)
    assert.equal("idle", cell.state)
    assert.equal("keep-me", cell.meta.id) -- ipynb identity survives
  end)

  it("flips markdown to code and bumps content_rev", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "markdown", source = "# hi" })
    local r0 = st.content_rev
    st:set_type(a, "code")
    assert.equal("code", st:cell(a).type)
    assert.truthy(st.content_rev > r0)
  end)

  it("is a no-op for the same type or a running cell", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x" })
    local r0 = st.content_rev
    st:set_type(a, "code")
    assert.equal(r0, st.content_rev)

    st:run_cell(a) -- fake client parks it: state stays running
    st:set_type(a, "markdown")
    assert.equal("code", st:cell(a).type)
  end)

  it("backs a queued cell out of the queue", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "a" })
    local b = st:insert_cell(2, { type = "code", source = "b" })
    st:run_cell(a)
    st:run_cell(b) -- queued behind a
    st:set_type(b, "markdown")
    assert.equal("markdown", st:cell(b).type)
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
    assert.equal(1, #client.executions) -- b never dispatched
  end)
end)

describe("store index", function()
  it("returns a cell's 1-based position, nil when gone", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "a" })
    local b = st:insert_cell(2, { type = "code", source = "b" })
    assert.equal(1, st:index(a))
    assert.equal(2, st:index(b))
    st:delete_cell(a)
    assert.equal(1, st:index(b))
    assert.is_nil(st:index(a))
  end)
end)

describe("store cell rev", function()
  it("bumps a cell's rev on mutations to that cell only", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "a" })
    local b = st:insert_cell(2, { type = "code", source = "b" })
    local ra, rb = st:cell(a).rev, st:cell(b).rev
    assert.equal("number", type(ra))

    st:set_source(a, "a2")
    assert.truthy(st:cell(a).rev > ra)
    assert.equal(rb, st:cell(b).rev)

    -- the whole execution lifecycle bumps: queued, running, outputs, done
    ra = st:cell(a).rev
    st:run_cell(a)
    assert.truthy(st:cell(a).rev > ra)
    ra = st:cell(a).rev
    client:last().handlers.on_stream("stdout", "x")
    assert.truthy(st:cell(a).rev > ra)
    ra = st:cell(a).rev
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
    assert.truthy(st:cell(a).rev > ra)
    assert.equal(rb, st:cell(b).rev) -- b untouched throughout
  end)

  it("bumps queued cells backed out by an interrupt", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "a" })
    local b = st:insert_cell(2, { type = "code", source = "b" })
    st:run_cell(a)
    st:run_cell(b)
    local rb = st:cell(b).rev
    st:interrupt()
    assert.equal("idle", st:cell(b).state)
    assert.truthy(st:cell(b).rev > rb)
  end)
end)

describe("store output management", function()
  local function run_with_output(st, client, id)
    st:run_cell(id)
    client:last().handlers.on_stream("stdout", "out\n")
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
  end

  it("clears a cell's outputs and count", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x" })
    run_with_output(st, client, a)
    local rev = st:cell(a).rev
    st:clear_outputs(a)
    assert.equal(0, #st:cell(a).outputs)
    assert.is_nil(st:cell(a).execution_count)
    assert.truthy(st:cell(a).rev > rev)
  end)

  it("clears all outputs across the notebook", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x" })
    st:insert_cell(2, { type = "markdown", source = "prose" })
    local b = st:insert_cell(3, { type = "code", source = "y" })
    run_with_output(st, client, a)
    run_with_output(st, client, b)
    st:clear_all_outputs()
    assert.equal(0, #st:cell(a).outputs)
    assert.equal(0, #st:cell(b).outputs)
  end)

  it("toggles a cell's output fold", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x" })
    assert.falsy(st:cell(a).collapsed)
    st:toggle_output(a)
    assert.is_true(st:cell(a).collapsed)
    st:toggle_output(a)
    assert.is_false(st:cell(a).collapsed)
  end)
end)

describe("store stdin", function()
  it("parks an input request and answers it through the client reply", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "input('Name: ')" })
    st:run_cell(a)
    local answered
    client:last().handlers.on_input("Name: ", false, function(text)
      answered = text
    end)
    assert.is_not_nil(st.pending_input)
    assert.equal(a, st.pending_input.cell_id)
    assert.equal("Name: ", st.pending_input.prompt)
    assert.is_false(st.pending_input.password)

    st:answer_input("bob")
    assert.equal("bob", answered)
    assert.is_nil(st.pending_input)
  end)

  it("drops a stale input request when the execution settles", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "input()" })
    st:run_cell(a)
    client:last().handlers.on_input("? ", false, function() end)
    assert.is_not_nil(st.pending_input)
    -- interrupt: the kernel abandons the prompt and the execute settles
    client:last().handlers.on_done({ status = "error" })
    assert.is_nil(st.pending_input)
  end)
end)

describe("store restart", function()
  it("restarts the kernel, backing queued and running cells out", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "a" })
    local b = st:insert_cell(2, { type = "code", source = "b" })
    st:run_cell(a)
    st:run_cell(b)
    st:restart()
    assert.equal(1, client.restarts)
    assert.equal("idle", st:cell(a).state)
    assert.equal("idle", st:cell(b).state)
    -- the next run dispatches fresh — nothing stuck in the old queue
    st:run_cell(b)
    assert.equal(2, #client.executions)
    assert.equal("b", client:last().code)
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
