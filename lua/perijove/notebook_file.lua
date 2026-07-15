-- The .ipynb entrypoint: a notebook file's buffer gets the perijove UI
-- mounted over its window, and vim's own file semantics keep working
-- (design decided 2026-07-13):
--
--   open    parse the buffer, build a store over a LAZY kernel client (no
--           jupyter until the first run), mount the view over the window;
--   save    BufWriteCmd on the file buffer AND on every cell sub-buffer
--           (acwrite) routes :w/:wa here: cell buffers sync into the store,
--           the store serializes to nbformat, the FILE is written, modified
--           flags clear — you always save what you see;
--   dirty   store content changes (content_rev) set the file buffer's
--           'modified', so :q protection guards unsaved notebook work;
--   toggle  <C-j>t drops to the raw JSON (serialized fresh from the store,
--           never stale) and back. The store — outputs, kernel session —
--           survives the round trip; editing the raw JSON while toggled
--           re-parses into a fresh store on remount (same client, so the
--           kernel survives even that).

local nr = require("fibrous")
local ipynb = require("perijove.ipynb")
local store_mod = require("perijove.store")
local notebook = require("perijove.view.notebook")
local lazy = require("perijove.client.lazy")

local M = {}

M._sessions = {} -- file bufnr -> sess

---------------------------------------------------------------------------
-- Kernel factory: the local-jupyter default (config hooks come later)
---------------------------------------------------------------------------

local function local_factory(sess)
  return function(cb)
    if vim.fn.executable("jupyter-server") == 0 then
      cb("jupyter-server not on PATH (nix develop provides it)")
      return
    end
    local localserver = require("perijove.localserver")
    local transport = require("perijove.transport")
    local server_client = require("perijove.client.server")
    local wire = require("perijove").transport() or transport.create(nil, {})
    local srv = localserver.spawn()
    sess.srv = srv
    -- readiness polling blocks briefly (pumping the loop); async polling is
    -- a noted refinement
    if not localserver.wait_ready(srv, wire, 60000) then
      srv.stop()
      sess.srv = nil
      cb("local jupyter server did not come up")
      return
    end
    local client = server_client.new({
      transport = wire,
      base_url = srv.base_url,
      token = srv.token,
      path = vim.api.nvim_buf_get_name(sess.bufnr),
    })
    client:connect(function(err)
      if err then
        srv.stop()
        sess.srv = nil
        cb(err)
      else
        cb(nil, client)
      end
    end)
  end
end

---------------------------------------------------------------------------
-- Mount / unmount
---------------------------------------------------------------------------

local function chord(buf, key, fn, desc)
  vim.keymap.set("n", notebook.PREFIX .. key, fn, { buffer = buf, desc = "perijove: " .. desc })
end

-- Mount the view for `sess`. With `cells` given, a fresh store is built
-- (open, or re-parse after raw edits); without, the existing store — with
-- its outputs and kernel wiring — is reused (toggle back).
local function mount(sess, cells)
  if cells then
    local st = store_mod.new(sess.client)
    for i, c in ipairs(cells) do
      st:insert_cell(i, c)
    end
    sess.store = st
    sess.saved_rev = st.content_rev
    -- content changes mark the FILE buffer modified, vim's own machinery
    -- then guards :q and drives 'autowriteall' etc.
    st:subscribe(function()
      if st.content_rev ~= sess.saved_rev and vim.api.nvim_buf_is_valid(sess.bufnr) then
        vim.bo[sess.bufnr].modified = true
      end
    end)
  end
  sess.actions = { current = {} }
  sess.handle = nr.mount_window(notebook.Notebook, {
    store = sess.store,
    actions = sess.actions,
    on_cell_write = function()
      M.save(sess.bufnr)
    end,
  }, { winid = 0, mode = "scroll", keys = notebook.KEYS })

  chord(sess.handle.bufnr, "t", function()
    M.toggle(sess.bufnr)
  end, "toggle raw ipynb")
  chord(sess.handle.bufnr, "w", function()
    M.save(sess.bufnr)
  end, "save notebook")
  chord(sess.handle.bufnr, "a", function()
    sess.store:run_all()
  end, "run all cells")
  chord(sess.handle.bufnr, "i", function()
    sess.store:interrupt()
  end, "interrupt kernel")
  chord(sess.handle.bufnr, "x", function()
    sess.store:clear_all_outputs()
  end, "clear all outputs")
  chord(sess.handle.bufnr, "R", function()
    sess.store:restart()
  end, "restart kernel")
  -- land the cursor IN the notebook: chords and cell navigation live on the
  -- view's buffer, not the covered file window
  sess.handle.focus()
