"""Server-rendered Fleet/Project views; every projected string is HTML data."""
import html
import json
import math
from pathlib import Path

from .reader import instant

CSS = Path(__file__).with_name('style.css').read_text(encoding='utf-8')
COLORS = {'busy': 'amber', 'idle': 'neutral', 'blocked': 'coral', 'done': 'green',
          'unknown': 'neutral', 'ok': 'green', 'corrupt': 'coral', 'absent': 'neutral', 'unreadable': 'neutral',
          'READY': 'green', 'WORKING': 'amber', 'WAITING': 'neutral', 'STOPPING': 'amber',
          'ORPHANED': 'coral', 'FAILED': 'coral', 'OFFLINE': 'neutral',
          'healthy': 'green', 'unhealthy': 'coral', 'expiring': 'amber', 'expired': 'coral', 'pending': 'amber'}
SESSION_LABELS = {'READY': 'ready', 'WORKING': 'working', 'WAITING': 'waiting',
                  'STOPPING': 'stopping', 'ORPHANED': 'orphaned',
                  'FAILED': 'failed', 'OFFLINE': 'offline'}
ACCOUNT_LABELS = {'absent': 'login absent', 'ok': 'login ok', 'expiring': 'login expiring',
                  'expired': 'login expired', 'pending': 'login pending'}
OUTCOME_LABELS = {'done': 'done', 'rejected': 'rejected', 'accepted': 'accepted'}


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


def badge(value, label=None):
    color = COLORS.get(value, 'neutral')
    return f'<span class="badge {color}">{escaped(value if label is None else label)}</span>'


def compact_age(seconds):
    if seconds < 90:
        return f'{seconds} s'
    minutes = seconds // 60
    if minutes < 90:
        return f'{minutes} min'
    hours = minutes // 60
    if hours < 48:
        return f'{hours} h {minutes % 60} min'
    return f'{hours // 24} d {hours % 24} h'


def freshness(age, stale):
    if age is None:
        return 'unknown'
    if age < 0:
        return f'<span class="quiet">clock ahead by {escaped(compact_age(-age))}</span>'
    label = escaped(compact_age(age))
    return f'<span class="quiet">stale since {label}</span>' if stale else f'<span class="quiet">fresh · {label} old</span>'


def relative_expiry(value, now):
    seconds = instant(value) - now
    magnitude = math.floor(abs(seconds))
    if magnitude >= 86400:
        amount, unit = magnitude // 86400, 'd'
    elif magnitude >= 3600:
        amount, unit = magnitude // 3600, 'h'
    else:
        amount, unit = magnitude // 60, 'min'
    return f'in {amount} {unit}' if seconds >= 0 else f'expired {amount} {unit} ago'


