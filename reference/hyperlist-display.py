#!/usr/bin/env python3
"""Render Claude Code answers as HyperList on screen.

MessageDisplay hook. Display-only: the transcript and what Claude reads keep
the original markdown, so nothing here can corrupt the conversation. If this
script fails or emits nothing, Claude Code shows the original text.

Conversion is mechanical, not semantic. It maps the structure markdown already
carries (headings, bullets, tables, code) onto tab-indented HyperList, splits
paragraphs into one sentence per line, and translates emphasis. It cannot
invent a hierarchy that the markdown did not have.

Counts its own invocations into $XDG_RUNTIME_DIR/hyperlist-hook.count (tmpfs,
no disk I/O) so the per-chunk fork cost can be measured before deciding to
keep this. Delete the counter block once that question is settled.
"""
import json
import os
import re
import struct
import sys

# Deltas arrive one chunk at a time and are converted independently, but the
# heading level a chunk establishes has to survive into the next chunk or the
# indentation resets mid-list. Carry the two pieces of cross-delta state in a
# small tmpfs file, reset whenever index == 0 starts a fresh message.
STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
                     "hyperlist-display.state")


HDR_MAX = 1024      # carried table header row, bounded
TAIL_MAX = 4096     # carried partial line, bounded
HDR_OFF = 136
TAIL_OFF = HDR_OFF + HDR_MAX


def load_state():
    """Base indent, heading shift, fenced-block state, the current table header
    row, and any unterminated trailing line. All of it must survive a chunk
    boundary: a table split across deltas would otherwise take its second
    chunk's first row as a new header and turn that row's cells into property
    names, and a sentence split across deltas would be measured as two short
    Items, so neither would wrap and the two would share a terminal row.

    HyperList 2.8 dropped the sibling-Starter rule, so no group state is
    needed: every line can be laid out knowing only its own Item."""
    try:
        with open(STATE, "rb") as f:
            raw = f.read(TAIL_OFF + TAIL_MAX)
        (base, shift, fence, find, hlen, tlen, kid, colon, quote, last,
         hoff, enum1, eshift, pbase1, prev1, dshift, dorigin) = \
            struct.unpack_from("<qqqqqqqqqqqqqqqqq", raw, 0)
        hdr = (raw[HDR_OFF:HDR_OFF + hlen].decode("utf-8", "replace")
               if hlen else None)
        tail = raw[TAIL_OFF:TAIL_OFF + tlen].decode("utf-8", "replace")
        return (base, shift, fence, find, hdr, tail, kid, bool(colon),
                quote, last, hoff, enum1, eshift, pbase1, prev1, dshift,
                dorigin)
    except Exception:
        return 0, 0, 0, 0, None, "", 0, False, 0, 0, 0, 0, 0, 0, 0, 0, 0


def save_state(base, shift, fence, find, hdr, tail, kid, colon, quote,
               last, hoff, enum1, eshift, pbase1, prev1, dshift, dorigin):
    try:
        b = (hdr or "").encode()[:HDR_MAX]
        t = (tail or "").encode()[:TAIL_MAX]
        raw = struct.pack("<qqqqqqqqqqqqqqqqq", base, shift, int(fence),
                          find, len(b) if hdr is not None else 0, len(t), kid,
                          1 if colon else 0, quote, last, hoff, enum1, eshift,
                          pbase1, prev1, dshift, dorigin)
        raw += b + b"\0" * (HDR_MAX - len(b)) + t
        raw += b"\0" * (TAIL_OFF + TAIL_MAX - len(raw))
        with open(STATE, "wb") as f:
            f.write(raw)
    except OSError:
        pass

# Three spaces per level, matching how the definition document itself indents
# its examples. A literal tab would render at whatever width the terminal is
# set to, which makes the wrap arithmetic below unpredictable.
TAB = "    "
TABW = 4
WIDTH = int(os.environ.get("HL_WIDTH") or 150)

