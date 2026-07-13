-- jotdown — a Jupyter notebook frontend for Neovim, built on fibrous.
--
-- Architecture (see README.md): a fibrous document UI over a store that
-- consumes an abstract kernel client; the shipped client speaks the Jupyter
-- Server REST + websocket API through a pluggable wire transport
-- (jotdown.transport). Local and remote (e.g. SageMaker) differ only in the
-- base URL and an auth provider.

local M = {}

local config = {
  -- name of a registered transport, or a ready-made instance
  transport = nil,
  -- per-tool binary overrides, e.g. { curl = "/usr/bin/curl" }
  tools = {},
  -- mount the notebook UI automatically when a .ipynb file is opened
  auto_open = true,
  -- every jotdown bind is a chord under this prefix
  prefix = "<C-j>",
}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  require("jotdown.tools").configure(config.tools)
  require("jotdown.view.notebook").configure({ prefix = config.prefix })

  local notebook_file = require("jotdown.notebook_file")
  notebook_file.setup_autocmds(config.auto_open)
  vim.api.nvim_create_user_command("Jotdown", function()
    local bufnr = vim.api.nvim_get_current_buf()
    if notebook_file._sessions[bufnr] then
      notebook_file.toggle(bufnr)
    else
      notebook_file.open(bufnr)
    end
  end, { desc = "jotdown: open or toggle the notebook UI for this buffer" })

  return config
end

-- The configured wire transport (constructed fresh per call; connections own
-- their transport instance).
function M.transport()
  return require("jotdown.transport").create(config.transport, config)
end

return M
