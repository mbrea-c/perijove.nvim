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

describe("notebook_file in-memory buffers", function()
  it("opens an unnamed ipynb buffer (the demo path) and refuses a nameless save", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(FIXTURE, "\n"))
    vim.bo[buf].modified = false

    local sess = notebook_file.open(buf, { client = fake_client.new() })
    assert.is_not_nil(sess.handle)
    assert.truthy(buf_text(sess.handle.bufnr):find("NbTitle", 1, true))

    -- no file name: saving must say so, not error out of writefile
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local ok = pcall(notebook_file.save, buf)
    vim.notify = orig
    assert.is_true(ok)
    assert.truthy((notified or ""):find("no file name", 1, true))

    cleanup(buf)
  end)
end)

describe("notebook_file legacy and non-notebook files", function()
  it("an nbformat 3 file opens upgraded, with a conversion notice", function()
    local path = vim.fn.tempname() .. ".ipynb"
    vim.fn.writefile(
      vim.split(
        vim.json.encode({
          metadata = { name = "old" },
          nbformat = 3,
          nbformat_minor = 0,
          worksheets = {
            {
              cells = {
                { cell_type = "heading", level = 1, metadata = vim.empty_dict(), source = { "LegacyTitle" } },
                {
                  cell_type = "code",
                  collapsed = false,
                  input = { "print('v3')" },
                  language = "python",
                  metadata = vim.empty_dict(),
                  outputs = {},
                  prompt_number = 2,
                },
              },
              metadata = vim.empty_dict(),
            },
          },
        }),
        "\n"
      ),
      path
    )
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()

    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local sess = notebook_file.open(bufnr, { client = fake_client.new() })
    vim.notify = orig

    assert.is_not_nil(sess.handle)
    local text = buf_text(sess.handle.bufnr)
    assert.truthy(text:find("LegacyTitle", 1, true))
    assert.truthy(text:find("print('v3')", 1, true))
    assert.truthy((notified or ""):find("nbformat", 1, true))

    -- :w writes the modern format
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("write")
    local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.equal(4, saved.nbformat)
    assert.is_nil(saved.worksheets)

    cleanup(bufnr)
  end)

  it("a JSON file that is no notebook stays a plain buffer, loudly", function()
    local path = vim.fn.tempname() .. ".ipynb"
    vim.fn.writefile({ '{"just": "json"}' }, path)
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()

    local notified, level
    local orig = vim.notify
    vim.notify = function(msg, lvl)
      notified, level = msg, lvl
    end
    local sess = notebook_file.open(bufnr, { client = fake_client.new() })
    vim.notify = orig

    assert.is_nil(sess)
    assert.is_nil(notebook_file._sessions[bufnr])
    assert.equal('{"just": "json"}', buf_text(bufnr))
    assert.equal(vim.api.nvim_get_current_buf(), bufnr) -- no UI mounted
    assert.truthy((notified or ""):find("nbformat", 1, true))
    assert.equal(vim.log.levels.ERROR, level)

    vim.cmd("silent! bwipeout! " .. bufnr)
  end)
end)

