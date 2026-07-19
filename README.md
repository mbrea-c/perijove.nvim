# perijove.nvim

A Jupyter notebook frontend for Neovim, built on
[fibrous](https://github.com/mbrea-c/fibrous.nvim). Early days: the transport
skeleton exists; the notebook UI, protocol layer, and `.ipynb` round-trip are
being built on top of it.

## Architecture

Jupyter separates frontend, middle layer, and kernel — the kernel never sees
the notebook document, only code strings. perijove is a frontend that speaks to
the official middle layer, **Jupyter Server's REST + websocket API** (the same
surface JupyterLab uses), so local and remote kernels are one code path:

- **local**: perijove spawns `jupyter server` itself and connects over
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

The **wire transport** (`lua/perijove/transport/`) is the narrow interface —
`request()` for HTTP, `ws_open()` for channels — with implementations
registered by name. The default shells out to curl and websocat; the nix
package pins both by store path (see `lua/perijove/tools.lua`), so the packaged
plugin never depends on `$PATH`.

## Using it

`setup()` registers the entrypoints: opening a `.ipynb` mounts the notebook
UI over that window (`auto_open = false` to opt out; `:Perijove` opens or
toggles by hand). The kernel is LAZY — nothing boots until the first run.

### Connections

Where the kernel lives is a **jupyter connection**: a named, declarative spec
kept in one plugin-global registry (`perijove.connections`). Resolving a
connection yields an endpoint (base url + credentials, plus a `stop()` when
the connection owns a process), and the same server client dials all of them.
The kinds:

- `local` — spawn `jupyter-server` on this machine (the builtin default,
  always registered as `local`; fields `cmd?`, `root_dir?`);
- `remote` — a server that already exists: `url`, plus `token` or `headers`
  (a table, or a function re-read per request for expiring credentials);
- `command` — a tunnel-shaped setup (SageMaker via SSM, `ssh -L`, ...):
  `argv` is spawned, prints ONE JSON handshake line on stdout
  (`{"url": ..., "token"?: ..., "headers"?: ...}`), then stays alive as the
  tunnel; it is killed when the notebook lets go;
- a raw `connect = function(spec, cb)` for anything dynamic, from `setup()`
  or the lua API only; `cb(err, endpoint)`.

Register them in `setup()` and pick the global default:

```lua
require("perijove").setup({
  connections = {
    { name = "gpu-box", kind = "remote", url = "http://gpu:8888", token = "..." },
    { name = "sagemaker", kind = "command", argv = { "ssm-tunnel", "up" } },
  },
  default_connection = "gpu-box",
})
```

or per project in a `perijove.json`, resolved upward from the notebook file
(nearest wins; its connections shadow global ones by name, its `default`
beats the global default):

```json
{
  "connections": [
    { "name": "team-gpu", "kind": "remote", "url": "http://gpu:8888" }
  ],
  "default": "team-gpu"
}
```

or dynamically: `require("perijove.connections").add{...}` / `.set_default()`
/ `.remove()`, and `require("perijove.notebook_file").set_connection(bufnr,
name)` for one notebook. Interactively: `<C-j>s` (or `:Perijove connections`)
picks the connection for the current notebook — switching a live notebook
shuts the old kernel down and the next run boots on the new connection,
outputs intact; outside a notebook it sets the global default. `:Perijove
connect <name>` skips the picker (names complete), `:Perijove new-connection`
creates one interactively (in-memory; persist it via `setup()` or
`perijove.json`). A notebook's effective connection is: explicitly selected >
`perijove.json` default > `setup()` default > `local`. Whatever is picked,
nothing dials until the first run.

### A custom local jupyter (nix)

The packaged plugin closes over its own python env: `jupyter-server`,
`ipykernel`, and `matplotlib`, pinned by store path (`lua/perijove/tools.lua`,
substituted in `flake.nix`). That is enough to boot a kernel and draw a plot,
and nothing else — the moment a notebook imports numpy or torch, the `local`
connection needs an env you built.

