-- The Jupyter Server client: implements the kernel-client contract by
-- gluing the protocol layer to the wire transport. Speced against a fake
-- transport — canned REST responses, a capturing websocket — so the whole
-- client is exercised with no network, no processes.

local server = require("perijove.client.server")

---------------------------------------------------------------------------
-- A fake wire transport: REST answered from a routes table, ws captured.
---------------------------------------------------------------------------

local function fake_transport(routes)
  local t = {
    requests = {}, -- every request opts, in order
    ws = nil, -- the one opened channel: { opts, handlers, sent, closed }
  }
  function t:request(opts, on_done)
    table.insert(self.requests, opts)
    local key = opts.method .. " " .. opts.url:gsub("%?.*$", "")
    local route = routes[key]
    if not route then
      on_done({ ok = false, error = "no route: " .. key })
      return
    end
    on_done({ ok = true, status = route.status or 200, body = vim.json.encode(route.body) })
  end
  function t:ws_open(opts, handlers)
    self.ws = { opts = opts, handlers = handlers, sent = {}, closed = false }
    local ws = self.ws
    return {
      send = function(text)
        table.insert(ws.sent, text)
      end,
      close = function()
        ws.closed = true
      end,
    }
  end
  return t
end

local BASE = "http://localhost:8888"

local function connected_client()
  local t = fake_transport({
    ["POST " .. BASE .. "/api/sessions"] = {
      status = 201,
      body = {
        id = "sess-1",
        kernel = { id = "kern-1", name = "python3" },
      },
    },
    ["POST " .. BASE .. "/api/kernels/kern-1/interrupt"] = { status = 204, body = vim.empty_dict() },
    ["POST " .. BASE .. "/api/kernels/kern-1/restart"] = { status = 200, body = vim.empty_dict() },
  })
  local c = server.new({ transport = t, base_url = BASE, token = "sekrit" })
  local err
  c:connect(function(e)
    err = e
  end)
  assert.is_nil(err)
  return c, t
end

-- server -> client wire frame
local function frame(channel, msg_type, parent_id, content)
  return vim.json.encode({
    channel = channel,
    header = { msg_id = "srv-1", msg_type = msg_type },
    parent_header = { msg_id = parent_id },
    content = content,
  })
end

describe("client.server connect", function()
  it("creates a session with the auth token and opens the kernel channel", function()
    local _, t = connected_client()

    local post = t.requests[1]
    assert.equal("POST", post.method)
    assert.equal(BASE .. "/api/sessions", post.url)
    assert.equal("token sekrit", post.headers["Authorization"])
    local body = vim.json.decode(post.body)
    assert.equal("python3", body.kernel.name)

    assert.is_not_nil(t.ws)
    assert.truthy(t.ws.opts.url:find("ws://localhost:8888/api/kernels/kern-1/channels", 1, true))
    assert.equal("token sekrit", t.ws.opts.headers["Authorization"])
  end)

  it("sends extra headers, re-reading a headers FUNCTION per request", function()
    local t = fake_transport({
      ["POST " .. BASE .. "/api/sessions"] = {
        status = 201,
        body = { id = "sess-1", kernel = { id = "kern-1", name = "python3" } },
      },
      ["POST " .. BASE .. "/api/kernels/kern-1/interrupt"] = { status = 204, body = vim.empty_dict() },
    })
    local serial = 0
    local c = server.new({
      transport = t,
      base_url = BASE,
      token = "sekrit",
      headers = function()
        serial = serial + 1
        return { ["X-Cred"] = "v" .. serial }
      end,
    })
    c:connect(function() end)
    -- dynamic creds: each request gets a FRESH read (SigV4, expiring tokens)
    assert.equal("v1", t.requests[1].headers["X-Cred"])
    assert.equal("token sekrit", t.requests[1].headers["Authorization"]) -- token still rides along
    assert.equal("v2", t.ws.opts.headers["X-Cred"])
    c:interrupt()
    assert.equal("v3", t.requests[2].headers["X-Cred"])
  end)

  it("synthesizes an idle status on connect for an attached store", function()
    local t = fake_transport({
      ["POST " .. BASE .. "/api/sessions"] = {
        status = 201,
        body = { id = "sess-1", kernel = { id = "kern-1", name = "python3" } },
      },
    })
    local c = server.new({ transport = t, base_url = BASE })
    local statuses = {}
    c:attach({
      on_status = function(s)
        table.insert(statuses, s)
      end,
    })
    c:connect(function() end)
    -- a fresh kernel is idle; without this the store shows "unknown" until
    -- the first execute
    assert.same({ "idle" }, statuses)
  end)

  it("reports a failed session create through the callback", function()
    local t = fake_transport({}) -- no routes: everything fails
    local c = server.new({ transport = t, base_url = BASE })
    local err
    c:connect(function(e)
      err = e
    end)
    assert.is_not_nil(err)
    assert.is_nil(t.ws)
  end)
end)

