#!/usr/bin/env python3
"""Convert whisper SRT output to readable Chinese text following 中文写作规范:
- Pangu spacing: a space between CJK and adjacent ASCII letters/digits.
- Sensible paragraph and sentence breaks (instead of one period per whisper cue).
- 「」 quotes around emphasized terms (X 这两个字 / 叫做 X / 所谓的 X / ...).
- 「？」 for clauses ending in 吗 / 呢.
"""
import re
import sys


# Topic-shift markers that start a new paragraph.
# Longer / more specific prefixes listed first so they win the prefix match.
PARA_STARTERS = [
    '那我们就直接进入',
    '那我们就来',
    '那接下来呢',
    '那接下来',
    '那讲到这里',
    '那为什么',
    '那说到这',
    '那如果',
    '那好',
    '那么我们',
    '接下来呢',
    '接下来',
    '然后我们',
    '我们再来',
    '我们就来',
    '我们这里',
    '我们可以来看',
    '我们来简单回顾',
    '我们来看',
    '总而言之',
    '总的来说',
    '所以啊',
    '最后也是',
    '最后我会',
    '最后',
    '首先',
    '其次',
    '第一个',
    '第二个',
    '第三个',
    '好了',
    '好的',
    '好,',
    '好，',
    '好。',
    'OK',
    'Ok',
    '说到这里',
    '讲到这里',
    '到这里',
    '听到这里',
    '这就引出',
    '比如说前段时间',
    '接着我们',
    '接着',
    '下面',
    '下一',
]

# Soft sentence-break markers within a paragraph (end previous clause with 。).
SENT_STARTERS = [
    '比如说',
    '比方说',
    '举个例子',
    '举例',
    '一个是',
    '另一个是',
    '另外',
    '换言之',
    '换句话说',
    '不管你是',
    '不管是',
    '相反',
    '其实你想',
    '其实你应该',
    '其实并不是',
    '我们可以打个比方',
    '我们打个比方',
]


# CJK Unified Ideographs (Basic), U+4E00..U+9FFF — the standard "any Chinese
# char" range. Spelled as \uXXXX escapes rather than the literal range so the
# source is readable (the literal upper bound, U+9FFF, renders as an obscure
# glyph that confuses readers).
CJK = r'\u4e00-\u9fff'

# Particles and prepositions that should never be the FIRST char of a quoted
# term — otherwise the regex grabs context (在独立 → 「在独立」) instead of the
# real term (独立). Used as a negative lookahead at the term head.
NOT_TERM_HEAD = '的是在了着过啊呢吗吧也就都还不又把跟和与这那让叫使被对从给到去往上下里外中'

# Quote certain emphasized terms with 「」 — applied as a final post-process pass.
QUOTE_PATTERNS = [
    (re.compile(rf'((?![{NOT_TERM_HEAD}])[{CJK}]{{1,3}})(这两个字)'), r'「\1」\2'),
    (re.compile(rf'((?![{NOT_TERM_HEAD}])[{CJK}]{{1,3}})(这两个词)'), r'「\1」\2'),
    (re.compile(rf'((?![{NOT_TERM_HEAD}])[{CJK}]{{1,4}})(这个词)'), r'「\1」\2'),
    (re.compile(rf'(所谓的)([{CJK}]{{2,4}})'), r'\1「\2」'),
    (re.compile(rf'(叫做)([A-Z][A-Za-z0-9 ]*?)(?=[{CJK}，。、；])'), r'\1「\2」'),
    (re.compile(rf'(叫)([A-Z][A-Za-z0-9 ]{{1,20}}?)(?=[{CJK}，。、；])'), r'\1「\2」'),
    (re.compile(rf'(名叫)([{CJK}A-Za-z]{{2,8}})'), r'\1「\2」'),
]


# Tiny tail paragraphs (transitions like 好了 / OK and orphaned short sentences)
# are merged into the previous paragraph instead of standing alone.
MIN_PARA_CHARS = 16