def supervised_card(agent_uid, supervisor, now, stale):
    if supervisor is False:
        return (f'<article class="sup-card sup-invalid" data-agent="{escaped(agent_uid)}" '
                'data-supervisor="invalid" data-login-state="invalid">'
                f'<h3>{code(agent_uid)}</h3><p>supervisor data invalid</p></article>')
    account = supervisor['account']
    login_state = 'none' if account is None else 'invalid' if account is False else account['state']
    braked = supervisor['brake']['tripped_at'] is not None
    css_class = 'sup-card sup-stale' if stale else 'sup-card'
    attributes = (
        f'class="{css_class}" data-agent="{escaped(agent_uid)}" '
        f'data-session-state="{escaped(supervisor["session_state"])}" '
        f'data-health="{escaped(supervisor["health"])}" '
        f'data-unit-state="{escaped(supervisor["unit_state"])}" '
        f'data-off-duty="{escaped(supervisor["off_duty"])}" '
        f'data-braked="{escaped(braked)}" data-login-state="{escaped(login_state)}"')
    result = f'<article {attributes}><div class="sup-card-heading"><h3>{code(agent_uid)}</h3>'
    result += badge(supervisor['session_state'], SESSION_LABELS[supervisor['session_state']]) + '</div>'
    result += f'<p class="sup-reason">{escaped(supervisor["state_reason"])}</p>'
    result += '<div class="sup-facts">'
    result += '<div><span class="key">health</span> ' + badge(supervisor['health'])
    result += sub('tick age ' + escaped(compact_age(supervisor['tick_age_s'])) if supervisor['tick_age_s'] is not None else 'tick age unknown') + '</div>'
    result += '<div><span class="key">unit</span> ' + code(supervisor['unit_state'])
    result += sub(field('disabled', supervisor['disabled'])) + '</div>'
    result += '<div><span class="key">brake</span> ' + code(supervisor['brake']['consecutive'])
    if braked:
        result += sub('braked since ' + stamp(supervisor['brake']['tripped_at']))
    if supervisor['off_duty']:
        result += sub('off duty')
    result += '</div><div><span class="key">activity</span> ' + field('restarts 24 h', supervisor['restarts_24h'])
    result += sub(field('inbox open', supervisor['inbox_open'])) + '</div></div>'
    result += '<div class="sup-account"><h4>Account</h4>'
    if account is False:
        result += '<p>account data invalid</p>'
    elif account is None:
        result += '<p class="quiet">No account data.</p>'
    else:
        result += '<p>' + badge(account['state'], ACCOUNT_LABELS[account['state']]) + ' <strong>' + escaped(account['label']) + '</strong>'
        if account['id_hint']:
            result += ' <span class="quiet">…' + escaped(account['id_hint']) + '</span>'
        result += '</p>'
        if account['expires_at'] is not None:
            result += '<p>expires <time datetime="' + escaped(account['expires_at']) + '">' + escaped(account['expires_at'][:10]) + '</time>'
            result += ' <span class="quiet">' + escaped(relative_expiry(account['expires_at'], now)) + '</span></p>'
        if account['checked_at'] is not None:
            result += '<p class="sub">checked ' + stamp(account['checked_at']) + '</p>'
    result += '</div><div class="sup-session"><h4>Session</h4>'
    if supervisor['current_turn'] is None:
        result += '<p class="quiet">No current turn.</p>'
    else:
        turn = supervisor['current_turn']
        result += '<p>' + field('current turn', turn['msg_id']) + sub(field('attempt', turn['attempt_id'])) + '</p>'
    session = '—' if supervisor['session_id_short'] is None else supervisor['session_id_short']
    result += '<p>' + field('session', session) + sub(field('turns', supervisor['turns_in_session'])) + '</p></div>'
    result += '<div class="sup-controls"><h4>Last control</h4>'
    if supervisor['last_control']:
        result += '<ol>'
        for control in supervisor['last_control']:
            outcome = OUTCOME_LABELS[control['outcome']]
            reason = ' (' + escaped(control['reason']) + ')' if control['reason'] else ''
            result += ('<li>' + stamp(control['at']) + ' · ' + escaped(control['verb']) +
                       ' · ' + escaped(outcome) + reason + '</li>')
        result += '</ol>'
    else:
        result += '<p class="quiet">No control outcomes.</p>'
    return result + '</div></article>'


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
        supervised = (f'<td class="sup-counts" data-supervised="{escaped(p["supervised_count"])}" '
                      f'data-braked="{escaped(p["braked_count"])}" '
                      f'data-login-attention="{escaped(p["login_attention_count"])}">'
                      f'{escaped(p["supervised_count"])} supervised' +
                      sub(escaped(p['braked_count']) + ' braked · ' +
                          escaped(p['login_attention_count']) + ' login attention') + '</td>')
        rows.append('<tr>' + name + ''.join('<td>' + c + '</td>' for c in cells) + supervised + '</tr>')
    count = 'unknown project set' if fleet['files_seen'] is None else f'{fleet["files_seen"]} projection files'
    body = f'<div class="page-title"><h1>Fleet</h1><span class="eyebrow">{escaped(count)}</span></div>'
    body += f'<p class="intro">Observed at {stamp(fleet["observed_at"])}. Freshness uses generated_at; stale beyond {escaped(threshold)} s.</p>'
    if fleet['root_status'] != 'ok':
        body += '<section class="missing"><h2>unknown</h2><p>The projection root is unavailable. No project set can be inferred.</p></section>'
    elif not rows:
        body += '<section class="missing"><h2>unknown</h2><p>No projection files published. This does not imply an empty registry or idle agents.</p></section>'
    else:
        body += table(('project_uid', 'generated_at / age', 'stream.status', 'capacity live / limit', 'attention', 'agents by state', 'supervision'), rows, 'fleet-table', 'Project projection snapshots')
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
    stale = elapsed > threshold
    body = '<a class="back" href="/">Back to Fleet</a>'
    body += f'<div class="page-title"><h1>{code(uid)}</h1><span class="eyebrow">Project · schema {escaped(p["schema"])}</span></div>'
    body += ('<div class="snapshot"><span><span class="key">generated_at</span> ' + stamp(p['generated_at']) + '</span>' +
             freshness(age, stale) + '<span>' + field('attested_sources', ', '.join(p['attested_sources'])) + '</span></div>')
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
    body += '</section>'
    supervised = [(agent_uid, agent.get('supervisor')) for agent_uid, agent in p['agents'].items()
                  if agent.get('supervisor') is not None]
    if supervised:
        body += '<section class="supervised-section"><div class="section-heading"><h2>Agents (supervised)</h2>'
        body += '<span>supervisor, account and control status from the read-only projection</span></div><div class="sup-grid">'
        body += ''.join(supervised_card(agent_uid, supervisor, now, stale)
                        for agent_uid, supervisor in supervised)
        body += '</div></section>'
    body += '<section class="agent-section"><div class="section-heading"><h2>Agents</h2><span>state is agent-asserted; launch and attempt are broker-attested</span></div>'
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
