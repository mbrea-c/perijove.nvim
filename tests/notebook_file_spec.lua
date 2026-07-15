-- The .ipynb entrypoint: opening a notebook file mounts the UI over its
-- window; :w — from the notebook, from a focused cell buffer, from anywhere
-- — serializes the store back to nbformat and writes the FILE; <C-j>t
-- toggles down to the raw JSON and back. Driven with a fake client, so no
-- kernel is involved (and none may be: opening must never boot one).

local notebook_file = require("perijove.notebook_file")
local fake_client = require("tests.fake_client")

local FIXTURE = vim.json.encode({
  cells = {
    { cell_type = "markdown", id = "md-1", metadata = vim.empty_dict(), source = { "# NbTitle" } },
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "code-1",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "print('from file')" },
    },
  },
  metadata = vim.empty_dict(),
  nbformat = 4,
  nbformat_minor = 5,
})

local function write_fixture()
  local path = vim.fn.tempname() .. ".ipynb"
  vim.fn.writefile(vim.split(FIXTURE, "\n"), path)
  return path
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- the visible text of whatever is showing in the current window
local function visible_text()
  return buf_text(vim.api.nvim_win_get_buf(0))
end

local function open_fixture()
  local path = write_fixture()
  vim.cmd("edit " .. path)
  local bufnr = vim.api.nvim_get_current_buf()
  local sess = notebook_file.open(bufnr, { client = fake_client.new() })
  return path, bufnr, sess
end

local function cleanup(bufnr)
  notebook_file.close(bufnr)
  vim.cmd("silent! bwipeout! " .. bufnr)
end

describe("notebook_file open", function()
  it("mounts the notebook view over the file's window", function()
    local _, bufnr, sess = open_fixture()
    local text = buf_text(sess.handle.bufnr)
    assert.truthy(text:find("NbTitle", 1, true))
    assert.truthy(text:find("print('from file')", 1, true))
    cleanup(bufnr)
  end)

  it("marks the file buffer modified when the store changes", function()
    local _, bufnr, sess = open_fixture()
    assert.is_false(vim.bo[bufnr].modified)
    sess.store:set_source(sess.store.cells[2].id, "edited = True")
    assert.is_true(vim.bo[bufnr].modified)
    cleanup(bufnr)
  end)
end)

describe("notebook_file save", function()
  it(":w on the notebook serializes cell-buffer edits to the file", function()
    local path, bufnr, sess = open_fixture()
    -- edit the code cell through its real buffer, like a user would
    local cellbuf
    sess.actions.current.each_cell_buf(function(b)
      cellbuf = b
    end)
    vim.api.nvim_buf_set_lines(cellbuf, 0, -1, false, { "answer = 42" })

    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)

    local on_disk = table.concat(vim.fn.readfile(path), "\n")
    assert.truthy(on_disk:find("answer = 42", 1, true))
    assert.truthy(on_disk:find('"id": "code-1"', 1, true)) -- fidelity kept
    assert.is_false(vim.bo[bufnr].modified)
    assert.is_false(vim.bo[cellbuf].modified)
    cleanup(bufnr)
  end)

  it(":w inside a cell sub-buffer saves the whole notebook", function()
    local path, bufnr, sess = open_fixture()
    local cellbuf
    sess.actions.current.each_cell_buf(function(b)
      cellbuf = b
    end)
    vim.api.nvim_buf_set_lines(cellbuf, 0, -1, false, { "cell_written = 1" })
    vim.api.nvim_buf_call(cellbuf, function()
      vim.cmd("silent write")
    end)
    local on_disk = table.concat(vim.fn.readfile(path), "\n")
    assert.truthy(on_disk:find("cell_written = 1", 1, true))
    assert.is_false(vim.bo[bufnr].modified)
    cleanup(bufnr)
  end)
end)

describe("notebook_file toggle", function()
  it("drops to current raw JSON and mounts back, keeping the store", function()
    local _, bufnr, sess = open_fixture()
    local store_before = sess.store
    sess.store:set_source(sess.store.cells[2].id, "toggled = True")

    notebook_file.toggle(bufnr)
    -- the raw view reflects the CURRENT store, not the stale file
    assert.truthy(visible_text():find('"cells"', 1, true))
    assert.truthy(visible_text():find("toggled = True", 1, true))

    notebook_file.toggle(bufnr)
    assert.truthy(buf_text(sess.handle.bufnr):find("NbTitle", 1, true))
    assert.rawequal(store_before, sess.store) -- same store: outputs/kernel kept
    cleanup(bufnr)
  end)

  it("re-parses when the raw JSON was edited while toggled", function()
    local _, bufnr, sess = open_fixture()
    notebook_file.toggle(bufnr)
    local raw = buf_text(bufnr):gsub("from file", "edited raw")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(raw, "\n"))
    notebook_file.toggle(bufnr)
    assert.truthy(buf_text(sess.handle.bufnr):find("edited raw", 1, true))
    cleanup(bufnr)
  end)
end)
