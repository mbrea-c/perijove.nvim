-- The Jupyter Server kernel client: implements the kernel-client contract
-- (perijove.client) against the server's REST + websocket API — the same
-- surface JupyterLab uses — through the pluggable wire transport. Local and
-- remote kernels differ only in base_url + auth; nothing here knows curl
-- from websocat.
--
-- Lifecycle: new{} -> connect(cb) creates a session (the notebook<->kernel
-- binding, /api/sessions) and opens the multiplexed kernel channel; execute
-- then sends channel-tagged protocol envelopes and the correlator routes the
-- kernel's replies back to the store's handlers.

local protocol = require("perijove.protocol")

local M = {}

local Client = {}
Client.__index = Client

-- opts: { transport (required), base_url (required), token?, kernel_name?,
--         name?, path? } — name/path label the session server-side.
function M.new(opts)
  return setmetatable({
    transport = opts.transport,
    base_url = opts.base_url:gsub("/$", ""),
    token = opts.token,
    kernel_name = opts.kernel_name or "python3",
    name = opts.name or "perijove",
    path = opts.path or "perijove.ipynb",
    -- our session id on the wire: ties every message we send together so
    -- other frontends on the same kernel can tell our traffic apart
    session = ("perijove-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime()),
    _kernel_handlers = {},
    _corr = nil,
    _conn = nil,
    kernel_id = nil,
    session_id = nil,
  }, Client)
end

function Client:_headers()
  local h = {}
  if self.token then
    h["Authorization"] = "token " .. self.token
  end
  return h
end

function Client:_ws_url(path)
  return self.base_url:gsub("^http", "ws") .. path
end

---------------------------------------------------------------------------
-- Connect: session create + channel open
---------------------------------------------------------------------------

function Client:connect(cb)
  self._corr = protocol.correlator({
    on_status = function(s)
      if self._kernel_handlers.on_status then
        self._kernel_handlers.on_status(s)
      end
    end,
  })
  self.transport:request({
    method = "POST",
    url = self.base_url .. "/api/sessions",
    headers = self:_headers(),
    body = vim.json.encode({
      name = self.name,
      path = self.path,
      type = "notebook",
      kernel = { name = self.kernel_name },
    }),
  }, function(res)
    if not res.ok or res.status >= 300 then
      cb(("session create failed: %s"):format(res.error or res.status))
      return
    end
    local sess = vim.json.decode(res.body)
    self.session_id = sess.id
    self.kernel_id = sess.kernel.id
    self._conn = self.transport:ws_open({
      url = self:_ws_url("/api/kernels/" .. self.kernel_id .. "/channels?session_id=" .. self.session),
      headers = self:_headers(),
    }, {
      on_message = function(text)
        local ok, m = pcall(vim.json.decode, text)
        if ok then
          self._corr:ingest(m)
        end
      end,
      on_close = function()
        -- an INTENTIONAL shutdown must not report: the notify would drive a
        -- re-render of a view that is being torn down (VimLeave, :q)
        if not self._closing and self._kernel_handlers.on_status then
          self._kernel_handlers.on_status("disconnected")
        end
      end,
      on_error = function(err)
        vim.notify("perijove: kernel channel error: " .. tostring(err), vim.log.levels.WARN)
      end,
    })
    -- a fresh kernel is idle; without this the store's status line reads
    -- "unknown" until the first execute produces a real status message
    if self._kernel_handlers.on_status then
      self._kernel_handlers.on_status("idle")
    end
    cb(nil)
  end)
end

---------------------------------------------------------------------------
-- The kernel-client contract
---------------------------------------------------------------------------

function Client:attach(handlers)
  self._kernel_handlers = handlers or {}
end

function Client:execute(code, handlers)
  local env = protocol.envelope("execute_request", protocol.execute_content(code), {
    session = self.session,
    channel = "shell",
  })
  -- stdin: the correlator routes the kernel's ask; the reply closure is
  -- ours to provide — an input_reply frame back down the same channel
  local tracked = handlers
  if handlers.on_input then
    tracked = setmetatable({
      on_input = function(prompt, password)
        handlers.on_input(prompt, password, function(text)
          local reply = protocol.envelope("input_reply", { value = text }, {
            session = self.session,
            channel = "stdin",
          })
          self._conn.send(vim.json.encode(reply))
        end)
      end,
    }, { __index = handlers })
  end
  self._corr:track(env.header.msg_id, tracked)
  self._conn.send(vim.json.encode(env))
end

function Client:interrupt()
  self.transport:request({
    method = "POST",
    url = self.base_url .. "/api/kernels/" .. self.kernel_id .. "/interrupt",
    headers = self:_headers(),
  }, function() end)
end

function Client:restart(cb)
  self.transport:request({
    method = "POST",
    url = self.base_url .. "/api/kernels/" .. self.kernel_id .. "/restart",
    headers = self:_headers(),
  }, function()
    if cb then
      cb()
    end
  end)
end

function Client:shutdown(cb)
  self._closing = true
  if self._conn then
    self._conn.close()
    self._conn = nil
  end
  if not self.session_id then
    if cb then
      cb()
    end
    return
  end
  self.transport:request({
    method = "DELETE",
    url = self.base_url .. "/api/sessions/" .. self.session_id,
    headers = self:_headers(),
  }, function()
    if cb then
      cb()
    end
  end)
end

return M