# HyperList uses *bold*, /italic/, _underline_. Markdown's **bold** and _em_
# collide, so translate rather than pass through.
RE_BOLD = re.compile(r"\*\*(.+?)\*\*", re.S)
RE_ITAL = re.compile(r"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])")
RE_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
RE_HEAD = re.compile(r"^(#{1,6})\s+(.*)$")
RE_BULL = re.compile(r"^(\s*)[-*+]\s+(.*)$")
# A numbered item may be wrapped in bold, "**1. Head**": the enumerator is
# still an enumerator, and the bold reopens on the rest of the Item.
RE_NUMB = re.compile(r"^(\s*)(\*\*)?(\d+)[.)]\s+(.*)$")
RE_FENCE = re.compile(r"^\s*```(.*)$")
RE_TROW = re.compile(r"^\s*\|(.+)\|\s*$")
RE_TSEP = re.compile(r"^\s*\|[\s:|-]+\|\s*$")
# A blockquote is quoted material, which HyperList carries as a child of
# the Item that introduces it rather than with a marker of its own.
RE_QUOTE = re.compile(r"^\s*>\s?(.*)$")
# Sentence split: end punctuation, closing quote/bracket optional, then space
# + capital. Protects the common abbreviations that would otherwise split.
# "If X, then Y" is a genuine HyperList Conditional. Bounded condition length
# so a long sentence that merely happens to contain a comma is left alone.
RE_COND = re.compile(r"^If\s+(.{1,120}?),\s+(?:then\s+)?(.+)$", re.S)
RE_SENT = re.compile(r"(?<=[.!?])\s+(?=[\"'(\[]?[A-Z0-9])"
                     r"|(?<=[.!?][\"')\]])\s+(?=[\"'(\[]?[A-Z0-9])")
ABBREV = ("e.g.", "i.e.", "etc.", "vs.", "cf.", "Mr.", "Dr.", "No.", "approx.")


# displayContent reaches the terminal as plain text, not markdown, so emphasis
# has to be real ANSI rather than HyperList's *bold* / /italic/ / _underline_
# markers. One-byte sentinels are carried through wrapping and expanded at
# emit time, so the markers cost no display columns and never break a line.
B_ON, B_OFF, I_ON, I_OFF, U_ON, U_OFF = "\x01\x02\x03\x04\x05\x06"
# Colour sentinels, one per HyperList element class plus a reset. 0x09, 0x0a
# and 0x0d are skipped: they are tab, newline and carriage return, which the
# line machinery reads as structure.
C_RED, C_GRN, C_BLU, C_MAG = "\x07\x08\x0b\x0c"
C_CYN, C_YEL, C_ORG, C_OFF = "\x0e\x0f\x10\x11"
SENTINELS = set("\x01\x02\x03\x04\x05\x06\x07\x08\x0b\x0c\x0e\x0f\x10\x11")
# Stands in for one byte of a code span while the markup passes run.
MASK = "\x12"
# The TUI theme puts Operators on 21 (#0000FF), which is unreadable on a dark
# terminal, so terminal output uses 27. The PDF and TUI keep 21.
ANSI = {B_ON: "\x1b[1m", B_OFF: "\x1b[22m",
        I_ON: "\x1b[3m", I_OFF: "\x1b[23m",
        U_ON: "\x1b[4m", U_OFF: "\x1b[24m",
        C_RED: "\x1b[38;5;203m", C_GRN: "\x1b[38;5;46m",
        C_BLU: "\x1b[38;5;27m", C_MAG: "\x1b[38;5;165m",
        C_CYN: "\x1b[38;5;51m", C_YEL: "\x1b[38;5;226m",
        C_ORG: "\x1b[38;5;208m", C_OFF: "\x1b[39m"}
RE_UL = re.compile(r"(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])")

# Paired delimiters, opener -> (closer, colour). Scanned left to right, first
# closer wins, no nesting: HyperList does not nest these and a prose paragraph
# full of half-open brackets must not swallow the rest of the line.
PAIRS = {"[": ("]", C_GRN), "<": (">", C_MAG), "(": (")", C_CYN),
         "{": ("}", C_YEL), '"': ('"', C_CYN)}
# Character classes transcribed from hyperlist.vim, the authoritative syntax.
# Any byte above ASCII counts as a letter, which is how the assembly port can
# accept the Nordic and accented capitals vim lists without a codepoint table.
OPER_CH = set("_-() /")
PROP_CH = set(",._&?!%= -/+<>#'\"()*")
TAG_CH = set(".:/_&?%=+-*")
REF_CH = set(",.:/ _~&@?%=+-*#")
KEYWORDS = ("SKIP", "END")


def after_colon(s, i, n):
    """True when only invisible sentinels stand between the colon at i and
    whitespace or the end of the Item. **Name:** puts a bold-off byte there."""
    j = i + 1
    while j < n and s[j] in SENTINELS:
        j += 1
    return j == n or s[j] in " \t"


def upper(c):
    return "A" <= c <= "Z" or c > "\x7f"


def letter(c):
    return "A" <= c <= "Z" or "a" <= c <= "z" or c > "\x7f"


def alnum(c):
    """ASCII only: the assembly port classifies bytes, not code points."""
    return "0" <= c <= "9" or "A" <= c <= "Z" or "a" <= c <= "z"


def expand_ansi(s):
    for k, v in ANSI.items():
        s = s.replace(k, v)
    return s