end

---------------------------------------------------------------------------
-- The entry points
---------------------------------------------------------------------------

-- Open the notebook UI over `bufnr` (a loaded .ipynb buffer, shown in the
-- current window). opts.client injects a kernel client (tests, remotes);
-- default is the lazy local-jupyter client.
function M.open(bufnr, opts)
  bufnr = bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  local existing = M._sessions[bufnr]
  if existing and existing.handle then
    return existing
  end
  local sess = existing or { bufnr = bufnr }
  M._sessions[bufnr] = sess
  sess.client = (opts and opts.client) or lazy.new(local_factory(sess))

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local doc
  if text:find("%S") then
    doc = ipynb.decode(text)
  else
    -- a brand-new notebook: valid skeleton, one empty cell to type into
    doc = { meta = ipynb.new_meta(), cells = { { type = "code", source = "" } } }
  end
  sess.meta = doc.meta
  mount(sess, doc.cells)

  -- :w and friends on the FILE buffer route through the notebook save
  sess.autocmds = {
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = bufnr,
      callback = function()
        M.save(bufnr)
      end,
    }),
  }
  chord(bufnr, "t", function()
    M.toggle(bufnr)
  end, "toggle notebook view")
  return sess
end

-- Serialize the store into nbformat lines (the file's content).
local function serialize(sess)
  sess.actions.current.sync_to_store()
  local text = ipynb.encode(sess.meta, sess.store.cells)
  return vim.split(text:gsub("\n$", ""), "\n")
end

-- Write the notebook to its file: sync cell buffers, serialize, refresh the
-- raw buffer, clear every modified flag.
function M.save(bufnr)
  local sess = M._sessions[bufnr]
  if not sess then
    return
  end
  local lines = serialize(sess)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.fn.writefile(lines, vim.api.nvim_buf_get_name(bufnr))
  vim.bo[bufnr].modified = false
  sess.saved_rev = sess.store.content_rev
  if sess.actions.current.each_cell_buf then
    sess.actions.current.each_cell_buf(function(b)
      vim.bo[b].modified = false
    end)
  end
end

-- Flip between the notebook UI and the raw JSON buffer.
function M.toggle(bufnr)
  local sess = M._sessions[bufnr]
  if not sess then
    return
  end
  if sess.handle then
    -- down to raw: serialize the CURRENT store so the JSON is never stale
    local was_dirty = vim.bo[bufnr].modified or sess.store.content_rev ~= sess.saved_rev
    local lines = serialize(sess)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = was_dirty
    sess.raw_tick = vim.api.nvim_buf_get_changedtick(bufnr)
    sess.handle.unmount()
    sess.handle = nil
  else
    -- back up: raw edits win — re-parse into a fresh store (same client, so
    -- a live kernel survives); untouched JSON reuses the store as-is
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= sess.raw_tick then
      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      local doc = ipynb.decode(text)
      sess.meta = doc.meta
      mount(sess, doc.cells)
    else
      mount(sess, nil)
    end
  end
end

-- Tear a session down (buffer wipeout, tests). Kernel/server cleanup rides
-- the client's shutdown.
function M.close(bufnr)
  local sess = M._sessions[bufnr]
  if not sess then
    return
  end
  if sess.handle then
    sess.handle.unmount()
  end
  for _, au in ipairs(sess.autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, au)
  end
  if sess.client and sess.client.shutdown then
    pcall(function()
      sess.client:shutdown()
    end)
  end
  if sess.srv then
    pcall(sess.srv.stop)
  end
  M._sessions[bufnr] = nil
end

-- Session-wide cleanup: kill every kernel/server on the way out.
function M.setup_autocmds(auto_open)
  local group = vim.api.nvim_create_augroup("PerijoveNotebookFile", { clear = true })
  if auto_open then
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = group,
      pattern = "*.ipynb",
      callback = function(ev)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            M.open(ev.buf)
          end
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for bufnr in pairs(M._sessions) do
        M.close(bufnr)
      end
    end,
  })
end

return M
