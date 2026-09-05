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
builds, and `settings.json` runs that path. So `make` is the whole
deploy. A fix is not live until that symlink points at the repo build;
never copy the binary somewhere else.

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