def mask_code(s):
    """Replace the inside of every code span with MASK, returning the masked
    text and the bytes taken out.

    A run of N backticks opens a span that ends at the next run of exactly N,
    which is what markdown does and what lets ``a `b` c`` quote a backtick.
    Toggling on single backticks would close that span at the first inner one.
    """
    out, saved, i, n = [], [], 0, len(s)
    while i < n:
        if s[i] == "`":
            j = i
            while j < n and s[j] == "`":
                j += 1
            run, k = j - i, j
            while k < n:
                if s[k] != "`":
                    k += 1
                    continue
                m = k
                while m < n and s[m] == "`":
                    m += 1
                if m - k == run:
                    break
                k = m
            if k < n:
                out.append(s[i:j])
                saved.extend(s[j:k])
                out.append(MASK * (k - j))
                out.append(s[k:k + run])
                i = k + run
                continue
        out.append(s[i])
        i += 1
    return "".join(out), saved


def inline(s):
    """Markdown inline markup -> one-byte style sentinels.

    Code spans are masked before the passes rather than split around them, so
    **`name` rewritten** still bolds while `*p` stays a dereference. The mask
    byte matches no rule and no pass deletes or reorders one, so the saved
    bytes go back in the order they came out. Bold is matched before italic
    because ** would otherwise be eaten by the single-asterisk rule.
    """
    s, saved = mask_code(s)
    s = RE_LINK.sub(r"\1 <\2>", s)               # [text](url) -> text <url>
    s = RE_BOLD.sub(B_ON + "\\1" + B_OFF, s)      # **bold**
    s = RE_ITAL.sub(I_ON + "\\1" + I_OFF, s)      # *italic*
    s = RE_UL.sub(U_ON + "\\1" + U_OFF, s)        # _underline_
    s = s.replace("~~", "")
    if saved:
        it = iter(saved)
        s = "".join(next(it) if c == MASK else c for c in s)
    return s.strip()


def conditional(s):
    """If X, then Y -> [? X] Y. Brackets are Qualifiers in HyperList, and this
    is the one construct a mechanical pass can spot without guessing."""
    m = RE_COND.match(s)
    return f"[? {m.group(1)}] {m.group(2)}" if m else s


def colorize(s):
    """Paint the HyperList element classes, following hyperlist.vim.

    Two single left-to-right scans so the assembly port can reproduce them
    exactly: an anchored head class first, then the delimited classes over
    the remainder. Two deliberate departures from the vim patterns, both
    because an Item here is a whole line rather than a buffer region: the
    colon of an Operator or Property may be followed by end-of-item as well
    as whitespace, and a Property is recognised only at the start of an Item,
    since vim's mid-line rule would paint most prose red.
    """
    n = len(s)
    head = ""

    # An Item that opens with a quotation is quoted material: nothing inside
    # it is an Operator, Identifier or Property of THIS list, so the head
    # scans are skipped and the pair rule below paints the quote cyan.
    q = 0
    while q < n and s[q] in SENTINELS:
        q += 1
    if q < n and s[q] == '"':
        return head + colorize_tail(s)

    # --- Operator: HLop, two or more capitals from [A-Z_-() /] then ": "
    # Style sentinels are invisible, so they are skipped rather than counted:
    # a bold lead-in must not hide an Operator or Property from these scans.
    i = seen = 0
    while i < n:
        if s[i] in SENTINELS:
            i += 1
            continue
        if not (upper(s[i]) or s[i] in OPER_CH):
            break
        seen += 1
        i += 1
    if seen >= 2 and i < n and s[i] == ":" and after_colon(s, i, n):
        head, s = C_BLU + s[:i + 1] + C_OFF, s[i + 1:]
    else:
        # --- Identifier: HLident, digits and dots only, then a space
        i = seen = 0
        while i < n:
            if s[i] in SENTINELS:
                i += 1
                continue
            if not ("0" <= s[i] <= "9" or s[i] == "."):
                break
            seen += 1
            i += 1
        if seen >= 1 and i < n and s[i] in " \t":
            # A genuine Identifier carries a dot: "1." or "1.1.1". A bare
            # number is prose that merely starts with a figure, "259 tests
            # passing", and reading it as a numbering is wrong. Give it the
            # neutral Starter instead, which is what 2.8 added it for: the
            # Item no longer begins with a number, and the digits stay plain.
            if "." not in s[:i]:
                return C_MAG + "- " + C_OFF + colorize_tail(s)
            # A Property may follow the Identifier, "4. Question: ...": the
            # scan below goes on as if the Item began after its number.
            head, s = C_MAG + s[:i] + C_OFF, s[i:]
            n = len(s)
        # --- Property: HLtag, two or more of its class then ": "
        i = seen = 0
        while i < n:
            if s[i] in SENTINELS:
                i += 1
                continue
            if not (letter(s[i]) or "0" <= s[i] <= "9" or s[i] in PROP_CH):
                break
            seen += 1
            i += 1
        if seen >= 2 and i < n and s[i] == ":" and after_colon(s, i, n):
            head, s = head + C_RED + s[:i + 1] + C_OFF, s[i + 1:]

    return head + colorize_tail(s)


