-- Notebook LSP, the proper way: LSP 3.17 notebookDocument synchronization.
-- Core Neovim has no notebook support, so perijove drives the protocol
-- itself: ONE client per server (vim.lsp.start, never buffer-attached — a
-- buffer attach would double-sync cells as standalone textDocuments), one
-- SESSION per open notebook. The session mirrors the store's code cells into
-- a notebook document (perijove.lsp.doc builds the payloads), streams cell
-- buffer edits as full-text changes, and maps diagnostics coming back on
-- cell URIs onto the real cell buffers.
--
-- Requests keep working through the same client with the CELL's uri swapped
-- into the params: hover on K, completion via omnifunc. Opt-in:
-- setup({ lsp = { cmd = { "basedpyright-langserver", "--stdio" } } }).

local doc = require("perijove.lsp.doc")

local M = {}

M._config = {}
M._by_buf = {} -- cell buffer -> { session, cell_id }
M._uri_to_buf = {} -- cell uri -> cell buffer (diagnostics come back on uris)
M._sessions = {} -- live sessions (a set), for server-initiated refreshes

function M.configure(opts)
  M._config = opts or {}
  M._hinted = false -- re-arm the one-shot configuration hints below
end

local Session = {}
Session.__index = Session

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---------------------------------------------------------------------------
-- The session: one notebook document over one client
---------------------------------------------------------------------------

-- opts: { store, path, client }. The client is anything colon-callable with
-- notify/request plus `initialized` and `server_capabilities` (tests inject
-- a recorder; production passes a vim.lsp.Client).
function M.attach(opts)
  local self = setmetatable({
    client = opts.client,
    store = opts.store,
    doc = doc.new(vim.uri_from_fname(opts.path)),
    bufs = {}, -- cell_id -> bufnr
    closed = false,
    _queue = {}, -- notifications parked until the client is initialized
    _dirty = {}, -- cell_id -> true while a text flush is scheduled
  }, Session)
  self:_send("notebookDocument/didOpen", doc.open_params(self.doc, self:_snapshot()))
  self._unsub = opts.store:subscribe(function()
    if not self.closed then
      self:_send("notebookDocument/didChange", doc.change_structure(self.doc, self:_snapshot()))
    end
  end)
  M._sessions[self] = true
  return self
end

