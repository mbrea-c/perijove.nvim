-- The "jupyter connection" concept: one plugin-global, named catalog of ways
-- to reach a Jupyter Server. A connection is a declarative SPEC; resolving it
-- yields an ENDPOINT the server client dials:
--
--   { base_url, token?, headers? (table or fn() -> table), stop?() }
--
-- The kinds, chosen so everything short of arbitrary Lua also works from the
-- perijove.json project file (JSON cannot carry functions):
--
--   local    spawn jupyter-server on loopback (the shipped default; fields
--            cmd?, root_dir?). The endpoint owns the server: stop() kills it.
--   remote   a server that already exists: url, plus token? or headers?.
--            headers may be a function, re-read per request (dynamic creds).
--   command  a tunnel-shaped setup (SageMaker via SSM, ssh -L, ...): argv is
--            spawned, must print ONE JSON handshake line on stdout
--            ({"url": ..., "token"?: ..., "headers"?: ...}), then stays alive
--            as the tunnel; stop() kills it.
--   lua      the escape hatch for setup()/API registration only: the spec
--            carries connect(spec, cb), cb(err, endpoint).
--
-- Registration is upsert-by-name (reload friendly). The builtin "local"
-- connection is always present and cannot be removed, only shadowed by
-- registering another spec named "local". `source` on each spec records where
-- it came from (builtin / api / setup / json) for the picker UI.

local M = {}

local registry
local default_name

local KINDS = { ["local"] = true, remote = true, command = true, lua = true }

local function builtin_local()
  return { name = "local", kind = "local", source = "builtin" }
end

-- (Re)initialize the registry: just the builtin, default "local".
function M._reset()
  registry = { ["local"] = builtin_local() }
  default_name = "local"
end

M._reset()

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