describe("notebook_file lifecycle", function()
  it(":q on the notebook window hides the UI; reshowing the buffer remounts it", function()
    local _, bufnr, sess = open_fixture()
    local store_before = sess.store
    sess.store:set_source(sess.store.cells[2].id, "survives_hide = True")

    -- a second window, so the notebook's window can actually close
    vim.cmd("botright vnew")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(vim.fn.bufwinid(bufnr), true)
    vim.wait(500, function()
      return sess.handle == nil
    end, 10)

    -- hidden, not dead: the session (store, outputs, kernel) survives
    assert.is_nil(sess.handle)
    assert.rawequal(sess, notebook_file.session_of(bufnr))

    -- showing the buffer again remounts the SAME store over the new window
    vim.api.nvim_set_current_win(other)
    vim.cmd("buffer " .. bufnr)
    vim.wait(500, function()
      return sess.handle ~= nil
    end, 10)
    assert.is_not_nil(sess.handle)
    assert.equal(other, sess.handle.host_winid)
    assert.rawequal(store_before, sess.store)
    assert.truthy(buf_text(sess.handle.bufnr):find("survives_hide = True", 1, true))

    cleanup(bufnr)
    vim.cmd("silent! only")
  end)

  it("toggling to raw keeps the notebook window open in split layouts", function()
    local _, bufnr, sess = open_fixture()
    vim.cmd("botright vnew") -- with a second window, closing is possible — and wrong
    local scratch = vim.api.nvim_get_current_buf()

    notebook_file.toggle(bufnr)
    local win = vim.fn.bufwinid(bufnr)
    assert.is_true(win ~= -1)
    assert.equal(win, vim.api.nvim_get_current_win()) -- cursor lands on the raw JSON
    assert.truthy(buf_text(bufnr):find('"cells"', 1, true))

    -- toggling back mounts over the buffer's own window, wherever focus sits
    vim.cmd("wincmd p")
    notebook_file.toggle(bufnr)
    assert.equal(win, sess.handle.host_winid)

    cleanup(bufnr)
    vim.cmd("silent! bwipeout! " .. scratch)
    vim.cmd("silent! only")
  end)

  it("wiping the buffer closes the whole session, kernel included", function()
    local _, bufnr, sess = open_fixture()
    local client = sess.client
    -- NB an nvim quirk: wiping a buffer whose ONLY normal window backs the
    -- mount, while the current window is a float, silently no-ops (no
    -- BufWipeout fires at all). Any real layout — a second window, focus on
    -- the pane — deletes fine, so give it one.
    vim.cmd("botright vnew")
    local scratch = vim.api.nvim_get_current_buf()
    vim.cmd("silent! bwipeout! " .. bufnr)
    vim.wait(500, function()
      return notebook_file.session_of(bufnr) == nil
    end, 10)

    assert.is_nil(notebook_file.session_of(bufnr))
    assert.is_nil(sess.handle)
    assert.equal(1, client.shutdowns)
    vim.cmd("silent! bwipeout! " .. scratch)
    vim.cmd("silent! only")
  end)

  it("auto_open mounts on display in a normal window, never on preview loads", function()
    notebook_file.setup_autocmds(true)
    local path = write_fixture()

    -- a preview-style load: read without showing (telescope previews, bufload)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.wait(200, function()
      return notebook_file.session_of(buf) ~= nil
    end, 10)
    assert.is_nil(notebook_file.session_of(buf))

    -- shown for real in the current window: the UI mounts
    vim.cmd("edit " .. path)
    vim.wait(500, function()
      return notebook_file.session_of(buf) ~= nil
    end, 10)
    local sess = notebook_file.session_of(buf)
    assert.is_not_nil(sess)
    assert.is_not_nil(sess.handle)

    cleanup(buf)
    notebook_file.setup_autocmds(false)
  end)
end)