-- The synced cells right now: the store's CODE cells, text from the live
-- buffer when one is registered (the buffer is authoritative while typing),
-- the store otherwise (a cell that has not rendered yet).
function Session:_snapshot()
  local cells = {}
  for _, cell in ipairs(self.store.cells) do
    if cell.type == "code" then
      local buf = self.bufs[cell.id]
      local text = (buf and vim.api.nvim_buf_is_valid(buf)) and buf_text(buf) or cell.source
      cells[#cells + 1] = { id = cell.id, text = text }
    end
  end
  return cells
end

---------------------------------------------------------------------------
-- The wire, gated on client readiness
---------------------------------------------------------------------------

-- Send, or park until the client finishes initializing (vim.lsp.start is
-- async and exposes no ready callback we can join after the fact, so a small
-- poll drains the queue). Order is preserved; params nil means nothing to say.
function Session:_send(method, params)
  if not params then
    return
  end
  table.insert(self._queue, { method = method, params = params })
  self:_flush()
end

function Session:_flush()
  if self.closed or #self._queue == 0 then
    return
  end
  if not self.client.initialized then
    if not self._poll then
      self._poll = vim.uv.new_timer()
      self._poll:start(
        30,
        30,
        vim.schedule_wrap(function()
          if self.client.initialized or self.closed then
            self._poll:stop()
            self._poll:close()
            self._poll = nil
            self:_flush()
          end
        end)
      )
    end
    return
  end
  local caps = self.client.server_capabilities
  if caps and not caps.notebookDocumentSync then
    vim.notify("perijove: LSP server has no notebookDocumentSync support; notebook LSP off", vim.log.levels.WARN)
    self._queue = {}
    self.closed = true
    return
  end
  local queue = self._queue
  self._queue = {}
  local synced = false
  for _, msg in ipairs(queue) do
    self.client:notify(msg.method, msg.params)
    synced = synced or msg.method == "notebookDocument/didOpen" or msg.method == "notebookDocument/didChange"
  end
  if synced then
    self:_schedule_pull()
  end
end

---------------------------------------------------------------------------
-- Diagnostics are PULLED (LSP 3.17): notebook-capable servers (basedpyright)
-- do not publish for cell documents — they register textDocument/diagnostic
-- with interFileDependencies and expect the client to ask. Core neovim pulls
-- only for attached buffers, so the session pulls for its cells: after every
-- sync change (an edit anywhere can change any cell's diagnostics), and when
-- the server requests a refresh.
---------------------------------------------------------------------------

function Session:_schedule_pull()
  if self._pull_queued then
    return
  end
  self._pull_queued = true
  vim.schedule(function()
    self._pull_queued = nil
    self:_pull()
  end)
end

function Session:_pull()
  if self.closed then
    return
  end
  for _, id in ipairs(self.doc.cells) do
    local buf = self.bufs[id]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local uri = doc.uri_of(self.doc, id)
      self.client:request("textDocument/diagnostic", { textDocument = { uri = uri } }, function(err, result)
        if err or not result or result.kind ~= "full" then
          return -- "unchanged" cannot happen: we never send previousResultId
        end
        M._on_diagnostics(nil, { uri = uri, diagnostics = result.items }, { client_id = self.client.id })
      end, buf)
    end
  end
end

---------------------------------------------------------------------------
-- Cell buffers: text streaming and request keymaps
---------------------------------------------------------------------------

function Session:register_buf(cell_id, buf)
  self.bufs[cell_id] = buf
  M._by_buf[buf] = { session = self, cell_id = cell_id }
  M._uri_to_buf[doc.uri_of(self.doc, cell_id)] = buf
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if self.closed or self.bufs[cell_id] ~= buf then
        return true -- detach: the session moved on
      end
      if self._dirty[cell_id] then
        return
      end
      self._dirty[cell_id] = true
      -- coalesce a burst of edits into one full-text change per loop tick
      vim.schedule(function()
        self._dirty[cell_id] = nil
        if self.closed or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        self:_send("notebookDocument/didChange", doc.change_text(self.doc, cell_id, buf_text(buf)))
      end)
    end,
    on_detach = function()
      M._by_buf[buf] = nil
      if self.bufs[cell_id] == buf then
        self.bufs[cell_id] = nil
        M._uri_to_buf[doc.uri_of(self.doc, cell_id)] = nil
      end
    end,
  })
  vim.keymap.set("n", "K", M.hover, { buffer = buf, desc = "perijove: LSP hover" })
  vim.bo[buf].omnifunc = "v:lua.require'perijove.lsp'.omnifunc"
end

function Session:did_save()
  self:_send("notebookDocument/didSave", doc.save_params(self.doc))
end

function Session:close()
  if self.closed then
    return
  end
  if self._unsub then
    self._unsub()
  end
  self:_send("notebookDocument/didClose", doc.close_params(self.doc))
  self.closed = true
  M._sessions[self] = nil
  for cell_id, buf in pairs(self.bufs) do
    M._by_buf[buf] = nil
    M._uri_to_buf[doc.uri_of(self.doc, cell_id)] = nil
  end
  self.bufs = {}
end

---------------------------------------------------------------------------
-- Requests from inside a cell: same client, the cell's uri in the params
---------------------------------------------------------------------------

local function cell_at_cursor()
  local ent = M._by_buf[vim.api.nvim_get_current_buf()]
  if not ent or ent.session.closed then
    return nil
  end
  return ent
end

local function position_params(ent)
  local params = vim.lsp.util.make_position_params(0, ent.session.client.offset_encoding or "utf-16")
  params.textDocument = { uri = doc.uri_of(ent.session.doc, ent.cell_id) }
  return params
end

