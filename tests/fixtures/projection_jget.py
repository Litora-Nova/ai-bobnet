#!/usr/bin/env python3
"""Test-only fixture helper for tests/projection_spec.sh.

Extracts one field from a projection JSON file by a small dotted path.
A path segment is one of:
  - a bare key            (dict lookup)
  - a bare integer         (list index)
  - key[field=value]      (first item of list `key` whose `field` stringifies
                            to `value`, e.g. "attention[kind=presumed_dead]")

Never used by anything but that one spec -- see docs/CONTRACT-visibility.md
SS3, the non-consumption clause the spec itself enforces mechanically.

Usage: projection_jget.py <json-file> <dotted-path>
Prints the resolved value, or one of:
  __PARSE_ERROR__   the file is missing or not valid JSON
  __MISSING__       a path segment does not exist / wrong container type
  __NOTFOUND__      a [field=value] filter matched no list item
"""
import json
import re
import sys

_FILTER = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\[([A-Za-z0-9_]+)=([^\]]*)\]$")
_INDEX = re.compile(r"^-?\d+$")


def resolve(cur, path):
    for seg in path.split("."):
        m = _FILTER.match(seg)
        if m:
            key, field, val = m.groups()
            if not isinstance(cur, dict) or key not in cur or not isinstance(cur[key], list):
                return "__MISSING__"
            found = None
            for item in cur[key]:
                if isinstance(item, dict) and str(item.get(field)) == val:
                    found = item
                    break
            if found is None:
                return "__NOTFOUND__"
            cur = found
            continue
        if _INDEX.match(seg):
            if not isinstance(cur, list):
                return "__MISSING__"
            try:
                cur = cur[int(seg)]
            except IndexError:
                return "__MISSING__"
            continue
        if not isinstance(cur, dict) or seg not in cur:
            return "__MISSING__"
        cur = cur[seg]
    return cur


def main():
    if len(sys.argv) != 3:
        print("__USAGE_ERROR__")
        return
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        print("__PARSE_ERROR__")
        return
    v = resolve(d, sys.argv[2])
    if isinstance(v, bool):
        print("true" if v else "false")
    elif v is None:
        print("null")
    elif isinstance(v, (dict, list)):
        print(json.dumps(v, sort_keys=True))
    else:
        print(v)


if __name__ == "__main__":
    main()
