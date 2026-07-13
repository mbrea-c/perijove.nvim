-- The notebook view: a fibrous document projecting the store. First slice —
-- kernel status line, markdown cells rendered rich (ui.markdown; the focused
-- editing UX is TBD, see README), code cells as per-cell REAL buffers in
-- render="focus" subwindows (unfocused you see the painted mirror, focusing
-- reveals the live float with native filetype/undo), outputs beneath.
--
-- Source-of-truth rules for code text:
--   - the store is authoritative when mutated through its API: a re-render
--     writes cell.source into the cell's buffer iff it changed store-side
--     since the last sync (tracked in `synced`), so user edits in the buffer
--     are never clobbered by unrelated re-renders;
--   - the buffer is authoritative at RUN time: run syncs buffer -> store
--     before queueing, so you always execute what you see.
--
-- No memoization yet: every store notify re-renders the whole column. Fine
-- for the demo scale; per-cell `memo = true` (the weave transcript pattern)
-- is the planned fix when notebooks grow.

local ui = require("fibrous").ui
local targets = require("fibrous.targets")

local M = {}

-- The keybind principle (see README): ONE prefix, every jotdown bind is a
-- chord under it, nothing else is touched. Stock <C-j> in normal mode is
-- <NL>, a synonym for `j` — free to steal; setup({ prefix = ... }) rebinds.
M.PREFIX = "<C-j>"

-- The per-cell chord suffixes: run, run-and-advance, add below/above,
-- delete, retype, move down/up.
local SUFFIXES = { "r", "<CR>", "o", "O", "d", "m", "J", "K" }

-- Keys the host mount must route to per-component on_key handlers (the
-- `keys` mount option). Rebuilt by configure().
M.KEYS = {}

function M.configure(opts)
  if opts and opts.prefix then
    M.PREFIX = opts.prefix
  end
  M.KEYS = {}
  for i, s in ipairs(SUFFIXES) do
    M.KEYS[i] = M.PREFIX .. s
  end
end
M.configure({})

local STATE_ICON = {
  idle = " ",
  queued = "…",
  running = "▶",
  ok = "✓",
  error = "✗",
}

---------------------------------------------------------------------------
-- Per-cell scratch buffers for code cells
---------------------------------------------------------------------------

-- Get-or-create the real buffer behind a code cell, honoring the sync rules
-- above. `slot` is a use_ref payload: { bufs = {id -> bufnr}, synced = {id -> source} }.
-- When the view is wired to a file (props.on_cell_write), cell buffers are
-- NAMED acwrite buffers, so :w inside a focused cell routes to the notebook
-- save instead of erroring on a nameless scratch buffer.
local function ensure_buf(slot, cell, on_cell_write)
  local buf = slot.bufs[cell.id]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "python"
    if on_cell_write then
      vim.bo[buf].buftype = "acwrite"
      vim.api.nvim_buf_set_name(buf, ("jotdown://%d/cell/%s"):format(buf, cell.id))
      vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
          on_cell_write()
        end,
      })
    end
    slot.bufs[cell.id] = buf
    slot.synced[cell.id] = nil -- force the initial write below
  end
  if slot.synced[cell.id] ~= cell.source then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(cell.source, "\n"))
    slot.synced[cell.id] = cell.source
    vim.bo[buf].modified = false
  end
  return buf
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---------------------------------------------------------------------------
-- Output rendering
---------------------------------------------------------------------------

