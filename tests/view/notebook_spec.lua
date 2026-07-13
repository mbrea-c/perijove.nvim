-- The notebook view: a fibrous document projecting the store — kernel status
-- line, markdown cells rendered rich, code cells as render="focus"
-- raw_buffers (the unfocused mirror paints their text into the root buffer),
-- outputs beneath each cell. Driven end to end through the fake client.

local mount = require("fibrous.inline.mount")

local store = require("jotdown.store")
local fake_client = require("tests.fake_client")
local notebook = require("jotdown.view.notebook")

local function trimmed(bufnr)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

local function text_of(bufnr)
  return table.concat(trimmed(bufnr), "\n")
end

local function mount_nb(st)
  return mount.floating(notebook.Notebook, { store = st }, { width = 60, height = 24, mode = "scroll" })
end

local function new_pair()
  local client = fake_client.new()
  return store.new(client), client
end

describe("view.notebook", function()
  it("renders kernel status, markdown cells, and code cell mirrors", function()
    local st = new_pair()
    st:insert_cell(1, { type = "markdown", source = "# Big Title" })
    st:insert_cell(2, { type = "code", source = 'print("hi")' })
    local handle = mount_nb(st)
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("kernel: unknown", 1, true))
    assert.truthy(text:find("Big Title", 1, true)) -- markdown rendered
    assert.truthy(text:find('print("hi")', 1, true)) -- raw_buffer mirror
    assert.truthy(text:find("In [ ]", 1, true)) -- unexecuted marker
    handle.unmount()
  end)

  it("live-updates: outputs stream in and the count lands on done", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x" })
    local handle = mount_nb(st)

    st:run_cell(a)
    local h = client:last().handlers
    h.on_stream("stdout", "part one, ")
    h.on_stream("stdout", "part two\n")
    assert.truthy(text_of(handle.bufnr):find("part one, part two", 1, true))

    h.on_result({ ["text/plain"] = "42" }, {})
    h.on_done({ status = "ok", execution_count = 3 })
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("42", 1, true))
    assert.truthy(text:find("In [3]", 1, true))
    handle.unmount()
  end)

  it("renders error outputs with name and traceback", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "boom()" })
    local handle = mount_nb(st)
    st:run_cell(a)
    client:last().handlers.on_error("ValueError", "boom", { "Traceback:", "ValueError: boom" })
    client:last().handlers.on_done({ status = "error", execution_count = 1 })
    local text = text_of(handle.bufnr)
    assert.truthy(text:find("ValueError: boom", 1, true))
    assert.truthy(text:find("Traceback:", 1, true))
    handle.unmount()
  end)

  it("tracks kernel status changes", function()
    local st, client = new_pair()
    st:insert_cell(1, { type = "code", source = "x" })
    local handle = mount_nb(st)
    client:push_status("busy")
    assert.truthy(text_of(handle.bufnr):find("kernel: busy", 1, true))
    handle.unmount()
  end)

  it("reflects source edits made through the store after a re-render", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "before" })
    local handle = mount_nb(st)
    assert.truthy(text_of(handle.bufnr):find("before", 1, true))
    st:set_source(a, "after")
    assert.truthy(text_of(handle.bufnr):find("after", 1, true))
    handle.unmount()
  end)
end)