def colorize_tail(s):
    """The delimited classes over the remainder after the head scan."""
    out, i, n, code = [], 0, len(s), False
    while i < n:
        c = s[i]
        if c == "`":                            # code span: no rule fires
            code = not code
            out.append(c)
            i += 1
            continue
        if code:
            out.append(c)
            i += 1
            continue

        pair = PAIRS.get(c)
        if pair:
            close, col = pair
            j = s.find(close, i + 1)
            if j != -1:
                if c == "<":                    # HLref has a charset, and
                    body = s[i + 1:j]           # may double its brackets
                    if body and all(letter(x) or "0" <= x <= "9"
                                    or x in REF_CH or x == "<" or x == ">"
                                    for x in body):
                        k = j
                        while k + 1 < n and s[k + 1] == ">":
                            k += 1
                        out.append(col + s[i:k + 1] + C_OFF)
                        i = k + 1
                        continue
                else:
                    out.append(col + s[i:j + 1] + C_OFF)
                    i = j + 1
                    continue
        if c == "#":
            j = i + 1
            while j < n and (letter(s[j]) or "0" <= s[j] <= "9"
                             or s[j] in TAG_CH):
                j += 1
            if j > i + 1:
                out.append(C_ORG + s[i:j] + C_OFF)
                i = j
                continue
        if c == ";":
            out.append(C_GRN + ";" + C_OFF)
            i += 1
            continue
        if c in "SE" and (i == 0 or not alnum(s[i - 1])):
            for kw in KEYWORDS:
                if s.startswith(kw, i) and (i + len(kw) == n
                                            or not alnum(s[i + len(kw)])):
                    out.append(C_MAG + kw + C_OFF)
                    i += len(kw)
                    break
            else:
                out.append(c)
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def sentences(text):
    """One item per sentence is closer to HyperList than one item per para.

    Never split inside an open quotation. A quoted passage of several
    sentences is one Item: splitting it loses the Quote and, worse, lets the
    Conditional rewrite reach words the user is quoting from someone else.
    """
    guard = text
    for i, a in enumerate(ABBREV):
        guard = guard.replace(a, f"\x00{i}\x00")
    def bare_number_before(i):
        """True when the punctuation ending at i-1 closes a bare enumerator
        like "1." or "**3." — an Identifier-to-be, not a sentence end.
        Splitting there would orphan the number from its Item."""
        j = i - 1
        if j < 0 or guard[j] != ".":
            return False
        j -= 1
        d = 0
        while j >= 0 and "0" <= guard[j] <= "9":
            j -= 1
            d += 1
        if not d:
            return False
        while j >= 0 and guard[j] == "*":
            j -= 1
        return j < 0 or guard[j] in " \t"

    out, start = [], 0
    for m in RE_SENT.finditer(guard):
        if guard.count('"', 0, m.start()) % 2:
            continue                        # inside a quotation: not a break
        if bare_number_before(m.start()):
            continue
        out.append(guard[start:m.start()])
        start = m.end()
    out.append(guard[start:])
    res = []
    for p in out:
        for i, a in enumerate(ABBREV):
            p = p.replace(f"\x00{i}\x00", a)
        p = p.strip()
        if p:
            res.append(p)
    return res


def wrap_body(body, first_avail, cont_avail):
    """Greedy wrap on spaces, budgeted in DISPLAY columns: style sentinels
    occupy none, so a styled line must not break earlier than a plain one.
    Written as a byte-style scan so the assembly port reproduces it exactly."""
    out, i, avail = [], 0, first_avail
    n = len(body)
    while dwidth(body[i:]) > avail:
        j, cols = i, 0                  # j = index after `avail` columns
        while j < n:
            c = body[j]
            if c not in SENTINELS:
                if cols >= avail:
                    break
                cols += 1
            j += 1
        brk = body.rfind(" ", i, j + 1)
        if brk <= i:                    # a single word longer than the line
            out.append(body[i:j])
            i = j
        else:
            out.append(body[i:brk])
            i = brk + 1                 # the break consumes one space
        avail = cont_avail
    out.append(body[i:])
    return out


def dwidth(s):
    """Display columns: the style sentinels occupy none."""
    return sum(1 for c in s if c not in SENTINELS)


