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
--   fresh   the buffer's JSON is refreshed (debounced) whenever someone can
--           actually see it — a second window, a hidden buffer — and stays
--           lazy while the mount's pane is its only window, because a
--           rewrite under the floats repaints the whole covered pane;
--   toggle  <C-j>t drops to the raw JSON (serialized fresh from the store,
--           never stale) and back. The store — outputs, kernel session —
--           survives the round trip; editing the raw JSON while toggled
--           re-parses into a fresh store on remount (same client, so the
--           kernel survives even that);
--   close   the UI and the buffer's window live and die together. :q on
--           either app window hides the notebook (store, outputs and kernel
--           survive; showing the buffer again remounts, jupyter-style); in
--           the LAST layout window :q quits vim, like :q on any file; :q!
--           on a modified view discards in ONE shot — the bang covers the
--           file buffer's mirrored dirtiness too, so only unsaved work
--           elsewhere can still veto;
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

-- :q's endgame when the notebook window is the last one standing (a seam:
-- the test suite must observe the quit, not perform it).
function M._quit()
  vim.cmd("quit")
end

---------------------------------------------------------------------------
-- Store -> buffer serialization
---------------------------------------------------------------------------

-- Serialize the store into nbformat lines (the file's content). Cell
-- sub-buffers are pulled into the store first while the view is up, so you
-- always serialize what you see.
local function serialize(sess)
  local sync = sess.actions and sess.actions.current.sync_to_store
  if sync then
    sync()
  end
  local text = ipynb.encode(sess.meta, sess.store.cells)
  return vim.split(text:gsub("\n$", ""), "\n")
end

-- Rewrite the file buffer as perijove's OWN edit: no undo entry (the user
-- never made this change, and u must not resurrect stale JSON), and
-- raw_tick advanced so toggle/remount keep treating the buffer as untouched
-- by the user.
local function write_buffer(sess, lines, modified)
  local buf = sess.bufnr
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul
  vim.bo[buf].modified = modified
  sess.raw_tick = vim.api.nvim_buf_get_changedtick(buf)
end

-- Mirror the notebook's unsaved state onto the mounted view buffer, so
-- vim's own machinery guards the view like the file it fronts: :q on a
-- modified view fails (E37, add ! to override), :q! keeps the usual hide.
-- Cell BUFFERS count as unsaved state too: typed text lives only there until
-- a run/save syncs it into the store (content_rev never moved), and unmount
-- force-deletes the buffers — without this, :q discards the edit silently.
local function sync_view_modified(sess)
  local handle = sess.handle
  if not handle or not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return
  end
  local dirty = sess.store.content_rev ~= sess.saved_rev
    or (vim.api.nvim_buf_is_valid(sess.bufnr) and vim.bo[sess.bufnr].modified)
  if not dirty and sess.actions and sess.actions.current.each_cell_buf then
    sess.actions.current.each_cell_buf(function(b)
      dirty = dirty or vim.bo[b].modified
    end)
  end
  vim.bo[handle.bufnr].modified = dirty
end

-- Make the view buffer carry that guard natively. The fibrous page buffer
-- is nofile, and nvim force-clears 'modified' on nofile buffers; acwrite
-- lets the flag stick and routes :w/:wa in the view to the notebook save,
-- and bufhidden=wipe is what turns an abandoning :q into E37. Fibrous
-- repaints go through nvim_buf_set_lines, which sets 'modified' as a side
-- effect, so every paint is followed by a re-sync of the honest value.
local function guard_view_buffer(sess)
  local viewbuf = sess.handle.bufnr
  vim.bo[viewbuf].buftype = "acwrite"
  vim.bo[viewbuf].bufhidden = "wipe"
  local name = vim.api.nvim_buf_get_name(sess.bufnr)
  pcall(vim.api.nvim_buf_set_name, viewbuf, "perijove://" .. (name ~= "" and name or ("buffer-%d"):format(sess.bufnr)))
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = viewbuf,
    callback = function()
      M.save(sess.bufnr)
    end,
  })
  vim.api.nvim_buf_attach(viewbuf, false, {
    on_lines = function()
      vim.schedule(function()
        if sess.handle and sess.handle.bufnr == viewbuf then
          sync_view_modified(sess)
        end
      end)
    end,
  })
  -- :q! (or ZQ) on a modified view is the user discarding the notebook's
  -- unsaved work, and the bang must cover the FILE buffer too — its
  -- 'modified' mirrors the very state being discarded, and left set it
  -- vetoes the window close / last-window quit in on_unmount. A plain :q
  -- on a modified view is stopped by E37 before any teardown, so "modified
  -- at QuitPre, buffer wiped anyway" can only be a forced quit (:wq lands
  -- here too, harmlessly: the save already cleared every flag). The check
  -- is deferred one tick: past the quit's outcome, still ahead of the
  -- mount's own deferred teardown.
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = viewbuf,
    callback = function()
      if M._sessions[sess.bufnr] ~= sess or not vim.bo[viewbuf].modified then
        return
      end
      vim.schedule(function()
        if M._sessions[sess.bufnr] == sess and not vim.api.nvim_buf_is_valid(viewbuf) then
          sess.force_discard = true
        end
      end)
    end,
  })
