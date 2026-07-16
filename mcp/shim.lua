-- perijove MCP stdio shim. Run as: nvim -l shim.lua
--
-- The MCP client launches this as its server subprocess. It connects to the
-- PARENT nvim over $NVIM (inherited by any process spawned from that nvim's
-- :terminal) and relays each JSON-RPC frame to perijove.mcp.handle() running
-- there, where the live notebook sessions are. No protocol logic and no tool
-- definitions live here.
--
-- Spec invariants (modelcontextprotocol.io 2025-06-18):
--  * stdio frames are newline-delimited, UTF-8, no embedded newlines.
--  * stdout carries ONLY MCP messages; logging goes to stderr.

local function log(msg)
  io.stderr:write("[perijove-mcp shim] " .. msg .. "\n")
end

local socket = vim.env.NVIM
if not socket or socket == "" then
  log("$NVIM is not set; this shim must be launched from within a Neovim :terminal")
  os.exit(1)
end

local ok, chan = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
if not ok or not chan or chan == 0 then
  log("failed to connect to parent nvim at " .. socket .. ": " .. tostring(chan))
  os.exit(1)
end

while true do
  local line = io.read("l")
  if line == nil then
    break -- stdin closed: graceful shutdown
  end
  if line ~= "" then
    -- decode in the parent nvim, so empty-table/JSON edge cases are handled
    -- in exactly one place; empty string back means "notification, no reply"
    local res_ok, response = pcall(
      vim.rpcrequest,
      chan,
      "nvim_exec_lua",
      [[
        local raw = ...
        local decoded = vim.json.decode(raw)
        local out = require("perijove.mcp").handle(decoded)
        if out == nil then return "" end
        return vim.json.encode(out)
      ]],
      { line }
    )

    if not res_ok then
      log("rpcrequest failed: " .. tostring(response))
      local id = nil
      local pok, parsed = pcall(vim.json.decode, line)
      if pok and type(parsed) == "table" then
        id = parsed.id
      end
      io.write(vim.json.encode({
        jsonrpc = "2.0",
        id = id,
        error = { code = -32603, message = "perijove-mcp bridge error: " .. tostring(response) },
      }) .. "\n")
      io.flush()
    elseif response ~= "" then
      io.write(response .. "\n")
      io.flush()
    end
  end
end