**`nix shell` does not help here.** The packaged plugin never looks at `$PATH`;
it runs the store path it was built with. Adding packages to your shell changes
nothing about which python the kernel gets. You have to point perijove at a
different env explicitly, which is what the two knobs below do.

Build the env like any other python env — `ipykernel` is what makes it a
usable kernel, `jupyter-server` is what perijove spawns:

```nix
notebookEnv = pkgs.python3.withPackages (ps: [
  ps.jupyter-server
  ps.ipykernel
  ps.numpy
  ps.pandas
  ps.matplotlib
]);
```

Then either give one connection its own server, which leaves the builtin
`local` alone as a fallback:

```nix
plugins.perijove.settings.connections = [
  {
    name = "ds";
    kind = "local";
    cmd = [ "${notebookEnv}/bin/jupyter-server" ];
    # the server's cwd for relative paths and data files; it defaults to
    # $TMPDIR, which is rarely what a notebook wants
    root_dir = "/home/you/work";
  }
];
plugins.perijove.settings.default_connection = "ds";
```

or replace the default binary globally, so every `local` connection (including
the builtin one) uses that env:

```nix
plugins.perijove.settings.tools."jupyter-server" = "${notebookEnv}/bin/jupyter-server";
```

`cmd` is an argv PREFIX: perijove appends its own `--ServerApp.*` flags (ip,
free port, generated token, no browser, root_dir), so anything that accepts
jupyter-server's options works — a wrapper script, `nix run`, a `poetry run`
line. `tools` takes single binaries, `cmd` takes a whole argv; both beat the
substituted store path (`tools.lua`: override > store path > PATH).

The kernels the config window offers come from that server's
`/api/kernelspecs`, so a package is importable in a cell exactly when it is in
the env whose `ipykernel` registered the kernelspec. Mixing envs (server from
one, kernel from another) is possible via kernelspecs but is not something
perijove sets up for you.

The same two knobs work from plain lua when you are not going through nix, with
whatever absolute path you like:

```lua
require("perijove").setup({
  connections = {
    { name = "ds", kind = "local", cmd = { "/path/to/env/bin/jupyter-server" } },
  },
  default_connection = "ds",
})
```

### The config window

`<C-j>S` (or `:Perijove config`) opens the **jupyter config window**, a
floating panel with a dropdown per axis: the **connection** the notebook
talks to (with the spec's kind/source/default shown beneath) and the
**kernel** it boots. Dropdowns filter as you type; `<C-n>`/`<C-p>` move the
selection, `<CR>`/`<C-y>` apply it — a pick switches the live notebook like
`set_connection`/`set_kernel` (old kernel down now, next run boots the new
choice). Once the notebook's server has booted, its `/api/kernelspecs`
listing fills the kernel dropdown; before that the field is free text (type
any kernelspec name). **+ new connection…** runs the guided creation flow.
Outside a notebook the window sets the global default connection and has no
kernel field. Programmatically: `notebook_file.set_kernel(bufnr, name)` /
`notebook_file.kernel_of(bufnr)`.

### Notebook LSP

perijove speaks LSP 3.17 **notebookDocument synchronization**, the protocol
notebook-aware language servers already know from VSCode: the notebook is one
document, each code cell a cell text document with its own URI, and the server
analyzes them as one module, in cell order. No concatenated shadow buffer, no
per-cell standalone files. Core Neovim has no notebook support, so perijove
drives the protocol itself (`lua/perijove/lsp/`), never buffer-attaching the
client (that would double-sync cells as ordinary files).

Opt in with a notebook-capable server (basedpyright is the tested one):

```lua
require("perijove").setup({
  lsp = { cmd = { "basedpyright-langserver", "--stdio" } },
})
```

What you get today: diagnostics with cross-cell name resolution (a variable
defined in cell 1 resolves in cell 2; editing cell 1 re-analyzes cell 2),
placed on the right cell buffers; hover on `K` inside a focused cell;
completion via omnifunc (`<C-x><C-o>`). Cell add/delete/move/retype and the
raw-JSON round trip keep the server's view in sync. Diagnostics are PULLED
(`textDocument/diagnostic`), which is what notebook servers actually
implement: the session pulls after every change and on server refresh
requests. One server instance is shared per project root; each notebook is
its own document.

Saving rides vim's own file semantics: `:w` — on the notebook, inside a
focused cell buffer (they are named acwrite buffers), `:wa`, anything —
syncs cell buffers into the store, serializes to nbformat (sorted keys,
indent 1, ids/metadata/unknown fields preserved), and writes the file.
Store changes set the file buffer's 'modified', so `:q` protection works
unmodified. `<C-j>t` toggles down to the raw JSON (serialized fresh, never
stale) and back; the store — outputs, kernel session — survives the round
trip, and raw-JSON edits win by re-parse on the way back up.

### MCP: live notebooks as agent tools

An agent that edits the `.ipynb` file behind nvim's back only meets the
external-change intake (reload, or keep-with-warning when the notebook has
unsaved work). `perijove.mcp` exposes the LIVE session instead: tools to
list open notebooks, list/read/edit/insert/delete cells, run a cell on the
notebook's kernel and wait for its outputs, and save — all against the
store, so edits land like a user's (view re-renders, dirty flag set, kernel
kept).

