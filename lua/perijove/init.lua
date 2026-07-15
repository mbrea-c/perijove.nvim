-- perijove — a Jupyter notebook frontend for Neovim, built on fibrous.
--
-- Architecture (see README.md): a fibrous document UI over a store that
-- consumes an abstract kernel client; the shipped client speaks the Jupyter
-- Server REST + websocket API through a pluggable wire transport
-- (perijove.transport). Local and remote (e.g. SageMaker) differ only in the
-- base URL and an auth provider.

local M = {}

local function default_config()
  return {
    -- name of a registered transport, or a ready-made instance
    transport = nil,
    -- per-tool binary overrides, e.g. { curl = "/usr/bin/curl" }
    tools = {},
    -- mount the notebook UI automatically when a .ipynb file is opened
    auto_open = true,
    -- every perijove bind is a chord under this prefix
    prefix = "<C-j>",
    -- preconfigured jupyter connections (specs; see perijove.connections)
    -- and the name of the one notebooks use unless something more specific
    -- (a perijove.json default, an explicit selection) says otherwise
    connections = {},
    default_connection = nil,
  }
end

local config = default_config()

-- test hook: restore pristine defaults (config is module-persistent)
function M._reset_config()
  config = default_config()
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  require("perijove.tools").configure(config.tools)
  require("perijove.view.notebook").configure({ prefix = config.prefix })

  local connections = require("perijove.connections")
  for _, spec in ipairs(config.connections) do
    spec.source = "setup"
    connections.add(spec)
  end
  if config.default_connection then
    connections.set_default(config.default_connection)
  end

  local notebook_file = require("perijove.notebook_file")
  notebook_file.setup_autocmds(config.auto_open)

  -- :Perijove                open/toggle the notebook UI (as always)
  -- :Perijove connections    pick a connection (this notebook, or the
  --                          global default outside one)
  -- :Perijove connect <name> the same, without the picker
  -- :Perijove new-connection guided creation of a connection
  vim.api.nvim_create_user_command("Perijove", function(cmd)
    local sub = cmd.fargs[1]
    local bufnr = vim.api.nvim_get_current_buf()
    local sess = notebook_file.session_of(bufnr)
    local function apply(name)
      if sess then
        notebook_file.set_connection(bufnr, name)
      else
        connections.set_default(name)
      end
    end
    if sub == nil then
      if notebook_file._sessions[bufnr] then
        notebook_file.toggle(bufnr)
      else
        notebook_file.open(bufnr)
      end
    elseif sub == "connections" then
      require("perijove.connections.ui").pick({
        project = sess and sess.project,
        current = sess and notebook_file.connection_of(bufnr),
      }, function(spec)
        if spec then
          apply(spec.name)
        end
      end)
    elseif sub == "connect" then
      local name = cmd.fargs[2]
      if not name then
        vim.notify("perijove: usage: :Perijove connect <name>", vim.log.levels.ERROR)
        return
      end
      apply(name)
    elseif sub == "new-connection" then
      require("perijove.connections.ui").create()
    else
      vim.notify(("perijove: unknown subcommand %q"):format(sub), vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(_, cmdline)
      if cmdline:match("connect%s+%S*$") and not cmdline:match("connections") then
        local sess = notebook_file.session_of(vim.api.nvim_get_current_buf())
        local names = {}
        for _, spec in ipairs(connections.view(sess and sess.project).list()) do
          names[#names + 1] = spec.name
        end
        return names
      end
      return { "connections", "connect", "new-connection" }
    end,
    desc = "perijove: open/toggle the notebook UI, or manage jupyter connections",
  })

  return config
end

-- The configured wire transport (constructed fresh per call; connections own
-- their transport instance).
function M.transport()
  return require("perijove.transport").create(config.transport, config)
end

return M
