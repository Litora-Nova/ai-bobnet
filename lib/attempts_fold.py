"""Attempt semantics over records already accepted by aib_event_scan.

There is no frame, checksum or sequence validator here. Undecodable UTF-8
records are anomalies for projection; the legacy text view retains the byte-
transparent scanner/awk behavior for scalar fields in those records.
"""
import json
import os
import re
import sys


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


def fold(path, status, highest, next_seq, torn, reason, present, readable):
    out = dict(status=status, reason=reason, highest=int(highest), next=int(next_seq),
               torn=bool(int(torn)), present=bool(int(present)), readable=bool(int(readable)),
               attempts=[], legacy_attempts=[], undecodable_records=[], diagnostic='')
    if status == 'corrupt':
        out['diagnostic'] = f'event stream is corrupt ({reason}) — refusing partial attempt fold'
        return out
    records = []
    try:
        with open(path, 'rb') as stream:
            for line in stream:
                seq, data = line.rstrip(b'\n').split(b'\t', 1)
                try:
                    text = data.decode('utf-8')
                    undecodable = False
                except UnicodeDecodeError:
                    text = data.decode('utf-8', errors='surrogateescape')
                    undecodable = True
                    out['undecodable_records'].append(int(seq))
                record = json.loads(text, object_pairs_hook=unique_pairs)
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
        print(f"stream_status:{result['status']} | integrity:{integrity} | highest_seq:{result['highest']} | next_seq:{result['next']} | uncommitted_tail:{int(result['torn'])}")
        for a in result['legacy_attempts']:
            print(f"attempt_id:{a['id']} | state:{a['state']} | decision:{a['decision']} | pid:{a['pid']} | exit_code:{a['exit_code']}")
    else:
        result = fold(*sys.argv[1:])
        print(result['status'], result['diagnostic'], sep='\t')
        print(json.dumps(result, ensure_ascii=True, separators=(',', ':')))
        for attempt in result['attempts']:
            print(attempt['id'])


if __name__ == '__main__':
    main()
