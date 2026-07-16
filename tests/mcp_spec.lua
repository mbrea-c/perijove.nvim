-- The MCP surface: live notebooks as tools for external agents. Driven
-- entirely through handle() (what the stdio shim forwards), against a real
-- session over the fake kernel client — no network, no shim process.

local notebook_file = require("perijove.notebook_file")
local mcp = require("perijove.mcp")
local fake_client = require("tests.fake_client")

local FIXTURE = vim.json.encode({
  cells = {
    { cell_type = "markdown", id = "md-1", metadata = vim.empty_dict(), source = { "# McpTitle" } },
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "c2",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "print('hello mcp')" },
    },
  },
  metadata = vim.empty_dict(),
  nbformat = 4,
  nbformat_minor = 5,
})

local function open_fixture()
  local path = vim.fn.tempname() .. ".ipynb"
  vim.fn.writefile(vim.split(FIXTURE, "\n"), path)
  vim.cmd("edit " .. path)
  local bufnr = vim.api.nvim_get_current_buf()
  local sess = notebook_file.open(bufnr, { client = fake_client.new() })
  return path, bufnr, sess
end

local function cleanup(bufnr)
  notebook_file.close(bufnr)
  vim.cmd("silent! bwipeout! " .. bufnr)
end

local next_id = 0
local function call(name, arguments)
  next_id = next_id + 1
  local res = mcp.handle({
    jsonrpc = "2.0",
    id = next_id,
    method = "tools/call",
    params = { name = name, arguments = arguments },
  })
  assert.is_nil(res.error)
  return res.result.content[1].text, res.result.isError
end

describe("mcp protocol", function()
  it("initialize advertises the tools capability", function()
    local res = mcp.handle({ jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
    assert.equal("2025-06-18", res.result.protocolVersion)
    assert.equal("perijove-mcp", res.result.serverInfo.name)
  end)

  it("tools/list carries every notebook tool with a schema", function()
    local res = mcp.handle({ jsonrpc = "2.0", id = 2, method = "tools/list" })
    local by_name = {}
    for _, t in ipairs(res.result.tools) do
      by_name[t.name] = t
    end
    for _, name in ipairs({
      "notebook_list",
      "notebook_cells",
      "notebook_read_cell",
      "notebook_edit_cell",
      "notebook_insert_cell",
      "notebook_delete_cell",
      "notebook_run_cell",
      "notebook_save",
    }) do
      assert.is_not_nil(by_name[name], name)
      assert.equal("object", by_name[name].inputSchema.type)
    end
  end)

  it("unknown methods and tools error per spec; notifications stay silent", function()
    local res = mcp.handle({ jsonrpc = "2.0", id = 3, method = "no/such" })
    assert.equal(-32601, res.error.code)
    res = mcp.handle({ jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "nope" } })
    assert.equal(-32602, res.error.code)
    assert.is_nil(mcp.handle({ jsonrpc = "2.0", method = "notifications/initialized" }))
  end)

  it("a failing tool is an isError result, not a protocol error", function()
    -- no notebook open at all
    local text, is_error = call("notebook_cells", {})
    assert.is_true(is_error)
    assert.truthy(text:find("no notebook", 1, true))
  end)
end)

describe("mcp notebook tools", function()
  it("lists, reads and edits the live notebook (view included)", function()
    local _, bufnr, sess = open_fixture()

    local text = call("notebook_list", {})
    assert.truthy(text:find("2 cells", 1, true))

    text = call("notebook_cells", {})
    assert.truthy(text:find("c1", 1, true))
    assert.truthy(text:find("hello mcp", 1, true))

    text = call("notebook_read_cell", { cell = 2 })
    assert.truthy(text:find("print('hello mcp')", 1, true))

    -- edit by STORE id (what notebook_cells lists; nbformat ids ride in cell.meta)
    call("notebook_edit_cell", { cell = "c2", source = "agent_was_here = 1" })
    assert.equal("agent_was_here = 1", sess.store:cell("c2").source)
    assert.truthy(
      table.concat(vim.api.nvim_buf_get_lines(sess.handle.bufnr, 0, -1, false), "\n"):find("agent_was_here", 1, true)
    )
    assert.is_true(vim.bo[bufnr].modified) -- unsaved, honestly

    cleanup(bufnr)
  end)

  it("inserts and deletes cells", function()
    local _, bufnr, sess = open_fixture()

    local text = call("notebook_insert_cell", { source = "appended = 1" })
    assert.truthy(text:find("index 3", 1, true))
    assert.equal("appended = 1", sess.store.cells[3].source)

    call("notebook_delete_cell", { cell = 3 })
    assert.equal(2, #sess.store.cells)

    cleanup(bufnr)
  end)

  it("runs a cell and reports settled state with outputs", function()
    local _, bufnr, sess = open_fixture()
    local client = sess.client

    local text = call("notebook_run_cell", { cell = 2, timeout_ms = 0 })
    assert.truthy(text:find("state: running", 1, true))

    -- the kernel answers; a later read shows the outputs
    local exec = client:last()
    exec.handlers.on_stream("stdout", "hello mcp\n")
    exec.handlers.on_done({ status = "ok", execution_count = 7 })
    text = call("notebook_read_cell", { cell = "c2" })
    assert.truthy(text:find("state: ok", 1, true))
    assert.truthy(text:find("hello mcp", 1, true))

    -- markdown cells refuse to run, as a tool error
    local err, is_error = call("notebook_run_cell", { cell = 1 })
    assert.is_true(is_error)
    assert.truthy(err:find("markdown", 1, true))

    cleanup(bufnr)
  end)

  it("saves through the notebook save path", function()
    local path, bufnr = open_fixture()
    call("notebook_edit_cell", { cell = "c2", source = "saved_by_agent = 1" })
    local text = call("notebook_save", {})
    assert.truthy(text:find("saved", 1, true))
    assert.truthy(table.concat(vim.fn.readfile(path), "\n"):find("saved_by_agent = 1", 1, true))
    assert.is_false(vim.bo[bufnr].modified)
    cleanup(bufnr)
  end)

  it("resolves notebooks by path suffix and errors helpfully on ambiguity", function()
    local path_a, buf_a = open_fixture()
    vim.cmd("botright vnew")
    local path_b, buf_b = open_fixture()

    -- two notebooks, no selector: a helpful error listing both
    local text, is_error = call("notebook_cells", {})
    assert.is_true(is_error)
    assert.truthy(text:find("several notebooks", 1, true))

    -- path suffix picks one
    text = call("notebook_cells", { notebook = vim.fn.fnamemodify(path_a, ":t") })
    assert.truthy(text:find("c1", 1, true))
    text = call("notebook_cells", { notebook = buf_b })
    assert.truthy(text:find("c1", 1, true))

    cleanup(buf_b)
    cleanup(buf_a)
    vim.cmd("silent! only")
    local _ = path_b
  end)
end)
