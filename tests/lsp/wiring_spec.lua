-- The notebook LSP session wired through the file layer: open starts it over
-- the store, the view's cell buffers register as they materialize (so edits
-- stream), save notifies, toggle-with-raw-edits rebuilds the session over the
-- fresh store, close closes. The LSP client is a recorder injected through
-- the lsp module's client_factory seam; the kernel client is the usual fake.

local notebook_file = require("perijove.notebook_file")
local perijove = require("perijove")
local lsp = require("perijove.lsp")
local ldoc = require("perijove.lsp.doc")
local fake_kernel = require("tests.fake_client")

local FIXTURE = vim.json.encode({
  cells = {
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "a",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "x = 1" },
    },
    { cell_type = "markdown", id = "b", metadata = vim.empty_dict(), source = { "# notes" } },
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "c",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "print(x)" },
    },
  },
  metadata = vim.empty_dict(),
  nbformat = 4,
  nbformat_minor = 5,
})

local clients

local function fake_lsp_client()
  local c = {
    initialized = true,
    offset_encoding = "utf-16",
    server_capabilities = { notebookDocumentSync = { notebookSelector = {} } },
    sent = {},
  }
  function c:notify(method, params)
    table.insert(self.sent, { method = method, params = params })
    return true
  end
  function c:request(method, params)
    table.insert(self.sent, { method = method, params = params })
    return true, #self.sent
  end
  table.insert(clients, c)
  return c
end

local function sent(client, method)
  local out = {}
  for _, msg in ipairs(client.sent) do
    if msg.method == method then
      out[#out + 1] = msg.params
    end
  end
  return out
end

local function open_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/nb.ipynb"
  vim.fn.writefile(vim.split(FIXTURE, "\n"), path)
  vim.cmd("edit " .. path)
  local bufnr = vim.api.nvim_get_current_buf()
  local sess = notebook_file.open(bufnr, { client = fake_kernel.new() })
  return bufnr, sess, path
end

local function cleanup(bufnr)
  notebook_file.close(bufnr)
  vim.cmd("silent! bwipeout! " .. bufnr)
end

describe("lsp wiring", function()
  before_each(function()
    clients = {}
    perijove._reset_config()
    lsp.configure({ client_factory = fake_lsp_client })
  end)

  after_each(function()
    lsp.configure({})
  end)

  it("open starts a session: didOpen with the file's code cells", function()
    local bufnr, _, path = open_fixture()
    assert.equal(1, #clients)
    local opens = sent(clients[1], "notebookDocument/didOpen")
    assert.equal(1, #opens)
    assert.equal(vim.uri_from_fname(path), opens[1].notebookDocument.uri)
    assert.same({ "x = 1", "print(x)" }, {
      opens[1].cellTextDocuments[1].text,
      opens[1].cellTextDocuments[2].text,
    })
    cleanup(bufnr)
  end)

  it("cell buffers register: an edit streams didChange", function()
    local bufnr, sess = open_fixture()
    local id = sess.store.cells[1].id
    local cell_buf = sess.lsp.bufs[id]
    assert.is_not_nil(cell_buf)
    vim.api.nvim_buf_set_lines(cell_buf, 0, -1, false, { "x = 99" })
    assert.is_true(vim.wait(1000, function()
      return #sent(clients[1], "notebookDocument/didChange") > 0
    end))
    local change = sent(clients[1], "notebookDocument/didChange")[1].change
    assert.same({ { text = "x = 99" } }, change.cells.textContent[1].changes)
    assert.equal(ldoc.uri_of(sess.lsp.doc, id), change.cells.textContent[1].document.uri)
    cleanup(bufnr)
  end)

  it("save notifies didSave", function()
    local bufnr = open_fixture()
    notebook_file.save(bufnr)
    assert.equal(1, #sent(clients[1], "notebookDocument/didSave"))
    cleanup(bufnr)
  end)

  it("toggle with raw edits rebuilds the session over the fresh store", function()
    local bufnr = open_fixture()
    notebook_file.toggle(bufnr) -- down to raw json
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "" }) -- any raw edit
    vim.cmd("silent undo") -- content back, changedtick moved: re-parse path
    notebook_file.toggle(bufnr) -- back up: fresh store
    assert.equal(1, #sent(clients[1], "notebookDocument/didClose"))
    assert.equal(2, #clients)
    assert.equal(1, #sent(clients[2], "notebookDocument/didOpen"))
    cleanup(bufnr)
  end)

  it("close closes the session", function()
    local bufnr = open_fixture()
    cleanup(bufnr)
    assert.equal(1, #sent(clients[1], "notebookDocument/didClose"))
  end)
end)
