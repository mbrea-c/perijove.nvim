-- A hand-cranked fake kernel client for store/UI specs: satisfies the
-- kernel-client contract (see lua/perijove/client/init.lua) but executes
-- nothing — each execute() is parked in .executions so the spec drives the
-- handler callbacks itself, in exactly the order it wants to test.

local M = {}

function M.new()
  local c = {
    executions = {}, -- { code = ..., handlers = ... } in submission order
    interrupts = 0,
    restarts = 0,
    kernel_handlers = nil, -- from attach()
  }

  function c:attach(handlers)
    self.kernel_handlers = handlers
  end

  function c:execute(code, handlers)
    table.insert(self.executions, { code = code, handlers = handlers })
  end

  function c:interrupt()
    self.interrupts = self.interrupts + 1
  end

  function c:restart(cb)
    self.restarts = self.restarts + 1
    if cb then
      cb()
    end
  end

  function c:shutdown()
    self.shutdowns = (self.shutdowns or 0) + 1
  end

  -- spec-side conveniences ------------------------------------------------

  -- the most recent execution parked on the fake
  function c:last()
    return self.executions[#self.executions]
  end

  -- push a kernel status event as the client would
  function c:push_status(status)
    self.kernel_handlers.on_status(status)
  end

  return c
end

return M
