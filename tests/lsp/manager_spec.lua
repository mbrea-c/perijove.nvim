-- perijove.lsp session manager, hermetic: a fake LSP client records every
-- notification; the store and the cell buffers are real. What is pinned here:
-- didOpen mirrors the store's CODE cells, buffer edits stream full-text
-- didChange (coalesced per loop tick), store structure mutations become
-- structure didChange, retype opens/closes the cell's text document, and
-- notifications queue until the client reports initialized.

local lsp = require("perijove.lsp")
local doc = require("perijove.lsp.doc")
local store_mod = require("perijove.store")

local function fake_lsp_client()
  return {
    initialized = true,
    offset_encoding = "utf-16",
    server_capabilities = { notebookDocumentSync = { notebookSelector = {} } },
    sent = {},
    notify = function(self, method, params)
      table.insert(self.sent, { method = method, params = params })
      return true
    end,
    request = function(self, method, params)
      table.insert(self.sent, { method = method, params = params })
      return true, #self.sent
    end,
  }
end

-- the store's kernel client: never dialed here
local kernel_stub = { attach = function() end }

local function new_store(cells)
  local st = store_mod.new(kernel_stub)
  for i, c in ipairs(cells) do
    st:insert_cell(i, c)
  end
  return st
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

local function make_buf(text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  return buf
end

describe("lsp manager", function()
  local client, session

  local function attach(cells)
    local store = new_store(cells)
    client = fake_lsp_client()
    session = lsp.attach({ store = store, path = "/tmp/proj/nb.ipynb", client = client })
    return store
  end

  after_each(function()
    if session then
      session:close()
      session = nil
    end
  end)

  it("didOpen carries the code cells only, text from the store", function()
    attach({
      { type = "code", source = "x = 1" },
      { type = "markdown", source = "# notes" },
      { type = "code", source = "print(x)" },
    })
    local opens = sent(client, "notebookDocument/didOpen")
    assert.equal(1, #opens)
    assert.equal("file:///tmp/proj/nb.ipynb", opens[1].notebookDocument.uri)
    assert.equal(2, #opens[1].notebookDocument.cells)
    assert.same({ "x = 1", "print(x)" }, {
      opens[1].cellTextDocuments[1].text,
      opens[1].cellTextDocuments[2].text,
    })
  end)

  it("a cell buffer edit streams a full-text didChange", function()
    local store = attach({ { type = "code", source = "x = 1" } })
    local id = store.cells[1].id
    local buf = make_buf("x = 1")
    session:register_buf(id, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x = 2" })
    assert.is_true(vim.wait(1000, function()
      return #sent(client, "notebookDocument/didChange") > 0
    end))
    local change = sent(client, "notebookDocument/didChange")[1].change
    assert.same({ { text = "x = 2" } }, change.cells.textContent[1].changes)
    assert.equal(doc.uri_of(session.doc, id), change.cells.textContent[1].document.uri)
  end)

  it("several edits in one tick coalesce into one didChange", function()
    local store = attach({ { type = "code", source = "" } })
    local buf = make_buf("")
    session:register_buf(store.cells[1].id, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a" })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ab" })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
    vim.wait(200, function()
      return #sent(client, "notebookDocument/didChange") > 0
    end)
    vim.wait(50) -- nothing else should trickle in
    local changes = sent(client, "notebookDocument/didChange")
    assert.equal(1, #changes)
    assert.same({ { text = "abc" } }, changes[1].change.cells.textContent[1].changes)
  end)

  it("inserting a store cell sends a structure change opening its document", function()
    local store = attach({ { type = "code", source = "x = 1" } })
    store:insert_cell(2, { type = "code", source = "y = 2" })
    local changes = sent(client, "notebookDocument/didChange")
    assert.equal(1, #changes)
    local s = changes[1].change.cells.structure
    assert.equal(1, s.array.start)
    assert.equal(0, s.array.deleteCount)
    assert.equal("y = 2", s.didOpen[1].text)
  end)

  it("deleting a store cell sends a structure change closing its document", function()
    local store = attach({
      { type = "code", source = "x = 1" },
      { type = "code", source = "y = 2" },
    })
    local gone = doc.uri_of(session.doc, store.cells[2].id)
    store:delete_cell(store.cells[2].id)
    local s = sent(client, "notebookDocument/didChange")[1].change.cells.structure
    assert.equal(1, s.array.deleteCount)
    assert.same({ { uri = gone } }, s.didClose)
  end)

  it("retype closes and reopens the cell's text document", function()
    local store = attach({ { type = "code", source = "x = 1" } })
    local id = store.cells[1].id
    store:set_type(id, "markdown")
    local first = sent(client, "notebookDocument/didChange")[1].change.cells.structure
    assert.is_not_nil(first.didClose)
    store:set_type(id, "code")
    local second = sent(client, "notebookDocument/didChange")[2].change.cells.structure
    assert.equal("x = 1", second.didOpen[1].text)
  end)

  it("did_save and close notify, and a closed session goes quiet", function()
    local store = attach({ { type = "code", source = "x = 1" } })
    session:did_save()
    assert.equal(1, #sent(client, "notebookDocument/didSave"))
    session:close()
    assert.equal(1, #sent(client, "notebookDocument/didClose"))
    local before = #client.sent
    store:insert_cell(2, { type = "code", source = "y" })
    assert.equal(before, #client.sent)
    session = nil
  end)

  it("notifications queue until the client is initialized", function()
    local store = new_store({ { type = "code", source = "x = 1" } })
    client = fake_lsp_client()
    client.initialized = false
    session = lsp.attach({ store = store, path = "/tmp/proj/nb.ipynb", client = client })
    store:insert_cell(2, { type = "code", source = "y" })
    assert.equal(0, #client.sent)
    client.initialized = true
    assert.is_true(vim.wait(1000, function()
      return #client.sent == 2
    end))
    assert.equal("notebookDocument/didOpen", client.sent[1].method)
    assert.equal("notebookDocument/didChange", client.sent[2].method)
  end)

  it("pulls textDocument/diagnostic for registered cells after a sync", function()
    local store = attach({ { type = "code", source = "x = 1" } })
    local id = store.cells[1].id
    session:register_buf(id, make_buf("x = 1"))
    store:insert_cell(2, { type = "code", source = "y" })
    assert.is_true(vim.wait(1000, function()
      return #sent(client, "textDocument/diagnostic") > 0
    end))
    assert.equal(doc.uri_of(session.doc, id), sent(client, "textDocument/diagnostic")[1].textDocument.uri)
  end)

  it("hover asks with the CELL uri at the cursor position", function()
    local store = attach({ { type = "code", source = "print(1)" } })
    local id = store.cells[1].id
    local buf = make_buf("print(1)")
    session:register_buf(id, buf)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    lsp.hover()
    local reqs = sent(client, "textDocument/hover")
    assert.equal(1, #reqs)
    assert.equal(doc.uri_of(session.doc, id), reqs[1].textDocument.uri)
    assert.same({ line = 0, character = 2 }, reqs[1].position)
  end)
end)
