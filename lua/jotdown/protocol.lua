-- The Jupyter messaging protocol (v5.3), pure of any transport: envelope
-- construction for the server-websocket wire format (channel-tagged JSON
-- frames — the server owns ZMQ framing and HMAC signing, we never see them),
-- and the correlator routing decoded incoming messages to per-execution
-- handlers by parent_header.msg_id.
--
-- The one delicate rule lives here: an execution is COMPLETE only when both
-- its shell execute_reply AND its iopub idle status have arrived — the two
-- travel on different channels and race in either order on a real kernel.

local M = {}

---------------------------------------------------------------------------
-- Envelopes
---------------------------------------------------------------------------

local counter = 0

local function msg_id()
  counter = counter + 1
  -- unique per process run; the kernel only reflects these back
  return ("jotdown-%d-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime(), counter)
end

-- A wire-ready message table: vim.json.encode(envelope(...)) is the frame.
-- opts: { session (required), channel (required) }.
function M.envelope(msg_type, content, opts)
  return {
    header = {
      msg_id = msg_id(),
      username = "jotdown",
      session = opts.session,
      msg_type = msg_type,
      version = "5.3",
      date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
    -- empty OBJECTS on the wire ({} not []), or the server rejects the frame
    parent_header = vim.empty_dict(),
    metadata = vim.empty_dict(),
    content = content or vim.empty_dict(),
    channel = opts.channel,
  }
end

-- The execute_request content for one cell run.
function M.execute_content(code)
  return {
    code = code,
    silent = false,
    store_history = true,
    user_expressions = vim.empty_dict(),
    allow_stdin = true, -- input_request routes through the correlator
    stop_on_error = true,
  }
end

---------------------------------------------------------------------------
-- Correlator
---------------------------------------------------------------------------

local Correlator = {}
Correlator.__index = Correlator

-- kernel_handlers: { on_status(state)? } — fired for EVERY status message,
-- whoever its parent, so the store's kernel line tracks busy/idle globally.
function M.correlator(kernel_handlers)
  return setmetatable({
    _kernel = kernel_handlers or {},
    _inflight = {}, -- parent msg_id -> { handlers, reply?, idle? }
  }, Correlator)
end

function Correlator:track(id, handlers)
  self._inflight[id] = { handlers = handlers }
end

-- Fire on_done once both halves are in, then untrack.
local function maybe_finish(self, id, entry)
  if entry.reply and entry.idle then
    self._inflight[id] = nil
    entry.handlers.on_done({
      status = entry.reply.status,
      execution_count = entry.reply.execution_count,
    })
  end
end

-- Feed one decoded incoming message. Unknown parents are dropped in silence:
-- other frontends on the same kernel produce traffic that is not ours.
function Correlator:ingest(m)
  local msg_type = m.header and m.header.msg_type

  if msg_type == "status" then
    local state = m.content and m.content.execution_state
    if self._kernel.on_status and state then
      self._kernel.on_status(state)
    end
  end

  local parent = m.parent_header and m.parent_header.msg_id
  local entry = parent and self._inflight[parent]
  if not entry then
    return
  end
  local h = entry.handlers
  local c = m.content or {}

  if msg_type == "stream" then
    h.on_stream(c.name, c.text)
  elseif msg_type == "execute_result" then
    h.on_result(c.data, c.metadata)
  elseif msg_type == "display_data" then
    h.on_display(c.data, c.metadata)
  elseif msg_type == "error" then
    h.on_error(c.ename, c.evalue, c.traceback)
  elseif msg_type == "input_request" then
    -- stdin: the kernel is blocked in input() until an input_reply; the
    -- reply plumbing is the client's business, we just route the ask
    h.on_input(c.prompt, c.password)
  elseif msg_type == "execute_reply" then
    entry.reply = { status = c.status, execution_count = c.execution_count }
    maybe_finish(self, parent, entry)
  elseif msg_type == "status" and c.execution_state == "idle" then
    entry.idle = true
    maybe_finish(self, parent, entry)
  end
end

return M