local function text_lines(text, hl)
  -- strip ANSI SGR sequences (ipykernel colors its tracebacks); parsing them
  -- into real highlights is on pending_tasks.md
  text = text:gsub("\27%[[%d;]*m", "")
  local children = {}
  for _, line in ipairs(vim.split(text:gsub("\n$", ""), "\n")) do
    children[#children + 1] = { comp = ui.text, props = { text = line, style = hl and { text_hl = hl } or nil } }
  end
  return children
end

local function output_node(out)
  if out.kind == "stream" then
    return {
      comp = ui.col,
      props = {},
      children = text_lines(out.text, out.name == "stderr" and "WarningMsg" or nil),
    }
  elseif out.kind == "result" or out.kind == "display" then
    -- mime dispatch is a later milestone; text/plain is the universal floor
    local text = out.data["text/plain"] or ("<" .. next(out.data) .. ">")
    return { comp = ui.col, props = {}, children = text_lines(text) }
  elseif out.kind == "error" then
    local children = text_lines(out.ename .. ": " .. out.evalue, "ErrorMsg")
    for _, line in ipairs(out.traceback) do
      vim.list_extend(children, text_lines(line, "ErrorMsg"))
    end
    return { comp = ui.col, props = {}, children = children }
  end
end

local function outputs_node(cell)
  if #cell.outputs == 0 then
    return nil
  end
  local children = {}
  for _, out in ipairs(cell.outputs) do
    children[#children + 1] = output_node(out)
  end
  return {
    comp = ui.col,
    props = { style = { padding = { x = 1 } } },
    children = children,
  }
end

---------------------------------------------------------------------------
-- Cell navigation: anchors and jumps
---------------------------------------------------------------------------

-- Every code cell's header marker carries a role naming its cell, purely as
-- an identity channel: fibrous.targets passes role strings through verbatim,
-- so the marker's geometry is findable by cell id (activation ignores
-- non-button roles; the only visible effect is hover on the marker, which is
-- honest — it IS a jump target).
local function anchor_role(id)
  return "jotdown:cell:" .. id
end

-- Land the cursor on cell `id`'s header anchor in `win` (the mount's root
-- window). Targets are viewport-filtered, but the root buffer already holds
-- the whole painted document, so paging topline through it finds any cell —
-- no repaint needed.
local function jump_to_cell(win, id)
  local role = anchor_role(id)
  local function find()
    return targets.targets({
      winid = win,
      predicate = function(t)
        return t.role == role
      end,
    })[1]
  end
  local t = find()
  if not t then
    vim.api.nvim_win_call(win, function()
      local h = vim.api.nvim_win_get_height(win)
      local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
      local top = 1
      while top <= last and not t do
        vim.fn.winrestview({ topline = top })
        t = find()
        top = top + h
      end
    end)
  end
  if t then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { t.pos[1], t.pos[2] })
    -- API cursor moves fire no autocmds, but fibrous's interaction layer
    -- anchors the cursor to the element under it ON CursorMoved — without
    -- this, the next flush's reanchor snaps the cursor back to the old cell
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
  end
end

-- Advance from `cell`: land on the next code cell, appending a fresh one
-- right below when there is none (the Jupyter run-and-advance staple).
local function advance(store, cell)
  local i = store:index(cell.id)
  if not i then
    return
  end
  local next_id
  for j = i + 1, #store.cells do
    if store.cells[j].type == "code" then
      next_id = store.cells[j].id
      break
    end
  end
  next_id = next_id or store:insert_cell(i + 1, { type = "code", source = "" })
  jump_to_cell(vim.api.nvim_get_current_win(), next_id)
end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

