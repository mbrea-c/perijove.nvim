-- The notebook view: a fibrous document projecting the store. First slice —
-- kernel status line, markdown cells rendered rich (ui.markdown; activation
-- opens split editing, see MarkdownCell), code cells as per-cell REAL buffers
-- in render="focus" subwindows (unfocused you see the painted mirror,
-- focusing reveals the live float with native filetype/undo), outputs beneath.
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
-- delete, retype, move down/up, toggle markdown side previews, fold
-- outputs, clear outputs. (Markdown EDITING has no chord: activation —
-- <CR>/click on the rendered cell — opens the editor.)
local SUFFIXES = { "r", "<CR>", "o", "O", "d", "m", "J", "K", "p", "c", "C" }

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

-- Side previews for markdown-cell editing, jotdown-global: the prefix-p
-- chord flips it from anywhere in a notebook (page or focused cell float).
-- Off = editing is the source buffer alone. Defaults to enabled.
M.preview = true

local STATE_ICON = {
  idle = " ",
  queued = "…",
  running = "▶",
  ok = "✓",
  error = "✗",
}

-- The empty-cell placeholder: grayed AND italic. There is no stock group
-- guaranteeing both, so borrow Comment's foreground and force the italic;
-- `default` keeps a user/colorscheme override authoritative. Re-derived on
-- ColorScheme because `:hi clear` wipes it.
local function define_placeholder_hl()
  local c = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "JotdownPlaceholder", { fg = c.fg, ctermfg = c.ctermfg, italic = true, default = true })
end
define_placeholder_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("JotdownViewHl", {}),
  callback = define_placeholder_hl,
})

---------------------------------------------------------------------------
-- Per-cell scratch buffers for code cells
---------------------------------------------------------------------------

-- Get-or-create the real buffer behind a code cell, honoring the sync rules
-- above. `slot` is a use_ref payload: { bufs = {id -> bufnr}, synced = {id -> source} }.
-- When the view is wired to a file (props.on_cell_write), cell buffers are
-- NAMED acwrite buffers, so :w inside a focused cell routes to the notebook
-- save instead of erroring on a nameless scratch buffer.
local function ensure_buf(slot, cell, on_cell_write, ft)
  local buf = slot.bufs[cell.id]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
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
  -- retypes (code <-> markdown) reuse the buffer with a new language
  if vim.bo[buf].filetype ~= ft then
    vim.bo[buf].filetype = ft
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

-- A result/display mime bundle, best representation first: markdown and
-- latex render rich (ui.markdown handles $...$ through the fibrous math
-- renderer), images degrade to their text/plain repr plus an honest label
-- (real image output is pending), anything else falls back to text/plain.
local function mime_node(data)
  if data["text/markdown"] then
    return { comp = ui.markdown, props = { text = data["text/markdown"] } }
  end
  if data["text/latex"] then
    return { comp = ui.markdown, props = { text = data["text/latex"] } }
  end
  local image = (data["image/png"] and "image/png") or (data["image/jpeg"] and "image/jpeg")
  if image then
    local children = text_lines(data["text/plain"] or "<image>")
    children[#children + 1] = {
      comp = ui.text,
      props = { text = "(" .. image .. " output; inline images pending)", style = { text_hl = "Comment" } },
    }
    return { comp = ui.col, props = {}, children = children }
  end
  local text = data["text/plain"] or ("<" .. (next(data) or "empty") .. ">")
  return { comp = ui.col, props = {}, children = text_lines(text) }
end

