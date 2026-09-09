"""Explicit GET/HEAD routes for the disposable projection reader."""
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import sys
import time
from urllib.parse import parse_qs, unquote, urlsplit

from .reader import ProjectionRoot, TOKEN
from .render import fleet_page, project_page

THEMES = ('dark', 'light', 'c64', 'auto')
ROUTES = (
    (re.compile(r'/\Z'), 'fleet_html'),
    (re.compile(r'/api/fleet\Z'), 'fleet_json'),
    (re.compile(r'/p/(' + TOKEN + r')\Z'), 'project_html'),
    (re.compile(r'/api/project/(' + TOKEN + r')\Z'), 'project_json'),
)


def theme_of(query, cookie):
    values = parse_qs(query, keep_blank_values=True)
    if 'theme' in values:
        choices = values['theme']
        if len(choices) == 1 and choices[0] in THEMES:
            return choices[0], choices[0]
        return 'auto', None
    try:
        parsed = SimpleCookie(cookie or '')
        choice = parsed['aib_theme'].value if 'aib_theme' in parsed else 'auto'
        return (choice if choice in THEMES else 'auto'), None
    except CookieError:
        return 'auto', None


class DashboardServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, root, threshold):
        self.root = ProjectionRoot(root)
        self.threshold = threshold
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = 'ai-bobnet'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, format_string, *args):
        # Do not log agent text, request query strings or client-controlled lines.
        pass

    def respond(self, status, body, content_type='application/json; charset=utf-8', cookie=None):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'")
        self.send_header('X-Content-Type-Options', 'nosniff')
        if status == 405:
            self.send_header('Allow', 'GET, HEAD')
        if cookie is not None:
            self.send_header('Set-Cookie', f'aib_theme={cookie}; Path=/; SameSite=Strict; HttpOnly')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        if getattr(self, 'command', '') != 'HEAD':
            self.wfile.write(body)

    def json_response(self, status, value, cookie=None):
        self.respond(status, json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False), cookie=cookie)

    def send_error(self, code, message=None, explain=None):
        self.json_response(code, {'error': 'invalid_request'})

    def parse_request(self):
        if not super().parse_request():
            return False
        if self.command not in ('GET', 'HEAD'):
            self.json_response(405, {'error': 'method_not_allowed'})
            return False
        return True

    def do_GET(self):
        try:
            url = urlsplit(self.path)
            path = unquote(url.path, encoding='utf-8', errors='strict')
            theme, cookie = theme_of(url.query, self.headers.get('Cookie'))
        except (ValueError, UnicodeError):
            self.json_response(404, {'error': 'unknown', 'reason': 'invalid_path'})
            return
        for pattern, route in ROUTES:
            match = pattern.fullmatch(path)
            if match:
                break
        else:
            self.json_response(404, {'error': 'unknown', 'reason': 'missing_route'}, cookie)
            return
        now = time.time()
        if route.startswith('fleet'):
            value = self.server.root.fleet(now, self.server.threshold)
            if route == 'fleet_json':
                self.json_response(200, value, cookie)
            else:
                self.respond(200, fleet_page(value, theme, self.server.threshold), 'text/html; charset=utf-8', cookie)
            return
        uid = match[1]
        value, reason = self.server.root.read(uid)
        if value is None:
            self.json_response(404, {'error': 'unknown', 'project_uid': uid, 'reason': reason}, cookie)
        elif route == 'project_json':
            self.json_response(200, value, cookie)
        else:
            self.respond(200, project_page(value, now, self.server.threshold, theme), 'text/html; charset=utf-8', cookie)

    do_HEAD = do_GET


def main(address, root, threshold):
    try:
        with DashboardServer(address, root, threshold) as server:
            if address[1] == 0:
                print(f'port={server.server_port}', flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
        return 0
    except (ValueError, OSError) as error:
        print(f'dashboard: {error}', file=sys.stderr)
        return 64
