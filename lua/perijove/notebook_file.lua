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
--           kernel survives even that);
--   close   the UI and the buffer's window live and die together. :q on
--           either app window hides the notebook (store, outputs and kernel
--           survive; showing the buffer again remounts, jupyter-style);
--           deleting or wiping the BUFFER closes the whole session, kernel
--           shutdown included.

local nr = require("fibrous")
local ipynb = require("perijove.ipynb")
local store_mod = require("perijove.store")
local notebook = require("perijove.view.notebook")
local lazy = require("perijove.client.lazy")
local connections = require("perijove.connections")
local project = require("perijove.connections.project")
local lsp = require("perijove.lsp")

local M = {}

M._sessions = {} -- file bufnr -> sess

---------------------------------------------------------------------------
-- Kernel factory: boot the session's EFFECTIVE connection on the first run
---------------------------------------------------------------------------

-- The session `bufnr` belongs to: the notebook FILE buffer (the session
-- key), or the mounted view buffer the cursor actually lives in.
function M.session_of(bufnr)
  if M._sessions[bufnr] then
    return M._sessions[bufnr]
  end
  for _, sess in pairs(M._sessions) do
    if sess.handle and sess.handle.bufnr == bufnr then
      return sess
    end
  end
end

-- The effective connection name for a notebook: explicitly selected >
-- perijove.json default > global default (setup or set_default) > "local".
function M.connection_of(bufnr)
  local sess = M.session_of(bufnr)
  if not sess then
    return nil
  end
  return sess.connection or connections.view(sess.project).default()
end

local function connection_factory(sess)
  return function(cb)
    local name = M.connection_of(sess.bufnr)
    local spec = connections.view(sess.project).get(name)
    if not spec then
      cb(("unknown connection %q (see :Perijove connections)"):format(name))
      return
    end
    connections.resolve(spec, function(err, ep)
      if err then
        cb(err)
        return
      end
      sess.endpoint = ep -- the session owns it: stop on switch/close
      local server_client = require("perijove.client.server")
      local client = server_client.new({
        transport = ep.transport or require("perijove").transport(),
        base_url = ep.base_url,
        token = ep.token,
        headers = ep.headers,
        path = vim.api.nvim_buf_get_name(sess.bufnr),
      })
      client:connect(function(cerr)
        if cerr then
          if ep.stop then
            pcall(ep.stop)
          end
          sess.endpoint = nil
          cb(cerr)
        else
          cb(nil, client)
        end
      end)
    end)
  end
end

-- Point a live notebook at another connection: the old kernel (and its
-- endpoint: tunnel, local server) goes away NOW, queued and running cells
-- settle locally (a switched-away kernel never answers), outputs stay, and
-- the next run boots on the new connection.
function M.set_connection(bufnr, name)
  local sess = M.session_of(bufnr)
  if not sess then
    return
  end
  assert(connections.view(sess.project).get(name), ("perijove: unknown connection %q"):format(tostring(name)))
  sess.connection = name
  local old_ep = sess.endpoint
  sess.endpoint = nil
  if sess.client.rebase then
    sess.client:rebase(connection_factory(sess))
  end
  if old_ep and old_ep.stop then
    pcall(old_ep.stop)
  end
  sess.store:restart()
end

---------------------------------------------------------------------------
-- Mount / unmount
---------------------------------------------------------------------------

local function chord(buf, key, fn, desc)
  vim.keymap.set("n", notebook.PREFIX .. key, fn, { buffer = buf, desc = "perijove: " .. desc })
end

-- Unmount the view because perijove says so (toggle, close, remount): the
-- flag keeps the mount's on_unmount from treating it as a user-driven :q.
local function drop_ui(sess)
  local handle = sess.handle
  if not handle then
    return
  end
  sess.unmounting = true
  sess.handle = nil
  handle.unmount()
  sess.unmounting = false
end

