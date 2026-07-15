# Pending tasks

UI items parked while other work happens. Roughly ordered.

## Rendering & scale

- [ ] Watch per-cell subwin float cost on large notebooks; if mirror/float
      materialization needs to get lazier, that is a fibrous-core
      discussion with Manuel FIRST (see AGENTS.md at the repo root).

## Outputs

- [ ] ANSI escape parsing into real highlights (streams and tracebacks are
      stripped today).
- [ ] Inline images: image/png / image/jpeg render as their text/plain repr
      plus an honest label today — kitty graphics, or an "open externally"
      affordance first.
- [ ] text/html: degrades to text/plain today; a crude tag-strip fallback
      for bundles that ship html only.
- [ ] Persist output folds (`cell.collapsed` is session state; nbformat has
      metadata.collapsed / jupyter.outputs_hidden).
- [ ] Scroll-to-output on run (the jump machinery in view/notebook makes
      this cheap now).

## Connections

- [ ] Share one resolved endpoint across notebooks on the same connection
      (today each notebook resolves its own: N notebooks on `local` means N
      jupyter servers; the sessions API would happily multiplex one).
- [ ] Async readiness polling for the local kind (wait_ready pumps the loop).
- [ ] Persist UI-created connections (offer to write them into the nearest
      perijove.json?); today they are in-memory only.
- [ ] Surface the effective connection name in the notebook status line.

## Kernel UX

- [ ] Password-style stdin (`getpass`): the prompt renders as a normal
      text_input today; conceal the typed value when password = true.
- [ ] A spinner / statusline integration beyond the busy-since timer.
- [ ] Shutdown chord (restart is `<C-j>R`; shutdown currently rides
      buffer close / VimLeave).

## Done (this file's graduates)

- [x] Jupyter connections: a plugin-global registry of declarative specs
      (local / remote / command / lua) resolving to endpoints; preconfigured
      via `setup({ connections, default_connection })`, per-project via
      `perijove.json` (upward, nearest wins), interactive pick/create
      (`<C-j>s`, `:Perijove connections|connect|new-connection`), lua API
      (`perijove.connections`, `notebook_file.set_connection`). Switching a
      live notebook rebases the lazy client: old kernel and tunnel torn
      down, next run boots on the new connection, outputs stay.

- [x] Cell management chords: `<C-j>o`/`<C-j>O` add below/above, `<C-j>d`
      delete, `<C-j>J`/`<C-j>K` move, `<C-j>m` retype — page-level via
      on_key routing AND buffer-local inside a focused cell (Esc-pops
      first). The fibrous mirror-restore ordering bug this exposed is
      fixed in fibrous core (tests/inline/mirror_move_spec.lua pins it).
- [x] Run-and-advance: `<C-j><CR>` runs the hovered cell and lands on the
      next code cell, appending a fresh one below when there is none;
      `<C-j><CR>` on a markdown cell just advances. Jump anchors ride
      per-cell `role` strings through fibrous.targets, paging the viewport
      when the target is off-screen.
- [x] `setup({ prefix = ... })`: every chord derives from the prefix
      (default `<C-j>`).
