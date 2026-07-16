-- perijove MCP server: live notebooks as tools for external agents.
--
-- An agent editing the .ipynb FILE behind nvim's back only meets the
-- external-change intake (reload or keep-with-warning). These tools operate
-- on the LIVE session instead — the store — so edits land in the running
-- notebook exactly like a user's, the view re-renders, the kernel stays,
-- and dirty/save semantics apply.
--
-- Architecture mirrors nvim-mcp (the dumb-shim pattern): a stdio shim
-- (`nvim -l mcp/shim.lua`, spawned by the MCP client from inside a
-- :terminal) forwards each JSON-RPC frame here via nvim_exec_lua; all
-- protocol logic and every tool run in the user's live nvim. Alternatively
-- register_into() plants the same tools into an already-running nvim-mcp
-- style server, so one server carries them all.

local notebook_file = require("perijove.notebook_file")

local M = {}

local PROTOCOL_VERSION = "2025-06-18"

local SERVER_INFO = {
  name = "perijove-mcp",
  version = "0.1.0",
}

---------------------------------------------------------------------------
-- Session and cell resolution
---------------------------------------------------------------------------

local function buf_label(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("[No Name #%d]"):format(bufnr)
end

-- `notebook` argument: nil picks the sole open notebook, a number is the
-- file bufnr, a string matches a path suffix. Errors are messages for the
-- agent, listing what IS open.
local function resolve_session(ref)
  local sessions = {}
  for bufnr, sess in pairs(notebook_file._sessions) do
    sessions[#sessions + 1] = { bufnr = bufnr, sess = sess }
  end
  if #sessions == 0 then
    error("no notebook is open in this nvim", 0)
  end
  if ref == nil then
    if #sessions == 1 then
      return sessions[1].sess
    end
    local names = {}
    for _, s in ipairs(sessions) do
      names[#names + 1] = ("%d: %s"):format(s.bufnr, buf_label(s.bufnr))
    end
    error("several notebooks are open; pass `notebook`:\n" .. table.concat(names, "\n"), 0)
  end
  if type(ref) == "number" then
    local sess = notebook_file._sessions[ref]
    if not sess then
      error(("no notebook session on buffer %d"):format(ref), 0)
    end
    return sess
  end
  for _, s in ipairs(sessions) do
    local name = vim.api.nvim_buf_get_name(s.bufnr)
    if name ~= "" and (name == ref or name:sub(-#ref) == ref) then
      return s.sess
    end
  end
  error(("no open notebook matches %q"):format(ref), 0)
end

-- `cell` argument: a number is the 1-based index, a string the cell id.
local function resolve_cell(sess, ref)
  if type(ref) == "number" then
    local cell = sess.store.cells[ref]
    if not cell then
      error(("cell index %d out of range (%d cells)"):format(ref, #sess.store.cells), 0)
    end
    return cell
  end
  local cell = sess.store:cell(ref)
  if not cell then
    error(("no cell with id %q"):format(tostring(ref)), 0)
  end
  return cell
end

---------------------------------------------------------------------------
-- Rendering store state as text for the agent
---------------------------------------------------------------------------

local MAX_OUTPUT_CHARS = 4000

local function clip(text, limit)
  if #text > limit then
    return text:sub(1, limit) .. ("\n[... %d more chars]"):format(#text - limit)
  end
  return text
end

local function outputs_text(cell)
  local parts = {}
  for _, out in ipairs(cell.outputs or {}) do
    if out.kind == "stream" then
      parts[#parts + 1] = out.text
    elseif out.kind == "result" or out.kind == "display" then
      local data = out.data or {}
      parts[#parts + 1] = type(data["text/plain"]) == "string" and data["text/plain"]
        or ("[%s]"):format(table.concat(vim.tbl_keys(data), ", "))
    elseif out.kind == "error" then
      parts[#parts + 1] = ("%s: %s"):format(out.ename or "error", out.evalue or "")
      if out.traceback then
        -- kernels embed ANSI colours in tracebacks; strip for the agent
        local tb = table.concat(out.traceback, "\n"):gsub("\27%[[%d;]*m", "")
        parts[#parts + 1] = tb
      end
    end
  end
  return clip(table.concat(parts, "\n"), MAX_OUTPUT_CHARS)
end

local function cell_line(i, cell)
  local head = vim.split(cell.source or "", "\n")[1] or ""
  if #head > 72 then
    head = head:sub(1, 72) .. "..."
  end
  local count = cell.execution_count and ("[%d]"):format(cell.execution_count) or "[ ]"
  return ("%2d  %s  %-8s %-7s %s  %s"):format(i, cell.id, cell.type, cell.state or "idle", count, head)
end

---------------------------------------------------------------------------
-- The tools
---------------------------------------------------------------------------

local NOTEBOOK_ARG = {
  description = "which notebook: file bufnr (number) or path suffix (string); omit when only one is open",
}
local CELL_ARG = {
  description = "which cell: 1-based index (number) or cell id (string, see notebook_cells)",
}

local tools = {}

tools.notebook_list = {
  description = "List the notebooks open in this nvim: buffer, path, cell count, kernel status.",
  inputSchema = { type = "object", properties = vim.empty_dict() },
  handler = function()
    local lines = {}
    for bufnr, sess in pairs(notebook_file._sessions) do
      lines[#lines + 1] = ("%d  %s  %d cells  kernel:%s  %s"):format(
        bufnr,
        buf_label(bufnr),
        #sess.store.cells,
        sess.store.kernel_status,
        sess.handle and "mounted" or (sess.raw and "raw view" or "hidden")
      )
    end
    return #lines > 0 and table.concat(lines, "\n") or "no notebooks open"
  end,
}

tools.notebook_cells = {
  description = "List a notebook's cells: index, id, type, state, execution count, first source line.",
  inputSchema = { type = "object", properties = { notebook = NOTEBOOK_ARG } },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local lines = {}
    for i, cell in ipairs(sess.store.cells) do
      lines[#lines + 1] = cell_line(i, cell)
    end
    return #lines > 0 and table.concat(lines, "\n") or "the notebook has no cells"
  end,
}

tools.notebook_read_cell = {
  description = "Read one cell: full source and its outputs (text form).",
  inputSchema = {
    type = "object",
    properties = { notebook = NOTEBOOK_ARG, cell = CELL_ARG },
    required = { "cell" },
  },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local cell = resolve_cell(sess, args.cell)
    local out = outputs_text(cell)
    local text = ("id: %s\ntype: %s\nstate: %s\nsource:\n%s"):format(cell.id, cell.type, cell.state, cell.source)
    if out ~= "" then
      text = text .. "\noutputs:\n" .. out
    end
    return text
  end,
}

tools.notebook_edit_cell = {
  description = "Replace a cell's source in the LIVE notebook. The view updates; the change is unsaved until notebook_save (or the user's :w).",
  inputSchema = {
    type = "object",
    properties = {
      notebook = NOTEBOOK_ARG,
      cell = CELL_ARG,
      source = { type = "string", description = "the new cell source" },
    },
    required = { "cell", "source" },
  },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local cell = resolve_cell(sess, args.cell)
    sess.store:set_source(cell.id, args.source)
    return ("cell %s updated"):format(cell.id)
  end,
}

tools.notebook_insert_cell = {
  description = "Insert a new cell. Omit `index` to append at the end.",
  inputSchema = {
    type = "object",
    properties = {
      notebook = NOTEBOOK_ARG,
      index = { type = "number", description = "1-based position for the new cell; default: append" },
      type = { type = "string", enum = { "code", "markdown" }, description = "cell type; default code" },
      source = { type = "string", description = "initial source; default empty" },
    },
  },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local pos = args.index or (#sess.store.cells + 1)
    local id = sess.store:insert_cell(pos, { type = args.type or "code", source = args.source or "" })
    return ("inserted %s cell %s at index %d"):format(args.type or "code", id, sess.store:index(id))
  end,
}

tools.notebook_delete_cell = {
  description = "Delete a cell from the live notebook.",
  inputSchema = {
    type = "object",
    properties = { notebook = NOTEBOOK_ARG, cell = CELL_ARG },
    required = { "cell" },
  },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local cell = resolve_cell(sess, args.cell)
    sess.store:delete_cell(cell.id)
    return ("cell %s deleted"):format(cell.id)
  end,
}

tools.notebook_run_cell = {
  description = "Run a code cell on the notebook's kernel and wait for it to settle (default 30s; timeout_ms=0 queues without waiting). Returns state and outputs.",
  inputSchema = {
    type = "object",
    properties = {
      notebook = NOTEBOOK_ARG,
      cell = CELL_ARG,
      timeout_ms = { type = "number", description = "how long to wait for the run to settle; 0 = do not wait" },
    },
    required = { "cell" },
  },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local cell = resolve_cell(sess, args.cell)
    if cell.type ~= "code" then
      error(("cell %s is a %s cell; only code cells run"):format(cell.id, cell.type), 0)
    end
    sess.store:run_cell(cell.id)
    local timeout = args.timeout_ms or 30000
    if timeout > 0 then
      vim.wait(timeout, function()
        local c = sess.store:cell(cell.id)
        return not c or (c.state ~= "queued" and c.state ~= "running")
      end, 50)
    end
    local c = sess.store:cell(cell.id)
    if not c then
      return ("cell %s was deleted while running"):format(cell.id)
    end
    local text = ("cell %s state: %s"):format(c.id, c.state)
    local out = outputs_text(c)
    if out ~= "" then
      text = text .. "\noutputs:\n" .. out
    end
    return text
  end,
}

tools.notebook_save = {
  description = "Save the notebook to its .ipynb file (what the user's :w does).",
  inputSchema = { type = "object", properties = { notebook = NOTEBOOK_ARG } },
  handler = function(args)
    local sess = resolve_session(args.notebook)
    local name = vim.api.nvim_buf_get_name(sess.bufnr)
    if name == "" then
      error("the notebook buffer has no file name; the user must :saveas it first", 0)
    end
    notebook_file.save(sess.bufnr)
    return ("saved %s"):format(buf_label(sess.bufnr))
  end,
}

M.tools = tools

-- Plant these tools into an nvim-mcp style server (anything exposing
-- register_tool(name, def)), so one MCP server carries them all.
function M.register_into(server)
  for name, def in pairs(tools) do
    server.register_tool(name, def)
  end
end

---------------------------------------------------------------------------
-- Standalone JSON-RPC handling (the shim's counterpart)
---------------------------------------------------------------------------

local function rpc_result(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

local function rpc_error(id, code, message, data)
  local err = { code = code, message = message }
  if data ~= nil then
    err.data = data
  end
  return { jsonrpc = "2.0", id = id, error = err }
end

local function to_tool_result(ok, ret)
  if not ok then
    -- a Lua error in the handler is a TOOL error (isError), not a protocol
    -- error: the call was well-formed, the tool just failed
    return {
      content = { { type = "text", text = "Tool error: " .. tostring(ret) } },
      isError = true,
    }
  end
  if type(ret) == "table" and ret.content ~= nil then
    return ret
  end
  return {
    content = { { type = "text", text = type(ret) == "string" and ret or vim.inspect(ret) } },
    isError = false,
  }
end

local methods = {}

function methods.initialize(_params)
  return {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = { tools = { listChanged = false } },
    serverInfo = SERVER_INFO,
  }
end

function methods.ping(_params)
  return vim.empty_dict()
end

methods["tools/list"] = function(_params)
  local list = {}
  for name, def in pairs(tools) do
    list[#list + 1] = {
      name = name,
      description = def.description or "",
      inputSchema = def.inputSchema or { type = "object", properties = vim.empty_dict() },
    }
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return { tools = list }
end

methods["tools/call"] = function(params)
  params = params or {}
  local def = tools[params.name]
  if not def then
    return nil, { code = -32602, message = "Unknown tool: " .. tostring(params.name) }
  end
  local ok, ret = pcall(def.handler, params.arguments or {})
  return to_tool_result(ok, ret)
end

-- Handle one decoded JSON-RPC request; returns a decoded response table, or
-- nil for notifications (no reply).
function M.handle(req)
  if type(req) ~= "table" or req.jsonrpc ~= "2.0" then
    return rpc_error(req and req.id, -32600, "Invalid Request")
  end
  local handler = methods[req.method]
  if req.id == nil then
    if handler then
      pcall(handler, req.params)
    end
    return nil
  end
  if not handler then
    return rpc_error(req.id, -32601, "Method not found: " .. tostring(req.method))
  end
  local ok, result, proto_err = pcall(handler, req.params)
  if not ok then
    return rpc_error(req.id, -32603, "Internal error: " .. tostring(result))
  end
  if proto_err then
    return rpc_error(req.id, proto_err.code, proto_err.message, proto_err.data)
  end
  return rpc_result(req.id, result)
end

return M
