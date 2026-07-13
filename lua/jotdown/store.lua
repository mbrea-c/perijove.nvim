-- The notebook store: the single source of truth the UI renders from.
-- Owns the cell list, each cell's execution state machine
-- (idle -> queued -> running -> ok/error), the SERIAL execution queue (one
-- execute in flight, ever — the store, not the kernel, owns ordering), and
-- output accumulation. Pure Lua over the kernel-client contract
-- (jotdown.client), so the whole thing is spec-driven with a fake client.
--
-- Cells are plain tables:
--   { id, type = "code"|"markdown", source, outputs = {}, state,
--     execution_count }
-- Outputs are tagged unions, consecutive same-name stream chunks coalesced:
--   { kind = "stream", name, text }
--   { kind = "result",  data, metadata }   execute_result mime bundle
--   { kind = "display", data, metadata }   display_data mime bundle
--   { kind = "error", ename, evalue, traceback }

local M = {}

local Store = {}
Store.__index = Store

function M.new(client)
  local st = setmetatable({
    cells = {},
    kernel_status = "unknown",
    client = client,
    _next_id = 0,
    _queue = {}, -- cell ids waiting; head runs only after the current settles
    _running = nil, -- id of the cell whose execute is in flight
    _subs = {},
  }, Store)
  client:attach({
    on_status = function(status)
      st.kernel_status = status
      st:_notify()
    end,
  })
  return st
end

---------------------------------------------------------------------------
-- Subscription
---------------------------------------------------------------------------

function Store:subscribe(fn)
  self._subs[fn] = true
  return function()
    self._subs[fn] = nil
  end
end

function Store:_notify()
  for fn in pairs(self._subs) do
    fn()
  end
end

---------------------------------------------------------------------------
-- Cell CRUD
---------------------------------------------------------------------------

function Store:insert_cell(pos, spec)
  self._next_id = self._next_id + 1
  local cell = {
    id = "c" .. self._next_id,
    type = spec.type or "code",
    source = spec.source or "",
    outputs = {},
    state = "idle",
    execution_count = nil,
  }
  table.insert(self.cells, pos, cell)
  self:_notify()
  return cell.id
end

-- The cell table for an id, or nil once deleted.
function Store:cell(id)
  local _, cell = self:_find(id)
  return cell
end

function Store:_find(id)
  for i, cell in ipairs(self.cells) do
    if cell.id == id then
      return i, cell
    end
  end
end

function Store:set_source(id, text)
  local _, cell = self:_find(id)
  if cell then
    cell.source = text
    self:_notify()
  end
end

function Store:delete_cell(id)
  local i = self:_find(id)
  if i then
    self:_unqueue(id)
    table.remove(self.cells, i)
    self:_notify()
  end
end

-- Move a cell by a signed offset, clamped to the document.
function Store:move_cell(id, delta)
  local i, cell = self:_find(id)
  if not i then
    return
  end
  local j = math.max(1, math.min(#self.cells, i + delta))
  if j ~= i then
    table.remove(self.cells, i)
    table.insert(self.cells, j, cell)
    self:_notify()
  end
end

---------------------------------------------------------------------------
-- Execution: serial queue over client:execute
---------------------------------------------------------------------------

function Store:run_cell(id)
  local _, cell = self:_find(id)
  -- markdown never executes; queued/running cells are already on their way
  if not cell or cell.type ~= "code" or cell.state == "queued" or cell.state == "running" then
    return
  end
  cell.state = "queued"
  table.insert(self._queue, id)
  self:_dispatch()
  self:_notify()
end

function Store:run_all()
  for _, cell in ipairs(self.cells) do
    if cell.type == "code" then
      self:run_cell(cell.id)
    end
  end
end

-- Interrupt the kernel; queued cells back out immediately, the running cell
-- settles through its own on_error/on_done when the kernel reports back.
function Store:interrupt()
  self:_clear_queue()
  self.client:interrupt()
  self:_notify()
end

function Store:_clear_queue()
  for _, id in ipairs(self._queue) do
    local _, cell = self:_find(id)
    if cell then
      cell.state = "idle"
    end
  end
  self._queue = {}
end

function Store:_unqueue(id)
  for i, queued in ipairs(self._queue) do
    if queued == id then
      table.remove(self._queue, i)
      return
    end
  end
end

function Store:_dispatch()
  if self._running or #self._queue == 0 then
    return
  end
  local id = table.remove(self._queue, 1)
  local _, cell = self:_find(id)
  if not cell then
    return self:_dispatch() -- deleted while queued; try the next
  end
  self._running = id
  cell.state = "running"
  cell.outputs = {}
  self.client:execute(cell.source, self:_exec_handlers(id))
end

-- The handler set for one execution. Every callback re-finds the cell by id
-- so a cell deleted mid-run is simply a no-op target, and closes over nothing
-- mutable but the store.
function Store:_exec_handlers(id)
  local function with_cell(fn)
    return function(...)
      local _, cell = self:_find(id)
      if cell then
        fn(cell, ...)
        self:_notify()
      end
    end
  end
  return {
    on_stream = with_cell(function(cell, name, text)
      local last = cell.outputs[#cell.outputs]
      if last and last.kind == "stream" and last.name == name then
        last.text = last.text .. text
      else
        table.insert(cell.outputs, { kind = "stream", name = name, text = text })
      end
    end),
    on_result = with_cell(function(cell, data, metadata)
      table.insert(cell.outputs, { kind = "result", data = data, metadata = metadata })
    end),
    on_display = with_cell(function(cell, data, metadata)
      table.insert(cell.outputs, { kind = "display", data = data, metadata = metadata })
    end),
    on_error = with_cell(function(cell, ename, evalue, traceback)
      table.insert(cell.outputs, { kind = "error", ename = ename, evalue = evalue, traceback = traceback })
    end),
    on_done = function(reply)
      self._running = nil
      local _, cell = self:_find(id)
      if cell then
        cell.state = reply.status == "ok" and "ok" or "error"
        cell.execution_count = reply.execution_count
      end
      if reply.status ~= "ok" then
        -- Jupyter aborts requests queued behind a failure; mirror that
        self:_clear_queue()
      end
      self:_dispatch()
      self:_notify()
    end,
  }
end

return M