end

-- When is the buffer worth refreshing eagerly? A rewrite under the mounted
-- floats repaints the whole covered pane (~2.3KB of terminal bytes per
-- event, termdraw-measured), so while the mount's pane is the only window
-- the buffer stays lazy: save/toggle/hide serialize fresh, and the modified
-- flag is honest throughout. Someone LOOKING at the raw JSON (a second
-- window, a preview float) gets it eagerly; a hidden notebook keeps its
-- buffer honest for grep and friends; a raw toggle owns the text, hands off.
local function buffer_refresh_due(sess)
  if sess.raw then
    return false
  end
  if not sess.handle then
    return true
  end
  for _, win in ipairs(vim.fn.win_findbuf(sess.bufnr)) do
    if win ~= sess.handle.host_winid then
      return true
    end
  end
  return false
end

local function refresh_buffer(sess)
  if not vim.api.nvim_buf_is_valid(sess.bufnr) or not buffer_refresh_due(sess) then
    return
  end
  local dirty = vim.bo[sess.bufnr].modified or sess.store.content_rev ~= sess.saved_rev
  write_buffer(sess, serialize(sess), dirty)
end

local REFRESH_DEBOUNCE_MS = 200

-- Debounced: store changes come in bursts (streaming outputs, run-all), one
-- serialization per quiet gap is plenty for eyes on a side window.
local function schedule_refresh(sess)
  if not sess.refresh_timer then
    sess.refresh_timer = vim.uv.new_timer()
  end
  sess.refresh_timer:stop()
  sess.refresh_timer:start(
    REFRESH_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if M._sessions[sess.bufnr] == sess then
        refresh_buffer(sess)
      end
    end)
  )
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

-- forward: the mount's on_unmount follows the buffer to a surviving window
local remount

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

-- Build a fresh store over `cells`, keeping the session's client (a live
-- kernel survives a re-parse), and point the LSP session at what is a new
-- notebook document as far as the server is concerned.
local function adopt(sess, cells)
  local st = store_mod.new(sess.client)
  for i, c in ipairs(cells) do
    st:insert_cell(i, c)
  end
  sess.store = st
  sess.saved_rev = st.content_rev
  -- content changes mark the FILE buffer modified, vim's own machinery
  -- then guards :q and drives 'autowriteall' etc.; the debounced refresh
  -- keeps the raw JSON fresh wherever it is actually visible
  st:subscribe(function()
    if st.content_rev ~= sess.saved_rev and vim.api.nvim_buf_is_valid(sess.bufnr) then
      vim.bo[sess.bufnr].modified = true
    end
    sync_view_modified(sess)
    schedule_refresh(sess)
  end)
  if sess.lsp then
    sess.lsp:close()
  end
  sess.lsp = lsp.attach_for(sess)
end