The MCP host is the separate
[clankbox.nvim](https://github.com/mbrea-c/clankbox.nvim) plugin: one server per
nvim, a dumb stdio shim (`nvim -l <clankbox.nvim>/shim.lua`, spawned by the MCP
client from inside a `:terminal`, finding the parent via `$NVIM`), protocol
and tool registry running in the live nvim. perijove is a pure tool
provider: when clankbox is installed, `setup()` registers the `notebook_*`
tools into it automatically, and nothing in perijove requires it. Any
server exposing `register_tool(name, def)` works:

```lua
require("perijove.mcp").register_into(my_server)
```

## UI plan (decided so far)

- Keybinds: ONE prefix — `<C-j>`, configurable via `setup({ prefix = ... })`
  — and every perijove bind is a chord under it, the weave
  `<leader><leader>` principle. Stock normal-mode `<C-j>` is `<NL>`, a
  synonym for `j`, so nothing native is lost; the known conflict is user
  window-nav maps on `<C-hjkl>`. Per-cell chords work over the page
  (fibrous on_key routing) and inside a focused cell buffer (buffer-local;
  management chords Esc-pop to the page first):
  `<C-j>r` run hovered cell · `<C-j><CR>` run and advance (appends a cell
  when there is no next one; on markdown, just advances) · `<C-j>o`/`<C-j>O`
  add cell below/above · `<C-j>d` delete cell · `<C-j>J`/`<C-j>K` move cell
  down/up · `<C-j>m` retype code<->markdown · `<C-j>c` fold outputs ·
  `<C-j>C` clear outputs.
  Notebook-wide: `<C-j>a` run all, `<C-j>i` interrupt, `<C-j>R` restart
  kernel, `<C-j>s` switch jupyter connection, `<C-j>S` jupyter config window
  (connection + kernel dropdowns), `<C-j>x` clear all outputs,
  `<C-j>w` save, `<C-j>t` toggle raw ipynb, `<C-j>p` toggle markdown side
  previews.

- `input()` works: the kernel's stdin ask renders an inline prompt under
  the running cell (a fibrous text_input; `<CR>` submits). The status line
  shows how long the kernel has been busy.

- Code cells are fibrous subwindows with `render = "focus"`: unfocused you
  see the painted mirror in the root buffer, focusing (`<CR>`/click on the
  mirror) reveals the live float with native filetype/undo.
- Markdown cells render rich and borderless (an empty one shows an italic
  grayed placeholder); ACTIVATING one — `<CR>` or click, like any fibrous
  widget — opens split editing: the raw source in a real markdown buffer
  on the left (auto-entered, cursor on the source line best matching the
  activated rendered line), a live rendered preview on the right,
  repainted as you type. Unfocusing the editor (fibrous `<Esc>` back to
  the page, a jump elsewhere) closes the split and the store takes the
  text. `<C-j>p` toggles the preview pane globally (default on; off =
  source-only editing). Built on fibrous-docs' playground pattern
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
