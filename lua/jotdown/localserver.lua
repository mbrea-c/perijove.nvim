-- Local jupyter server lifecycle: spawn one on a free loopback port with a
-- generated token, poll it ready, kill it on stop. This is how "open a local
-- notebook" will work — the local case is just the remote case pointed at a
-- server we happen to own (see README).

local M = {}

-- Ask the OS for a free port by binding port 0 and reading back the choice.
-- (Racy by nature; the server grabs it immediately after.)
local function free_port()
  local sock = vim.uv.new_tcp()
  sock:bind("127.0.0.1", 0)
  local port = sock:getsockname().port
  sock:close()
  return port
end

local function random_token()
  return ("%d%d"):format(vim.uv.hrtime(), math.random(1e9)):gsub("%D", "")
end

-- Spawn a server. opts: { cmd? (argv prefix, default jupyter-server),
-- root_dir? }. Returns { base_url, token, stop() } immediately; poll
-- readiness with M.wait_ready.
function M.spawn(opts)
  opts = opts or {}
  local port = free_port()
  local token = random_token()
  local argv = vim.list_extend(vim.deepcopy(opts.cmd or { "jupyter-server" }), {
    "--ServerApp.ip=127.0.0.1",
    "--ServerApp.port=" .. port,
    "--ServerApp.port_retries=0",
    "--ServerApp.token=" .. token,
    "--ServerApp.open_browser=False",
    "--ServerApp.root_dir=" .. (opts.root_dir or vim.uv.os_tmpdir()),
  })
  local proc = vim.system(argv, { text = true })
  return {
    base_url = "http://127.0.0.1:" .. port,
    token = token,
    stop = function()
      proc:kill("sigterm")
      proc:wait(3000)
    end,
  }
end

-- Block (pumping the main loop, so transport callbacks run) until the
-- server answers /api/status, or the timeout passes. Returns true if ready.
function M.wait_ready(srv, transport, timeout_ms)
  local ready = false
  local pending = false
  local function poke()
    if pending then
      return
    end
    pending = true
    transport:request({
      method = "GET",
      url = srv.base_url .. "/api/status",
      headers = { ["Authorization"] = "token " .. srv.token },
      timeout_ms = 2000,
    }, function(res)
      pending = false
      ready = res.ok and res.status == 200
    end)
  end
  vim.wait(timeout_ms or 30000, function()
    if ready then
      return true
    end
    poke()
    return false
  end, 200)
  return ready
end

return M
