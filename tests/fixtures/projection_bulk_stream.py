#!/usr/bin/env python3
"""Test-only fixture generator for tests/projection_spec.sh's fold-time budget
pin (docs/CONTRACT-visibility.md SS16: "10,000 records under 2 seconds").

Builds a framed `main.events` stream of N valid, open `attempt.decided`
records directly (bypassing aib_event_commit, whose full-stream rescan per
append is O(n^2) by design -- docs/CONTRACT-execution-binding.md SS8.6 -- and
would make generating a 10,000-record FIXTURE itself take unreasonably long).
The frame/record shape matches lib/aibobnet.sh's `_aib_event_compose_record`
and `aib_event_compose_decided_payload` exactly, including a POSIX-cksum
reimplementation validated against the real `cksum(1)` (see this file's own
`_cksum` and the spec's setup section, which cross-checks one record against
the real binary before trusting the rest).

Usage: projection_bulk_stream.py <out-events-file> <count> <project_uid> <agent_uid>
"""
import sys

_POLY = 0x04C11DB7


def _build_table():
    table = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ _POLY) & 0xFFFFFFFF if (c & 0x80000000) else (c << 1) & 0xFFFFFFFF
        table.append(c)
    return table


_TABLE = _build_table()


def cksum(data: bytes):
    """Reimplements POSIX cksum(1): CRC-32/MPEG-2-family over the bytes plus
    the byte-length appended LSB-first, then bitwise-complemented."""
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _TABLE[((crc >> 24) ^ b) & 0xFF]
    length = len(data)
    n = length
    while n:
        c = n & 0xFF
        n >>= 8
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _TABLE[((crc >> 24) ^ c) & 0xFF]
    crc = (~crc) & 0xFFFFFFFF
    return crc, length


def jstr(s):
    if s is None:
        return "null"
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def main():
    out_path, count_s, project_uid, agent_uid = sys.argv[1:5]
    count = int(count_s)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        for seq in range(1, count + 1):
            event_id = f"{project_uid}-main-{seq}"
            payload = (
                '{"decision":"allow","code":0,"reasons":"",'
                '"provider":{"requested":null,"resolved":null,"source":null,"effective":null},'
                '"model":{"requested":null,"resolved":null,"source":null,"effective":null},'
                '"effort":{"requested":null,"resolved":null,"source":null,"effective":null},'
                '"sandbox":{"requested":null,"effective":null},'
                '"adapter":{"raw":null,"effective_path":null,"source":null},'
                f'"pid":{1000 + (seq % 30000)},'
                '"prompt":{"len":null,"sha256":null},'
                '"label":null,"label_len":null}'
            )
            record = (
                "{"
                f'"event_id":{jstr(event_id)},"event_type":"attempt.decided",'
                '"occurred_at":"2026-09-07T00:00:00+00:00","actor_type":"service",'
                f'"actor_id":"aib-broker","project_uid":{jstr(project_uid)},'
                f'"team_uid":null,"agent_uid":{jstr(agent_uid)},'
                '"session_id":null,"run_id":null,"task_id":null,"gate_id":null,'
                '"grant_id":null,"effect_id":null,'
                f'"attempt_id":{jstr(event_id)},"correlation_id":{jstr(event_id)},'
                f'"causation_id":{jstr(event_id)},"schema_version":2,'
                f'"payload":{payload}'
                "}"
            )
            crc, length = cksum(record.encode("utf-8"))
            f.write(f"{seq} {crc} {length} {record}\n")


if __name__ == "__main__":
    main()
