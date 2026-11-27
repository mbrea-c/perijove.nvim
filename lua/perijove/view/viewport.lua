-- Fibrous measures rows by ordinal. A notebook can insert, remove and move
-- cells, so carry its two view anchors across a change of order by cell ID.
local Visibility = require("fibrous.inline.visibility")
local Viewport = setmetatable({}, { __index = Visibility })
Viewport.__index = Viewport

function Viewport.new(store)
  local self = setmetatable(Visibility.new({ estimate = 4, gap = 1 }), Viewport)
  self.store = store
  self.ids = {}
  return self
end

function Viewport:cells(ctx)
  -- The kernel status is item 1. Each cell occupies exactly one list item.
  local first, last = self:use_range(ctx, #self.store.cells + 1, self.store.order_rev)
  local ids = {}
  for index = math.max(first, 2), last do
    ids[index] = self.store.cells[index - 1].id
  end
  self.ids = ids
  return first, last
end

function Viewport:invalidate()
  Visibility.invalidate(self)
  local anchor = self.saved_anchor
  if not anchor then
    return
  end

  local count = #self.store.cells + 1
  local function relocate(index)
    local id = self.ids[index]
    local pos = id and self.store:index(id)
    return pos and pos + 1 or math.min(index, count)
  end
  anchor[1], anchor[3] = relocate(anchor[1]), relocate(anchor[3])
  -- A long move can separate the cursor's cell from the old top cell.
  -- Include the cursor in the first materialized band in that case.
  local top = self:offset(anchor[1] - 1) + anchor[2]
  local cursor = self:offset(anchor[3] - 1) + anchor[4]
  if cursor < top or cursor >= top + self.height then
    anchor[1], anchor[2] = anchor[3], anchor[4]
    top = cursor
  end
  self.top, self.tail = top, false
end

function Viewport:flush(target, tree, list, width, ns)
  -- The target owns the canvas buffer. Resolve its actual window here so
  -- embedded notebooks and standalone floats both follow their own scroll.
  if not self.win then
    local win = vim.fn.bufwinid(target.bufnr)
    if win ~= -1 then
      self:bind(win)
      -- A notebook's host window can already show another notebook by the
      -- time its deferred teardown runs. Release its window hooks on wipe.
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = target.bufnr,
        group = self.group,
        once = true,
        callback = function()
          self:close()
        end,
      })
    end
  end
  return Visibility.flush(self, target, tree, list, width, ns)
end

return Viewport
