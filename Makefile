# Note: avoid the name NVIM — Neovim sets $NVIM to its server socket in child
# processes, which would shadow a `NVIM ?= nvim` default.
NVIM_BIN ?= nvim

# Where fibrous lives during development (the flake pins its own copy; the
# runners fall back to this sibling checkout when FIBROUS_PATH is unset).
FIBROUS_PATH ?= ../fibrous.nvim
export FIBROUS_PATH

# Run the full suite in a fully isolated headless Neovim: `-u NONE` loads no
# user config and no plugins, so failures can only come from our own code.
.PHONY: test
test:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua

# Run a single spec file for focused red-green TDD:
#   make test-file FILE=tests/transport/registry_spec.lua
.PHONY: test-file
test-file:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua $(FILE)

# The demo notebook (scripted kernel, no jupyter) in a clean interactive Neovim
.PHONY: demo
demo:
	$(NVIM_BIN) --clean -u demo/init.lua

# The same notebook over a REAL local jupyter kernel (needs jupyter-server,
# curl and websocat on PATH — `nix develop` provides them)
.PHONY: demo-real
demo-real:
	$(NVIM_BIN) --clean -u demo/real.lua