describe("notebook_file quit protection", function()
  it(":q on a modified notebook view fails like a modified buffer; :q! hides", function()
    local _, bufnr, sess = open_fixture()
    sess.store:set_source(sess.store.cells[2].id, "unsaved = True")

    -- the view buffer carries the unsaved state, so vim's own machinery
    -- guards :q (the pane buffer is bufhidden=wipe)
    assert.is_true(vim.bo[sess.handle.bufnr].modified)

    vim.api.nvim_set_current_win(sess.handle.winid)
    local ok, err = pcall(vim.cmd, "quit")
    assert.is_false(ok)
    assert.truthy(tostring(err):find("E37", 1, true))
    assert.is_not_nil(sess.handle) -- still mounted, nothing torn down

    -- the bang keeps today's hide semantics: view goes, session survives
    vim.cmd("quit!")
    vim.wait(500, function()
      return sess.handle == nil
    end, 10)
    assert.is_nil(sess.handle)
    assert.rawequal(sess, notebook_file.session_of(bufnr))

    cleanup(bufnr)
    vim.cmd("silent! only")
  end)

  it(":q in the last window quits vim instead of stranding the raw JSON", function()
    vim.cmd("silent! only")
    local _, bufnr, sess = open_fixture()

    -- seam: really quitting would take the test run with it
    local quits = 0
    local orig_quit = notebook_file._quit
    notebook_file._quit = function()
      quits = quits + 1
    end

    vim.api.nvim_set_current_win(sess.handle.winid)
    vim.cmd("quit")
    vim.wait(500, function()
      return quits > 0
    end, 10)
    notebook_file._quit = orig_quit

    assert.equal(1, quits)
    -- had vim stayed (an unsaved buffer vetoed), the session is still whole
    assert.rawequal(sess, notebook_file.session_of(bufnr))
    cleanup(bufnr)
  end)

  it("typing in a cell buffer marks the view modified, so :q guards the edit", function()
    local _, bufnr, sess = open_fixture()
    assert.is_false(vim.bo[sess.handle.bufnr].modified)

    -- edit the code cell through its real buffer, like a user typing in the
    -- focused float: the text lives ONLY there until a run/save syncs it into
    -- the store, and unmount force-deletes cell buffers — an unguarded :q
    -- would discard the edit silently
    local cellbuf
    sess.actions.current.each_cell_buf(function(b)
      cellbuf = b
    end)
    vim.api.nvim_buf_set_lines(cellbuf, 0, -1, false, { "typed_only = 1" })
    vim.wait(500, function()
      return vim.bo[sess.handle.bufnr].modified
    end, 10)
    assert.is_true(vim.bo[sess.handle.bufnr].modified)

    vim.api.nvim_set_current_win(sess.handle.winid)
    local ok, err = pcall(vim.cmd, "quit")
    assert.is_false(ok)
    assert.truthy(tostring(err):find("E37", 1, true))
    assert.is_not_nil(sess.handle)

    -- saving takes the text in and releases the guard
    notebook_file.save(bufnr)
    assert.is_false(vim.bo[sess.handle.bufnr].modified)

    cleanup(bufnr)
    vim.cmd("silent! only")
  end)

  it("saving clears the view buffer's modified flag; a clean view still quits", function()
    local _, bufnr, sess = open_fixture()
    assert.is_false(vim.bo[sess.handle.bufnr].modified)

    sess.store:set_source(sess.store.cells[2].id, "then_saved = True")
    assert.is_true(vim.bo[sess.handle.bufnr].modified)

    notebook_file.save(bufnr)
    assert.is_false(vim.bo[sess.handle.bufnr].modified)

    -- and a remount over unsaved work is guarded from the start
    sess.store:set_source(sess.store.cells[2].id, "dirty_again = True")
    vim.cmd("botright vnew")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(vim.fn.bufwinid(bufnr), true)
    vim.wait(500, function()
      return sess.handle == nil
    end, 10)
    vim.api.nvim_set_current_win(other)
    vim.cmd("buffer " .. bufnr)
    vim.wait(500, function()
      return sess.handle ~= nil
    end, 10)
    assert.is_true(vim.bo[sess.handle.bufnr].modified)

    cleanup(bufnr)
    vim.cmd("silent! only")
  end)
end)

describe("notebook_file buffer freshness", function()
  it("a second window showing the buffer gets fresh JSON as the store changes", function()
    local _, bufnr, sess = open_fixture()
    -- the raw JSON alongside the notebook: only now is eager serialization
    -- worth its redraw cost (a covered pane rewrite is ~2.3KB of terminal
    -- bytes per event; with no second window the buffer stays lazy)
    vim.cmd("botright vsplit")
    vim.cmd("buffer " .. bufnr)

    sess.store:set_source(sess.store.cells[2].id, "second_window_sees = 1")
    vim.wait(2000, function()
      return buf_text(bufnr):find("second_window_sees", 1, true) ~= nil
    end, 20)

    assert.truthy(buf_text(bufnr):find("second_window_sees", 1, true))
    assert.is_true(vim.bo[bufnr].modified) -- still unsaved, honestly so
    cleanup(bufnr)
    vim.cmd("silent! only")
  end)

  it("hiding the notebook leaves current JSON in the buffer, and remount reuses the store", function()
    local _, bufnr, sess = open_fixture()
    local store_before = sess.store
    sess.store:set_source(sess.store.cells[2].id, "hidden_fresh = 1")

    vim.cmd("botright vnew")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(vim.fn.bufwinid(bufnr), true)
    vim.wait(500, function()
      return sess.handle == nil
    end, 10)

    -- the hidden buffer is honest: grep and friends see the real document
    assert.truthy(buf_text(bufnr):find("hidden_fresh = 1", 1, true))

    -- and our own write did not fool the remount into a re-parse
    vim.api.nvim_set_current_win(other)
    vim.cmd("buffer " .. bufnr)
    vim.wait(500, function()
      return sess.handle ~= nil
    end, 10)
    assert.rawequal(store_before, sess.store)
    cleanup(bufnr)
    vim.cmd("silent! only")
  end)

  it(":w while toggled to raw writes the buffer text, not the stale store", function()
    local path, bufnr, sess = open_fixture()
    notebook_file.toggle(bufnr)
    local raw = buf_text(bufnr):gsub("from file", "raw wins")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(raw, "\n"))

    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)

    local on_disk = table.concat(vim.fn.readfile(path), "\n")
    assert.truthy(on_disk:find("raw wins", 1, true))
    assert.is_false(vim.bo[bufnr].modified)
    -- toggling back re-parses the saved raw edits
    notebook_file.toggle(bufnr)
    assert.truthy(buf_text(sess.handle.bufnr):find("raw wins", 1, true))
    cleanup(bufnr)
  end)