-- Mount the view for `sess`. With `cells` given, a fresh store is built
-- (open, or re-parse after raw edits); without, the existing store — with
-- its outputs and kernel wiring — is reused (toggle back, remount after a
-- hide). `winid` is the window to mount over (default: the current one).
local function mount(sess, cells, winid)
  if cells then
    adopt(sess, cells)
  end
  -- resolve "current window" NOW: on_unmount below needs to know which
  -- window was the mount's own, long after current has moved on
  local host_winid = winid or vim.api.nvim_get_current_win()
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
      -- typing in a cell is unsaved notebook work the moment it happens:
      -- re-derive the view's modified flag on every edit (deferred — the
      -- 'modified' side effect settles after on_lines returns)
      vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
          if M._sessions[sess.bufnr] ~= sess then
            return true -- detach: the session moved on
          end
          vim.schedule(function()
            if M._sessions[sess.bufnr] == sess then
              sync_view_modified(sess)
            end
          end)
        end,
      })
    end,
  }, {
    winid = host_winid,
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
      if not vim.api.nvim_buf_is_valid(sess.bufnr) then
        return
      end
      sess.raw_tick = vim.api.nvim_buf_get_changedtick(sess.bufnr)
      -- leave honest JSON behind for grep and friends (cheap: the pane is
      -- on its way out); refresh also re-advances raw_tick, so the later
      -- remount reuses the store instead of re-parsing our own write
      refresh_buffer(sess)
      -- a forced quit discarded the notebook's unsaved work: the bang
      -- covers the file buffer, or our own modified flag would veto the
      -- close/quit below (armed in guard_view_buffer's QuitPre)
      if sess.force_discard then
        sess.force_discard = nil
        vim.bo[sess.bufnr].modified = false
      end
      -- closing either closes the other: the mount's OWN window goes with
      -- the UI. The very last layout window is vim's to keep, and leaving
      -- it showing raw JSON is not what :q on a notebook means — there :q
      -- does what :q on any file does: quit vim. Plain :quit, so an unsaved
      -- buffer ELSEWHERE still vetoes with its usual error; the notebook's
      -- own dirtiness was either already saved (:q refuses otherwise) or
      -- explicitly discarded by the bang above.
      if vim.api.nvim_win_is_valid(host_winid) then
        pcall(vim.api.nvim_win_close, host_winid, false)
        if vim.api.nvim_win_is_valid(host_winid) then
          vim.schedule(function()
            if M._sessions[sess.bufnr] ~= sess or sess.handle or not vim.api.nvim_win_is_valid(host_winid) then
              return
            end
            -- re-attempt: the layout may have changed since the tick began
            if not pcall(vim.api.nvim_win_close, host_winid, false) then
              pcall(M._quit)
            end
          end)
        end
      end
      -- the view follows the buffer: if some OTHER window still shows it,
      -- the UI belongs there ("the window the ipynb buffer is open in");
      -- deferred, teardown is no place to open windows
      vim.schedule(function()
        if M._sessions[sess.bufnr] ~= sess or sess.handle or sess.raw then
          return
        end
        local win = layout_win_of(sess.bufnr)
        if win and win ~= host_winid then
          remount(sess, win)
        end
      end)
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
  -- a remount over unsaved work starts guarded, not clean
  guard_view_buffer(sess)
  sync_view_modified(sess)
  -- land the cursor IN the notebook: chords and cell navigation live on the
  -- view's buffer, not the covered file window
  sess.handle.focus()
end

-- Bring the UI back over `winid` after a hide or a raw toggle. Raw edits
-- win: a changed buffer re-parses into a fresh store (same client, so a
-- live kernel survives); an untouched one reuses the store as-is.
-- (declared forward above: mount's own on_unmount uses it)
function remount(sess, winid)
  if vim.api.nvim_buf_get_changedtick(sess.bufnr) ~= sess.raw_tick then
    local text = table.concat(vim.api.nvim_buf_get_lines(sess.bufnr, 0, -1, false), "\n")
    local ok, doc = pcall(ipynb.decode, text)
    if not ok then
      -- edited into something unreadable: stay on the raw text, loudly
      vim.notify("perijove: buffer is not valid nbformat; staying raw: " .. tostring(doc), vim.log.levels.ERROR)
      sess.raw = true
      return
    end
    sess.meta = doc.meta
    mount(sess, doc.cells, winid)
  else
    mount(sess, nil, winid)
  end
end

-- The buffer changed under the session (autoread after an external write,
-- :e/:e! reload): take it in. A fresh store is parsed out of the new text
-- (same client, live kernel kept) and the view remounted where it was. The
-- tick guard skips the cases where nothing actually reloaded (a kept buffer
-- after a dirty-notebook conflict); a raw toggle needs no help (toggle-up
-- re-parses on its own tick check).
local function reload_from_buffer(sess)
  local tick = vim.api.nvim_buf_get_changedtick(sess.bufnr)
  if tick == sess.raw_tick or sess.raw then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(sess.bufnr, 0, -1, false), "\n")
  local ok, doc = pcall(ipynb.decode, text)
  if not ok then
    vim.notify("perijove: reloaded ipynb is not valid nbformat; leaving the raw text", vim.log.levels.ERROR)
    drop_ui(sess)
    sess.raw = true
    return
  end
  sess.meta = doc.meta
  sess.raw_tick = tick
  if sess.handle then
    local win = sess.handle.host_winid
    drop_ui(sess)
    mount(sess, doc.cells, win)
  else
    -- hidden: adopt the new document now, so a late refresh can never
    -- serialize the old store over it; BufWinEnter remounts this store
    adopt(sess, doc.cells)
  end
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
  -- project-level connections (perijove.json, resolved upward from the
  -- file); an unnamed buffer (in-memory notebooks, the demos) has no project
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    local proj, perr = project.load_for(name)
    if perr then
      vim.notify("perijove: " .. perr, vim.log.levels.WARN)
    end
    sess.project = proj
  end
  sess.client = (opts and opts.client) or lazy.new(connection_factory(sess))

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local doc
  if text:find("%S") then
    local ok, res = pcall(ipynb.decode, text)
    if not ok then
      -- not a notebook we can read: leave the buffer alone, plain vim JSON
      -- editing included, rather than mount a blank notebook over it
      if not existing then
        M._sessions[bufnr] = nil
      end
      vim.notify("perijove: cannot open notebook: " .. tostring(res), vim.log.levels.ERROR)
      return nil
    end
    doc = res
    if doc.upgraded_from then
      vim.notify(
        ("perijove: legacy nbformat %d notebook upgraded on read; saving writes nbformat 4"):format(doc.upgraded_from),
        vim.log.levels.WARN
      )
    end
  else
    -- a brand-new notebook: valid skeleton, one empty cell to type into
    doc = { meta = ipynb.new_meta(), cells = { { type = "code", source = "" } } }
  end
  sess.meta = doc.meta
  mount(sess, doc.cells, layout_win_of(bufnr))
  -- the buffer as read IS the document we just parsed: the baseline every
  -- later tick comparison (toggle, remount, external intake) works from
  sess.raw_tick = vim.api.nvim_buf_get_changedtick(bufnr)

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
    -- external writes (jupyter lab on the same file, git checkout): a clean
    -- notebook follows the file; unsaved work is kept, loudly
    vim.api.nvim_create_autocmd("FileChangedShell", {
      buffer = bufnr,
      callback = function()
        if sess.store.content_rev ~= sess.saved_rev or vim.bo[bufnr].modified then
          vim.v.fcs_choice = ""
          vim.notify(
            "perijove: "
              .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
              .. " changed on disk; keeping the unsaved notebook (:e! takes the disk version)",
            vim.log.levels.WARN
          )
        else
          vim.v.fcs_choice = "reload"
        end
      end,
    }),
    -- the buffer changed under us (autoread reload, :e/:e!): take it in
    vim.api.nvim_create_autocmd({ "FileChangedShellPost", "BufReadPost" }, {
      buffer = bufnr,
      callback = function()
        vim.schedule(function()
          if M._sessions[bufnr] == sess then
            reload_from_buffer(sess)
          end
        end)
      end,
    }),
  }
  chord(bufnr, "t", function()
    M.toggle(bufnr)
  end, "toggle notebook view")
  return sess
end

-- Write the notebook to its file: sync cell buffers, serialize, refresh the
-- raw buffer, clear every modified flag. While the user is editing the raw
-- JSON (toggled down), the BUFFER is the document: writing the store here
-- would clobber their edits, so the buffer text goes to disk as-is and the
-- next toggle-up re-parses it.
function M.save(bufnr)
  local sess = M._sessions[bufnr]
  if not sess then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    vim.notify("perijove: no file name (:saveas one first)", vim.log.levels.WARN)
    return
  end
  local lines
  if sess.raw and vim.api.nvim_buf_get_changedtick(bufnr) ~= sess.raw_tick then
    -- raw edits in flight: save them verbatim; raw_tick stays behind the
    -- buffer's tick on purpose, so toggle-up still knows to re-parse
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    lines = serialize(sess)
    write_buffer(sess, lines, false)
    sess.saved_rev = sess.store.content_rev
  end
  vim.fn.writefile(lines, name)
  vim.bo[bufnr].modified = false
  if sess.actions and sess.actions.current.each_cell_buf then
    sess.actions.current.each_cell_buf(function(b)
      vim.bo[b].modified = false
    end)
  end
  sync_view_modified(sess)
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
    write_buffer(sess, serialize(sess), was_dirty)
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
  if sess.refresh_timer then
    sess.refresh_timer:stop()
    sess.refresh_timer:close()
    sess.refresh_timer = nil
  end
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