-- Mount the view for `sess`. With `cells` given, a fresh store is built
-- (open, or re-parse after raw edits); without, the existing store — with
-- its outputs and kernel wiring — is reused (toggle back, remount after a
-- hide). `winid` is the window to mount over (default: the current one).
local function mount(sess, cells, winid)
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
    -- the LSP session mirrors THIS store; a re-parse (raw edits) is a new
    -- notebook document as far as the server is concerned
    if sess.lsp then
      sess.lsp:close()
    end
    sess.lsp = lsp.attach_for(sess)
  end
  sess.actions = { current = {} }
  sess.raw = false
  sess.handle = nr.mount_window(notebook.Notebook, {
    store = sess.store,
    actions = sess.actions,
    on_cell_write = function()
      M.save(sess.bufnr)
    end,
    on_cell_buf = function(cell, buf)
      if sess.lsp then
        sess.lsp:register_buf(cell.id, buf)
      end
    end,
  }, {
    winid = winid or 0,
    mode = "scroll",
    keys = notebook.KEYS,
    on_unmount = function()
      if sess.unmounting then
        return
      end
      -- the UI died on nvim's side (:q on the float or its window): HIDE.
      -- The session — store, outputs, kernel — survives; showing the buffer
      -- again remounts it (BufWinEnter in M.open).
      sess.handle = nil
      if vim.api.nvim_buf_is_valid(sess.bufnr) then
        sess.raw_tick = vim.api.nvim_buf_get_changedtick(sess.bufnr)
        -- closing either closes the other: take the buffer's window along
        -- (a last window survives — vim won't close it — showing raw JSON)
        local win = vim.fn.bufwinid(sess.bufnr)
        if win ~= -1 then
          pcall(vim.api.nvim_win_close, win, false)
        end
      end
    end,
  })

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
  chord(sess.handle.bufnr, "s", function()
    require("perijove.connections.ui").pick({
      project = sess.project,
      current = M.connection_of(sess.bufnr),
    }, function(spec)
      if spec then
        M.set_connection(sess.bufnr, spec.name)
      end
    end)
  end, "switch jupyter connection")
  -- land the cursor IN the notebook: chords and cell navigation live on the
  -- view's buffer, not the covered file window
  sess.handle.focus()
end

-- Bring the UI back over `winid` after a hide or a raw toggle. Raw edits
-- win: a changed buffer re-parses into a fresh store (same client, so a
-- live kernel survives); an untouched one reuses the store as-is.
local function remount(sess, winid)
  if vim.api.nvim_buf_get_changedtick(sess.bufnr) ~= sess.raw_tick then
    local text = table.concat(vim.api.nvim_buf_get_lines(sess.bufnr, 0, -1, false), "\n")
    local doc = ipynb.decode(text)
    sess.meta = doc.meta
    mount(sess, doc.cells, winid)
  else
    mount(sess, nil, winid)
  end
end

-- The window currently showing `bufnr` in the real layout, or nil. Floats
-- (previews and the like) don't count: the notebook never mounts over one.
local function layout_win_of(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 or vim.api.nvim_win_get_config(win).relative ~= "" then
    return nil
  end
  return win
end

---------------------------------------------------------------------------
-- The entry points
---------------------------------------------------------------------------

-- Open the notebook UI over `bufnr` (a loaded .ipynb buffer, shown in the
-- current window). opts.client injects a kernel client (tests); the default
-- is a lazy client that boots the session's effective connection on the
-- first run.
function M.open(bufnr, opts)
  bufnr = bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  local existing = M._sessions[bufnr]
  if existing and existing.handle then
    return existing
  end
  local sess = existing or { bufnr = bufnr }
  M._sessions[bufnr] = sess
  -- project-level connections (perijove.json, resolved upward from the file)
  local proj, perr = project.load_for(vim.api.nvim_buf_get_name(bufnr))
  if perr then
    vim.notify("perijove: " .. perr, vim.log.levels.WARN)
  end
  sess.project = proj
  sess.client = (opts and opts.client) or lazy.new(connection_factory(sess))

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local doc
  if text:find("%S") then
    doc = ipynb.decode(text)
  else
    -- a brand-new notebook: valid skeleton, one empty cell to type into
    doc = { meta = ipynb.new_meta(), cells = { { type = "code", source = "" } } }
  end
  sess.meta = doc.meta
  mount(sess, doc.cells, layout_win_of(bufnr))

  -- :w and friends on the FILE buffer route through the notebook save
  sess.autocmds = {
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = bufnr,
      callback = function()
        M.save(bufnr)
      end,
    }),
    -- a hidden notebook remounts when its buffer is shown again — unless it
    -- was toggled to raw on purpose, or the showing window is a preview float
    vim.api.nvim_create_autocmd("BufWinEnter", {
      buffer = bufnr,
      callback = function()
        vim.schedule(function()
          if M._sessions[bufnr] ~= sess or sess.handle or sess.raw then
            return
          end
          local win = layout_win_of(bufnr)
          if win then
            remount(sess, win)
          end
        end)
      end,
    }),
    -- the buffer going away takes the whole session with it, kernel included
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      buffer = bufnr,
      callback = function()
        vim.schedule(function()
          M.close(bufnr)
        end)
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
  if sess.lsp then
    sess.lsp:did_save()
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
    sess.raw = true -- deliberate: BufWinEnter must not remount over the raw view
    drop_ui(sess)
    -- land the cursor on the raw JSON, wherever focus fell after the floats
    local win = layout_win_of(bufnr)
    if win then
      vim.api.nvim_set_current_win(win)
    end
  else
    remount(sess, layout_win_of(bufnr))
  end
end

-- Tear a session down (buffer wipeout, tests). Kernel/server cleanup rides
-- the client's shutdown.
function M.close(bufnr)
  local sess = M._sessions[bufnr]
  if not sess then
    return
  end
  drop_ui(sess)
  for _, au in ipairs(sess.autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, au)
  end
  if sess.client and sess.client.shutdown then
    pcall(function()
      sess.client:shutdown()
    end)
  end
  if sess.endpoint and sess.endpoint.stop then
    pcall(sess.endpoint.stop)
  end
  if sess.lsp then
    sess.lsp:close()
  end
  M._sessions[bufnr] = nil
end

-- Session-wide cleanup: kill every kernel/server on the way out.
function M.setup_autocmds(auto_open)
  local group = vim.api.nvim_create_augroup("PerijoveNotebookFile", { clear = true })
  if auto_open then
    -- BufWinEnter, not BufReadPost: the trigger is a notebook being SHOWN in
    -- a real window, not merely loaded — telescope-style preview floats and
    -- bufload() must never boot a session behind the user's back.
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      pattern = "*.ipynb",
      callback = function(ev)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(ev.buf) or M._sessions[ev.buf] then
            return
          end
          if layout_win_of(ev.buf) then
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
