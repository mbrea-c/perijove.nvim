# jotdown.nvim

A Jupyter notebook frontend for Neovim, built on
[fibrous](https://github.com/mbrea-c/fibrous.nvim). Early days: the transport
skeleton exists; the notebook UI, protocol layer, and `.ipynb` round-trip are
being built on top of it.

## Architecture

Jupyter separates frontend, middle layer, and kernel — the kernel never sees
the notebook document, only code strings. jotdown is a frontend that speaks to
the official middle layer, **Jupyter Server's REST + websocket API** (the same
surface JupyterLab uses), so local and remote kernels are one code path:

- **local**: jotdown spawns `jupyter server` itself and connects over
  localhost with token auth;
- **remote** (a GPU box, SageMaker, ...): same client pointed at a remote base
  URL, credentials supplied by a pluggable auth provider. The `.ipynb` stays
  local; only code goes up, mime bundles come back.

Layers, top to bottom, with the two swap points marked:

    fibrous document UI  (markdown cells, raw_buffer code cells, outputs)
    notebook store       (cells, outputs, execution queue, kernel status)
    kernel client        <- pluggable: scripted (tests/demo), server REST+WS,
    |                       or e.g. a jupyter_client python sidecar
    protocol layer       (Jupyter message envelopes, correlation, sessions)
    wire transport       <- pluggable: curl+websocat (default), or a future
    |                       pure-Lua vim.uv implementation
    curl / websocat      (HTTP(S) / stdio<->wss bridge; dumb pipes)

The **wire transport** (`lua/jotdown/transport/`) is the narrow interface —
`request()` for HTTP, `ws_open()` for channels — with implementations
registered by name. The default shells out to curl and websocat; the nix
package pins both by store path (see `lua/jotdown/tools.lua`), so the packaged
plugin never depends on `$PATH`.

## Using it

`setup()` registers the entrypoints: opening a `.ipynb` mounts the notebook
UI over that window (`auto_open = false` to opt out; `:Jotdown` opens or
toggles by hand). The kernel is LAZY — nothing boots until the first run.

Saving rides vim's own file semantics: `:w` — on the notebook, inside a
focused cell buffer (they are named acwrite buffers), `:wa`, anything —
syncs cell buffers into the store, serializes to nbformat (sorted keys,
indent 1, ids/metadata/unknown fields preserved), and writes the file.
Store changes set the file buffer's 'modified', so `:q` protection works
unmodified. `<C-j>t` toggles down to the raw JSON (serialized fresh, never
stale) and back; the store — outputs, kernel session — survives the round
trip, and raw-JSON edits win by re-parse on the way back up.

## UI plan (decided so far)

- Keybinds: ONE prefix — `<C-j>`, configurable via `setup({ prefix = ... })`
  — and every jotdown bind is a chord under it, the weave
  `<leader><leader>` principle. Stock normal-mode `<C-j>` is `<NL>`, a
  synonym for `j`, so nothing native is lost; the known conflict is user
  window-nav maps on `<C-hjkl>`. Per-cell chords work over the page
  (fibrous on_key routing) and inside a focused cell buffer (buffer-local;
  management chords Esc-pop to the page first):
  `<C-j>r` run hovered cell · `<C-j><CR>` run and advance (appends a cell
  when there is no next one; on markdown, just advances) · `<C-j>o`/`<C-j>O`
  add cell below/above · `<C-j>d` delete cell · `<C-j>J`/`<C-j>K` move cell
  down/up · `<C-j>m` retype code<->markdown · `<C-j>e` edit markdown in a
  split preview · `<C-j>c` fold outputs · `<C-j>C` clear outputs.
  Notebook-wide: `<C-j>a` run all, `<C-j>i` interrupt, `<C-j>x` clear all
  outputs, `<C-j>w` save, `<C-j>t` toggle raw ipynb.

- Code cells are fibrous subwindows with `render = "focus"`: unfocused you
  see the painted mirror in the root buffer, focusing (`<CR>`/click on the
  mirror) reveals the live float with native filetype/undo.
- Markdown cells render rich; `<C-j>e` toggles split editing — the raw
  source in a real markdown buffer on the left (visible, auto-entered),
  a live rendered preview on the right, repainted as you type. `<C-j>e`
  again (inside or hovering) closes the split and the store takes the
  text. Built on fibrous-docs' playground pattern
  (`site/lua/webapp/playground.lua`).

## Development

    make test                       # full suite, working tree
    make test-file FILE=tests/...  # one spec
    make demo                       # the notebook over the scripted kernel
    nix flake check                 # the suite in the sandbox, pinned deps
    nix develop                     # nvim, stylua, lua-ls, curl, websocat,
                                    # jupyter-server + ipykernel

Tests run in a fully isolated headless Neovim (`-u NONE`); the harness is a
small busted-flavored runner in `tests/harness.lua`. Unit specs are hermetic
(fakes all the way down); the one integration spec boots a REAL local
jupyter server through the real curl+websocat transport, and skips itself
when `jupyter-server` is not on PATH (`nix develop` provides it).