def codewrap(txt):
    """Literal lines go to the terminal inside a code span: the terminal's
    own inline-markdown pass would otherwise pair a bare `_` or `*` with one
    on a LATER line, eating both and italicising everything between. A run
    one longer than the longest inside keeps the span well-formed."""
    if not txt:
        return txt
    longest = max((len(m.group()) for m in re.finditer(r"`+", txt)), default=0)
    ticks = "`" * (longest + 1)
    return ticks + txt + ticks


def render(items, prev1=0, dshift=0, dorigin=0):
    """Lay the Items out, wrapping where needed (HyperList 2.8).

    An Item that spans more than one line takes a neutral Starter, "+ ", and
    its continuation lines sit two spaces beyond the Item's own indent. No
    other Item is affected, so each line can be laid out on its own.
    Literal lines (fenced code) are exempt: wrapping them would corrupt them.
    """
    out = []
    for ind, txt, lit in items:
        # HyperList indents one level at a time: a child sits exactly one
        # level under its parent. A jump of two has no parent to belong
        # to, so lift the whole block by the same amount rather than
        # clamping line by line, or siblings would drift apart. The lift
        # holds until a line comes back shallower than the one that
        # opened it. prev1 is the previous indent, encoded +1.
        if dshift and ind < dorigin:
            dshift = dorigin = 0
        if not dshift and ind > prev1:
            dshift, dorigin = ind - prev1, ind
        ind -= dshift
        prev1 = ind + 1
        tabs = TAB * ind
        if lit:
            out.append(tabs + codewrap(txt))
            continue
        avail = max(WIDTH - ind * TABW, 20)
        wraps = dwidth(txt) + 2 > avail
        # One Starter per Item. When an Item that already carries the
        # neutral "- " wraps, that marker becomes the multi-line "+" rather
        # than the Item taking a second one.
        neutral = C_MAG + "- " + C_OFF
        # An Item that opens with an Identifier already carries its
        # line-leading marker, so it takes no Starter: vim's HLident cannot
        # match behind one either. The continuation indent still shows the
        # Item spans lines.
        ident = txt[:2].startswith(C_MAG) and len(txt) > 1 and "0" <= txt[1] <= "9"
        if wraps and txt.startswith(neutral):
            body = C_MAG + "+ " + C_OFF + txt[len(neutral):]
        else:
            body = (C_MAG + "+ " + C_OFF if wraps and not ident else "") + txt
        parts = wrap_body(body, avail, avail - 2)
        out.append(tabs + expand_ansi(parts[0]))
        # Continuation lines sit two spaces beyond the Item's own indent.
        out.extend(tabs + "  " + expand_ansi(p) for p in parts[1:])
    return out, prev1, dshift, dorigin


