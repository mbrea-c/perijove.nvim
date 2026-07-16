-- perijove.lsp.doc: pure bookkeeping for ONE notebook document under LSP 3.17
-- notebookDocument synchronization. It allocates cell URIs, tracks notebook and
-- cell text document versions, and builds the didOpen/didChange/didSave/didClose
-- payloads. No vim.lsp, no client: the session manager owns the wire.

local doc = require("perijove.lsp.doc")

local NB = "file:///tmp/proj/nb.ipynb"

local function cell(id, text)
  return { id = id, text = text or ("# " .. id) }
end

describe("lsp.doc", function()
  describe("open", function()
    it("builds didOpen with cell text documents", function()
      local d = doc.new(NB)
      local p = doc.open_params(d, { cell("c1", "x = 1"), cell("c2", "print(x)") })
      assert.equal(NB, p.notebookDocument.uri)
      assert.equal("jupyter-notebook", p.notebookDocument.notebookType)
      assert.equal(0, p.notebookDocument.version)
      assert.equal(2, #p.notebookDocument.cells)
      -- kind 2 = Code; the document field is the cell's own URI
      assert.equal(2, p.notebookDocument.cells[1].kind)
      assert.equal(doc.uri_of(d, "c1"), p.notebookDocument.cells[1].document)
      assert.same({
        { uri = doc.uri_of(d, "c1"), languageId = "python", version = 0, text = "x = 1" },
        { uri = doc.uri_of(d, "c2"), languageId = "python", version = 0, text = "print(x)" },
      }, p.cellTextDocuments)
    end)

    it("allocates cell URIs on the notebook path, fragment-tagged by cell id", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1") })
      local uri = doc.uri_of(d, "c1")
      assert.equal("vscode-notebook-cell:///tmp/proj/nb.ipynb#c1", uri)
    end)
  end)

  describe("structure changes", function()
    it("is nil when the cell sequence is unchanged", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1"), cell("c2") })
      assert.is_nil(doc.change_structure(d, { cell("c1"), cell("c2") }))
      assert.equal(0, d.version)
    end)

    it("appending a cell splices it in and opens its text document", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1"), cell("c2") })
      local p = doc.change_structure(d, { cell("c1"), cell("c2"), cell("c3", "y = 2") })
      assert.equal(1, p.notebookDocument.version)
      local s = p.change.cells.structure
      assert.equal(2, s.array.start)
      assert.equal(0, s.array.deleteCount)
      assert.same({ { kind = 2, document = doc.uri_of(d, "c3") } }, s.array.cells)
      assert.same({ { uri = doc.uri_of(d, "c3"), languageId = "python", version = 0, text = "y = 2" } }, s.didOpen)
      assert.is_nil(s.didClose)
    end)

    it("removing a cell splices it out and closes its text document", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1"), cell("c2"), cell("c3") })
      local gone = doc.uri_of(d, "c2")
      local p = doc.change_structure(d, { cell("c1"), cell("c3") })
      local s = p.change.cells.structure
      assert.equal(1, s.array.start)
      assert.equal(1, s.array.deleteCount)
      assert.is_nil(s.array.cells)
      assert.is_nil(s.didOpen)
      assert.same({ { uri = gone } }, s.didClose)
    end)

    it("a move is one splice with no opens or closes", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1"), cell("c2"), cell("c3") })
      local p = doc.change_structure(d, { cell("c2"), cell("c1"), cell("c3") })
      local s = p.change.cells.structure
      assert.equal(0, s.array.start)
      assert.equal(2, s.array.deleteCount)
      assert.same({
        { kind = 2, document = doc.uri_of(d, "c2") },
        { kind = 2, document = doc.uri_of(d, "c1") },
      }, s.array.cells)
      assert.is_nil(s.didOpen)
      assert.is_nil(s.didClose)
    end)
  end)

  describe("text changes", function()
    it("sends the full text and bumps both versions", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1", "x = 1") })
      local p = doc.change_text(d, "c1", "x = 2")
      assert.equal(1, p.notebookDocument.version)
      assert.same({
        {
          document = { uri = doc.uri_of(d, "c1"), version = 1 },
          changes = { { text = "x = 2" } },
        },
      }, p.change.cells.textContent)
      local p2 = doc.change_text(d, "c1", "x = 3")
      assert.equal(2, p2.notebookDocument.version)
      assert.equal(2, p2.change.cells.textContent[1].document.version)
    end)

    it("is nil for a cell the document does not hold", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1") })
      assert.is_nil(doc.change_text(d, "nope", "y"))
    end)
  end)

  describe("save and close", function()
    it("didSave names the notebook", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1") })
      assert.same({ notebookDocument = { uri = NB } }, doc.save_params(d))
    end)

    it("didClose lists the cell text documents still open", function()
      local d = doc.new(NB)
      doc.open_params(d, { cell("c1"), cell("c2") })
      doc.change_structure(d, { cell("c1") })
      assert.same({
        notebookDocument = { uri = NB },
        cellTextDocuments = { { uri = doc.uri_of(d, "c1") } },
      }, doc.close_params(d))
    end)
  end)
end)
