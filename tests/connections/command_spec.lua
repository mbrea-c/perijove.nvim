-- :Perijove subcommands for connections. Bare :Perijove keeps its open/
-- toggle behavior; `connections` opens the picker (applying to the current
-- notebook, or the global default outside one), `connect <name>` skips the
-- picker, `new-connection` starts the guided create flow.

local connections = require("perijove.connections")
local notebook_file = require("perijove.notebook_file")
local perijove = require("perijove")
local fake_client = require("tests.fake_client")

local FIXTURE = vim.json.encode({
  cells = {
    {
      cell_type = "code",
      execution_count = vim.NIL,
      id = "c1",
      metadata = vim.empty_dict(),
      outputs = {},
      source = { "1" },
    },
  },
  metadata = vim.empty_dict(),
  nbformat = 4,
  nbformat_minor = 5,
})

local function open_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/nb.ipynb"
  vim.fn.writefile(vim.split(FIXTURE, "\n"), path)
  vim.cmd("edit " .. path)
  local bufnr = vim.api.nvim_get_current_buf()
  notebook_file.open(bufnr, { client = fake_client.new() })
  return bufnr
end

local function cleanup(bufnr)
  notebook_file.close(bufnr)
  vim.cmd("silent! bwipeout! " .. bufnr)
end

describe(":Perijove connection subcommands", function()
  before_each(function()
    connections._reset()
    perijove._reset_config()
    perijove.setup({ auto_open = false })
    connections.add({ name = "gpu", kind = "remote", url = "http://gpu" })
  end)

  it("connect <name> sets the notebook's connection (from the view buffer)", function()
    local bufnr = open_fixture()
    -- open() lands the cursor in the mounted VIEW buffer; the command must
    -- still find this notebook's session
    vim.cmd("Perijove connect gpu")
    assert.equal("gpu", notebook_file.connection_of(bufnr))
    cleanup(bufnr)
  end)

  it("connect <name> outside a notebook sets the global default", function()
    vim.cmd("enew")
    vim.cmd("Perijove connect gpu")
    assert.equal("gpu", connections.get_default())
  end)

  it("connections opens the picker and applies the choice", function()
    local real_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      for _, item in ipairs(items) do
        if item.name == "gpu" then
          on_choice(item)
          return
        end
      end
    end
    local bufnr = open_fixture()
    vim.cmd("Perijove connections")
    vim.ui.select = real_select
    assert.equal("gpu", notebook_file.connection_of(bufnr))
    cleanup(bufnr)
  end)

  it("completes subcommands and connection names", function()
    local subs = vim.fn.getcompletion("Perijove ", "cmdline")
    assert.truthy(vim.tbl_contains(subs, "connections"))
    assert.truthy(vim.tbl_contains(subs, "connect"))
    assert.truthy(vim.tbl_contains(subs, "new-connection"))
    local names = vim.fn.getcompletion("Perijove connect ", "cmdline")
    assert.truthy(vim.tbl_contains(names, "gpu"))
    assert.truthy(vim.tbl_contains(names, "local"))
  end)
end)
