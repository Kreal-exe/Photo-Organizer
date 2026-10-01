#!/usr/bin/env python3
"""Localization helper.

  localize.py wrap   wraps every Objective-C string literal that contains Cyrillic in POL(…), once
  localize.py keys   prints every POL key found in Sources/, one JSON string per line

The interface is written in Russian in the sources; POL() looks the text up in en.lproj/Localizable.strings
when the app runs in another language. Adjacent literals (@"a" @"b") form one key.
"""
import glob, json, re, sys

SKIP = {"Sources/POLabels.m"}          # its tables are data, translated by hand
CYRILLIC = re.compile("[А-Яа-яЁё]")


def literals(text):
    """Yields (start, end) of each group of adjacent @"…" literals outside comments."""
    i, n, group = 0, len(text), None
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            i = text.find("\n", i); i = n if i < 0 else i
        elif text.startswith("/*", i):
            i = text.find("*/", i) + 2
        elif c == "'":
            i = text.index("'", i + 2) + 1 if text[i + 1] == "\\" else i + 3
        elif c == '"' or text.startswith('@"', i):
            start = i
            i += 2 if c == "@" else 1
            while text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            if c == "@":
                if group and not text[group[1]:start].strip():
                    group = (group[0], i)
                else:
                    if group: yield group
                    group = (start, i)
            continue
        else:
            i += 1
            continue
    if group: yield group


def key_of(source):
    parts = re.findall(r'@"((?:[^"\\]|\\.)*)"', source, re.S)
    raw = "".join(parts)
    return raw.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\').replace('\\e', '\x1b').replace('\\r', '\r')


def main():
    mode = sys.argv[1]
    keys = []
    for path in sorted(glob.glob("Sources/*.m")):
        if path in SKIP: continue
        text = open(path, encoding="utf-8").read()
        out, last = [], 0
        for start, end in literals(text):
            literal = text[start:end]
            if not CYRILLIC.search(literal): continue
            wrapped = text[max(0, start - 4):start] == "POL("
            if mode == "keys":
                if wrapped: keys.append(key_of(literal))
            elif not wrapped:
                out.append(text[last:start] + "POL(" + literal + ")")
                last = end
        if mode == "wrap" and out:
            open(path, "w", encoding="utf-8").write("".join(out) + text[last:])
    if mode == "keys":
        for key in dict.fromkeys(keys): print(json.dumps(key, ensure_ascii=False))


main()
