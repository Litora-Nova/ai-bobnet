"""Read-only framed-stream fold used by aib_attempts_fold, never a writer.

POSIX cksum uses the same polynomial as zlib, with opposite bit order and a
length suffix. Translate byte bit order before the C-backed CRC, then reverse
the result. This avoids a subprocess (or Python byte loop) for every record.
"""
import json
import os
import re
import sys
import zlib

_REVERSE = bytes(int(f'{b:08b}'[::-1], 2) for b in range(256))
_FRAME = re.compile(rb'([0-9]+) ([0-9]+) ([0-9]+) (.*)\Z')


def cksum(data):
    n = len(data)
    suffix = n.to_bytes((n.bit_length() + 7) // 8, 'little')
    crc = zlib.crc32((data + suffix).translate(_REVERSE), 0xffffffff)
    return int(f'{crc:032b}'[::-1], 2)


def scalar(value):
    if value is None:
        return ''
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ValueError('invalid scalar in attempt payload')
    return str(value)


def unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError('duplicate JSON object key')
        out[key] = value
    return out


def fold(path):
    out = dict(status='ok', reason='', highest=0, next=1, torn=False,
               present=True, readable=True, attempts=[])
    attempts = {}
    previous = offset = 0
    try:
        stream = open(path, 'rb')
    except FileNotFoundError:
        out['present'] = False
        return out
    except OSError:
        out.update(status='corrupt', readable=False, reason='events stream is not readable')
        return out
    try:
        with stream:
            for line in stream:
                if not line.endswith(b'\n'):
                    out['torn'] = True
                    break
                match = _FRAME.fullmatch(line[:-1])
                if not match:
                    raise ValueError(f'unparsable framed record near offset {offset}')
                seq_s, crc_s, length_s, data = match.groups()
                seq, length = int(seq_s), int(length_s)
                if not data.startswith(b'{'):
                    raise ValueError(f'record body is not a JSON object (seq {seq})')
                if len(data) != length:
                    raise ValueError(f'len mismatch (seq {seq})')
                if str(cksum(data)).encode() != crc_s:
                    raise ValueError(f'crc/len mismatch (seq {seq})')
                if previous and seq <= previous:
                    raise ValueError(f'non-monotonic seq {seq} after {previous}')
                if seq != previous + 1:
                    out['status'] = 'degraded'
                previous = out['highest'] = seq
                record = json.loads(data, object_pairs_hook=unique_pairs)
                event_id = record.get('event_id', '')
                if not isinstance(event_id, str) or event_id.rsplit('-', 1)[-1].encode() != seq_s:
                    raise ValueError(f'event_id/seq mismatch (seq {seq})')
                kind = record.get('event_type')
                ident = record.get('attempt_id')
                payload = record.get('payload', {})
                if kind in ('attempt.decided', 'attempt.ended'):
                    if not isinstance(ident, str) or not ident or any(c in ident for c in '\n\r\t\0') or not isinstance(payload, dict):
                        raise ValueError(f'incomplete attempt record (seq {seq})')
                if kind == 'attempt.decided':
                    if ident in attempts:
                        raise ValueError('duplicate attempt.decided')
                    decision = payload.get('decision')
                    pid = scalar(payload.get('pid'))
                    if decision not in ('allow', 'deny') or not re.fullmatch('[0-9]+', pid) or int(pid) <= 0:
                        raise ValueError('invalid attempt decision or pid')
                    attempts[ident] = dict(id=ident, agent=record.get('agent_uid'),
                        decided_at=record.get('occurred_at'), decision=decision, pid=pid,
                        state='open' if decision == 'allow' else 'deny', exit_code='null',
                        open=decision == 'allow', last=dict(class_=None, stage=None, ended_at=None))
                elif kind == 'attempt.ended':
                    attempt = attempts.get(ident)
                    if not attempt or attempt['decision'] != 'allow' or not attempt['open']:
                        raise ValueError('unknown, denied or duplicate terminal attempt')
                    exit_info = payload.get('exit', {})
                    if not isinstance(exit_info, dict):
                        raise ValueError('invalid exit object')
                    exit_class = exit_info.get('class')
                    code = scalar(exit_info.get('code'))
                    if exit_class not in ('ok', 'provider-failure', 'timeout', 'io-refused', 'aborted'):
                        raise ValueError('invalid attempt exit class')
                    if code and not re.fullmatch('[0-9]+', code):
                        raise ValueError('invalid attempt exit code')
                    if exit_class in ('provider-failure', 'timeout', 'io-refused') and not code:
                        raise ValueError('attempt exit requires a numeric code')
                    attempt.update(state=exit_class, exit_code=code or 'null', open=False,
                        last=dict(class_=exit_class, stage=exit_info.get('stage'), ended_at=record.get('occurred_at')))
                offset += len(line)
    except (ValueError, TypeError, KeyError, OverflowError) as error:
        out.update(status='corrupt', reason=str(error))
        return out
    except OSError:
        out.update(status='corrupt', readable=False, reason='events stream is not readable')
        return out
    out['next'] = out['highest'] + 1
    for attempt in attempts.values():
        if attempt['open']:
            try:
                os.kill(int(attempt['pid']), 0)
            except (OSError, OverflowError):
                attempt['state'] = 'presumed-dead'
        attempt['last']['class'] = attempt['last'].pop('class_')
    out['attempts'] = list(attempts.values())
    return out


def main():
    if sys.argv[1:] == ['--text']:
        result = json.load(sys.stdin)
        integrity = 'lost' if result['status'] == 'degraded' else 'ok'
        print(f"stream_status:{result['status']} | integrity:{integrity} | highest_seq:{result['highest']} | next_seq:{result['next']} | uncommitted_tail:{int(result['torn'])}")
        for a in result['attempts']:
            print(f"attempt_id:{a['id']} | state:{a['state']} | decision:{a['decision']} | pid:{a['pid']} | exit_code:{a['exit_code']}")
    else:
        result = fold(sys.argv[1])
        print(result['status'], result['highest'], result['next'], int(result['torn']), sep='\t')
        print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
        for attempt in result['attempts']:
            print(attempt['id'])


if __name__ == '__main__':
    main()
