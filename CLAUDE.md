# hyperlist-display: project notes

Pure x86_64 NASM, no libc. A Claude Code `MessageDisplay` hook that
rewrites an answer into tab-indented HyperList before it is shown.
Part of the CHasm suite; read the umbrella `../chasm/CLAUDE.md` first
for the three rules (no wasted cycles, lightning fast, battery).

## Build and deploy

```
make
```

`~/.claude/hooks/hyperlist-display-asm` is a symlink to the binary this
builds. So `make` is the whole deploy. A fix is not live until that
symlink points at the repo build; never copy the binary somewhere else.

Since 2026-09-05 `settings.json` does not run that path directly. The
`MessageDisplay` entry is `~/.claude/hooks/style-gate`, a small Python
hook owned by the #system session. It buffers the whole answer, runs
`stylecheck` on it, and only then calls this binary once with the
complete message as a single delta (index 0, final true). To bypass the
gate, point `MessageDisplay` back at `hyperlist-display-asm`.

Nothing under `~/.claude` is in git. The symlinks point into this repo;
the repo never points back.

The three helpers are symlinked the same way:

| in the repo | deployed as |
|---|---|
| `hyperlist-toggle` | `~/.claude/hooks/hyperlist-toggle` |
| `hyperlist-output-state.sh` | `~/.claude/hooks/hyperlist-output-state.sh` |
| `commands/hl.md` | `~/.claude/commands/hl.md` |

`reference/hyperlist-display.py` is the earlier Python version. It is
not wired in. It is the reference for behaviour: when the asm and the
Python disagree on how some markdown should map, the Python one says
what was meant. Change it too when the mapping changes on purpose.

## Wire format, learned the hard way

- The hook JSON's text field is `delta`, not `message_text`, and it
  arrives **per streamed chunk**. The hook may run many times for one
  answer. That is why this is assembly: the Python version cost 52 ms
  per run, nearly all interpreter startup.
- Behind style-gate the live path sends one delta per answer, so the
  cross-delta code (held tail, carried table header, reset on index 0)
  is not exercised there. Keep it: `/hl off` and any direct wiring
  still stream.
- The `settings.json` entry needs the nested `{"hooks": [ ... ]}` block
  inside the `MessageDisplay` array, not a bare command object.
- Output is `displayContent`, which reaches the terminal as plain text,
  not markdown. Emphasis therefore has to be real ANSI. One-byte
  sentinels mark bold and italic through wrapping and expand at emit
  time, so they cost no display columns.
- Exit 1 anywhere means "show the original text". Claude Code falls
  back on a failed hook, so every error path is a jump to `fail`. Never
  emit a partial rewrite.

## Mapping rules that exist because something looked wrong

- **Attach-list rule (2026-09-02):** a list right after a prose line
  with no blank line between nests under that line, incrementing the
  child counter, rather than starting a sibling.
- **Sibling rule (2026-10-07):** the items of one list stay on one
  level. A list item shallower than the prose line above it does not
  attach to that line; the line was a continuation under an earlier
  item. Inside a numbered item an attachment raises that item's lift,
  which ends at the next number, and not the child counter, which
  never comes down inside a block. Content shallower than a numbered
  item ends its block. `make test` has the cases.
- **Numbered row rule (2026-10-08):** a table row that opens with a
  bare number is a numbered item. The number and the first property
  that has a value share one line, "4. Question: ...", and the other
  properties hang under it. Any other first cell keeps its own line.
- **Property after a number (2026-10-08):** a Property is painted at
  the start of an Item and also right after its Identifier. That keeps
  "Question:" red in a numbered row, and "1. Note: ..." in a list too.
- **Tab expansion in `lead_cols`:** leading tabs count as indentation
  for bullet and numbered depth, so a tab-indented list from Claude
  nests the way a space-indented one does.

## The toggle

`/hl` runs `hyperlist-toggle`, which creates or removes
`~/.claude/hyperlist-display.off`. Both hooks check that flag on every
invocation with one `stat()`, so the off path costs nothing and the
change lands on the next answer. `hyperlist-output-state.sh` repeats
"HyperList is off" into context each turn while the flag exists, so
Claude stops writing in hierarchy too. The state survives restarts and
context compaction because it is a file, not session memory.

## Sizes

`IN_MAX`, `MSG_MAX` 1 MB; `OUT_MAX` 2 MB (JSON escaping can double);
`LINE_MAX` and `PARA_MAX` 64 KB. All BSS, no allocator. Anything past a
cap falls back to the original text rather than truncating.
