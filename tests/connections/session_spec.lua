-- Connections wired into notebook sessions: opening a .ipynb picks the
-- EFFECTIVE connection (explicitly selected > perijove.json default > global
-- default > builtin local) but dials nothing until the first run (the lazy
-- client); set_connection() switches a live notebook by rebasing that lazy
-- client — the old kernel shuts down, the next run boots on the new
-- connection, outputs stay.
--
-- Hermetic: connections here are lua-kind specs resolving to endpoints whose
-- `transport` is a fake (canned REST, capturing ws), so the REAL server
-- client and protocol layer run with no network and no processes.

local connections = require("perijove.connections")
local notebook_file = require("perijove.notebook_file")

---------------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------------

local FIXTURE = vim.json.encode({
  cells = {
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "code-1",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "print('hi')" },
    },
  },
  metadata = vim.empty_dict(),
  nbformat = 4,
  nbformat_minor = 5,
})

-- every fixture in its own directory: perijove.json discovery is upward, so
-- a shared tmp dir would leak one test's project file into the next
local function write_fixture(project_json)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/nb.ipynb"
  vim.fn.writefile(vim.split(FIXTURE, "\n"), path)
  if project_json then
    vim.fn.writefile({ vim.json.encode(project_json) }, dir .. "/perijove.json")
  end
  return path
end

local function open_fixture(project_json)
  local path = write_fixture(project_json)
  vim.cmd("edit " .. path)
  local bufnr = vim.api.nvim_get_current_buf()
  local sess = notebook_file.open(bufnr)
  return bufnr, sess
end

local function cleanup(bufnr)
  notebook_file.close(bufnr)
  vim.cmd("silent! bwipeout! " .. bufnr)
end

-- the server_spec fake wire transport, canned for one kernel
local function fake_transport(base)
  local t = {
    requests = {},
    ws = nil,
  }
  function t:request(opts, on_done)
    table.insert(self.requests, opts)
    if opts.method == "POST" and opts.url == base .. "/api/sessions" then
      on_done({
        ok = true,
        status = 201,
        body = vim.json.encode({ id = "sess-1", kernel = { id = "kern-1", name = "python3" } }),
      })
    elseif opts.method == "GET" and opts.url == base .. "/api/kernelspecs" then
      on_done({
        ok = true,
        status = 200,
        body = vim.json.encode({
          default = "python3",
          kernelspecs = {
            ["python3"] = { name = "python3", spec = { display_name = "Python 3" } },
            ["julia-1.10"] = { name = "julia-1.10", spec = { display_name = "Julia 1.10" } },
          },
        }),
      })
    else
      on_done({ ok = true, status = 204, body = "{}" })
    end
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

-- register a lua-kind connection resolving to a fake-transport endpoint
local function add_fake_connection(name)
  local base = "http://" .. name
  local t = fake_transport(base)
  local stopped = { count = 0 }
  connections.add({
    name = name,
    connect = function(_, cb)
      cb(nil, {
        base_url = base,
        token = "tok-" .. name,
        transport = t,
        stop = function()
          stopped.count = stopped.count + 1
        end,
      })
    end,
  })
  return t, stopped
end

local function executed_code(t)
  for _, text in ipairs(t.ws.sent) do
    local msg = vim.json.decode(text)
    if msg.header.msg_type == "execute_request" then
      return msg.content.code
    end
  end
end

---------------------------------------------------------------------------

