-- Headless test runner. Invoked as:
--   nvim --headless -u NONE -i NONE -l tests/run.lua [path/to/file_spec.lua]
--
-- With no argument, discovers and runs every tests/**/*_spec.lua. With a path
-- argument, runs only that spec file (useful for focused TDD).
--
-- Exits non-zero if any test fails, so `make test` / CI can gate on it.

local root = vim.fn.getcwd()

-- Only our own lua/ plus fibrous (the UI framework — a real dependency, not a
-- stray plugin) go on the module path, so test failures can never be confused
-- with user config. Fibrous comes from FIBROUS_PATH when set (`nix run .#test`
-- points it at the pinned flake input) and the sibling checkout otherwise.
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../fibrous.nvim")
-- Neovim's runtimepath loader beats package.path, so a fibrous (or perijove)
-- installed in the running nvim (e.g. a nix vim-pack-dir) would silently
-- shadow the trees under test. Prepend them so the suite tests THESE.
vim.opt.runtimepath:prepend(fibrous)
vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua",
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local harness = require("tests.harness")
harness.expose()

local arg_file = _G.arg and _G.arg[1]
local specs
if arg_file and arg_file ~= "" then
  specs = { vim.fn.fnamemodify(arg_file, ":p") }
else
  specs = vim.fn.glob(root .. "/tests/**/*_spec.lua", false, true)
end

table.sort(specs)

if #specs == 0 then
  io.write("no spec files found\n")
  vim.cmd("cquit 1")
end

for _, spec in ipairs(specs) do
  dofile(spec)
end

local results = harness.run()
if results.failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quitall!")
end