TIMESTAMP_RE = re.compile(r'^\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->')

# Soft cap for one running sentence — break at next opportunity once this is hit.
MAX_SENT_CHARS = 70
# Soft cap for one paragraph.
MAX_PARA_CHARS = 240


def parse_srt(path):
    segments = []
    with open(path) as f:
        raw = f.read().strip()
    for block in re.split(r'\n\s*\n', raw):
        lines = [ln.rstrip() for ln in block.splitlines() if ln.strip()]
        text_lines = [ln for ln in lines
                      if not ln.strip().isdigit() and not TIMESTAMP_RE.match(ln)]
        text = ' '.join(text_lines).strip()
        if text:
            segments.append(text)
    return segments


def starts_with_any(text, options):
    return any(text.startswith(p) for p in options)


def is_question(last_clause):
    tail = last_clause.rstrip('?？!！。.,，')
    return tail.endswith(('吗', '呢'))


def apply_quotes(text):
    for pattern, repl in QUOTE_PATTERNS:
        text = pattern.sub(repl, text)
    return text


def normalize_punct(text):
    """Convert half-width punctuation surrounded by CJK to full-width."""
    text = re.sub(r'([\u4e00-\u9fff])\s*,\s*(?=[\u4e00-\u9fff])', r'\1，', text)
    text = re.sub(r'([\u4e00-\u9fff])\s*\.\s*(?=[\u4e00-\u9fff])', r'\1。', text)
    text = re.sub(r'([\u4e00-\u9fff])\s*\?\s*', r'\1？', text)
    text = re.sub(r'([\u4e00-\u9fff])\s*!\s*', r'\1！', text)
    return text


def apply_pangu(text):
    """Add a space between CJK and adjacent ASCII alphanumeric — the Pangu rule."""
    text = re.sub(r'([\u4e00-\u9fff])([A-Za-z0-9])', r'\1 \2', text)
    text = re.sub(r'([A-Za-z0-9])([\u4e00-\u9fff])', r'\1 \2', text)
    return text


def to_readable(segments):
    if not segments:
        return ''

    paragraphs = []
    sentences = []
    clauses = []

    def total_len(items):
        return sum(len(x) for x in items)

    def end_sentence():
        nonlocal clauses
        if not clauses:
            return
        body = '，'.join(c for c in clauses if c)
        body += '？' if is_question(clauses[-1]) else '。'
        sentences.append(body)
        clauses = []

    def end_paragraph():
        nonlocal sentences
        end_sentence()
        if not sentences:
            return
        para = ''.join(sentences)
        if paragraphs and len(para) < MIN_PARA_CHARS:
            paragraphs[-1] += para
        else:
            paragraphs.append(para)
        sentences = []

    for seg in segments:
        seg = seg.strip().rstrip('。，.,!?？！')
        if not seg:
            continue

        if starts_with_any(seg, PARA_STARTERS):
            end_paragraph()
            clauses = [seg]
        elif starts_with_any(seg, SENT_STARTERS) and clauses:
            end_sentence()
            clauses = [seg]
        else:
            clauses.append(seg)

        if total_len(clauses) >= MAX_SENT_CHARS:
            end_sentence()
        if total_len(sentences) + total_len(clauses) >= MAX_PARA_CHARS:
            end_paragraph()

    end_paragraph()

    text = '\n\n'.join(paragraphs)
    text = normalize_punct(text)
    text = apply_quotes(text)
    text = apply_pangu(text)
    return text


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <input.srt> [output.txt]')
        sys.exit(1)

    srt_path = sys.argv[1]
    segments = parse_srt(srt_path)
    text = to_readable(segments)

    if len(sys.argv) >= 3:
        with open(sys.argv[2], 'w') as f:
            f.write(text + '\n')
        print(f'Saved to {sys.argv[2]}')
    else:
        print(text)