function M.hover()
  local ent = cell_at_cursor()
  if not ent then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  ent.session.client:request("textDocument/hover", position_params(ent), function(err, result)
    if err or not (result and result.contents) then
      return
    end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    vim.lsp.util.open_floating_preview(lines, "markdown", { focusable = true })
  end, buf)
end

-- <C-x><C-o> completion. Synchronous by omnifunc's nature; completion-plugin
-- integration (an nvim-cmp/blink source) is a noted follow-up.
function M.omnifunc(findstart, base)
  local ent = cell_at_cursor()
  if not ent then
    return findstart == 1 and -3 or {}
  end
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    return col - #(line:sub(1, col):match("[%w_]*$") or "")
  end
  local resp = ent.session.client:request_sync(
    "textDocument/completion",
    position_params(ent),
    2000,
    vim.api.nvim_get_current_buf()
  )
  local items = resp and resp.result and (resp.result.items or resp.result) or {}
  local words = {}
  for _, item in ipairs(items) do
    local word = item.insertText or item.label
    if vim.startswith(word, base) then
      words[#words + 1] = {
        word = word,
        menu = item.detail,
        kind = vim.lsp.protocol.CompletionItemKind[item.kind] or "",
        icase = 1,
        dup = 0,
      }
    end
  end
  return words
end

---------------------------------------------------------------------------
-- The real client (shared per root; sessions are per notebook)
---------------------------------------------------------------------------

-- Diagnostics arrive on cell uris: retarget each batch at the registered
-- cell buffer and let core's publishDiagnostics machinery do the rest
-- (severity, encoding, display). Batches for unmaterialized cells drop; the
-- server republishes on the next change.
function M._on_diagnostics(err, result, ctx)
  local buf = result and M._uri_to_buf[result.uri]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  result.uri = vim.uri_from_bufnr(buf)
  vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx)
end

local function start_client(cmd, path)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil
  end
  local capabilities = vim.tbl_deep_extend("force", vim.lsp.protocol.make_client_capabilities(), {
    notebookDocument = { synchronization = { executionSummarySupport = false } },
  })
  local root = vim.fs.root(path, { "pyproject.toml", "setup.py", "requirements.txt", ".git" }) or vim.fs.dirname(path)
  local client_id = vim.lsp.start({
    name = "perijove-notebook-ls",
    cmd = cmd,
    root_dir = root,
    capabilities = capabilities,
    handlers = {
      ["textDocument/publishDiagnostics"] = M._on_diagnostics,
      -- core's default refresh handler covers attached buffers only; ours
      -- are not attached, so re-pull every session on this client
      ["workspace/diagnostic/refresh"] = function(_, _, ctx)
        for session in pairs(M._sessions) do
          if session.client.id == ctx.client_id then
            session:_schedule_pull()
          end
        end
        return vim.NIL
      end,
    },
  }, { attach = false })
  return client_id and vim.lsp.get_client_by_id(client_id) or nil
end

-- The notebook_file entry point: a session for `sess`'s store, on the
-- configured server. Nil when LSP is not configured or the binary is
-- missing — but never QUIETLY nil: a one-shot hint per configure() says
-- why (a silent nil is how "LSPs are not loading" goes undiagnosed).
-- `client_factory` is the test seam.
function M.attach_for(sess)
  local client
  if M._config.client_factory then
    client = M._config.client_factory()
  elseif M._config.cmd then
    client = start_client(M._config.cmd, vim.api.nvim_buf_get_name(sess.bufnr))
    if not client and not M._hinted then
      M._hinted = true
      vim.notify(
        ("perijove: LSP cmd %q not executable; notebook LSP off"):format(tostring(M._config.cmd[1])),
        vim.log.levels.WARN
      )
    end
  elseif not M._hinted then
    M._hinted = true
    vim.notify(
      'perijove: notebook LSP not configured; setup({ lsp = { cmd = { "basedpyright-langserver", "--stdio" } } }) enables it',
      vim.log.levels.INFO
    )
  end
  if not client then
    return nil
  end
  return M.attach({ store = sess.store, path = vim.api.nvim_buf_get_name(sess.bufnr), client = client })
end

return M
