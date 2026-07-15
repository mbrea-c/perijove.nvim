-- A scripted kernel client (the weave demo-agent playbook): satisfies the
-- kernel-client contract with canned, timed timelines, so the store and the
-- notebook UI are drivable — and demoable — with zero protocol code.
--
-- The timeline a cell gets is keyed on its source, crude on purpose:
--   contains "sleep"          a slow cell (seconds), the one to interrupt
--   contains "raise"/"error"  an error traceback
--   anything else             streamed stdout, then an execute_result
--
-- Time is injected: opts.defer(ms, fn) defaults to vim.defer_fn scheduling,
-- and specs substitute a hand-cranked queue. Cancellation (interrupt, or a
-- next execute after a wedged one) is a per-execution `live` flag every
-- scheduled step checks before delivering — stale steps are dead, not merely
-- late.

local M = {}

local Client = {}
Client.__index = Client

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _defer = opts.defer or function(ms, fn)
      vim.defer_fn(fn, ms)
    end,
    _count = 0,
    _kernel = nil, -- attach() handlers
    _current = nil, -- { live = true, handlers = h } while an execute runs
  }, Client)
end

function Client:attach(handlers)
  self._kernel = handlers
end

function Client:_status(s)
  if self._kernel and self._kernel.on_status then
    self._kernel.on_status(s)
  end
end

function Client:execute(code, handlers)
  self._count = self._count + 1
  local count = self._count
  local run = { live = true, handlers = handlers }
  self._current = run
  self:_status("busy")

  -- schedule a step at a cumulative offset; delivery is gated on the run
  -- still being live when the clock fires
  local t = 0
  local function at(ms, fn)
    t = t + ms
    self._defer(t, function()
      if run.live then
        fn()
      end
    end)
  end
  local function finish(status)
    run.live = false
    self._current = nil
    handlers.on_done({ status = status, execution_count = count })
    self:_status("idle")
  end

  if code:find("sleep") then
    -- the slow cell: a long gap, then a note that it survived un-interrupted
    at(5000, function()
      handlers.on_stream("stdout", "woke up\n")
    end)
    at(100, function()
      finish("ok")
    end)
  elseif code:find("raise") or code:find("error") then
    at(80, function()
      handlers.on_error("ValueError", "boom", {
        "Traceback (most recent call last):",
        '  File "<cell>", line 1, in <module>',
        "ValueError: boom",
      })
    end)
    at(40, function()
      finish("error")
    end)
  else
    at(60, function()
      handlers.on_stream("stdout", "hello from the scripted kernel\n")
    end)
    at(60, function()
      handlers.on_stream("stdout", "…still streaming…\n")
    end)
    at(60, function()
      handlers.on_result({ ["text/plain"] = "42" }, {})
    end)
    at(60, function()
      finish("ok")
    end)
  end
end

-- Best-effort, like the real thing: kill the running timeline and settle it
-- through the ordinary error + done path, exactly as a kernel-side
-- KeyboardInterrupt would arrive.
function Client:interrupt()
  local run = self._current
  if not run then
    return
  end
  run.live = false
  self._current = nil
  local count = self._count
  self._defer(1, function()
    run.handlers.on_error("KeyboardInterrupt", "", { "KeyboardInterrupt" })
    run.handlers.on_done({ status = "error", execution_count = count })
    self:_status("idle")
  end)
end

return M