end)

describe("notebook_file multi-window", function()
  it("the view follows the buffer to a surviving window", function()
    local _, bufnr, sess = open_fixture()
    local first_host = sess.handle.host_winid
    vim.cmd("botright vsplit")
    vim.cmd("buffer " .. bufnr)
    local second = vim.api.nvim_get_current_win()

    vim.api.nvim_win_close(sess.handle.winid, true) -- :q on the app
    vim.wait(1000, function()
      return sess.handle ~= nil and sess.handle.host_winid == second
    end, 10)

    -- closing either closes the other: the mount's own window went with it;
    -- but the buffer is still open elsewhere, so the UI moves there instead
    -- of stranding raw JSON ("the window the ipynb buffer is open in")
    assert.is_not_nil(sess.handle)
    assert.equal(second, sess.handle.host_winid)
    assert.is_false(vim.api.nvim_win_is_valid(first_host))

    cleanup(bufnr)
    vim.cmd("silent! only")
  end)
end)

describe("notebook_file external changes", function()
  local function rewrite_on_disk(path, marker)
    local text = FIXTURE:gsub("print%('from file'%)", marker)
    vim.fn.writefile(vim.split(text, "\n"), path)
    -- move the mtime unambiguously: same-second writes are invisible to
    -- vim's timestamp granularity, and this spec is about detection, not
    -- about how fast a test can type
    vim.uv.fs_utime(path, os.time() + 7200, os.time() + 7200)
  end

  it("our own :w is not an external change (checktime stays quiet)", function()
    local path = write_fixture()
    -- vim remembers a FUTURE mtime at read time, so a writefile-style save
    -- (which cannot update that memory) is guaranteed to look external on
    -- the next :checktime; a real :write refreshes the bookkeeping
    vim.uv.fs_utime(path, os.time() + 3600, os.time() + 3600)
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    local sess = notebook_file.open(bufnr, { client = fake_client.new() })
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local store = sess.store

    vim.cmd("silent! checktime")
    vim.wait(300, function()
      return false
    end, 50)

    -- no reload, no re-parse: nvim's mtime bookkeeping saw our write
    assert.equal(tick, vim.api.nvim_buf_get_changedtick(bufnr))
    assert.rawequal(store, sess.store)
    assert.is_false(vim.bo[bufnr].modified)
    cleanup(bufnr)
  end)

  it("a clean notebook follows the file: external writes re-parse into the view", function()
    local path, bufnr, sess = open_fixture()
    rewrite_on_disk(path, "external_edit = 1")

    vim.cmd("silent! checktime")
    vim.wait(2000, function()
      return sess.handle and buf_text(sess.handle.bufnr):find("external_edit = 1", 1, true) ~= nil
    end, 20)

    assert.truthy(buf_text(sess.handle.bufnr):find("external_edit = 1", 1, true))
    assert.is_false(vim.bo[bufnr].modified)
    cleanup(bufnr)
  end)

  it("a dirty notebook is kept over an external write, with a warning", function()
    local path, bufnr, sess = open_fixture()
    sess.store:set_source(sess.store.cells[2].id, "unsaved_work = 1")

    local warned
    local orig = vim.notify
    vim.notify = function(msg)
      warned = msg
    end
    rewrite_on_disk(path, "external_edit = 2")
    vim.cmd("silent! checktime")
    vim.wait(300, function()
      return false
    end, 50)
    vim.notify = orig

    assert.truthy((warned or ""):find("changed on disk", 1, true))
    assert.truthy(buf_text(sess.handle.bufnr):find("unsaved_work = 1", 1, true))
    assert.is_true(vim.bo[bufnr].modified)
    cleanup(bufnr)
  end)

  it(":e! takes the disk version, unsaved notebook or not", function()
    local path, bufnr, sess = open_fixture()
    sess.store:set_source(sess.store.cells[2].id, "will_be_discarded = 1")
    rewrite_on_disk(path, "disk_wins = 1")

    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent edit!")
    end)
    vim.wait(2000, function()
      return sess.handle and buf_text(sess.handle.bufnr):find("disk_wins = 1", 1, true) ~= nil
    end, 20)

    assert.truthy(buf_text(sess.handle.bufnr):find("disk_wins = 1", 1, true))
    assert.falsy(buf_text(sess.handle.bufnr):find("will_be_discarded", 1, true))
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
