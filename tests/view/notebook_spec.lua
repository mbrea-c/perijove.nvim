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
  return mount.floating(
    notebook.Notebook,
    { store = st },
    { width = 60, height = 24, mode = "scroll", keys = notebook.KEYS }
  )
end

-- Find "needle" in the buffer; returns 1-based row and 0-based col.
local function locate(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      return i, col - 1
    end
  end
  error(
    "not found in buffer: " .. needle .. "\n" .. table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
    2
  )
end

local function press_at(handle, needle, key)
  -- mirror repaints are scheduled/coalesced: give the loop a beat so the
  -- painted text matches the (synchronously updated) layout tree, as it
  -- always does between real keypresses
  vim.wait(50)
  local row, col = locate(handle.bufnr, needle)
  vim.api.nvim_set_current_win(handle.winid)
  vim.api.nvim_win_set_cursor(handle.winid, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
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

  it("strips ANSI escapes from outputs (ipykernel colors its tracebacks)", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x" })
    local handle = mount_nb(st)
    st:run_cell(a)
    client:last().handlers.on_error("ValueError", "boom", {
      "\27[0;31m---------------------------\27[0m",
      "\27[0;31mValueError\27[0m: boom",
    })
    client:last().handlers.on_done({ status = "error", execution_count = 1 })
    local text = text_of(handle.bufnr)
    assert.falsy(text:find("\27", 1, true))
    assert.truthy(text:find("ValueError: boom", 1, true))
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

  it("runs the hovered cell on the prefix-r chord, syncing the buffer first", function()
    local st, client = new_pair()
    st:insert_cell(1, { type = "markdown", source = "prose here" })
    local a = st:insert_cell(2, { type = "code", source = "x = 1" })
    local handle = mount_nb(st)

    -- over the markdown cell: nothing runs
    press_at(handle, "prose here", notebook.PREFIX .. "r")
    assert.equal(0, #client.executions)

    -- over the code cell's mirror: the cell runs, with the buffer's text
    press_at(handle, "x = 1", notebook.PREFIX .. "r")
    assert.equal(1, #client.executions)
    assert.equal("x = 1", client:last().code)
    assert.equal("running", st:cell(a).state)
    handle.unmount()
  end)

  it("publishes sync_to_store and makes cell buffers writeable when wired", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "before" })
    local actions = { current = {} }
    local writes = 0
    local handle = mount.floating(notebook.Notebook, {
      store = st,
      actions = actions,
      on_cell_write = function()
        writes = writes + 1
      end,
    }, { width = 60, height = 24, mode = "scroll", keys = notebook.KEYS })

    -- the cell buffer is a named acwrite buffer: :w works and routes to us
    local cellbuf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("jotdown://", 1, true) then
        cellbuf = b
      end
    end
    assert.is_not_nil(cellbuf)
    assert.equal("acwrite", vim.bo[cellbuf].buftype)

    -- edit the buffer, sync: the store sees the new source
    vim.api.nvim_buf_set_lines(cellbuf, 0, -1, false, { "after = 1" })
    actions.current.sync_to_store()
    assert.equal("after = 1", st:cell(a).source)

    -- :w inside the cell buffer fires the notebook save hook
    vim.api.nvim_buf_call(cellbuf, function()
      vim.cmd("silent write")
    end)
    assert.equal(1, writes)
    handle.unmount()
  end)

  -- NOTE on spec structure: chords that shift a subwindow DOWNWARD corrupt
  -- the painted canvas today (a fibrous sync-ordering bug: a moved entry
  -- restores its old box over the fresh mirror a neighbour just painted —
  -- see pending_tasks.md). The store stays correct, so each such press is
  -- the LAST action of its spec, asserted store-side. The full multi-chord
  -- flow is pinned below, skipped until the fibrous fix lands.
  it("adds a code cell below the hovered cell on prefix-o", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "first = 1" })
    st:insert_cell(2, { type = "markdown", source = "prose here" })
    local handle = mount_nb(st)
    press_at(handle, "first = 1", notebook.PREFIX .. "o")
    assert.equal(3, #st.cells)
    assert.equal(1, st:index(a))
    assert.equal("code", st.cells[2].type)
    assert.equal("", st.cells[2].source)
    handle.unmount()
  end)

  it("adds a code cell above the hovered cell on prefix-O", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "first = 1" })
    local handle = mount_nb(st)
    press_at(handle, "first = 1", notebook.PREFIX .. "O")
    assert.equal(2, #st.cells)
    assert.equal(2, st:index(a)) -- pushed down, not replaced
    assert.equal("code", st.cells[1].type)
    handle.unmount()
  end)

  it("deletes the hovered cell on prefix-d", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "first = 1" })
    st:insert_cell(2, { type = "markdown", source = "prose here" })
    local handle = mount_nb(st)
    press_at(handle, "first = 1", notebook.PREFIX .. "d")
    assert.is_nil(st:index(a))
    assert.equal(1, #st.cells)
    handle.unmount()
  end)

  it("retypes the hovered cell on prefix-m, markdown and back", function()
    local st = new_pair()
    st:insert_cell(1, { type = "code", source = "first = 1" })
    local b = st:insert_cell(2, { type = "markdown", source = "prose here" })
    local handle = mount_nb(st)
    press_at(handle, "prose here", notebook.PREFIX .. "m")
    assert.equal("code", st:cell(b).type)
    press_at(handle, "prose here", notebook.PREFIX .. "m")
    assert.equal("markdown", st:cell(b).type)
    handle.unmount()
  end)

  it("moves the hovered cell down and back up on prefix-J/K", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "first = 1" })
    st:insert_cell(2, { type = "code", source = "second = 2" })
    local handle = mount_nb(st)
    press_at(handle, "first = 1", notebook.PREFIX .. "J")
    assert.equal(2, st:index(a))
    -- after J the moved cell repainted LAST, so its text is still locatable
    press_at(handle, "first = 1", notebook.PREFIX .. "K")
    assert.equal(1, st:index(a))
    handle.unmount()
  end)

  -- The full flow — chord after chord over one live notebook, locating cells
  -- by their PAINTED text. Exercises exactly what the fibrous bug corrupts;
  -- un-skip when the mirror-restore ordering fix lands in fibrous core.
  local FIBROUS_MIRROR_MOVE_FIXED = false
  it("chains management chords over one notebook (blocked on fibrous)", function()
    if not FIBROUS_MIRROR_MOVE_FIXED then
      io.write("[skip] view: fibrous mirror-restore ordering bug (pending_tasks.md)\n")
      return
    end
    local st = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "first = 1" })
    st:insert_cell(2, { type = "markdown", source = "prose here" })
    local handle = mount_nb(st)

    press_at(handle, "first = 1", notebook.PREFIX .. "o")
    assert.equal(3, #st.cells)
    press_at(handle, "first = 1", notebook.PREFIX .. "O")
    assert.equal(4, #st.cells)
    assert.equal(2, st:index(a))
    press_at(handle, "prose here", notebook.PREFIX .. "m")
    assert.equal("code", st.cells[4].type)
    press_at(handle, "prose here", notebook.PREFIX .. "m")
    assert.equal("markdown", st.cells[4].type)
    press_at(handle, "first = 1", notebook.PREFIX .. "J")
    assert.equal(3, st:index(a))
    press_at(handle, "first = 1", notebook.PREFIX .. "K")
    assert.equal(2, st:index(a))
    press_at(handle, "first = 1", notebook.PREFIX .. "d")
    assert.is_nil(st:index(a))
    assert.equal(3, #st.cells)
    handle.unmount()
  end)

  it("run-and-advance runs the hovered cell and lands on the next one", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "one = 1" })
    st:insert_cell(2, { type = "markdown", source = "between" })
    local b = st:insert_cell(3, { type = "code", source = "two = 2" })
    local handle = mount_nb(st)

    press_at(handle, "one = 1", notebook.PREFIX .. "<CR>")
    assert.equal(1, #client.executions)
    assert.equal("one = 1", client:last().code)
    -- the cursor moved past the markdown cell onto the next CODE cell: the
    -- run chord now targets it
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(notebook.PREFIX .. "r", true, false, true), "xt", false)
    assert.equal(2, #client.executions)
    assert.equal("two = 2", client:last().code)
    assert.equal("running", st:cell(b).state)
    handle.unmount()
  end)

  it("run-and-advance on the last code cell appends a fresh one", function()
    local st, client = new_pair()
    st:insert_cell(1, { type = "code", source = "only = 1" })
    local handle = mount_nb(st)
    press_at(handle, "only = 1", notebook.PREFIX .. "<CR>")
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
    assert.equal(2, #st.cells)
    assert.equal("code", st.cells[2].type)
    assert.equal("", st.cells[2].source)
    handle.unmount()
  end)

  it("advances across a viewport boundary by scrolling the root", function()
    local st, client = new_pair()
    local filler = {}
    for i = 1, 40 do
      filler[i] = "line " .. i
    end
    local a = st:insert_cell(1, { type = "code", source = "top = 1" })
    st:insert_cell(2, { type = "markdown", source = table.concat(filler, "\n\n") })
    local b = st:insert_cell(3, { type = "code", source = "bottom = 2" })
    local handle = mount_nb(st) -- height 24: the bottom cell starts off-screen

    press_at(handle, "top = 1", notebook.PREFIX .. "<CR>")
    client:last().handlers.on_done({ status = "ok", execution_count = 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(notebook.PREFIX .. "r", true, false, true), "xt", false)
    assert.equal("bottom = 2", client:last().code)
    assert.equal("running", st:cell(b).state)
    handle.unmount()
  end)

  it("derives every chord from a configurable prefix", function()
    notebook.configure({ prefix = "<C-k>" })
    local st, client = new_pair()
    st:insert_cell(1, { type = "code", source = "x = 1" })
    local handle = mount_nb(st)
    press_at(handle, "x = 1", "<C-k>r")
    assert.equal(1, #client.executions)
    handle.unmount()
    notebook.configure({ prefix = "<C-j>" })
  end)

  it("edits a markdown cell in a split preview on prefix-e", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "markdown", source = "# HeadingOne" })
    local handle = mount_nb(st)
    assert.truthy(text_of(handle.bufnr):find("HeadingOne", 1, true)) -- rendered

    -- enter editing: a real markdown buffer appears, split beside a live
    -- preview, and the editor is focused ready to type
    press_at(handle, "HeadingOne", notebook.PREFIX .. "e")
    vim.wait(50)
    local editor = vim.api.nvim_win_get_buf(0) -- auto-entered
    assert.truthy(editor ~= handle.bufnr)
    assert.equal("markdown", vim.bo[editor].filetype)
    assert.equal("# HeadingOne", table.concat(vim.api.nvim_buf_get_lines(editor, 0, -1, false), "\n"))

    -- typing live-updates the preview without touching the store yet
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "# HeadingTwo" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = editor })
    vim.wait(50)
    assert.truthy(text_of(handle.bufnr):find("HeadingTwo", 1, true))

    -- prefix-e inside the editor leaves editing: the store takes the text,
    -- the cell renders rich again, focus returns to the page
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(notebook.PREFIX .. "e", true, false, true), "xt", false)
    vim.wait(50)
    assert.equal("# HeadingTwo", st:cell(a).source)
    assert.equal(handle.bufnr, vim.api.nvim_win_get_buf(0))
    handle.unmount()
  end)

  it("saves markdown editor buffers through sync_to_store", function()
    local st = new_pair()
    local a = st:insert_cell(1, { type = "markdown", source = "before" })
    local actions = { current = {} }
    local handle = mount.floating(notebook.Notebook, {
      store = st,
      actions = actions,
    }, { width = 60, height = 24, mode = "scroll", keys = notebook.KEYS })

    press_at(handle, "before", notebook.PREFIX .. "e")
    vim.wait(50)
    local editor
    actions.current.each_cell_buf(function(b)
      editor = b
    end)
    assert.is_not_nil(editor)
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "after md" })
    actions.current.sync_to_store()
    assert.equal("after md", st:cell(a).source)
    handle.unmount()
  end)

  it("memoizes cells: only the touched cell re-renders", function()
    local st, client = new_pair()
    local a = st:insert_cell(1, { type = "code", source = "x = 1" })
    st:insert_cell(2, { type = "markdown", source = "prose" })
    local handle = mount_nb(st)

    -- a kernel-status notify re-renders the document but NO cell
    local before = notebook._probe.cell_renders
    client:push_status("busy")
    assert.equal(before, notebook._probe.cell_renders)

    -- a one-cell edit re-renders exactly that cell
    st:set_source(a, "x = 2")
    assert.equal(before + 1, notebook._probe.cell_renders)
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
