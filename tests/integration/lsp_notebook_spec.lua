-- END-TO-END notebook LSP: a real basedpyright over stdio, driven through
-- the real vim.lsp client and perijove's notebookDocument synchronization.
-- The point being proven is CROSS-CELL semantics: a name defined in cell 1
-- resolves in cell 2 (no false undefined-variable), an actually undefined
-- name is flagged, and editing cell 1 re-analyzes cell 2. Skipped (loudly)
-- when basedpyright-langserver isn't on PATH; the nix devShell and the
-- flake check both provide it.

if vim.fn.executable("basedpyright-langserver") == 0 then
  io.write("[skip] integration: basedpyright-langserver not on PATH\n")
  return
end

local notebook_file = require("perijove.notebook_file")
local lsp = require("perijove.lsp")
local fake_kernel = require("tests.fake_client")

local FIXTURE = vim.json.encode({
  cells = {
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "def",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "x = 1" },
    },
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "use",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "print(x)", "totally_undefined_name" },
    },
  },
  metadata = vim.empty_dict(),
  nbformat = 4,
  nbformat_minor = 5,
})

local function messages(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    out[#out + 1] = d.message
  end
  return table.concat(out, " | ")
end

describe("integration: notebook LSP (basedpyright)", function()
  it("resolves names across cells and re-analyzes on edit", function()
    lsp.configure({ cmd = { "basedpyright-langserver", "--stdio" } })
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/nb.ipynb"
    vim.fn.writefile(vim.split(FIXTURE, "\n"), path)
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    local sess = notebook_file.open(bufnr, { client = fake_kernel.new() })
    assert.is_not_nil(sess.lsp)

    local def_buf = sess.lsp.bufs[sess.store.cells[1].id]
    local use_buf = sess.lsp.bufs[sess.store.cells[2].id]
    assert.is_not_nil(def_buf)
    assert.is_not_nil(use_buf)

    -- the undefined name is flagged, on the RIGHT cell's buffer
    assert.is_true(
      vim.wait(120000, function()
        return messages(use_buf):find("totally_undefined_name", 1, true) ~= nil
      end, 200),
      "no diagnostic for the undefined name; got: " .. messages(use_buf)
    )
    -- and x, defined one cell up, resolved: cross-cell analysis works
    assert.is_nil(messages(use_buf):find('"x"', 1, true))

    -- cross-cell invalidation: remove the definition, cell 2 re-analyzes
    vim.api.nvim_buf_set_lines(def_buf, 0, -1, false, { "y = 1" })
    assert.is_true(
      vim.wait(120000, function()
        return messages(use_buf):find('"x"', 1, true) ~= nil
      end, 200),
      "no diagnostic after removing the definition; got: " .. messages(use_buf)
    )

    notebook_file.close(bufnr)
    lsp.configure({})
    for _, client in ipairs(vim.lsp.get_clients({ name = "perijove-notebook-ls" })) do
      client:stop(true)
    end
    vim.cmd("silent! bwipeout! " .. bufnr)
  end)
end)
