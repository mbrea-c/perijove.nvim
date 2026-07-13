-- The wire-transport boundary. A transport turns abstract HTTP requests and
-- websocket channels into bytes on a Jupyter Server, and NOTHING else — no
-- Jupyter message knowledge lives at or below this line, so an implementation
-- can be swapped without touching the protocol layer above (the shipped
-- curl+websocat one, a future pure-Lua vim.uv one, ...). A python-sidecar
-- direction would swap at the coarser kernel-client boundary instead; see
-- AGENTS.md for the two-boundary picture.
--
-- Interface every implementation satisfies:
--
--   transport.request(opts, on_done)
--     opts     { method, url, headers?, body?, cookie_jar?, timeout_ms? }
--     on_done  called once, on the main loop, with
--              { ok, status?, body?, error? }
--
--   transport.ws_open(opts, handlers) -> conn
--     opts     { url, headers? }
--     handlers { on_message(text), on_close(code?), on_error(err) }
--     conn     { send(text), close() }
--
-- Messages are newline-delimited JSON in both directions; transports may
-- assume payloads never contain raw newlines (JSON encoding escapes them).

local M = {}

local registry = {}

M.default = "curl-websocat"

-- Register a constructor: factory(opts) -> transport instance.
function M.register(name, factory)
  registry[name] = factory
end

-- Construct by registered name (nil means the default). A table that already
-- looks like a transport (has request + ws_open) passes through untouched,
-- so callers can inject instances directly — fakes in tests, out-of-tree
-- implementations in user config.
function M.create(name, opts)
  if type(name) == "table" and name.request and name.ws_open then
    return name
  end
  name = name or M.default
  local factory = registry[name]
  if not factory then
    error(("jotdown: unknown transport %q (registered: %s)"):format(name, table.concat(vim.tbl_keys(registry), ", ")))
  end
  return factory(opts or {})
end

M.register("curl-websocat", function(opts)
  return require("jotdown.transport.curl_websocat").new(opts)
end)

return M
