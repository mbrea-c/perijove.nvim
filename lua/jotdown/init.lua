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
}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  require("jotdown.tools").configure(config.tools)
  return config
end

-- The configured wire transport (constructed fresh per call; connections own
-- their transport instance).
function M.transport()
  return require("jotdown.transport").create(config.transport, config)
end

return M