describe("notebook_file connections", function()
  before_each(function()
    connections._reset()
  end)

  it("open picks the effective connection but dials NOTHING", function()
    local t = add_fake_connection("conn-a")
    connections.set_default("conn-a")
    local bufnr = open_fixture()
    assert.equal("conn-a", notebook_file.connection_of(bufnr))
    assert.equal(0, #t.requests)
    cleanup(bufnr)
  end)

  it("perijove.json default beats the global default", function()
    add_fake_connection("conn-a")
    connections.set_default("conn-a")
    local bufnr = open_fixture({
      connections = { { name = "proj", kind = "remote", url = "http://proj" } },
      default = "proj",
    })
    assert.equal("proj", notebook_file.connection_of(bufnr))
    cleanup(bufnr)
  end)

  it("first run boots the effective connection and executes on it", function()
    local t = add_fake_connection("conn-a")
    connections.set_default("conn-a")
    local bufnr, sess = open_fixture()
    sess.store:run_cell(sess.store.cells[1].id)
    assert.equal("token tok-conn-a", t.requests[1].headers["Authorization"])
    assert.equal("print('hi')", executed_code(t))
    cleanup(bufnr)
  end)

  it("set_connection rebases a live session onto the new connection", function()
    local ta = add_fake_connection("conn-a")
    local tb = add_fake_connection("conn-b")
    connections.set_default("conn-a")
    local bufnr, sess = open_fixture()
    sess.store:run_cell(sess.store.cells[1].id)
    assert.is_not_nil(ta.ws)

    notebook_file.set_connection(bufnr, "conn-b")
    assert.equal("conn-b", notebook_file.connection_of(bufnr))
    assert.is_true(ta.ws.closed) -- the old kernel is gone
    assert.equal(0, #tb.requests) -- and the new one is still lazy
    -- the in-flight run settled locally (a switched-away kernel never answers)
    assert.equal("idle", sess.store.cells[1].state)

    sess.store:run_cell(sess.store.cells[1].id)
    assert.equal("print('hi')", executed_code(tb))
    cleanup(bufnr)
  end)

  it("set_kernel rebases a live session; the next boot asks for the new kernel", function()
    local t = add_fake_connection("conn-a")
    connections.set_default("conn-a")
    local bufnr, sess = open_fixture()
    -- nothing selected: the client's shipped default
    assert.equal("python3", notebook_file.kernel_of(bufnr))

    sess.store:run_cell(sess.store.cells[1].id)
    assert.equal("python3", vim.json.decode(t.requests[1].body).kernel.name)
    local first_ws = t.ws

    notebook_file.set_kernel(bufnr, "julia-1.10")
    assert.equal("julia-1.10", notebook_file.kernel_of(bufnr))
    assert.is_true(first_ws.closed) -- the old kernel is gone
    -- the in-flight run settled locally (a switched-away kernel never answers)
    assert.equal("idle", sess.store.cells[1].state)

    sess.store:run_cell(sess.store.cells[1].id)
    local last_boot
    for _, req in ipairs(t.requests) do
      if req.method == "POST" and req.url:find("/api/sessions", 1, true) then
        last_boot = req
      end
    end
    assert.equal("julia-1.10", vim.json.decode(last_boot.body).kernel.name)
    cleanup(bufnr)
  end)

  it("open_config drives connection and kernel switches end-to-end", function()
    local ta = add_fake_connection("conn-a")
    add_fake_connection("conn-b")
    connections.set_default("conn-a")
    local bufnr, sess = open_fixture()
    sess.store:run_cell(sess.store.cells[1].id) -- boot, so kernelspecs can load

    local handle = notebook_file.open_config(bufnr)
    -- the effective connection and kernel show as the field values
    local inputs = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
        local buf = vim.api.nvim_win_get_buf(win)
        inputs[vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]] = win
      end
    end
    assert.is_not_nil(inputs["conn-a"])
    assert.is_not_nil(inputs["python3"])

    -- the booted server's kernelspecs were fetched into the kernel dropdown
    vim.wait(500, function()
      return false
    end, 10)
    vim.api.nvim_set_current_win(inputs["python3"])
    local listed = vim.wait(500, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable == false then
          local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
          if text:find("julia-1.10", 1, true) then
            return true
          end
        end
      end
      return false
    end, 5)
    assert.is_true(listed)
    -- pick julia through the popup: selection starts on python3 (current)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-p><CR>", true, false, true), "xt", false)
    local switched = vim.wait(500, function()
      return notebook_file.kernel_of(bufnr) == "julia-1.10"
    end, 5)
    assert.is_true(switched)
    assert.is_true(ta.ws.closed) -- the kernel switch rebased the session

    -- switch the connection through its dropdown: conn-a → conn-b
    handle.close()
    handle = notebook_file.open_config(bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.w[win].fibrous_anchor == handle.winid and vim.api.nvim_win_get_config(win).focusable ~= false then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "conn-a" then
          vim.api.nvim_set_current_win(win)
        end
      end
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-n><CR>", true, false, true), "xt", false)
    local reconnected = vim.wait(500, function()
      return notebook_file.connection_of(bufnr) == "conn-b"
    end, 5)
    assert.is_true(reconnected)

    handle.close()
    cleanup(bufnr)
  end)

  it("close stops the resolved endpoint (tunnels, local servers)", function()
    local _, stopped = add_fake_connection("conn-a")
    connections.set_default("conn-a")
    local bufnr, sess = open_fixture()
    sess.store:run_cell(sess.store.cells[1].id)
    cleanup(bufnr)
    assert.equal(1, stopped.count)
  end)
end)
