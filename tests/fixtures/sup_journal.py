#!/usr/bin/env python3
"""Test-only helper for the supervisor specs: reads the supervisor journal (JSON Lines).

  sup_journal.py count   <file> <event>             number of records whose "event" == <event>
  sup_journal.py field   <file> <event> <n> <key>   <key> of the <n>th (1-based; -1 = last) such record
  sup_journal.py valid   <file>                     "ok" iff every line is a JSON object with an integer "seq"
                                                    and seq is exactly 1,2,3,... (strictly +1, no gap, no repeat)
  sup_journal.py lastseq <file>                     highest seq (0 for a missing/empty file)
  sup_journal.py first   <file> <event> <key> <val> line number (1-based) of the first record of <event>
                                                    whose <key> == <val>; empty when none
Prints "__MISSING__" when a record or key does not exist.
"""
import json
import sys


def load(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if raw:
                    out.append(json.loads(raw))
    except FileNotFoundError:
        pass
    return out


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    try:
        recs = load(path)
    except Exception:
        print("__PARSE_ERROR__")
        return
    if cmd == "count":
        print(sum(1 for r in recs if r.get("event") == sys.argv[3]))
    elif cmd == "field":
        hits = [r for r in recs if r.get("event") == sys.argv[3]]
        n = int(sys.argv[4])
        try:
            rec = hits[n - 1] if n > 0 else hits[n]
            v = rec[sys.argv[5]] if sys.argv[5] in rec else "__MISSING__"
            print(json.dumps(v) if isinstance(v, (bool, type(None), dict, list)) else v)
        except IndexError:
            print("__MISSING__")
    elif cmd == "valid":
        seqs = [r.get("seq") for r in recs]
        good = len(recs) > 0 and all(isinstance(r, dict) for r in recs) and all(isinstance(s, int) and not isinstance(s, bool) for s in seqs) \
            and seqs == list(range(1, len(seqs) + 1))
        print("ok" if good else "bad")
    elif cmd == "lastseq":
        print(max([r.get("seq", 0) for r in recs] or [0]))
    elif cmd == "first":
        for i, r in enumerate(recs, 1):
            if r.get("event") == sys.argv[3] and str(r.get(sys.argv[4])) == sys.argv[5]:
                print(i)
                return
        print("")


if __name__ == "__main__":
    main()