-- The management chords shared by every cell, keyed for on_key routing.
-- `sync` (code cells) pulls the cell buffer into the store first, so a
-- retype never drops text typed since the last run.
local function cell_ops(store, cell, sync)
  local function insert_at(pos)
    local id = store:insert_cell(pos, { type = "code", source = "" })
    jump_to_cell(vim.api.nvim_get_current_win(), id)
  end
  return {
    [M.PREFIX .. "o"] = function()
      insert_at((store:index(cell.id) or #store.cells) + 1)
    end,
    [M.PREFIX .. "O"] = function()
      insert_at(store:index(cell.id) or 1)
    end,
    [M.PREFIX .. "d"] = function()
      store:delete_cell(cell.id)
    end,
    [M.PREFIX .. "m"] = function()
      if sync then
        sync()
      end
      store:set_type(cell.id, cell.type == "code" and "markdown" or "code")
    end,
    [M.PREFIX .. "J"] = function()
      store:move_cell(cell.id, 1)
    end,
    [M.PREFIX .. "K"] = function()
      store:move_cell(cell.id, -1)
    end,
  }
end

local function code_cell(store, slot, cell, on_cell_write)
  local buf = ensure_buf(slot, cell, on_cell_write)
  local mark = cell.execution_count and ("In [" .. cell.execution_count .. "]") or "In [ ]"
  local sync = function()
    store:set_source(cell.id, buf_text(buf))
  end
  local run = function()
    sync()
    store:run_cell(cell.id)
  end
  local keys = cell_ops(store, cell, sync)
  keys[M.PREFIX .. "r"] = run
  keys[M.PREFIX .. "<CR>"] = function()
    run()
    advance(store, cell)
  end
  -- chords-from-inside: the root-buffer on_key routing below only covers the
  -- page; buffer-local chords make the same binds work while the cell's
  -- float is focused (normal mode; leave insert-mode <C-j> alone). Run stays
  -- in place; everything else pops focus to the root first (fibrous's <Esc>
  -- lands the root cursor on this cell's mirror) so jumps and re-renders
  -- never happen under a float that is being torn down.
  if not slot.mapped[cell.id] then
    slot.mapped[cell.id] = true
    vim.keymap.set("n", M.PREFIX .. "r", run, { buffer = buf, desc = "jotdown: run this cell" })
    for lhs, fn in pairs(keys) do
      if lhs ~= M.PREFIX .. "r" then
        vim.keymap.set("n", lhs, function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
          fn()
        end, { buffer = buf, desc = "jotdown: cell chord" })
      end
    end
  end
  local header = {
    comp = ui.row,
    props = { gap = 1 },
    children = {
      {
        comp = ui.text,
        props = {
          text = mark .. " " .. STATE_ICON[cell.state],
          style = { text_hl = "Special" },
          role = anchor_role(cell.id), -- the cell's jump anchor (see above)
        },
      },
      { comp = ui.button, props = { label = "run", on_press = run } },
    },
  }
  local editor = {
    comp = ui.raw_buffer,
    props = { bufnr = buf, render = "focus", style = { border = true } },
  }
  return {
    comp = ui.col,
    -- keyed by cell id: inserts and moves must MOVE this fiber (keeping the
    -- subwindow bound to this cell's buffer), never morph it into a neighbor
    key = cell.id,
    -- on_key fires for the component under the cursor: anywhere on this
    -- cell — header, mirror, outputs — the chords target THIS cell
    props = { gap = 0, on_key = keys },
    children = { header, editor, outputs_node(cell) },
  }
end

local function markdown_cell(store, cell)
  -- render="focus" subwindow editing for markdown is the TBD next step
  -- (leaning split-preview, see README); until decided it renders rich,
  -- always. Management chords work here too; <CR> just advances (Jupyter's
  -- run-on-markdown renders and moves on).
  local keys = cell_ops(store, cell, nil)
  keys[M.PREFIX .. "<CR>"] = function()
    advance(store, cell)
  end
  return {
    comp = ui.col,
    key = cell.id,
    props = { on_key = keys },
    children = { { comp = ui.markdown, props = { text = cell.source } } },
  }
end

---------------------------------------------------------------------------
-- The document
---------------------------------------------------------------------------

function M.Notebook(ctx, props)
  local store = props.store

  -- re-render on every store notify
  local tick = ctx.use_state(0)
  ctx.use_effect(function()
    return store:subscribe(function()
      tick.set(tick.get() + 1)
    end)
  end, {})

  -- per-cell buffers live as long as the view; deleted with it
  local slot = ctx.use_ref(nil)
  if not slot.current then
    slot.current = { bufs = {}, synced = {}, mapped = {} }
  end
  ctx.use_effect(function()
    return function()
      for _, buf in pairs(slot.current.bufs) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end, {})

  -- Publish the imperative surface the file layer needs (the weave counter
  -- pattern: stable closures, published once). sync_to_store pulls every
  -- cell buffer's text into the store — the save path calls it so you
  -- always save what you see; each_cell_buf lets the saver clear modified
  -- flags after a write.
  if props.actions then
    ctx.use_effect(function()
      props.actions.current = {
        sync_to_store = function()
          for id, buf in pairs(slot.current.bufs) do
            if vim.api.nvim_buf_is_valid(buf) and store:cell(id) then
              local text = buf_text(buf)
              if text ~= store:cell(id).source then
                store:set_source(id, text)
              end
              slot.current.synced[id] = store:cell(id).source
            end
          end
        end,
        each_cell_buf = function(fn)
          for _, buf in pairs(slot.current.bufs) do
            if vim.api.nvim_buf_is_valid(buf) then
              fn(buf)
            end
          end
        end,
      }
    end, {})
  end

  local children = {
    {
      comp = ui.text,
      props = { text = "kernel: " .. store.kernel_status, style = { text_hl = "Comment" } },
    },
  }
  for _, cell in ipairs(store.cells) do
    if cell.type == "code" then
      children[#children + 1] = code_cell(store, slot.current, cell, props.on_cell_write)
    else
      children[#children + 1] = markdown_cell(store, cell)
    end
  end

  return {
    comp = ui.col,
    props = { grow = 1, gap = 1, style = { padding = { x = 1 } } },
    children = children,
  }
end

return M
