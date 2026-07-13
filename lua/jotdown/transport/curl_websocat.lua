-- The default wire transport: curl for HTTP(S), websocat as a stdio<->wss
-- bridge. Both are dumb pipes — every scrap of Jupyter knowledge lives above
-- the transport boundary (see transport/init.lua). Both binaries are pinned
-- by the nix package through jotdown.tools, so the packaged plugin never
-- depends on the user's PATH.
--
-- Everything that can be pure IS pure — argv construction, response parsing,
-- stream line-splitting — so tests cover the tricky parts without spawning
-- processes or touching the network. The vim.system glue at the bottom is
-- deliberately the thinnest possible layer over those pure functions.

local tools = require("jotdown.tools")

local M = {}

---------------------------------------------------------------------------
-- Pure parts (unit tested in tests/transport/curl_websocat_spec.lua)
---------------------------------------------------------------------------

-- Argv for one HTTP request. Headers are emitted in sorted order so the
-- command is deterministic; bodies travel via stdin (--data-binary @-) so
-- payloads never hit argv (size limits, quoting, `ps` visibility). The
-- write-out suffix appends "\n<status>" after the body, which
-- parse_curl_output below strips back off.
function M.curl_args(curl, o)
  local args = { curl, "--silent", "--show-error", "--no-progress-meter" }
  vim.list_extend(args, { "-X", o.method or "GET" })
  local names = vim.tbl_keys(o.headers or {})
  table.sort(names)
  for _, name in ipairs(names) do
    vim.list_extend(args, { "-H", ("%s: %s"):format(name, o.headers[name]) })
  end
  if o.body then
    vim.list_extend(args, { "--data-binary", "@-" })
  end
  if o.cookie_jar then
    -- one jar, read and write: the auth provider owns cookie lifetime
    vim.list_extend(args, { "-b", o.cookie_jar, "-c", o.cookie_jar })
  end
  if o.timeout_ms then
    vim.list_extend(args, { "--max-time", tostring(math.ceil(o.timeout_ms / 1000)) })
  end
  vim.list_extend(args, { "-w", "\n%{http_code}", o.url })
  return args
end

-- Split curl's stdout back into { status, body }: the last line is the
-- write-out status code, everything before its newline is the verbatim body.
-- Returns nil if the marker is missing (curl died before the write-out ran).
function M.parse_curl_output(out)
  local nl_body, code = out:match("^(.*)\n(%d%d%d)$")
  if not code then
    return nil
  end
  return { status = tonumber(code), body = nl_body }
end

-- Argv for one websocket channel: text mode (one line per ws message), stdio
-- on our end, exit when either side closes.
function M.ws_args(websocat, o)
  local args = { websocat, "-t", "--exit-on-eof" }
  local names = vim.tbl_keys(o.headers or {})
  table.sort(names)
  for _, name in ipairs(names) do
    vim.list_extend(args, { "-H", ("%s: %s"):format(name, o.headers[name]) })
  end
  table.insert(args, o.url)
  return args
end

-- Stateful chunk->line reassembly for the websocat stdout stream: returns a
-- feed(chunk) function; feed(nil) signals eof and flushes any trailing
-- partial line. Empty lines are dropped (keepalive noise, final newline).
function M.line_splitter(on_line)
  local buf = ""
  return function(chunk)
    if chunk == nil then
      if buf ~= "" then
        on_line(buf)
        buf = ""
      end
      return
    end
    buf = buf .. chunk
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      if line ~= "" then
        on_line(line)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Process glue (vim.system; async, callbacks delivered on the main loop)
---------------------------------------------------------------------------

local T = {}
T.__index = T

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    curl = opts.curl or tools.path("curl"),
    websocat = opts.websocat or tools.path("websocat"),
  }, T)
end

function T:request(o, on_done)
  local args = M.curl_args(self.curl, o)
  vim.system(args, { stdin = o.body, text = true }, function(res)
    local reply
    if res.code ~= 0 then
      reply = { ok = false, error = ("curl exited %d: %s"):format(res.code, res.stderr or "") }
    else
      local parsed = M.parse_curl_output(res.stdout or "")
      if not parsed then
        reply = { ok = false, error = "curl produced no status marker" }
      else
        reply = { ok = true, status = parsed.status, body = parsed.body }
      end
    end
    vim.schedule(function()
      on_done(reply)
    end)
  end)
end

function T:ws_open(o, handlers)
  local feed = M.line_splitter(function(line)
    vim.schedule(function()
      handlers.on_message(line)
    end)
  end)
  local proc = vim.system(M.ws_args(self.websocat, o), {
    stdin = true,
    text = true,
    stdout = function(err, chunk)
      if err then
        vim.schedule(function()
          handlers.on_error(err)
        end)
        return
      end
      feed(chunk) -- vim.system signals eof with chunk == nil
    end,
  }, function(res)
    vim.schedule(function()
      handlers.on_close(res.code)
    end)
  end)
  return {
    send = function(text)
      proc:write(text .. "\n")
    end,
    close = function()
      proc:write(nil) -- close stdin; --exit-on-eof winds the bridge down
    end,
  }
end

return M