local function output_node(out)
  if out.kind == "stream" then
    return {
      comp = ui.col,
      props = {},
      children = text_lines(out.text, out.name == "stderr" and "WarningMsg" or nil),
    }
  elseif out.kind == "result" or out.kind == "display" then
    return mime_node(out.data)
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
  if cell.collapsed then
    return {
      comp = ui.text,
      props = {
        text = ("· output hidden (%d)"):format(#cell.outputs),
        style = { text_hl = "Comment", padding = { x = 1 } },
      },
    }
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

-- Render probe: total cell-component renders, for the memoization spec.
M._probe = { cell_renders = 0 }

-- Both cell components are memoized on shallow prop equality: store, slot,
-- the cell TABLE (mutated in place, so its identity is stable) and the
-- on_cell_write closure never change — `rev` is the one prop that moves,
-- and the store bumps it exactly when this cell is touched. A kernel-status
-- notify or another cell's output stream re-renders no cell here.
local function CodeCell(_, props)
  M._probe.cell_renders = M._probe.cell_renders + 1
  local store, slot, cell, on_cell_write = props.store, props.slot, props.cell, props.on_cell_write
  local buf = ensure_buf(slot, cell, on_cell_write, "python")
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
  keys[M.PREFIX .. "c"] = function()
    store:toggle_output(cell.id)
  end
  keys[M.PREFIX .. "C"] = function()
    store:clear_outputs(cell.id)
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
    -- the preview toggle is notebook-global, so it works from inside a
    -- focused code cell too (in place, no Esc-pop needed)
    vim.keymap.set("n", M.PREFIX .. "p", function()
      local t = slot.toggle_preview
      if t then
        t()
      end
    end, { buffer = buf, desc = "jotdown: toggle markdown side previews" })
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
  local children = { header, editor }
  children[#children + 1] = outputs_node(cell)
  -- stdin: the kernel is blocked in input() on THIS cell — prompt inline,
  -- below the output printed so far, like Jupyter does
  local pending = store.pending_input
  if pending and pending.cell_id == cell.id then
    children[#children + 1] = {
      comp = ui.row,
      props = { gap = 1, style = { padding = { x = 1 } } },
      children = {
        {
          comp = ui.text,
          props = { text = pending.prompt ~= "" and pending.prompt or "input:", style = { text_hl = "Question" } },
        },
        {
          comp = ui.text_input,
          props = {
            width = 30,
            clear_on_submit = true,
            -- an empty input mirrors as nothing: the border IS the field's
            -- visible (and hoverable) presence on the page
            style = { border = "rounded" },
            on_submit = function(value)
              store:answer_input(value)
            end,
          },
        },
        {
          comp = ui.text,
          props = { text = "(<CR> in normal mode submits)", style = { text_hl = "Comment" } },
        },
      },
    }
  end
  return {
    comp = ui.col,
    -- on_key fires for the component under the cursor: anywhere on this
    -- cell — header, mirror, outputs — the chords target THIS cell
    props = { gap = 0, on_key = keys },
    children = children,
  }
end

-- Best-effort source map for activation: the markdown parser keeps no source
-- positions, so map the RENDERED line under the cursor back to source by
-- word overlap — the source line sharing the most words wins (ties: the
-- earliest). Inline markup is punctuation to the word pattern, so words
-- survive rendering for prose, headings and lists; when nothing matches
-- (tables, heavy math) the editor opens at the top.
---@param source string
---@param rendered_line string
---@return integer lnum 1-based source line
function M.source_line_for(source, rendered_line)
  local want, any = {}, false
  for w in rendered_line:gmatch("[%w\128-\255_]+") do
    want[w:lower()] = true
    any = true
  end
  if not any then
    return 1
  end
  local best, best_score = 1, 0
  for i, line in ipairs(vim.split(source, "\n", { plain = true })) do
    local score = 0
    for w in line:gmatch("[%w\128-\255_]+") do
      if want[w:lower()] then
        score = score + 1
      end
    end
    if score > best_score then
      best, best_score = i, score
    end
  end
  return best
end

-- Markdown cells render rich; ACTIVATING one (<CR>/click, like any fibrous
-- widget — there is no dedicated edit chord) opens split editing: the raw
-- source in a REAL markdown buffer on the left (render="always", so it is
-- visible and auto-focused, cursor on the source line matching the activated
-- rendered line), a live rendered preview on the right (repainted from the
-- buffer on every text change; dropped entirely while M.preview is off).
-- Editing ends when the editor buffer loses focus — fibrous <Esc> back to
-- the page, a jump elsewhere — and only then does the store take the text,
-- like code cells take theirs at run. Management chords work here too; the
-- <CR> CHORD just advances (Jupyter's run-on-markdown renders and moves on).
local function MarkdownCell(ctx, props)
  M._probe.cell_renders = M._probe.cell_renders + 1
  local store, slot, cell = props.store, props.slot, props.cell
  local editing = ctx.use_state(false)
  local live = ctx.use_state({}) -- { text? }: the preview while typing

  local keys = cell_ops(store, cell, nil)
  keys[M.PREFIX .. "<CR>"] = function()
    advance(store, cell)
  end

  local function enter_editing(rendered_line)
    live.set({})
    editing.set(true)
    -- land in the editor once this render's flush has opened its float
    vim.schedule(function()
      local buf = slot.bufs[cell.id]
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          vim.api.nvim_set_current_win(win)
          if rendered_line then
            pcall(vim.api.nvim_win_set_cursor, win, { M.source_line_for(cell.source, rendered_line), 0 })
          end
          return
        end
      end
    end)
  end

  local function leave_editing()
    local buf = slot.bufs[cell.id]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      -- the buffer wins on the way out, exactly like a code cell at run
      local text = buf_text(buf)
      slot.synced[cell.id] = text
      store:set_source(cell.id, text)
    end
    editing.set(false)
  end

  -- Published per render so the once-created WinLeave autocmd always calls
  -- the live closures — the playground's `entry.reload` pattern.
  slot.md_leave[cell.id] = function()
    if editing.get() then
      leave_editing()
    end
  end

  if not editing.get() then
    -- borderless — markdown reads as prose on the page, no box chrome; but
    -- never zero-height: an empty cell renders a placeholder so it stays
    -- hoverable (chords hit-test against the cell's box, so there must BE one)
    local body
    if cell.source:find("%S") then
      body = { comp = ui.markdown, props = { text = cell.source } }
    else
      body = {
        comp = ui.text,
        props = { text = "(empty markdown cell)", style = { text_hl = "JotdownPlaceholder" } },
      }
    end
    return {
      comp = ui.col,
      -- the whole cell is an activation target: <CR>/click opens the editor.
      -- The current (root) line at press time is the activated RENDERED line,
      -- which picks the source line the editor's cursor lands on.
      props = {
        on_key = keys,
        role = "button",
        on_press = function()
          enter_editing(vim.api.nvim_get_current_line())
        end,
        style = { padding = { x = 1 } },
      },
      children = { body },
    }
  end

  local buf = ensure_buf(slot, cell, props.on_cell_write, "markdown")
  if not slot.md_mapped[cell.id] then
    slot.md_mapped[cell.id] = true
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      callback = function()
        local fn = slot.live[cell.id]
        if fn then
          fn()
        end
      end,
    })
    -- editing ends when focus leaves the editor. Scheduled with a re-check:
    -- a transient window hop is back before the loop turns, so only a REAL
    -- focus change away from the buffer closes the split.
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = buf,
      callback = function()
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() ~= buf then
            local fn = slot.md_leave[cell.id]
            if fn then
              fn()
            end
          end
        end)
      end,
    })
    vim.keymap.set("n", M.PREFIX .. "p", function()
      local t = slot.toggle_preview
      if t then
        t()
      end
    end, { buffer = buf, desc = "jotdown: toggle markdown side previews" })
  end
  slot.live[cell.id] = function()
    live.set({ text = buf_text(buf) })
  end

  -- one row either way, so the editor keeps its fiber (and float) across a
  -- preview toggle; the preview pane is simply present or not
  local panes = {
    {
      comp = ui.col,
      props = { grow = 1 },
      children = {
        { comp = ui.raw_buffer, props = { bufnr = buf, render = "always", style = { border = true } } },
      },
    },
  }
  if props.preview then
    panes[#panes + 1] = {
      comp = ui.col,
      props = { grow = 1, style = { border = true, padding = { x = 1 } } },
      children = { { comp = ui.markdown, props = { text = live.get().text or cell.source } } },
    }
  end
  return {
    comp = ui.col,
    props = { on_key = keys },
    children = { { comp = ui.row, props = { gap = 1 }, children = panes } },
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
    slot.current = { bufs = {}, synced = {}, mapped = {}, md_mapped = {}, md_leave = {}, live = {} }
  end

  -- The markdown-preview flag lives on the module (jotdown-global); flipping
  -- it re-renders THIS mount through a state bump. Published on the slot so
  -- the buffer-local chord inside a focused cell float reaches the live
  -- closure too.
  local pv = ctx.use_state(0)
  slot.current.toggle_preview = function()
    M.preview = not M.preview
    pv.set(pv.get() + 1)
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

  -- busy-since ticker: while the kernel is busy a 1s timer re-renders the
  -- status line with the elapsed time — matters on remote boxes that bill
  -- while you stare at a spinner
  local busy_since = ctx.use_ref(nil)
  local tick = ctx.use_state(0)
  ctx.use_effect(function()
    if store.kernel_status ~= "busy" then
      busy_since.current = nil
      return
    end
    busy_since.current = vim.uv.now()
    local timer = vim.uv.new_timer()
    timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        tick.set(tick.get() + 1)
      end)
    )
    return function()
      timer:stop()
      timer:close()
    end
  end, { store.kernel_status })

  local status = "kernel: " .. store.kernel_status
  if store.kernel_status == "busy" and busy_since.current then
    local secs = math.floor((vim.uv.now() - busy_since.current) / 1000)
    if secs > 0 then
      status = ("%s · %ds"):format(status, secs)
    end
  end
  local children = {
    {
      comp = ui.text,
      props = { text = status, style = { text_hl = "Comment" } },
    },
  }
  for _, cell in ipairs(store.cells) do
    children[#children + 1] = {
      comp = cell.type == "code" and CodeCell or MarkdownCell,
      -- keyed by cell id: inserts and moves must MOVE this fiber (keeping
      -- a code cell's subwindow bound to its own buffer), never morph it
      -- into a neighbor; memo bails when the cell wasn't touched (rev)
      key = cell.id,
      memo = true,
      props = {
        store = store,
        slot = slot.current,
        cell = cell,
        rev = cell.rev,
        preview = M.preview, -- busts the memo when the global flag flips
        on_cell_write = props.on_cell_write,
      },
    }
  end

  return {
    comp = ui.col,
    props = {
      grow = 1,
      gap = 1,
      style = { padding = { x = 1 } },
      -- page-wide chords: on_key routes to the nearest carrier under the
      -- cursor and nothing deeper carries prefix-p, so this fires anywhere
      on_key = { [M.PREFIX .. "p"] = slot.current.toggle_preview },
    },
    children = children,
  }
end

return M