def convert(md, base=0, shift=None, in_fence=0, fence_indent=0,
            table_hdr=None, kid=0, colon=False, quote=0, last=0, hoff=0,
            enum1=0, eshift=0, pbase1=0, prev1=0, dshift=0, dorigin=0):
    lines = md.split("\n")
    # "a\n" splits to ["a", ""]; that trailing empty is the newline itself, not
    # a blank line. Inside a fence it would otherwise emit a line of indent.
    if lines and lines[-1] == "":
        lines.pop()
    # Answers usually start at ## rather than #, so shift the whole tree left
    # by the shallowest heading present. Otherwise every line carries a tab of
    # dead indent and the deepest items run off a narrow terminal.
    # The shift is the shallowest heading level in the whole message, but a
    # chunk with no headings must not fix it at 0 -- that would push every
    # heading in a later chunk one level too deep. -1 means "not established
    # yet"; the first chunk that actually has a heading sets it.
    levels = [len(m.group(1)) - 1
              for m in (RE_HEAD.match(l) for l in lines) if m]
    if levels:
        shift = min(levels) if shift is None or shift < 0 else min(shift, min(levels))
    elif shift is None:
        shift = -1
    eff_shift = max(shift, 0)
    out = []   # (indent, text, literal)
    fence = {"on": in_fence, "ind": fence_indent}
    para = []
    # A paragraph indented under a list item is that item's content, so it
    # keeps the depth its own indentation carries, exactly as bullets do.
    # Set from the first line of each paragraph; a plain paragraph is 0.
    para_ind = 0

    state = {"base": base, "kid": kid, "colon": colon, "quote": quote,
             "last": last, "hoff": hoff, "enum1": enum1, "eshift": eshift,
             "pbase1": pbase1}

    def visible(t):
        return "".join(c for c in t if c not in SENTINELS).rstrip()

    def flush_para():
        """Emit the pending paragraph, one Item per sentence."""
        nonlocal para
        if not para:
            return
        body = " ".join(para)
        if state["quote"]:
            t = body.strip()
            # Quoted material carries visible quotation marks, and the
            # splitter then keeps the whole passage as one opaque Item.
            if not (len(t) > 1 and t.startswith('"') and t.endswith('"')):
                body = '"' + body + '"'
        for t in sentences(body):
            emit(state["base"] + para_ind, colorize(conditional(inline(t))),
                 shiftable=True)
        para = []

    def emit(indent, text, literal=False, shiftable=False):
        """Every Item goes through here so the block bookkeeping sees it.

        Quoted material sits exactly one level under the item that
        introduced it (the stored quote level), takes no Property-parent
        indent of its own, and never becomes a parent itself.

        A numbered item parents the block that follows it: shiftable
        content no deeper than the enumerator engages a shift that puts
        it one level under, and the shift holds until a blank line, a
        heading or the next enumerator. Content already deeper than the
        enumerator carries its own structure and engages nothing."""
        if state["quote"]:
            ind = state["quote"] - 1
        else:
            ind = indent + state["kid"]
            if shiftable and state["enum1"]:
                if ind + 1 < state["enum1"]:
                    # Shallower than the numbered item: outside its list,
                    # so the block it parents is over.
                    state["enum1"] = state["eshift"] = 0
                else:
                    if state["eshift"] == 0 and ind < state["enum1"]:
                        state["eshift"] = state["enum1"] - ind
                    ind += state["eshift"]
        out.append((ind, text, literal))
        if not literal:
            state["last"] = ind + 1        # encoded +1; 0 = nothing yet
        # Code and quotes are never Property parents.
        state["colon"] = (not literal and not state["quote"]
                          and visible(text).endswith(":"))

    def attach_list(depth):
        """A list that follows a prose line with no blank line between is
        that line's content: "Two paths:" or "Recommendation: X." and then
        the bullets. Markdown leaves them at the same level; HyperList puts
        the list one level under the line that introduced it. A blank line
        breaks the attachment (end_block then decides on the colon alone),
        which stops one intro from swallowing every list after it.

        Two cases are not an attachment, and without them the items of
        one list drift apart. An item shallower than the prose line: that
        line is a continuation under an earlier item, and this item is
        that item's sibling. And a numbered item in force: the extra level
        then goes into its shift, which ends at the next numbered item,
        so 1, 2 and 3 stay level."""
        attached = bool(para) and depth >= para_ind
        flush_para()
        if attached:
            state["colon"] = False
            if state["enum1"]:
                state["eshift"] += 1
            else:
                state["kid"] += 1

    def end_block():
        """A pure Property, "What went:", is a parent in HyperList: it names
        what follows and cannot stand childless. Markdown gives it no
        nesting, so when a block ends on one the next block is indented under
        it, whether that block is a paragraph or a list. Scope is one block,
        which stops the rule swallowing the rest of the answer."""
        flush_para()
        state["kid"] = 1 if state["colon"] else 0
        state["colon"] = False
        state["enum1"] = 0
        state["eshift"] = 0

    for raw in lines:
        # --- fenced code: passed through verbatim. A fence carrying a language
        # tag holds sample code, so it gets the "EXAMPLE: " Operator and sits a
        # level under it. A bare fence is the answer itself held verbatim, not
        # an example of anything, so it passes through unlabelled at base.
        m = RE_FENCE.match(raw)
        if m:
            if not fence["on"]:
                flush_para()
                # A fence after a pure Property is that Property's content,
                # not an example of anything: "regenerate with:" then the
                # command. Promote the Property to parent (keeping one
                # already in force) and skip the EXAMPLE: label.
                if state["colon"]:
                    state["kid"] = 1
                    state["colon"] = False
                tag = m.group(1).strip()
                # A fence tagged hyperlist IS a HyperList, not sample code:
                # no EXAMPLE: label, and its lines render as real Items.
                hl = bool(tag) and tag.split()[0] == "hyperlist"
                fence["on"] = 2 if hl else 1
                tagged = bool(tag) and not hl
                if tagged and not state["kid"]:
                    fence["ind"] = state["base"] + 1
                    emit(state["base"], colorize("EXAMPLE:"))
                else:
                    fence["ind"] = state["base"]
            else:
                fence["on"] = 0
            continue
        if fence["on"] == 2:
            # One leading tab per level, exactly as HyperList is written.
            # The [_] checkbox displays as [ ]: the terminal's own markdown
            # pass would pair the bare underscores across lines, eating them
            # and italicising everything in between.
            body = raw.rstrip()
            stripped = body.lstrip("\t")
            if stripped.strip():
                tabs = len(body) - len(stripped)
                out.append((fence["ind"] + state["kid"] + tabs,
                            colorize(stripped.replace("[_]", "[ ]")), False))
            continue
        if fence["on"]:
            emit(fence["ind"], raw.rstrip(), True)
            continue

        line = raw.rstrip()
        # --- blockquote: strip the marker, indent the quoted material one
        # level. HyperList has no quote marker of its own; quoted text is a
        # child of the Item that introduces it.
        m = RE_QUOTE.match(line)
        if m:
            if not state["quote"]:
                flush_para()
                state["quote"] = (state["last"] if state["last"]
                                  else state["base"]) + 1
            if not m.group(1).strip():
                flush_para()               # a bare ">" separates paragraphs
            else:
                para.append(m.group(1))
            continue
        if state["quote"]:
            flush_para()
            state["quote"] = 0
        if not line.strip():
            end_block()
            table_hdr = None
            continue

        # --- headings set the hierarchy level
        m = RE_HEAD.match(line)
        if m:
            flush_para()
            if state["kid"]:
                state["hoff"] += 1         # the Property parents this section
                state["kid"] = 0
            state["colon"] = False
            state["enum1"] = 0
            state["eshift"] = 0
            state["pbase1"] = 0
            table_hdr = None
            hlvl = len(m.group(1)) - 1 - eff_shift + state["hoff"]
            out.append((hlvl, colorize(inline(m.group(2))), False))
            state["base"] = hlvl + 1
            state["last"] = hlvl + 1
            state["colon"] = False      # same: a heading parents on its own
            continue

        # --- tables: header cells become Properties on each row item
        m = RE_TROW.match(line)
        if m:
            flush_para()
            if RE_TSEP.match(line):
                continue
            cells = [c.strip() for c in m.group(1).split("|")]
            if table_hdr is None:
                table_hdr = m.group(1)
                continue
            if not cells:
                continue
            hdr_cells = [c.strip() for c in table_hdr.split("|")]
            props = [(h, c) for h, c in zip(hdr_cells[1:], cells[1:]) if c]
            if props and cells[0].isascii() and cells[0].isdigit():
                # A row that opens with a bare number is a numbered item:
                # the number and its first property share the line,
                # "4. Question: ...", and the rest hang under it.
                h, c = props.pop(0)
                item = f"{cells[0]}. {inline(h)}: {inline(c)}"
            else:
                item = inline(cells[0])
            emit(state["base"], colorize(item), shiftable=True)
            for h, c in props:
                emit(state["base"] + 1, colorize(f"{inline(h)}: {inline(c)}"),
                     shiftable=True)
            continue
        table_hdr = None

        # --- bullets and numbered items keep their own nesting depth
        m = RE_BULL.match(line)
        if m:
            # Markdown nests lists with either 2 or 4 spaces per level.
            # Treat a multiple of 4 as 4-space style so both conventions
            # yield one HyperList level per nesting level.
            lead = len(m.group(1).expandtabs(4))
            depth = lead // 4 if lead and lead % 4 == 0 else lead // 2
            attach_list(depth)
            emit(state["base"] + depth, colorize(conditional(inline(m.group(2)))),
                 shiftable=True)
            continue
        m = RE_NUMB.match(line)
        if m:
            # Markdown nests lists with either 2 or 4 spaces per level.
            # Treat a multiple of 4 as 4-space style so both conventions
            # yield one HyperList level per nesting level.
            lead = len(m.group(1).expandtabs(4))
            depth = lead // 4 if lead and lead % 4 == 0 else lead // 2
            attach_list(depth)
            # A bold wrapper reopens on the rest of the Item.
            rest = ("**" + m.group(4)) if m.group(2) else m.group(4)
            # HyperList numbered items take a period, never a colon
            emit(state["base"] + depth, colorize(f"{m.group(3)}. {inline(rest)}"))
            # The enumerator parents whatever block content follows it.
            state["enum1"] = state["last"]
            state["eshift"] = 0
            continue

        # A line that is entirely bold is a section head: Claude uses these
        # as headings, so it parents everything until the next head. Unlike
        # the enumerator rule this survives blank lines, exactly as a real
        # heading's base does.
        t = line.strip()
        if (len(t) > 4 and t.startswith("**") and t.endswith("**")
                and "*" not in t[2:-2] and t[2:-2].strip()):
            flush_para()
            if state["pbase1"]:
                state["base"] = state["pbase1"] - 1
            state["kid"] = 0
            state["colon"] = False
            state["enum1"] = 0
            state["eshift"] = 0
            table_hdr = None
            emit(state["base"], colorize(inline(t)))
            # The head already parents by raising the base. Its trailing
            # colon must not parent a second time, or the block below it
            # lands two levels under a one-level parent.
            state["colon"] = False
            state["pbase1"] = state["base"] + 1
            state["base"] += 1
            continue

        if set(line.strip()) <= {"-", "=", "_"} and len(line.strip()) > 2:
            continue                                   # horizontal rule

        # Each prose line is its own Item source: Claude writes one idea per
        # line, so joining lines would merge deliberate Items, and the join
        # would depend on where the delta boundaries happen to fall. Only
        # blockquotes still accumulate; a quoted passage is one Item.
        flush_para()
        ws = line[:len(line) - len(line.lstrip())]
        lead = len(ws.expandtabs(4))
        para_ind = lead // 4 if lead and lead % 4 == 0 else lead // 2
        para.append(line.strip())

    flush_para()
    lines_out, prev1, dshift, dorigin = render(out, prev1, dshift, dorigin)
    return ("\n".join(lines_out), state["base"], shift, fence["on"],
            fence["ind"], table_hdr, state["kid"], state["colon"],
            state["quote"], state["last"], state["hoff"], state["enum1"],
            state["eshift"], state["pbase1"], prev1, dshift, dorigin)


