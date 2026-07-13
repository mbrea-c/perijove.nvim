-- The .ipynb round trip: decode nbformat 4 JSON into store-shaped cells plus
-- preserved bookkeeping, encode back with everything we don't own carried
-- through verbatim (cell ids, metadata, unknown fields, nbformat versions).
-- The emitted JSON matches nbformat's own style — sorted keys, indent 1 — so
-- diffs against jupyter-touched files stay minimal.

local ipynb = require("jotdown.ipynb")

local FIXTURE = [[
{
 "cells": [
  {
   "cell_type": "markdown",
   "id": "md-1",
   "metadata": {},
   "source": [
    "# Title\n",
    "prose"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": 3,
   "id": "code-1",
   "metadata": {"collapsed": true},
   "outputs": [
    {
     "name": "stdout",
     "output_type": "stream",
     "text": [
      "one\n",
      "two\n"
     ]
    },
    {
     "data": {
      "text/plain": [
       "42"
      ]
     },
     "execution_count": 3,
     "metadata": {},
     "output_type": "execute_result"
    },
    {
     "ename": "ValueError",
     "evalue": "boom",
     "output_type": "error",
     "traceback": ["tb line 1", "tb line 2"]
    }
   ],
   "source": [
    "print(1)\n",
    "42"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "id": "code-2",
   "metadata": {},
   "outputs": [],
   "source": "never_ran"
  },
  {
   "cell_type": "raw",
   "id": "raw-1",
   "metadata": {},
   "source": "raw text"
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}
]]

describe("ipynb.decode", function()
  it("maps cells to store shape, joining list sources", function()
    local doc = ipynb.decode(FIXTURE)
    assert.equal(4, #doc.cells)
    local md, code, code2, raw = doc.cells[1], doc.cells[2], doc.cells[3], doc.cells[4]
    assert.equal("markdown", md.type)
    assert.equal("# Title\nprose", md.source)
    assert.equal("code", code.type)
    assert.equal("print(1)\n42", code.source)
    assert.equal(3, code.execution_count)
    assert.is_nil(code2.execution_count) -- JSON null
    assert.equal("never_ran", code2.source) -- string source form
    assert.equal("raw", raw.type)
  end)

  it("maps outputs to the store's tagged kinds", function()
    local outs = ipynb.decode(FIXTURE).cells[2].outputs
    assert.same({ kind = "stream", name = "stdout", text = "one\ntwo\n" }, outs[1])
    assert.equal("result", outs[2].kind)
    assert.equal("42", outs[2].data["text/plain"])
    assert.equal("error", outs[3].kind)
    assert.equal("ValueError", outs[3].ename)
    assert.same({ "tb line 1", "tb line 2" }, outs[3].traceback)
  end)

  it("keeps per-cell bookkeeping (id, metadata) and notebook meta", function()
    local doc = ipynb.decode(FIXTURE)
    assert.equal("code-1", doc.cells[2].meta.id)
    assert.is_true(doc.cells[2].meta.metadata.collapsed)
    assert.equal("python3", doc.meta.metadata.kernelspec.name)
    assert.equal(4, doc.meta.nbformat)
    assert.equal(5, doc.meta.nbformat_minor)
  end)
end)

describe("ipynb.encode", function()
  local function reparse(doc)
    return vim.json.decode(ipynb.encode(doc.meta, doc.cells), { luanil = { object = false, array = false } })
  end

  it("round-trips the fixture semantically", function()
    local doc = ipynb.decode(FIXTURE)
    local nb = reparse(doc)
    assert.equal(4, #nb.cells)
    assert.equal("code-1", nb.cells[2].id)
    assert.equal("markdown", nb.cells[1].cell_type)
    assert.same({ "# Title\n", "prose" }, nb.cells[1].source)
    assert.same({ "print(1)\n", "42" }, nb.cells[2].source)
    assert.equal(3, nb.cells[2].execution_count)
    assert.equal(vim.NIL, nb.cells[3].execution_count) -- null preserved
    assert.equal("python3", nb.metadata.kernelspec.name)
    assert.equal(5, nb.nbformat_minor)
    -- outputs back in nbformat shape
    local outs = nb.cells[2].outputs
    assert.equal("stream", outs[1].output_type)
    assert.same({ "one\n", "two\n" }, outs[1].text)
    assert.equal("execute_result", outs[2].output_type)
    assert.equal(3, outs[2].execution_count)
    assert.equal("error", outs[3].output_type)
  end)

  it("gives brand-new cells a generated id and empty metadata", function()
    local doc = ipynb.decode(FIXTURE)
    table.insert(doc.cells, { type = "code", source = "new()", outputs = {} })
    local nb = reparse(doc)
    local cell = nb.cells[5]
    assert.equal("code", cell.cell_type)
    assert.truthy(type(cell.id) == "string" and #cell.id > 0)
    assert.equal(vim.NIL, cell.execution_count)
    assert.same({ "new()" }, cell.source)
  end)

  it("emits nbformat style: sorted keys, indent 1, {} vs [] preserved", function()
    local doc = ipynb.decode(FIXTURE)
    local text = ipynb.encode(doc.meta, doc.cells)
    -- indent-1 style, like nbformat's json.dumps(indent=1, sort_keys=True)
    assert.truthy(text:find('{\n "cells": [\n', 1, true))
    -- sorted: "cell_type" before "id" before "metadata" before "source"
    local a = text:find('"cell_type": "markdown"', 1, true)
    local b = text:find('"id": "md-1"', 1, true)
    assert.truthy(a and b and a < b)
    -- empty containers keep their JSON type
    assert.truthy(text:find('"outputs": []', 1, true)) -- code-2's empty list
    assert.truthy(text:find('"metadata": {}', 1, true)) -- empty dicts stay dicts
  end)

  it("preserves unknown output types verbatim", function()
    local doc = ipynb.decode([[
{
 "cells": [
  {
   "cell_type": "code",
   "execution_count": 1,
   "id": "c",
   "metadata": {},
   "outputs": [
    {"output_type": "update_display_data", "data": {"text/plain": ["x"]}, "metadata": {}, "transient": {"display_id": "d1"}}
   ],
   "source": "x"
  }
 ],
 "metadata": {},
 "nbformat": 4,
 "nbformat_minor": 5
}
]])
    assert.equal("unknown", doc.cells[1].outputs[1].kind)
    local nb = vim.json.decode(ipynb.encode(doc.meta, doc.cells))
    assert.equal("update_display_data", nb.cells[1].outputs[1].output_type)
    assert.equal("d1", nb.cells[1].outputs[1].transient.display_id)
  end)
end)

describe("ipynb.new_meta", function()
  it("makes a valid empty-notebook skeleton", function()
    local text = ipynb.encode(ipynb.new_meta(), {})
    local nb = vim.json.decode(text)
    assert.equal(4, nb.nbformat)
    assert.truthy(text:find('"cells": []', 1, true))
    assert.truthy(text:find('"metadata": {}', 1, true))
  end)
end)
