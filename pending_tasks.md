# Pending tasks

UI items parked while the real-kernel work happens. Roughly ordered.

## Cell management

- [ ] Chords for add cell above/below (`<C-j>o` / `<C-j>O`?), delete cell,
      move cell up/down, change cell type (code <-> markdown).
- [ ] Run-and-advance (the notebook staple: run hovered cell, cursor to the
      next one).

## Markdown cell editing (decision pending)

- [ ] Decide between (a) rendered when unfocused / raw source while focused,
      and (b) split preview while focused — source left, rendered right —
      and rendered-only when unfocused. Currently leaning (b);
      fibrous-docs' `site/lua/webapp/playground.lua` is the prior art.
- [ ] Implement it with a render="focus" subwindow, like code cells.

## Rendering & scale

- [ ] Memoize per-cell components (`memo = true`, the weave transcript
      pattern) so a store notify re-renders only the changed cell.
- [ ] Watch per-cell subwin float cost on large notebooks; if mirror/float
      materialization needs to get lazier, that is a fibrous-core
      discussion with Manuel FIRST (see AGENTS.md at the repo root).

## Outputs

- [ ] ANSI escape handling in streams and tracebacks (IPython colors its
      tracebacks) — parse to highlights, or strip at minimum.
- [ ] Rich mime dispatch: text/markdown via ui.markdown, text/latex via the
      fibrous math renderer, image/png (kitty graphics? degrade to an
      "open externally" affordance first), text/html degrade to text.
- [ ] Output management: collapse/clear a cell's output, clear all,
      scroll-to-output on run.

## Kernel UX

- [ ] stdin (`input()`) prompts: on_input_request wired to a prompt UI.
- [ ] Kernel status surfacing: busy-since timer, spinner, restart/shutdown
      chords — matters for remote GPU boxes that bill while idle.

## Config

- [ ] `setup()` takes the keybind prefix (default `<C-j>`); all chords
      derive from it.
