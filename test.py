#!/usr/bin/env python3
"""Items of one list come out on one level. Run with: make test

Each case is markdown and the level every output line must have. The
binary and the Python reference must both give it. A TEXT case names the
lines themselves, colour codes left out.
"""
import json
import re
import subprocess
import sys

ENGINES = {"asm": ["./hyperlist-display"],
           "py": [sys.executable, "reference/hyperlist-display.py"]}

CASES = [
    ("a continuation under a numbered item, then the outer list",
     "- Open\n  1. one\n     more about one\n  2. two\n  3. three\n- Closed\n",
     [0, 1, 2, 1, 1, 0]),
    ("text at the number's own indent",
     "1. one\nmore about one\n2. two\n3. three\n",
     [0, 1, 0, 0]),
    ("bullets under a text line inside a numbered item",
     "1. one\nDo this:\n- a\n- b\n2. two\n- c\n",
     [0, 1, 2, 2, 0, 1]),
    ("the same, indented under the number",
     "1. one\n   Do this:\n   - a\n   - b\n2. two\n",
     [0, 1, 2, 2, 0]),
    ("an intro line, a numbered list, a continuation",
     "Steps:\n1. one\n   more about one\n2. two\n",
     [0, 1, 2, 1]),
    ("bullets with a continuation line",
     "- a\n  more about a\n- b\n- c\n",
     [0, 1, 0, 0]),
    ("a number under a bullet, then the next bullet",
     "- top\n  1. one\n  text under one\n- next\n",
     [0, 1, 2, 0]),
    ("a list still nests under the line that introduces it",
     "Steps:\n1. one\n2. two\n",
     [0, 1, 1]),
    ("a numbered table row shares its line with the first property",
     "| # | Question | Rec |\n|--|--|--|\n| 4 | Cut? | Yes |\n| 5 | Go? | No |\n",
     [0, 1, 0, 1]),
]

TEXT = [
    ("a numbered table row",
     "| # | Question | Rec |\n|--|--|--|\n| 4 | Cut? | Yes |\n| 12 | | Wait |\n| 13 | | |\n",
     ["4. Question: Cut?", "    Rec: Yes", "12. Rec: Wait", "13"]),
    ("a row that opens with a name keeps its own line",
     "| File | Size |\n|--|--|\n| a.rs | 12 |\n",
     ["a.rs", "    Size: 12"]),
]


def lines(cmd, md):
    payload = json.dumps({"delta": md, "index": 0, "final": True})
    out = subprocess.run(cmd, input=payload, capture_output=True, text=True).stdout
    text = json.loads(out)["hookSpecificOutput"]["displayContent"]
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    return [l for l in text.split("\n") if l.strip()]


def levels(cmd, md):
    return [(len(l) - len(l.lstrip(" "))) // 4 for l in lines(cmd, md)]


failed = 0
for name, md, want in CASES:
    for engine, cmd in ENGINES.items():
        got = levels(cmd, md)
        if got != want:
            failed += 1
            print("FAIL {} ({}): want {} got {}".format(name, engine, want, got))
for name, md, want in TEXT:
    for engine, cmd in ENGINES.items():
        got = lines(cmd, md)
        if got != want:
            failed += 1
            print("FAIL {} ({}): want {} got {}".format(name, engine, want, got))
print("{} cases, {} engines, {} failed".format(len(CASES) + len(TEXT), len(ENGINES), failed))
sys.exit(1 if failed else 0)
