# Pending tasks

UI items parked while other work happens. Roughly ordered.

## BLOCKED: fibrous mirror-restore ordering bug (core fix, discuss with Manuel)

Found 2026-07-13 while building cell management. When a flush moves
subwindow boxes DOWNWARD (insert a cell above, move a cell down), the moved
entries' mirrors go blank: `subwin.sync()` repositions entries in document
order, and each moved entry first restores the canvas under its OLD box
("A moved/resized box leaves the old one's mirror stranded ... restore the
canvas there first", reposition's extraction-memo branch) — but in a
downward shift, entry N's old box overlaps entry N-1's NEW box, so the
restore lands on top of the mirror N-1 painted moments earlier in the same
sync. Destroys already guard against exactly this ("Destroys run FIRST");
moves don't. The extraction memo then records the paint as done, so no
later scroll/flush repairs it.

- Minimal repro (pure fibrous, no jotdown): a keyed col of two raw_buffers,
  prepend a third — every mirror except the LAST goes blank. Script kept at
  `/tmp/fib_minimal.lua` during the session; trivially rebuilt from this
  description.
- Proposed fix: two-phase sync — first pass restores every moved entry's
  old box (and clears `entry.mirrored`), second pass repositions/paints.
  Mirrors of upward moves and deletes already survive by ordering luck.
- Pinned by the skipped spec in `tests/view/notebook_spec.lua`
  ("chains management chords over one notebook"): flip
  `FIBROUS_MIRROR_MOVE_FIXED` once the fix lands.
- Until then: the chords WORK (store correct, saves correct) but the
  painted notebook blanks some cells after insert-above/move until a cell
  is focused or the notebook is remounted.

## Rendering & scale

- [ ] Watch per-cell subwin float cost on large notebooks; if mirror/float
      materialization needs to get lazier, that is a fibrous-core
      discussion with Manuel FIRST (see AGENTS.md at the repo root).

## Outputs

- [ ] ANSI escape parsing into real highlights (streams and tracebacks are
      stripped today).
- [ ] Rich mime dispatch: text/markdown via ui.markdown, text/latex via the
      fibrous math renderer, image/png (kitty graphics? degrade to an
      "open externally" affordance first), text/html degrade to text.
- [ ] Output management: collapse/clear a cell's output, clear all,
      scroll-to-output on run.

## Kernel UX

- [ ] stdin (`input()`) prompts: on_input_request wired to a prompt UI.
- [ ] Kernel status surfacing: busy-since timer, spinner, restart/shutdown
      chords — matters for remote GPU boxes that bill while idle.

## Done (this file's graduates)

- [x] Cell management chords: `<C-j>o`/`<C-j>O` add below/above, `<C-j>d`
      delete, `<C-j>J`/`<C-j>K` move, `<C-j>m` retype — page-level via
      on_key routing AND buffer-local inside a focused cell (Esc-pops
      first). Display caveat above until the fibrous fix.
- [x] Run-and-advance: `<C-j><CR>` runs the hovered cell and lands on the
      next code cell, appending a fresh one below when there is none;
      `<C-j><CR>` on a markdown cell just advances. Jump anchors ride
      per-cell `role` strings through fibrous.targets, paging the viewport
      when the target is off-screen.
- [x] `setup({ prefix = ... })`: every chord derives from the prefix
      (default `<C-j>`).
