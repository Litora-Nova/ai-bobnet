"""Projection-file boundary. No engine state or policy resolution lives here."""
import datetime as dt
import json
import math
import os
import re
import stat

TOKEN = r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?'
UID = re.compile(TOKEN + r'\Z')
FILE = re.compile('(' + TOKEN + r')\.json\Z')
STATES = ('busy', 'idle', 'blocked', 'done', 'unknown')


def instant(value):
    if not isinstance(value, str):
        raise ValueError('missing timestamp')
    stamp = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if stamp.utcoffset() is None:
        raise ValueError('timestamp without offset')
    return stamp.timestamp()


def is_instant(value):
    try:
        return math.isfinite(instant(value))
    except (ValueError, OverflowError):
        return False


def nullable(check):
    return lambda value: value is None or check(value)


def text(value):
    return isinstance(value, str)


def count(value):
    return type(value) is int and value >= 0


def fields(value, shape):
    return isinstance(value, dict) and all(key in value and check(value[key]) for key, check in shape.items())


def binding(value):
    return fields(value, {key: nullable(text) for key in ('requested', 'resolved', 'effective', 'source')})


def launch(value):
    return fields(value, dict(provider=binding, model=binding, effort=binding,
        sandbox=lambda v: fields(v, dict(requested=nullable(text), effective=nullable(text))),
        adapter=lambda v: fields(v, dict(source=nullable(text))), reasons=text, attested=lambda v: v is True))


def attempt(value):
    return fields(value, dict(id=text, decided_at=is_instant, decision=lambda v: v in ('allow', 'deny'),
        open=lambda v: type(v) is bool,
        last=lambda v: fields(v, {'class': nullable(text), 'stage': nullable(text), 'ended_at': nullable(is_instant)})))


def agent(value):
    return fields(value, dict(state=lambda v: v in STATES, since=nullable(is_instant), message=text,
        stale=lambda v: type(v) is bool, attested=lambda v: v is False,
        attempt=nullable(attempt), launch=nullable(launch)))


def projection(value, uid):
    return fields(value, dict(
        schema=lambda v: type(v) is int and v >= 2,
        generated_at=is_instant, project_uid=lambda v: v == uid,
        attested_sources=lambda v: isinstance(v, list) and all(text(item) for item in v),
        stream=lambda v: fields(v, dict(status=lambda s: s in ('ok', 'corrupt', 'absent', 'unreadable'),
            last_seq=count, anchor=lambda a: fields(a, dict(value=nullable(count), relationship=lambda r: r in ('ok', 'lag', 'ahead', 'absent'))),
            torn_tail=lambda t: type(t) is bool, undecodable_records=lambda a: isinstance(a, list) and all(count(i) for i in a))),
        capacity=lambda v: fields(v, dict(limit=lambda n: count(n) and n > 0, live=nullable(count), as_of=nullable(is_instant))),
        attention=lambda v: isinstance(v, list) and all(fields(item, dict(kind=text, agent=nullable(text), reason=text, since=is_instant, attested=lambda b: type(b) is bool)) for item in v),
        agents=lambda v: isinstance(v, dict) and all(agent(a) for a in v.values()),
        anomalies=lambda v: fields(v, {key: count for key in ('unregistered_logs', 'unparsable_lines', 'uid_mismatches', 'undecodable_records', 'launch_malformed')})))


def unique_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate key')
        value[key] = item
    return value


def reject_constant(value):
    raise ValueError('nonfinite JSON number')


class ProjectionRoot:
    def __init__(self, path):
        self.path = path

    def open_root(self):
        return os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    @staticmethod
    def read_at(root_fd, uid):
        if not UID.fullmatch(uid):
            return None, 'invalid_uid'
        try:
            fd = os.open(uid + '.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
            with os.fdopen(fd, 'rb') as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    return None, 'unreadable'
                raw = stream.read()
        except FileNotFoundError:
            return None, 'missing'
        except OSError:
            return None, 'unreadable'
        try:
            value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_keys, parse_constant=reject_constant)
            # JSON escapes can introduce lone surrogates, invalid as UTF-8 HTML.
            json.dumps(value, ensure_ascii=False, allow_nan=False).encode('utf-8')
            if not projection(value, uid):
                return None, 'schema'
            return value, None
        except (ValueError, TypeError, RecursionError, OverflowError):
            return None, 'unparsable'

    def read(self, uid):
        if not UID.fullmatch(uid):
            return None, 'invalid_uid'
        try:
            fd = self.open_root()
        except OSError:
            return None, 'root_unavailable'
        try:
            return self.read_at(fd, uid)
        finally:
            os.close(fd)

    def fleet(self, now, threshold):
        result = dict(observed_at=dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(timespec='seconds'),
                      root_status='unknown', files_seen=None, projects=[])
        try:
            fd = self.open_root()
        except OSError:
            return result
        try:
            names = []
            with os.scandir(fd) as entries:
                for entry in entries:
                    match = FILE.fullmatch(entry.name)
                    if match and entry.is_file(follow_symlinks=False):
                        names.append(match[1])
            for uid in sorted(names):
                value, reason = self.read_at(fd, uid)
                row = dict(project_uid=uid, present=value is not None, reason=reason,
                           generated_at=None, age_seconds=None, stale=None, stream_status=None,
                           capacity=None, attention_count=None, agents_by_state=None)
                if value is not None:
                    elapsed = now - instant(value['generated_at'])
                    age = math.floor(elapsed)
                    row.update(generated_at=value['generated_at'], age_seconds=age, stale=elapsed > threshold,
                        stream_status=value['stream']['status'], capacity=value['capacity'], attention_count=len(value['attention']),
                        agents_by_state={state: sum(a['state'] == state for a in value['agents'].values()) for state in STATES})
                result['projects'].append(row)
            result.update(root_status='ok', files_seen=len(names))
        except OSError:
            # The enumeration was incomplete: do not label the partial set empty.
            result['projects'] = []
        finally:
            os.close(fd)
        return result
