-- The MCP surface: live notebooks as tools for external agents. The protocol
-- host (JSON-RPC, shim, tools/list) lives in the separate clankbox plugin;
-- perijove only PROVIDES tool defs, planted via register_into(). Specs drive
-- the handlers through a fake server table, against a real session over the
-- fake kernel client — no network, no shim, no clankbox dependency.

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

-- a clankbox shaped server, reduced to what the tools touch
local function fake_server()
  local srv = { tools = {} }
  function srv.register_tool(name, def)
    srv.tools[name] = def
  end
  return srv
end

local server = fake_server()
mcp.register_into(server)

-- what the host does with a call: pcall the handler, report text + isError
local function call(name, arguments)
  local def = server.tools[name]
  assert.is_not_nil(def)
  local ok, ret = pcall(def.handler, arguments or {})
  return tostring(ret), not ok
end

describe("mcp registration", function()
  it("registers every notebook tool with a description and an object schema", function()
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
      local def = server.tools[name]
      assert.is_not_nil(def, name)
      assert.equal("object", def.inputSchema.type)
      assert.truthy(#def.description > 0)
    end
  end)

  it("a failing tool raises; the host turns that into an isError result", function()
    -- no notebook open at all
    local text, is_error = call("notebook_cells", {})
    assert.is_true(is_error)
    assert.truthy(text:find("no notebook", 1, true))
  end)

  it("setup() plants the tools into an installed clankbox", function()
    local fake = fake_server()
    package.loaded["clankbox"] = fake
    require("perijove").setup({ auto_open = false })
    package.loaded["clankbox"] = nil
    require("perijove")._reset_config()
    assert.is_not_nil(fake.tools.notebook_list)
    assert.is_not_nil(fake.tools.notebook_save)
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

    -- markdown cells refuse to run, as a raised (tool) error
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
