"""Verified reader frame parser and shared attempt semantics.

The Bash scanner remains the reference. The permanent parity corpus checks its
classification, next sequence and exact intact records against this fast pass.
Undecodable payloads are record anomalies, never frame failures by themselves.
"""
import json
import os
import re
import subprocess
from pathlib import Path
import sys
import zlib


_REVERSE = bytes(int(f'{b:08b}'[::-1], 2) for b in range(256))
_FRAME = re.compile(rb'([0-9]+) ([0-9]+) ([0-9]+) (.*)\Z')


def cksum(data):
    # POSIX polynomial/length suffix, with C-backed CRC and reversed bit order.
    n = len(data)
    suffix = n.to_bytes((n.bit_length() + 7) // 8, 'little')
    crc = zlib.crc32((data + suffix).translate(_REVERSE), 0xffffffff)
    return int(f'{crc:032b}'[::-1], 2)


def frame_event_id(data):
    try:
        # JSON syntax/UTF-8 are not frame health. The common valid-object path
        # is fast; exceptional syntax uses the existing byte-oriented accessor.
        if b'\\u' in data:
            raise ValueError('reference accessor preserves unicode escapes')
        obj = json.loads(data.decode('utf-8', errors='surrogateescape'), object_pairs_hook=unique_pairs)
        ident = obj.get('event_id', '')
        return ident if isinstance(ident, str) else ''
    except (ValueError, AttributeError):
        command = '. "$1"; IFS= read -r -d "" json || :; aib_event_field "$json" event_id'
        return subprocess.check_output(['bash','-c',command,'_',str(Path(__file__).with_name('aibobnet.sh'))],
            input=data, env=dict(os.environ, LC_ALL='C')).rstrip(b'\n').decode('utf-8', errors='surrogateescape')


def scan(path):
    out = dict(status='ok', reason='', highest=0, highest_text='0', next=1,
               torn=False, truncate_at=0, present=True, readable=True)
    records = []
    if not os.path.exists(path):
        out['present'] = False
        return out, records
    try:
        stream = open(path, 'rb')
    except OSError:
        out.update(status='corrupt', readable=False, reason='events stream is not readable')
        return out, records
    previous = offset = 0
    try:
        with stream:
            for raw in stream:
                terminated = raw.endswith(b'\n')
                # Bash read -r silently discards NUL before all frame checks.
                line = (raw[:-1] if terminated else raw).replace(b'\0', b'')
                if not terminated:
                    if line:
                        out['torn'] = True
                    break
                match = _FRAME.fullmatch(line)
                if not match:
                    raise ValueError(f'unparsable framed record near offset {offset}')
                seq_b, crc_b, length_b, data = match.groups()
                seq_s = seq_b.decode('ascii')
                seq = int(seq_s)
                if not data.startswith(b'{'):
                    raise ValueError(f'record body is not a JSON object (seq {seq_s})')
                if len(data) != int(length_b):
                    raise ValueError(f'len mismatch (seq {seq_s})')
                if str(cksum(data)).encode() != crc_b:
                    raise ValueError(f'crc/len mismatch (seq {seq_s})')
                if previous and seq <= previous:
                    raise ValueError(f"non-monotonic seq {seq_s} after {out['highest_text']}")
                if seq != previous + 1:
                    out['status'] = 'degraded'
                previous = out['highest'] = seq
                out['highest_text'] = seq_s
                ident = frame_event_id(data)
                if ident.rsplit('-', 1)[-1] != seq_s:
                    raise ValueError(f'event_id/seq mismatch (seq {seq_s}, event_id {ident})')
                records.append((seq_b, data))
                offset += len(line) + 1
                out['truncate_at'] = offset
    except ValueError as error:
        out.update(status='corrupt', reason=str(error))
        return out, records
    except OSError:
        out.update(status='corrupt', readable=False, reason='events stream is not readable')
        return out, records
    out['next'] = out['highest'] + 1
    return out, records


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


def legacy_record(data):
    # Only undecodable records use this compatibility path. Reuse exactly the
    # scalar accessors of the old CLI rather than inventing a lossy JSON repair.
    script = r''' . "$1"
IFS= read -r -d "" json || :
kind=$(aib_event_field "$json" event_type)
printf '%s\0' "$kind" "$(aib_event_field "$json" attempt_id)"
case "$kind" in
  attempt.decided) keys='decision pid';;
  attempt.ended) keys='exit.class exit.code';;
  *) keys='';;
esac
for key in $keys; do
  printf '%s\0' "$(aib_event_payload_field "$json" "$key")"
done
'''
    raw = subprocess.check_output(['bash', '-c', script, '_', str(Path(__file__).with_name('aibobnet.sh'))], input=data)
    values = [v.decode('utf-8', errors='surrogateescape') for v in raw.split(b'\0')[:-1]]
    kind, ident = values[:2]
    payload = {}
    if kind == 'attempt.decided':
        payload = dict(decision=values[2], pid=values[3])
    elif kind == 'attempt.ended':
        payload = {'exit':{'class':values[2], 'code':values[3]}}
    return dict(event_type=kind, attempt_id=ident, payload=payload)


def fold_records(records, legacy=False):
    attempts = {}
    excluded = set()
    for seq, record, undecodable in records:
        kind = record.get('event_type')
        ident = record.get('attempt_id')
        if undecodable and not legacy:
            if kind == 'attempt.decided':
                excluded.add(ident)
            continue
        payload = record.get('payload', {})
        if kind in ('attempt.decided', 'attempt.ended'):
            if not ident:
                raise ValueError(f'{kind} has no attempt_id')
            if not isinstance(ident, str) or any(c in ident for c in '\n\r\t\0') or not isinstance(payload, dict):
                raise ValueError(f'incomplete attempt record (seq {seq})')
        if kind == 'attempt.decided':
            if ident in attempts:
                raise ValueError(f"duplicate attempt.decided for '{ident}'")
            decision = payload.get('decision')
            pid = scalar(payload.get('pid'))
            if decision not in ('allow', 'deny'):
                raise ValueError(f"attempt '{ident}' has invalid decision '{scalar(decision)}'")
            if not re.fullmatch('[0-9]+', pid):
                raise ValueError(f"attempt '{ident}' has invalid pid '{pid}'")
            if int(pid) <= 0:
                raise ValueError(f"attempt '{ident}' has non-positive pid '{pid}'")
            attempts[ident] = dict(id=ident, agent=record.get('agent_uid'),
                decided_at=record.get('occurred_at'), decision=decision, pid=pid,
                state='open' if decision == 'allow' else 'deny', exit_code='null',
                open=decision == 'allow', last={'class':None, 'stage':None, 'ended_at':None})
        elif kind == 'attempt.ended':
            if not legacy and ident in excluded:
                continue
            attempt = attempts.get(ident)
            if not attempt:
                raise ValueError(f"attempt.ended references unknown attempt '{ident}'")
            if attempt['decision'] != 'allow':
                raise ValueError(f"denied attempt '{ident}' carries an impossible ended record")
            if not attempt['open']:
                raise ValueError(f"duplicate attempt.ended for '{ident}'")
            exit_info = payload.get('exit', {})
            if not isinstance(exit_info, dict):
                raise ValueError('invalid exit object')
            exit_class = exit_info.get('class')
            code = scalar(exit_info.get('code'))
            if exit_class not in ('ok', 'provider-failure', 'timeout', 'io-refused', 'aborted'):
                raise ValueError(f"attempt '{ident}' has invalid exit class '{scalar(exit_class)}'")
            if code and not re.fullmatch('[0-9]+', code):
                raise ValueError(f"attempt '{ident}' has invalid exit code '{code}'")
            if exit_class in ('provider-failure', 'timeout', 'io-refused') and not code:
                raise ValueError(f"attempt '{ident}' exit '{exit_class}' requires a numeric code")
            attempt.update(state=exit_class, exit_code=code or 'null', open=False,
                last={'class':exit_class, 'stage':exit_info.get('stage'), 'ended_at':record.get('occurred_at')})
    for attempt in attempts.values():
        if attempt['open']:
            try:
                os.kill(int(attempt['pid']), 0)
            except (OSError, OverflowError):
                attempt['state'] = 'presumed-dead'
    return list(attempts.values())


def fold(path):
    frame, intact = scan(path)
    out = dict(frame, scan_status=frame['status'], scan_reason=frame['reason'],
               attempts=[], legacy_attempts=[], undecodable_records=[], diagnostic='')
    if frame['status'] == 'corrupt':
        out['diagnostic'] = f"event stream is corrupt ({frame['reason']}) — refusing partial attempt fold"
        return out
    records = []
    try:
        for seq, data in intact:
            try:
                text = data.decode('utf-8')
                undecodable = False
            except UnicodeDecodeError:
                undecodable = True
                out['undecodable_records'].append(int(seq))
            record = legacy_record(data) if undecodable else json.loads(text, object_pairs_hook=unique_pairs)
            records.append((int(seq), record, undecodable))
        # Compute the legacy view first for its established semantic diagnostics.
        out['legacy_attempts'] = fold_records(records, legacy=True)
        out['attempts'] = fold_records(records)
    except (ValueError, TypeError, KeyError, OverflowError) as error:
        out.update(status='corrupt', reason=str(error), diagnostic=str(error), attempts=[], legacy_attempts=[])
    return out


def main():
    if sys.argv[1:] == ['--text']:
        result = json.load(sys.stdin)
        sys.stdout.reconfigure(errors='surrogateescape')
        integrity = 'lost' if result['status'] == 'degraded' else 'ok'
        print(f"stream_status:{result['status']} | integrity:{integrity} | highest_seq:{result['highest_text']} | next_seq:{result['next']} | uncommitted_tail:{int(result['torn'])}")
        for a in result['legacy_attempts']:
            print(f"attempt_id:{a['id']} | state:{a['state']} | decision:{a['decision']} | pid:{a['pid']} | exit_code:{a['exit_code']}")
    else:
        result = fold(*sys.argv[1:])
        print(result['status'], result['highest_text'], result['next'], int(result['torn']), result['scan_status'], result['truncate_at'], sep='\t')
        print(result['diagnostic'])
        print(result['scan_reason'])
        print(json.dumps(result, ensure_ascii=True, separators=(',', ':')))
        for attempt in result['attempts']:
            print(attempt['id'])


if __name__ == '__main__':
    main()