-- Validate a spec (shared by add() and the json layer). Returns the spec with
-- `kind` normalized ("lua" is inferred from a connect function).
function M.validate(spec)
  assert(type(spec) == "table", "perijove: connection spec must be a table")
  if spec.connect ~= nil then
    assert(type(spec.connect) == "function", "perijove: connection `connect` must be a function")
    spec.kind = spec.kind or "lua"
  end
  assert(KINDS[spec.kind], ("perijove: unknown connection kind %q"):format(tostring(spec.kind)))
  if spec.kind == "remote" then
    assert(type(spec.url) == "string", "perijove: remote connection needs a `url`")
  elseif spec.kind == "command" then
    assert(type(spec.argv) == "table" and #spec.argv > 0, "perijove: command connection needs an `argv` list")
  elseif spec.kind == "lua" then
    assert(type(spec.connect) == "function", "perijove: lua connection needs a `connect` function")
  end
  return spec
end

-- Register (upsert) a connection. spec.source defaults to "api".
function M.add(spec)
  M.validate(spec)
  assert(type(spec.name) == "string" and spec.name ~= "", "perijove: connection needs a `name`")
  spec.source = spec.source or "api"
  registry[spec.name] = spec
  return spec
end

function M.remove(name)
  assert(name ~= "local", "perijove: the builtin local connection cannot be removed")
  registry[name] = nil
  if default_name == name then
    default_name = "local"
  end
end

function M.get(name)
  return registry[name]
end

-- All registered connections, sorted by name.
function M.list()
  local out = {}
  for _, spec in pairs(registry) do
    out[#out + 1] = spec
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function M.set_default(name)
  assert(registry[name], ("perijove: unknown connection %q"):format(tostring(name)))
  default_name = name
end

function M.get_default()
  return default_name
end

-- A merged read-view of the registry with a project (perijove.json) layered
-- on top: project connections shadow registry ones by name, the project
-- default beats the global one. `project` is what
-- perijove.connections.project.load_for returns (nil is fine).
function M.view(project)
  local overlay = project and project.connections or {}
  return {
    get = function(name)
      return overlay[name] or registry[name]
    end,
    list = function()
      local merged = {}
      for name, spec in pairs(registry) do
        merged[name] = spec
      end
      for name, spec in pairs(overlay) do
        merged[name] = spec
      end
      local out = {}
      for _, spec in pairs(merged) do
        out[#out + 1] = spec
      end
      table.sort(out, function(a, b)
        return a.name < b.name
      end)
      return out
    end,
    default = function()
      return (project and project.default) or default_name
    end,
  }
end

---------------------------------------------------------------------------
-- Resolution: spec -> endpoint
---------------------------------------------------------------------------

-- Default spawner for command connections: run argv, deliver stdout lines to
-- on_line as they arrive. Returns { kill() }.
local function system_spawner(argv, on_line)
  local buf = ""
  local proc = vim.system(argv, {
    text = true,
    stdout = function(_, chunk)
      if not chunk then
        return
      end
      buf = buf .. chunk
      while true do
        local line, rest = buf:match("^([^\n]*)\n(.*)$")
        if not line then
          break
        end
        buf = rest
        vim.schedule(function()
          on_line(line)
        end)
      end
    end,
  })
  return {
    kill = function()
      proc:kill("sigterm")
      proc:wait(3000)
    end,
  }
end

local resolvers = {}

resolvers["remote"] = function(spec, cb)
  cb(nil, {
    base_url = spec.url:gsub("/+$", ""),
    token = spec.token,
    headers = spec.headers,
  })
end

resolvers["lua"] = function(spec, cb)
  spec.connect(spec, cb)
end

resolvers["local"] = function(spec, cb, opts)
  local localserver = opts.localserver or require("perijove.localserver")
  local transport = opts.transport or require("perijove").transport()
  local jupyter = require("perijove.tools").path("jupyter-server")
  if not opts.localserver and vim.fn.executable((spec.cmd or { jupyter })[1]) == 0 then
    cb("jupyter-server not found (the nix package pins one; otherwise PATH or nix develop provides it)")
    return
  end
  local srv = localserver.spawn({ cmd = spec.cmd, root_dir = spec.root_dir })
  -- readiness polling blocks briefly (pumping the loop); async polling is a
  -- noted refinement in localserver
  if not localserver.wait_ready(srv, transport, spec.timeout_ms or 60000) then
    srv.stop()
    cb("local jupyter server did not come up")
    return
  end
  cb(nil, { base_url = srv.base_url, token = srv.token, stop = srv.stop })
end

resolvers["command"] = function(spec, cb, opts)
  local spawner = opts.spawner or system_spawner
  local done = false
  local proc
  local function handshake(line)
    local ok, hand = pcall(vim.json.decode, line)
    if not ok or type(hand) ~= "table" or type(hand.url) ~= "string" then
      proc.kill() -- a half-open tunnel must not leak
      cb(("connection %s: bad handshake line: %s"):format(spec.name or "?", line))
      return
    end
    cb(nil, {
      base_url = hand.url:gsub("/+$", ""),
      token = hand.token,
      headers = hand.headers,
      stop = proc.kill,
    })
  end
  -- the spawner may deliver the handshake before it returns proc (a fake, or
  -- a tunnel that answers instantly), so park the line until proc exists
  local parked
  proc = spawner(spec.argv, function(line)
    if done then
      return -- only the FIRST line is the handshake; the rest is tunnel noise
    end
    done = true
    if proc then
      handshake(line)
    else
      parked = line
    end
  end)
  if parked then
    handshake(parked)
  end
end

-- Resolve a connection to an endpoint. `what` is a registered name or an
-- anonymous spec table; cb(err, endpoint). opts carries injectables (tests)
-- and the transport local readiness-polling uses.
function M.resolve(what, cb, opts)
  opts = opts or {}
  local spec = what
  if type(what) == "string" then
    spec = registry[what]
    if not spec then
      cb(("perijove: unknown connection %q"):format(what))
      return
    end
  else
    M.validate(spec)
  end
  resolvers[spec.kind](spec, cb, opts)
end

return M
