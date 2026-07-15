-- The lazy kernel client: satisfies the kernel-client contract from the
-- moment a notebook opens, but only BOOTS a kernel when the first execute
-- arrives — opening a .ipynb must never spawn a jupyter server (and later,
-- never wake a remote GPU box) uninvited.
--
-- `factory(cb)` does the actual boot (spawn + connect, or dial a remote) and
-- calls cb(err, real_client). While boot is in flight the pending execute is
-- parked; the store's serial queue guarantees there is at most one.

local M = {}

local Client = {}
Client.__index = Client

function M.new(factory)
  return setmetatable({
    _factory = factory,
    _real = nil,
    _booting = false,
    _pending = nil, -- the one parked { code, handlers }
    _handlers = {},
    _gen = 0, -- bumped by rebase(); boots from an older gen are stale
  }, Client)
end

function Client:attach(handlers)
  self._handlers = handlers or {}
  if self._real then
    self._real:attach(handlers)
  end
end

function Client:_status(s)
  if self._handlers.on_status then
    self._handlers.on_status(s)
  end
end

function Client:_boot()
  self._booting = true
  local gen = self._gen
  self:_status("starting")
  self._factory(function(err, real)
    if gen ~= self._gen then
      -- rebase() happened mid-boot: this client belongs to the OLD
      -- connection; retire it and boot again for the new one if needed
      if real and real.shutdown then
        real:shutdown()
      end
      self._booting = false
      if self._pending then
        self:_boot()
      end
      return
    end
    self._booting = false
    if err or not real then
      self:_status("dead")
      local pending = self._pending
      self._pending = nil
      if pending then
        -- settle the parked execute through the ordinary error path so the
        -- cell (and the store's queue) unwinds like any failed run
        pending.handlers.on_error("KernelStartError", tostring(err), { tostring(err) })
        pending.handlers.on_done({ status = "error" })
      end
      return
    end
    self._real = real
    real:attach(self._handlers)
    local pending = self._pending
    self._pending = nil
    if pending then
      real:execute(pending.code, pending.handlers)
    end
  end)
end

function Client:execute(code, handlers)
  if self._real then
    self._real:execute(code, handlers)
    return
  end
  self._pending = { code = code, handlers = handlers }
  if not self._booting then
    self:_boot()
  end
end

-- Swap the boot recipe (a connection switch): the current real client is
-- shut down NOW and the next execute boots through the new factory. The
-- store's serial queue and handlers survive untouched.
function Client:rebase(factory)
  self._factory = factory
  self._gen = self._gen + 1
  if self._real then
    local old = self._real
    self._real = nil
    if old.shutdown then
      old:shutdown()
    end
  end
end

function Client:interrupt()
  if self._real then
    self._real:interrupt()
  end
end

function Client:restart(cb)
  if self._real and self._real.restart then
    self._real:restart(cb)
  elseif cb then
    cb()
  end
end

function Client:shutdown(cb)
  if self._real and self._real.shutdown then
    self._real:shutdown(cb)
  elseif cb then
    cb()
  end
end

return M
