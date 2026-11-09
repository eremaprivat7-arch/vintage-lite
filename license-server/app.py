import hashlib
import hmac
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from uuid import UUID

from flask import Flask, abort, jsonify, render_template, request

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 4096
admin_password = os.environ['ADMIN_PASSWORD']
if len(admin_password) < 20:
    raise RuntimeError('ADMIN_PASSWORD must contain at least 20 characters')
csrf = hmac.digest(admin_password.encode(), b'vintage-admin-form', 'sha256').hex()
database = os.environ.get('LICENSE_DB', 'licenses.sqlite3')
schema = """
CREATE TABLE IF NOT EXISTS licenses (
 id INTEGER PRIMARY KEY, digest TEXT UNIQUE NOT NULL, label TEXT NOT NULL,
 seats INTEGER NOT NULL, lifetime INTEGER NOT NULL, expires INTEGER, revoked INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS devices (
 license INTEGER NOT NULL REFERENCES licenses(id) ON DELETE CASCADE, device TEXT NOT NULL,
 blocked INTEGER DEFAULT 0, PRIMARY KEY(license,device)
);
"""
with sqlite3.connect(database) as initial:
    initial.executescript(schema)


@contextmanager
def connect(write=False):
    db = sqlite3.connect(database, timeout=10)
    db.row_factory = sqlite3.Row
    try:
        db.execute('PRAGMA foreign_keys=ON')
        if write:
            db.execute('BEGIN IMMEDIATE')
        yield db
        db.commit()
    finally:
        db.close()


@app.before_request
def authorize_admin():
    if request.path.startswith('/admin'):
        auth = request.authorization
        if not auth or auth.username != 'admin' or not hmac.compare_digest(
            (auth.password or '').encode(), admin_password.encode()
        ):
            return '', 401, {'WWW-Authenticate': 'Basic realm="Vintage Lite"'}
        if request.method == 'POST' and not hmac.compare_digest(request.form.get('csrf', '').encode(), csrf.encode()):
            abort(403)


@app.after_request
def no_cache(response):
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Referrer-Policy'] = 'no-referrer'
    return response


def dashboard(new_key=None):
    with connect() as db:
        rows = db.execute('SELECT * FROM licenses ORDER BY id DESC').fetchall()
        devices = db.execute('SELECT * FROM devices ORDER BY license,device').fetchall()
    return render_template('admin.html', rows=rows, devices=devices, csrf=csrf, new_key=new_key,
                           now=int(time.time()), utc=lambda t: datetime.fromtimestamp(t, timezone.utc).strftime('%d.%m.%Y %H:%M UTC'))


@app.get('/admin')
def admin():
    return dashboard()


@app.post('/admin/create')
def create():
    seats = request.form.get('seats', type=int)
    duration = request.form.get('duration', type=int)
    unit = request.form.get('unit')
    if seats is None or not 1 <= seats <= 100000 or duration is None or not 1 <= duration <= 36500 or unit not in ('hours', 'days'):
        abort(400)
    until = request.form.get('until', '')
    expiry = None
    if until:
        try:
            expiry = int(datetime.strptime(until, '%Y-%m-%dT%H:%M').replace(tzinfo=timezone.utc).timestamp())
        except ValueError:
            abort(400)
        if expiry <= time.time():
            abort(400)
    key = 'VL-' + secrets.token_hex(16).upper()
    with connect(True) as db:
        db.execute('INSERT INTO licenses(digest,label,seats,lifetime,expires) VALUES(?,?,?,?,?)',
                   (hashlib.sha256(key.encode()).hexdigest(), key[-8:], seats, duration * (3600 if unit == 'hours' else 86400), expiry))
    return dashboard(key)


@app.post('/admin/<int:license_id>/<action>')
def manage(license_id, action):
    from flask import redirect
    with connect(True) as db:
        if action == 'delete':
            db.execute('DELETE FROM licenses WHERE id=?', (license_id,))
        elif action == 'revoke':
            db.execute('UPDATE licenses SET revoked=1 WHERE id=?', (license_id,))
        elif action == 'block':
            db.execute('UPDATE devices SET blocked=1 WHERE license=? AND device=?', (license_id, request.form.get('device')))
        else:
            abort(404)
    return redirect('/admin', 303)


@app.post('/api/check')
def check():
    body = request.get_json(silent=True)
    if not isinstance(body, dict) or not isinstance(body.get('key'), str):
        abort(400)
    try:
        device = str(UUID(body['device']))
    except (KeyError, TypeError, ValueError, AttributeError):
        abort(400)
    digest = hashlib.sha256(body['key'].strip().upper().encode()).hexdigest()
    with connect(True) as db:
        now = int(time.time())
        key = db.execute('SELECT * FROM licenses WHERE digest=?', (digest,)).fetchone()
        if not key or key['revoked']:
            return jsonify(error='invalid'), 403
        expiry = key['expires']
        if expiry is not None and now >= expiry:
            return jsonify(error='expired'), 403
        lid = key['id']
        slot = db.execute('SELECT blocked FROM devices WHERE license=? AND device=?', (lid, device)).fetchone()
        if slot and slot['blocked']:
            return jsonify(error='blocked'), 403
        if not slot:
            used = db.execute('SELECT COUNT(*) FROM devices WHERE license=? AND blocked=0', (lid,)).fetchone()[0]
            if used >= key['seats']:
                return jsonify(error='full'), 403
            db.execute('INSERT INTO devices(license,device) VALUES(?,?)', (lid, device))
        if expiry is None:
            expiry = now + key['lifetime']
            db.execute('UPDATE licenses SET expires=? WHERE id=?', (expiry, lid))
        return jsonify(valid=True, remaining=expiry-now)
