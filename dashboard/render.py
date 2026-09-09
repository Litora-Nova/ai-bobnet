"""Server-rendered Fleet/Project views; every projected string is HTML data."""
import html
import json
import math
from pathlib import Path

from .reader import instant

CSS = Path(__file__).with_name('style.css').read_text(encoding='utf-8')
COLORS = {'busy': 'amber', 'idle': 'neutral', 'blocked': 'coral', 'done': 'green',
          'unknown': 'neutral', 'ok': 'green', 'corrupt': 'coral', 'absent': 'neutral', 'unreadable': 'neutral'}


def escaped(value):
    if value is None:
        value = 'null'
    elif isinstance(value, bool):
        value = 'true' if value else 'false'
    elif isinstance(value, (list, dict)):
        value = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    return html.escape(str(value), quote=True)


def code(value):
    return f'<code>{escaped(value)}</code>'


def field(key, value):
    return f'<span class="field"><span class="key">{escaped(key)}</span> {code(value)}</span>'


def sub(value):
    return f'<span class="sub">{value}</span>'


def stamp(value):
    return 'unknown' if value is None else f'<time datetime="{escaped(value)}">{escaped(value)}</time>'


def badge(value):
    color = COLORS.get(value, 'neutral')
    return f'<span class="badge {color}">{escaped(value)}</span>'


def freshness(age, stale):
    if age is None:
        return 'unknown'
    if age < 0:
        return f'<span class="quiet">clock ahead by {escaped(-age)} s</span>'
    return f'<span class="quiet">stale since {escaped(age)} s</span>' if stale else f'<span class="quiet">fresh · {escaped(age)} s old</span>'


def page(title, body, theme, uid=None):
    path = '/p/' + uid if uid is not None else '/'
    project_nav = f'<span aria-current="page">Project: {code(uid)}</span>' if uid is not None else ''
    themes = ''.join(f'<a href="{escaped(path)}?theme={name}"' + (' aria-current="true"' if theme == name else '') + f'>{name}</a>' for name in ('dark', 'light', 'c64'))
    body_class = f' class="{theme}"' if theme in ('dark', 'light', 'c64') else ''
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<meta http-equiv="refresh" content="10">'
        f'<title>{escaped(title)} · ai-bobnet</title><style>{CSS}</style></head><body{body_class}>'
        '<header class="topbar"><div class="brand">ai-bobnet <span>Read-only dashboard</span></div>'
        f'<nav aria-label="Main"><a href="/">Fleet</a>{project_nav}</nav><nav class="themes" aria-label="Theme">{themes}</nav></header>'
        f'<main>{body}</main><footer class="page-footer">Projection snapshots · refresh every 10 s · no commands</footer></body></html>')


def table(headers, rows, css_class, label):
    head = ''.join(f'<th scope="col">{escaped(h)}</th>' for h in headers)
    return (f'<div class="table-scroll" role="region" aria-label="{escaped(label)}" tabindex="0">'
            f'<table class="{css_class}"><caption class="sr-only">{escaped(label)}</caption>'
            f'<thead><tr>{head}</tr></thead><tbody>{"".join(rows)}</tbody></table></div>')


def fleet_page(fleet, theme, threshold):
    rows = []
    for p in fleet['projects']:
        uid = p['project_uid']
        name = f'<th scope="row"><a href="/p/{escaped(uid)}">{code(uid)}</a></th>'
        if not p['present']:
            cells = ['unknown' + sub(escaped(p['reason']))] + ['unknown'] * 4
        else:
            states = '<span class="states">' + ''.join(f'<span>{escaped(k)} <b>{escaped(v)}</b></span>' for k, v in p['agents_by_state'].items()) + '</span>'
            capacity = p['capacity']
            live = 'unknown' if capacity['live'] is None else escaped(capacity['live'])
            cells = [freshness(p['age_seconds'], p['stale']) + sub(stamp(p['generated_at'])), badge(p['stream_status']),
                     f'{live} / {escaped(capacity["limit"])}', escaped(p['attention_count']), states]
        rows.append('<tr>' + name + ''.join('<td>' + c + '</td>' for c in cells) + '</tr>')
    count = 'unknown project set' if fleet['files_seen'] is None else f'{fleet["files_seen"]} projection files'
    body = f'<div class="page-title"><h1>Fleet</h1><span class="eyebrow">{escaped(count)}</span></div>'
    body += f'<p class="intro">Observed at {stamp(fleet["observed_at"])}. Freshness uses generated_at; stale beyond {escaped(threshold)} s.</p>'
    if fleet['root_status'] != 'ok':
        body += '<section class="missing"><h2>unknown</h2><p>The projection root is unavailable. No project set can be inferred.</p></section>'
    elif not rows:
        body += '<section class="missing"><h2>unknown</h2><p>No projection files published. This does not imply an empty registry or idle agents.</p></section>'
    else:
        body += table(('project_uid', 'generated_at / age', 'stream.status', 'capacity live / limit', 'attention', 'agents by state'), rows, 'fleet-table', 'Project projection snapshots')
    return page('Fleet', body, theme)


def binding_cell(agent, dimension, stream_status):
    launch = agent['launch']
    if launch is None:
        return '<span class="quiet">' + ('never launched' if stream_status == 'ok' else 'unknown') + '</span>'
    binding = launch[dimension]
    effective = binding['effective']
    decision = agent['attempt']['decision'] if agent['attempt'] else None
    primary = 'denied' if effective is None and decision == 'deny' else 'unknown' if effective is None else effective
    result = field('effective', primary)
    resolved = binding.get('resolved')
    if resolved is not None and resolved != effective:
        result += sub(field('resolved', resolved))
    # Sandbox has no resolved slot: compare its real request with effective.
    compare = binding.get('resolved', effective)
    if binding['requested'] is not None and binding['requested'] != compare:
        result += sub(field('requested', binding['requested']))
    if 'source' in binding:
        result += sub(field('source', binding['source']))
    return result


