-- The .ipynb (nbformat 4) round trip. Decode produces store-shaped cells
-- plus preserved bookkeeping; encode rewrites ONLY what perijove owns (cell
-- sources, outputs, execution counts) and carries everything else through
-- verbatim — cell ids, metadata, attachments, unknown fields, nbformat
-- versions. Output style matches nbformat's own json.dumps(indent=1,
-- sort_keys=True), so diffs against jupyter-touched files stay minimal.
--
-- Empty-container fidelity rides vim.json's decode tagging: empty JSON
-- objects carry the vim.empty_dict() metatable, empty arrays stay plain
-- tables, and the emitter below preserves the distinction.

local M = {}

---------------------------------------------------------------------------
-- Canonical JSON (sorted keys, indent 1)
---------------------------------------------------------------------------

local empty_dict_mt = getmetatable(vim.empty_dict())

local function is_empty_dict(t)
  return getmetatable(t) == empty_dict_mt
end

local function to_json(v, depth)
  if v == vim.NIL then
    return "null"
  end
  if type(v) ~= "table" then
    return vim.json.encode(v) -- scalars: numbers, booleans, escaped strings
  end
  local pad = (" "):rep(depth)
  local inner = (" "):rep(depth + 1)
  if next(v) == nil then
    return is_empty_dict(v) and "{}" or "[]"
  end
  if vim.islist(v) then
    local parts = {}
    for _, item in ipairs(v) do
      parts[#parts + 1] = inner .. to_json(item, depth + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ("%s%s: %s"):format(inner, vim.json.encode(tostring(k)), to_json(v[k], depth + 1))
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

function M.to_json(v)
  return to_json(v, 0)
end

---------------------------------------------------------------------------
-- Source and mime-bundle line conventions
---------------------------------------------------------------------------

-- nbformat stores multi-line text as a list of lines, each keeping its
-- trailing newline; a bare string is also legal on the way in.
local function join_lines(v)
  if type(v) == "table" then
    return table.concat(v)
  end
  return v or ""
end

local function split_lines(s)
  if s == "" then
    return {}
  end
  local lines = {}
  local pieces = vim.split(s, "\n")
  for i, piece in ipairs(pieces) do
    lines[i] = i < #pieces and (piece .. "\n") or piece
  end
  -- a trailing newline leaves an empty last piece; drop it (its "\n" already
  -- rides on the previous line)
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

-- mime bundles: text-typed values arrive as line lists; join for the store,
-- split back on encode. Non-string payloads (application/json, ...) pass
-- through untouched.
local function join_mime(data)
  local out = vim.empty_dict()
  for mime, v in pairs(data or {}) do
    if type(v) == "table" and (v[1] == nil or type(v[1]) == "string") and not is_empty_dict(v) then
      out[mime] = join_lines(v)
    else
      out[mime] = v
    end
  end
  return out
end

local function split_mime(data)
  local out = vim.empty_dict()
  for mime, v in pairs(data or {}) do
    if type(v) == "string" then
      out[mime] = split_lines(v)
    else
      out[mime] = v
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Outputs: nbformat <-> the store's tagged kinds
---------------------------------------------------------------------------

local function decode_output(o)
  if o.output_type == "stream" then
    return { kind = "stream", name = o.name, text = join_lines(o.text) }
  elseif o.output_type == "execute_result" then
    return { kind = "result", data = join_mime(o.data), metadata = o.metadata }
  elseif o.output_type == "display_data" then
    return { kind = "display", data = join_mime(o.data), metadata = o.metadata }
  elseif o.output_type == "error" then
    return { kind = "error", ename = o.ename, evalue = o.evalue, traceback = o.traceback }
  end
  -- anything we don't model is carried through untouched
  return { kind = "unknown", raw = o }
end

local function encode_output(out, execution_count)
  if out.kind == "stream" then
    return { output_type = "stream", name = out.name, text = split_lines(out.text) }
  elseif out.kind == "result" then
    return {
      output_type = "execute_result",
      data = split_mime(out.data),
      metadata = out.metadata or vim.empty_dict(),
      execution_count = execution_count or vim.NIL,
    }
  elseif out.kind == "display" then
    return {
      output_type = "display_data",
      data = split_mime(out.data),
      metadata = out.metadata or vim.empty_dict(),
    }
  elseif out.kind == "error" then
    return {
      output_type = "error",
      ename = out.ename,
      evalue = out.evalue,
      traceback = out.traceback or {},
    }
  end
  return out.raw
end

---------------------------------------------------------------------------
-- nbformat 3 (IPython "worksheets") -> 4, upgraded on read like jupyter
-- does. Cells flatten out of the worksheets; heading cells become markdown;
-- code cells rename input/prompt_number; outputs trade the old shapes
-- (pyout/pyerr, mime shorthand keys) for the v4 ones. Saving writes v4.
---------------------------------------------------------------------------

-- v3 outputs carry mime payloads as top-level shorthand keys
local V3_MIME = {
  text = "text/plain",
  html = "text/html",
  svg = "image/svg+xml",
  png = "image/png",
  jpeg = "image/jpeg",
  latex = "text/latex",
  json = "application/json",
  javascript = "application/javascript",
  pdf = "application/pdf",
}

local function v3_mime_bundle(o)
  local data = vim.empty_dict()
  for short, mime in pairs(V3_MIME) do
    if o[short] ~= nil then
      data[mime] = o[short]
    end
  end
  return data
end

local function upgrade_v3_output(o)
  if o.output_type == "stream" then
    return { output_type = "stream", name = o.stream or "stdout", text = o.text }
  elseif o.output_type == "pyout" then
    return {
      output_type = "execute_result",
      data = v3_mime_bundle(o),
      metadata = vim.empty_dict(),
      execution_count = o.prompt_number,
    }
  elseif o.output_type == "display_data" then
    return { output_type = "display_data", data = v3_mime_bundle(o), metadata = vim.empty_dict() }
  elseif o.output_type == "pyerr" then
    return { output_type = "error", ename = o.ename, evalue = o.evalue, traceback = o.traceback or {} }
  end
  return o
end

local function upgrade_v3_cell(c)
  local metadata = c.metadata or vim.empty_dict()
  if c.cell_type == "heading" then
    return {
      cell_type = "markdown",
      metadata = metadata,
      source = ("#"):rep(c.level or 1) .. " " .. join_lines(c.source),
    }
  elseif c.cell_type == "code" then
    local outputs = {}
    for _, o in ipairs(c.outputs or {}) do
      outputs[#outputs + 1] = upgrade_v3_output(o)
    end
    return {
      cell_type = "code",
      metadata = metadata,
      source = c.input,
      execution_count = c.prompt_number,
      outputs = outputs,
    }
  end
  return { cell_type = c.cell_type, metadata = metadata, source = c.source }
end

local function upgrade_v3(nb)
  local cells = {}
  for _, ws in ipairs(nb.worksheets or {}) do
    for _, c in ipairs(ws.cells or {}) do
      cells[#cells + 1] = upgrade_v3_cell(c)
    end
  end
  local metadata = nb.metadata or vim.empty_dict()
  metadata.name, metadata.signature = nil, nil -- v3-only top-level fields
  return { cells = cells, metadata = metadata, nbformat = 4, nbformat_minor = 5 }
end

---------------------------------------------------------------------------
-- The document
---------------------------------------------------------------------------

-- What perijove owns per cell; everything else is bookkeeping to carry.
local OWNED = { cell_type = true, source = true, outputs = true, execution_count = true }

-- decode(text) -> { meta, cells }: meta is the top-level notebook table
-- minus cells; each cell is store-shaped plus .meta (its unowned fields).
-- Legacy nbformat 3 is upgraded in place (doc.upgraded_from says so, meta
-- already reads nbformat 4); anything that is not a notebook errors.
function M.decode(text)
  local nb = vim.json.decode(text, { luanil = { object = true, array = true } })
  if type(nb) ~= "table" or type(nb.nbformat) ~= "number" then
    error("no nbformat field; this is not a Jupyter notebook", 0)
  end
  local upgraded_from
  if nb.nbformat == 3 then
    nb = upgrade_v3(nb)
    upgraded_from = 3
  elseif nb.nbformat ~= 4 then
    error(("unsupported nbformat %d (perijove reads 3 and 4)"):format(nb.nbformat), 0)
  end
  local cells = {}
  for _, c in ipairs(nb.cells or {}) do
    local meta = {}
    for k, v in pairs(c) do
      if not OWNED[k] then
        meta[k] = v
      end
    end
    local outputs = {}
    for _, o in ipairs(c.outputs or {}) do
      outputs[#outputs + 1] = decode_output(o)
    end
    cells[#cells + 1] = {
      type = c.cell_type,
      source = join_lines(c.source),
      execution_count = c.execution_count,
      outputs = outputs,
      meta = meta,
    }
  end
  local meta = {}
  for k, v in pairs(nb) do
    if k ~= "cells" then
      meta[k] = v
    end
  end
  return { meta = meta, cells = cells, upgraded_from = upgraded_from }
end

local id_counter = 0

local function new_cell_id()
  id_counter = id_counter + 1
  return ("jd-%x-%d"):format(vim.uv.hrtime(), id_counter)
end

-- encode(meta, cells) -> nbformat JSON text. `cells` are store-shaped (the
-- store's own bookkeeping like .id/.state is ignored; .meta is merged back).
function M.encode(meta, cells)
  local out_cells = {}
  for _, cell in ipairs(cells) do
    local c = {
      cell_type = cell.type,
      source = split_lines(cell.source or ""),
    }
    if cell.type == "code" then
      c.execution_count = cell.execution_count or vim.NIL
      c.outputs = {}
      for _, o in ipairs(cell.outputs or {}) do
        c.outputs[#c.outputs + 1] = encode_output(o, cell.execution_count)
      end
    end
    for k, v in pairs(cell.meta or {}) do
      c[k] = v
    end
    c.id = c.id or new_cell_id()
    c.metadata = c.metadata or vim.empty_dict()
    out_cells[#out_cells + 1] = c
  end
  local nb = { cells = out_cells }
  for k, v in pairs(meta) do
    nb[k] = v
  end
  return M.to_json(nb) .. "\n"
end

-- Top-level skeleton for a brand-new notebook.
function M.new_meta()
  return { metadata = vim.empty_dict(), nbformat = 4, nbformat_minor = 5 }
end

return M
