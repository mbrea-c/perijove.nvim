-- Interactive connection management: a vim.ui.select picker (merged
-- registry+project view, current and default marked) and a guided
-- vim.ui.input creation flow. Driven with stubbed vim.ui, so no real
-- prompts appear.

local connections = require("perijove.connections")
local ui = require("perijove.connections.ui")

local real_select, real_input

-- queue-driven stubs: each vim.ui call pops its scripted answer
local select_calls, input_answers

local function stub_ui(select_answer)
  select_calls = {}
  vim.ui.select = function(items, opts, on_choice)
    table.insert(select_calls, { items = items, opts = opts })
    on_choice(select_answer(items, opts))
  end
  vim.ui.input = function(opts, on_confirm)
    local answer = table.remove(input_answers, 1)
    on_confirm(answer)
  end
end

describe("connections.ui", function()
  before_each(function()
    connections._reset()
    real_select, real_input = vim.ui.select, vim.ui.input
    input_answers = {}
  end)

  after_each(function()
    vim.ui.select, vim.ui.input = real_select, real_input
  end)

  it("pick shows the merged view and marks current + default", function()
    connections.add({ name = "gpu", kind = "remote", url = "http://gpu" })
    connections.set_default("gpu")
    local labels
    stub_ui(function(items, opts)
      labels = {}
      for _, item in ipairs(items) do
        labels[#labels + 1] = opts.format_item(item)
      end
      return items[1] -- "gpu" (sorted)
    end)
    local picked
    ui.pick({ current = "local" }, function(spec)
      picked = spec
    end)
    assert.equal("gpu", picked.name)
    assert.truthy(labels[1]:find("gpu", 1, true))
    assert.truthy(labels[1]:find("default", 1, true))
    assert.truthy(labels[2]:find("current", 1, true)) -- local is current
  end)

  it("pick layers a project over the registry", function()
    local picked
    stub_ui(function(items)
      for _, item in ipairs(items) do
        if item.name == "proj" then
          return item
        end
      end
    end)
    ui.pick({
      project = { connections = { proj = { name = "proj", kind = "remote", url = "http://p", source = "json" } } },
    }, function(spec)
      picked = spec
    end)
    assert.equal("proj", picked.name)
  end)

  it("create registers a remote connection from the prompted fields", function()
    stub_ui(function(items)
      return "remote"
    end)
    input_answers = { "gpu-box", "http://gpu:8888", "sekrit" }
    local created
    ui.create(function(spec)
      created = spec
    end)
    assert.equal("remote", created.kind)
    assert.equal("http://gpu:8888", connections.get("gpu-box").url)
    assert.equal("sekrit", connections.get("gpu-box").token)
    assert.equal("api", connections.get("gpu-box").source)
  end)

  it("create splits a command line into argv", function()
    stub_ui(function()
      return "command"
    end)
    input_answers = { "sm", "ssm-tunnel start --port 8888" }
    ui.create()
    assert.same({ "ssm-tunnel", "start", "--port", "8888" }, connections.get("sm").argv)
  end)

  it("an empty optional field is simply omitted", function()
    stub_ui(function()
      return "remote"
    end)
    input_answers = { "open-box", "http://box", "" } -- no token
    ui.create()
    assert.is_nil(connections.get("open-box").token)
  end)

  it("cancelling any prompt aborts without registering", function()
    stub_ui(function()
      return "remote"
    end)
    input_answers = { "half-made", nil } -- url prompt cancelled
    local called = false
    ui.create(function()
      called = true
    end)
    assert.is_nil(connections.get("half-made"))
    assert.is_false(called)
  end)
end)
