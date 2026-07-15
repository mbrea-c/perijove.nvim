-- perijove.json: a project-level connection file, resolved UPWARD from the
-- notebook's directory (like .editorconfig). It carries declarative
-- connection specs and optionally names the project default:
--
--   { "connections": [ { "name": ..., "kind": ... }, ... ], "default": "name" }
--
-- Its connections layer over the global registry for notebooks under that
-- tree, shadowing by name; JSON cannot carry lua functions, so only the
-- declarative kinds (local / remote / command) are allowed.

local connections = require("perijove.connections")
local project = require("perijove.connections.project")

local function tmptree()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/sub/deeper", "p")
  return dir
end

local function write_json(path, tbl)
  vim.fn.writefile({ vim.json.encode(tbl) }, path)
end

describe("perijove.json project config", function()
  before_each(function()
    connections._reset()
  end)

  it("finds nothing without a file", function()
    local dir = tmptree()
    assert.is_nil(project.load_for(dir .. "/sub/deeper/nb.ipynb"))
  end)

  it("resolves upward from the notebook and parses connections", function()
    local dir = tmptree()
    write_json(dir .. "/perijove.json", {
      connections = {
        { name = "gpu", kind = "remote", url = "http://gpu:8888", token = "t" },
        { name = "sagemaker", kind = "command", argv = { "ssm-tunnel", "up" } },
      },
      default = "gpu",
    })
    local proj = project.load_for(dir .. "/sub/deeper/nb.ipynb")
    assert.equal(dir .. "/perijove.json", proj.file)
    assert.equal("gpu", proj.default)
    assert.equal("remote", proj.connections["gpu"].kind)
    assert.equal("json", proj.connections["gpu"].source)
    assert.same({ "ssm-tunnel", "up" }, proj.connections["sagemaker"].argv)
  end)

  it("the NEAREST file wins", function()
    local dir = tmptree()
    write_json(dir .. "/perijove.json", { default = "outer" })
    write_json(dir .. "/sub/perijove.json", {
      connections = { { name = "inner", kind = "remote", url = "http://in" } },
      default = "inner",
    })
    local proj = project.load_for(dir .. "/sub/deeper/nb.ipynb")
    assert.equal("inner", proj.default)
  end)

  it("rejects bad JSON and invalid specs loudly", function()
    local dir = tmptree()
    vim.fn.writefile({ "{ not json" }, dir .. "/perijove.json")
    local proj, err = project.load_for(dir .. "/nb.ipynb")
    assert.is_nil(proj)
    assert.truthy(err:find("perijove.json", 1, true))

    write_json(dir .. "/perijove.json", { connections = { { name = "x", kind = "remote" } } })
    proj, err = project.load_for(dir .. "/nb.ipynb")
    assert.is_nil(proj)
    assert.truthy(err:find("url", 1, true))
  end)

  it("rejects the lua kind (functions cannot live in JSON)", function()
    local dir = tmptree()
    write_json(dir .. "/perijove.json", { connections = { { name = "x", kind = "lua" } } })
    local proj, err = project.load_for(dir .. "/nb.ipynb")
    assert.is_nil(proj)
    assert.truthy(err:find("lua", 1, true))
  end)
end)

describe("connections.view (registry + project layered)", function()
  before_each(function()
    connections._reset()
  end)

  it("without a project it mirrors the registry", function()
    connections.add({ name = "a", kind = "remote", url = "http://a" })
    local view = connections.view(nil)
    assert.equal("http://a", view.get("a").url)
    assert.equal("local", view.default())
    local names = {}
    for _, c in ipairs(view.list()) do
      names[#names + 1] = c.name
    end
    assert.same({ "a", "local" }, names)
  end)

  it("project connections shadow registry ones by name", function()
    connections.add({ name = "gpu", kind = "remote", url = "http://global" })
    local view = connections.view({
      connections = { gpu = { name = "gpu", kind = "remote", url = "http://project", source = "json" } },
    })
    assert.equal("http://project", view.get("gpu").url)
    local names = {}
    for _, c in ipairs(view.list()) do
      names[#names + 1] = c.name
    end
    assert.same({ "gpu", "local" }, names)
  end)

  it("project default beats the global default", function()
    connections.add({ name = "a", kind = "remote", url = "http://a" })
    connections.set_default("a")
    assert.equal("a", connections.view(nil).default())
    local view = connections.view({
      connections = { gpu = { name = "gpu", kind = "remote", url = "http://p", source = "json" } },
      default = "gpu",
    })
    assert.equal("gpu", view.default())
  end)
end)
