# perijove.nvim — agent notes

A Jupyter notebook frontend for Neovim, built on fibrous. Read README.md for
the architecture; this file records the working conventions.

## Conventions

- Lua is 2-space indented; run `stylua` (devShell provides it) before
  committing.
- Red-green TDD: write the failing spec first, then the code. Run with
  `make test` (working tree) or `make test-file FILE=...` for one spec.
  Unit specs must never touch the network or spawn servers — anything that
  can be pure (argv construction, parsing, correlation) is a pure function
  or fake-driven with unit specs. The exceptions live in tests/integration/
  only: real_kernel_spec.lua (loopback-only, real jupyter-server + curl +
  websocat) and lsp_notebook_spec.lua (real basedpyright over stdio). Each
  skips itself (loudly) when its binary is not on PATH — `nix develop`
  provides both.
- `make` may be missing from PATH in some sandboxes; the direct invocation is
  `nvim --headless -u NONE -i NONE -l tests/run.lua [spec]`.
- fibrous during development comes from `FIBROUS_PATH` (defaults to the
  sibling `../fibrous.nvim` checkout); the flake pins its own copy for
  `nix flake check`.

## Layer boundaries (enforced, not aspirational)

Two pluggable seams, chosen so either can be replaced without touching its
neighbors:

0. **jupyter connection** (`lua/perijove/connections/`) — WHERE a kernel
   lives: a named declarative spec (local / remote / command / lua) in one
   plugin-global registry, resolving to an endpoint (base url, credentials,
   optional stop()). Project overrides come from `perijove.json` (nearest,
   upward from the notebook). Everything below consumes endpoints; nothing
   above the connection layer may know how one is established.
1. **kernel client** — the interface the notebook store consumes
   (execute/interrupt/... plus iopub-shaped handler callbacks). The scripted
   client used by tests/demo, the real server client, and a hypothetical
   jupyter_client python sidecar all implement THIS. Nothing above it may
   know how kernels are reached.
2. **wire transport** (`lua/perijove/transport/`) — `request()` + `ws_open()`,
   implementations registered by name in `transport/init.lua`. No Jupyter
   knowledge at or below this line: transports move bytes. The default
   `curl-websocat` implementation shells out; a pure-Lua vim.uv transport
   would register alongside it.

External binaries are resolved through `lua/perijove/tools.lua` ONLY — never
call `curl`/`websocat` by bare name elsewhere. The nix build substitutes
store paths into that file (flake.nix postPatch), which is what makes the
packaged plugin reproducible; keep the `@curl@`/`@websocat@` placeholders
intact in source.