def attempt_cell(attempt, stream_status):
    if attempt is None:
        return '<span class="quiet">' + ('never launched' if stream_status == 'ok' else 'unknown') + '</span>'
    return (f'<strong class="attempt-id">{code(attempt["id"])}</strong>' +
        sub(field('decision', attempt['decision']) + ' · ' + field('open', attempt['open'])) +
        sub('decided_at ' + stamp(attempt['decided_at'])) +
        sub(field('class', attempt['last']['class']) + ' · ' + field('stage', attempt['last']['stage'])) +
        sub('ended_at ' + stamp(attempt['last']['ended_at'])) + sub('broker-attested attempt'))


def project_page(p, now, threshold, theme):
    uid = p['project_uid']
    elapsed = now - instant(p['generated_at'])
    age = math.floor(elapsed)
    body = '<a class="back" href="/">Back to Fleet</a>'
    body += f'<div class="page-title"><h1>{code(uid)}</h1><span class="eyebrow">Project · schema {escaped(p["schema"])}</span></div>'
    body += ('<div class="snapshot"><span><span class="key">generated_at</span> ' + stamp(p['generated_at']) + '</span>' +
             freshness(age, elapsed > threshold) + '<span>' + field('attested_sources', ', '.join(p['attested_sources'])) + '</span></div>')
    stream, capacity = p['stream'], p['capacity']
    facts = [('status', badge(stream['status'])), ('last_seq', code(stream['last_seq'])), ('anchor.value', code(stream['anchor']['value'])),
             ('anchor.relationship', code(stream['anchor']['relationship'])), ('torn_tail', code(stream['torn_tail'])), ('undecodable_records', code(stream['undecodable_records']))]
    body += '<div class="health"><section class="health-box"><h2>Stream</h2><dl>' + ''.join(f'<div><dt>{escaped(k)}</dt><dd>{v}</dd></div>' for k, v in facts) + '</dl></section>'
    live = 'unknown' if capacity['live'] is None else escaped(capacity['live'])
    body += f'<section class="health-box"><h2>Capacity</h2><p class="capacity-value"><strong>{live} / {escaped(capacity["limit"])}</strong> <span>live / limit</span></p>'
    if capacity['live'] is not None:
        # CSS meter avoids browser-defined colors outside the theme tokens.
        width = 100 if capacity['live'] >= capacity['limit'] else capacity['live'] / capacity['limit'] * 100
        body += f'<div class="capacity-meter" role="meter" aria-label="Capacity live out of limit" aria-valuemin="0" aria-valuemax="{escaped(capacity["limit"])}" aria-valuenow="{escaped(capacity["live"])}"><span style="width:{width:.2f}%"></span></div>'
    body += '<p class="sub">as_of ' + stamp(capacity['as_of']) + '</p></section></div>'
    body += f'<section class="attention"><div class="section-heading"><h2>Attention <span class="count">{len(p["attention"])}</span></h2></div>'
    if p['attention']:
        body += '<ol>'
        for item in p['attention']:
            body += ('<li><div class="attention-top">' + badge(item['kind']) + ' ' + field('agent', item['agent']) +
                     '<span>' + field('attested', item['attested']) + '</span></div><p>' + escaped(item['reason']) + '</p>' + sub('since ' + stamp(item['since'])) + '</li>')
        body += '</ol>'
    else:
        body += '<p class="quiet">No attention items in this snapshot. Absence is not proof that no help is needed.</p>'
    body += '</section><section class="agent-section"><div class="section-heading"><h2>Agents</h2><span>state is agent-asserted; launch and attempt are broker-attested</span></div>'
    body += '<p class="table-hint">effective is the primary value; differences and their source follow below. The table scrolls horizontally on narrower screens.</p>'
    rows = []
    for agent_uid, agent in p['agents'].items():
        launch = agent['launch']
        name = '<th scope="row">' + code(agent_uid) + f'<span class="message">{escaped(agent["message"])}</span>'
        name += sub(field('launch.attested', launch['attested'] if launch else 'unknown'))
        if launch:
            name += sub(field('adapter.source', launch['adapter']['source']))
            if launch['reasons']:
                name += f'<span class="reasons">{field("reasons", launch["reasons"])}</span>'
        name += '</th>'
        state = badge(agent['state']) + sub('since ' + stamp(agent['since'])) + sub(field('stale', agent['stale']) + ' · ' + field('attested', agent['attested']))
        cells = [state] + [binding_cell(agent, dimension, stream['status']) for dimension in ('provider', 'model', 'effort', 'sandbox')] + [attempt_cell(agent['attempt'], stream['status'])]
        rows.append('<tr>' + name + ''.join('<td>' + c + '</td>' for c in cells) + '</tr>')
    body += table(('uid', 'state / since', 'provider', 'model', 'effort', 'sandbox', 'last attempt'), rows, 'agents', 'Agent state and effective launch bindings') if rows else '<p class="quiet">No registered agents in this snapshot.</p>'
    body += '</section><footer class="anomalies"><strong>Anomalies</strong>' + ''.join(field(k, v) for k, v in p['anomalies'].items()) + '</footer>'
    return page(uid, body, theme, uid)
