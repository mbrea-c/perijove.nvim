-- Demo entry point: a clean Neovim (`nvim --clean -u demo/init.lua`, or
-- `make demo` / `nix run .#demo`) with jotdown and fibrous on the path,
-- showing the notebook view against the SCRIPTED kernel client — no jupyter,
-- no network. Mounted over the REAL current window (not a float), like
-- actual usage will be.
--
-- Keybinds are chords under the jotdown prefix (<C-j>, see view/notebook.lua
-- and the seed's first cell): per-cell r/<CR>/o/O/d/J/K/m/e/c/C, plus
--   <C-j>a  run all cells
--   <C-j>i  interrupt the kernel (try it on the sleep cell)
--   <C-j>x  clear all outputs
--   <C-j>q  quit the demo
-- Plus the fibrous basics: hjkl glides over cells; <CR>/i on a code cell
-- enters its real buffer (hjkl at the edge steps back out); hover a [run]
-- button and press <CR>/<Space>.

-- Resolve paths from this file's own location, not the cwd, so the nix app
-- (`-u /nix/store/...-source/demo/init.lua`) works from anywhere.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")
local fibrous = vim.env.FIBROUS_PATH or (root .. "/../fibrous.nvim")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(fibrous)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua", -- demo.seed lives outside lua/
  fibrous .. "/lua/?.lua",
  fibrous .. "/lua/?/init.lua",
  package.path,
}, ";")

local nr = require("fibrous")
local store = require("jotdown.store")
local scripted = require("jotdown.client.scripted")
local notebook = require("jotdown.view.notebook")
local seed = require("demo.seed")

local st = store.new(scripted.new())
seed.fill(st)

-- Over the current (only) window — a notebook is a document you open, not a
-- popup. `keys` routes the run chord to the cell under the cursor.
local handle = nr.mount_window(notebook.Notebook, { store = st }, { winid = 0, mode = "scroll", keys = notebook.KEYS })
handle.focus()

local prefix = notebook.PREFIX
vim.keymap.set("n", prefix .. "a", function()
  st:run_all()
end, { desc = "jotdown: run all cells" })
vim.keymap.set("n", prefix .. "i", function()
  st:interrupt()
end, { desc = "jotdown: interrupt the kernel" })
vim.keymap.set("n", prefix .. "x", function()
  st:clear_all_outputs()
end, { desc = "jotdown: clear all outputs" })
vim.keymap.set("n", prefix .. "q", function()
  vim.cmd("qa!")
end, { desc = "jotdown: quit the demo" })