def count_invocation():
    d = os.environ.get("XDG_RUNTIME_DIR")
    if not d:
        return
    try:
        with open(os.path.join(d, "hyperlist-hook.count"), "a") as f:
            f.write("1\n")
    except OSError:
        pass


# Presence of this file means "off". Checked before anything else so the
# disabled path is one stat() and an exit. Presence/absence rather than a
# file whose contents must be read and parsed, for the same reason.
OFF_FLAG = os.path.expanduser("~/.claude/hyperlist-display.off")


def main():
    if os.path.exists(OFF_FLAG):
        return
    data = json.load(sys.stdin)
    text = data.get("delta") or ""    # the field is "delta", not "message_text"
    index = data.get("index") or 0
    if index == 0:
        (base, shift, fence, find, hdr, held, kid, colon, quote, last, hoff,
         enum1, eshift, pbase1, prev1, dshift, dorigin) = (
            0, None, 0, 0, None, "", 0, False, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    else:
        (base, shift, fence, find, hdr, held, kid, colon, quote, last,
         hoff, enum1, eshift, pbase1, prev1, dshift,
         dorigin) = load_state()
    count_invocation()
    # A line split across two deltas has to be rejoined before it is measured.
    # Converted apart, each half is under the width, so neither wraps and
    # neither takes a Starter, yet the two land on one terminal row well past
    # it. So hold an unterminated last line back and prepend it to the next
    # delta. The final delta flushes whatever is held, as does a line longer
    # than the buffer, which no real Item reaches.
    text = held + text
    tail = ""
    if not data.get("final") and not text.endswith("\n"):
        cut = text.rfind("\n") + 1          # 0 when the whole chunk is partial
        if len(text) - cut <= TAIL_MAX:     # bound the TAIL, not the chunk
            text, tail = text[:cut], text[cut:]
    if not text.strip():
        # A chunk of nothing but newlines is markdown paragraph spacing. In
        # HyperList the indent carries the structure, so it contributes
        # nothing at all, but it still ENDS A BLOCK: a Property that closed
        # the previous chunk has to become a parent here, or the blank line
        # that separates it from its children is the one chunk that never
        # notices. A fresh message has no heading shift yet; -1 stores that.
        if "\n" in text and not fence:
            kid, colon, quote = (1 if colon else 0), False, 0
            enum1, eshift = 0, 0
        save_state(base, -1 if shift is None else shift,
                   fence, find, hdr, tail, kid, colon, quote, last, hoff,
                   enum1, eshift, pbase1, prev1, dshift, dorigin)
        json.dump({"hookSpecificOutput": {"hookEventName": "MessageDisplay",
                                          "displayContent": ""}}, sys.stdout)
        return
    (converted, base, shift, fence, find, hdr, kid, colon, quote, last,
     hoff, enum1, eshift, pbase1, prev1, dshift, dorigin) = convert(
        text, base, shift, fence, find, hdr, kid, colon, quote, last,
        hoff, enum1, eshift, pbase1, prev1, dshift, dorigin)
    save_state(base, shift, fence, find, hdr, tail, kid, colon, quote, last,
               hoff, enum1, eshift, pbase1, prev1, dshift, dorigin)
    # One newline at each edge, never more: enough to stop chunks running
    # together, but no blank lines. HyperList separates by indent.
    # Only a trailing newline. The held-tail carry means a chunk always ends
    # on a line boundary and emits its own newline, so a leading one from the
    # next chunk lands on top of it and opens a blank line, which HyperList
    # does not use.
    # No Items, no newline: a chunk that is only a blockquote marker or other
    # structure would otherwise contribute a bare newline and open a blank line.
    body = converted + ("\n" if text[-1:] == "\n" and converted else "")
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "MessageDisplay",
                # Deltas are concatenated on screen, so the leading and
                # trailing newlines have to survive or chunks run together.
                "displayContent": body,
            }
        },
        sys.stdout,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(1)      # Claude Code falls back to the original text