describe("client.server execute", function()
  it("sends a channel-tagged execute_request with the cell's code", function()
    local c, t = connected_client()
    c:execute("print(1)", {})
    assert.equal(1, #t.ws.sent)
    local sent = vim.json.decode(t.ws.sent[1])
    assert.equal("shell", sent.channel)
    assert.equal("execute_request", sent.header.msg_type)
    assert.equal("print(1)", sent.content.code)
    assert.is_true(sent.content.allow_stdin)
  end)

  it("answers an input_request through the stdin channel", function()
    local c, t = connected_client()
    local got
    c:execute("input('Name: ')", {
      on_input = function(prompt, password, reply)
        got = { prompt = prompt, password = password, reply = reply }
      end,
      on_done = function() end,
    })
    local parent = vim.json.decode(t.ws.sent[1]).header.msg_id
    t.ws.handlers.on_message(frame("stdin", "input_request", parent, { prompt = "Name: ", password = false }))
    assert.is_not_nil(got)
    assert.equal("Name: ", got.prompt)
    assert.is_false(got.password)

    got.reply("bob")
    assert.equal(2, #t.ws.sent)
    local sent = vim.json.decode(t.ws.sent[2])
    assert.equal("stdin", sent.channel)
    assert.equal("input_reply", sent.header.msg_type)
    assert.equal("bob", sent.content.value)
  end)

  it("routes kernel replies back to the execution's handlers", function()
    local c, t = connected_client()
    local events = {}
    c:execute("x", {
      on_stream = function(name, text)
        table.insert(events, { "stream", name, text })
      end,
      on_result = function(data)
        table.insert(events, { "result", data["text/plain"] })
      end,
      on_display = function() end,
      on_error = function() end,
      on_done = function(reply)
        table.insert(events, { "done", reply.status, reply.execution_count })
      end,
    })
    local parent = vim.json.decode(t.ws.sent[1]).header.msg_id
    local h = t.ws.handlers
    h.on_message(frame("iopub", "stream", parent, { name = "stdout", text = "out\n" }))
    h.on_message(frame("iopub", "execute_result", parent, { data = { ["text/plain"] = "42" } }))
    h.on_message(frame("shell", "execute_reply", parent, { status = "ok", execution_count = 5 }))
    h.on_message(frame("iopub", "status", parent, { execution_state = "idle" }))
    assert.same({ "stream", "stdout", "out\n" }, events[1])
    assert.same({ "result", "42" }, events[2])
    assert.same({ "done", "ok", 5 }, events[3])
  end)

  it("forwards kernel busy/idle to the attached store handlers", function()
    local c, t = connected_client()
    local statuses = {}
    c:attach({
      on_status = function(s)
        table.insert(statuses, s)
      end,
    })
    c:execute("x", { on_done = function() end })
    local parent = vim.json.decode(t.ws.sent[1]).header.msg_id
    t.ws.handlers.on_message(frame("iopub", "status", parent, { execution_state = "busy" }))
    assert.same({ "busy" }, statuses)
  end)
end)

describe("client.server interrupt", function()
  it("POSTs to the kernel's interrupt endpoint", function()
    local c, t = connected_client()
    c:interrupt()
    local last = t.requests[#t.requests]
    assert.equal("POST", last.method)
    assert.equal(BASE .. "/api/kernels/kern-1/interrupt", last.url)
  end)
end)

describe("client.server close", function()
  it("reports an unexpected channel close, but not an intentional shutdown", function()
    local c, t = connected_client()
    local statuses = {}
    c:attach({
      on_status = function(s)
        table.insert(statuses, s)
      end,
    })
    -- unexpected: the wire dropped under us
    t.ws.handlers.on_close()
    assert.same({ "disconnected" }, statuses)

    -- intentional: shutdown closes the channel itself; the late on_close
    -- must not notify a view that is being torn down (the :q crash)
    statuses = {}
    c:shutdown()
    t.ws.handlers.on_close()
    assert.same({}, statuses)
  end)
end)

describe("client.server restart", function()
  it("POSTs to the kernel's restart endpoint", function()
    local c, t = connected_client()
    c:restart()
    local last = t.requests[#t.requests]
    assert.equal("POST", last.method)
    assert.equal(BASE .. "/api/kernels/kern-1/restart", last.url)
  end)
end)

describe("client.server kernelspecs", function()
  it("lists the server's kernelspecs, normalized and name-sorted", function()
    local t = fake_transport({
      ["GET " .. BASE .. "/api/kernelspecs"] = {
        body = {
          default = "python3",
          kernelspecs = {
            ["python3"] = { name = "python3", spec = { display_name = "Python 3 (ipykernel)" } },
            ["julia-1.10"] = { name = "julia-1.10", spec = { display_name = "Julia 1.10" } },
          },
        },
      },
    })
    local got
    server.list_kernelspecs({ transport = t, base_url = BASE, token = "sekrit" }, function(err, specs)
      got = { err = err, specs = specs }
    end)
    assert.is_nil(got.err)
    assert.equal("python3", got.specs.default)
    assert.same({
      { name = "julia-1.10", display_name = "Julia 1.10" },
      { name = "python3", display_name = "Python 3 (ipykernel)" },
    }, got.specs.kernels)
    -- the request carried auth, like every other server call
    assert.equal("token sekrit", t.requests[1].headers["Authorization"])
  end)

  it("reports a failed listing through the callback", function()
    local t = fake_transport({})
    local got
    server.list_kernelspecs({ transport = t, base_url = BASE }, function(err, specs)
      got = { err = err, specs = specs }
    end)
    assert.truthy(got.err)
    assert.is_nil(got.specs)
  end)
end)
