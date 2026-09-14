#!/usr/bin/env python3
"""Check or remove only the new Emblem website. Never touches the app or Gmail.

Requires a user-supplied Cloudflare token scoped to Workers Scripts and Workers
Routes on this account. Default is read-only; --apply explicitly withdraws the
website. Keep OAuth branding links valid before withdrawing a production site.
"""
import argparse
import json
import os
import re
import urllib.request
from pathlib import Path

ACCOUNT = 'ea4c1993858dbf893bd3db78d07def85'
SCRIPT = 'emblem-site'
DOMAINS = {
    'emblem.protoyard.com': 'd515a8a45989b7fc4a011a774985f56b2cb68bc3',
    'mailportrait.protoyard.com': '4c35f1a182d2cad05bc21a0f8936bc6df0373d9d',
}
PREFIX = f'/accounts/{ACCOUNT}/workers'

def rollback(api, apply=False):
    expected = []
    for host, domain_id in DOMAINS.items():
        domains = api('GET', PREFIX + '/domains?hostname=' + host)['result']
        matches = [d for d in domains if d.get('hostname') == host]
        if len(matches) > 1 or any(d.get('service') != SCRIPT or d.get('id') != domain_id for d in matches):
            raise RuntimeError('Domain binding changed; leaving it untouched.')
        expected.extend(matches)
    workers = api('GET', PREFIX + '/scripts')['result']
    present = any(w.get('id') == SCRIPT for w in workers)
    plan = {'hostnames': sorted(d.get('hostname') for d in expected), 'worker_present': present, 'apply': apply}
    if apply:
        for domain in expected:
            api('DELETE', PREFIX + '/domains/' + domain['id'])
        if present: api('DELETE', PREFIX + '/scripts/' + SCRIPT)
        remaining = []
        for host in DOMAINS:
            remaining.extend(api('GET', PREFIX + '/domains?hostname=' + host)['result'])
        scripts = api('GET', PREFIX + '/scripts')['result']
        if any(d.get('hostname') in DOMAINS for d in remaining) or any(s.get('id') == SCRIPT for s in scripts):
            raise RuntimeError('Withdrawal did not complete; inspect Cloudflare state.')
    return plan

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if not token:
        config = Path.home() / 'Library/Preferences/.wrangler/config/default.toml'
        match = re.search(r'^oauth_token\s*=\s*"([^"]+)"', config.read_text() if config.exists() else '', re.M)
        token = match.group(1) if match else None
    if not token: parser.error('Log in with Wrangler or provide CLOUDFLARE_API_TOKEN through the environment.')
    def api(method, path):
        req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path, method=method,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=30) as response: data = json.load(response)
        if not data.get('success'): raise RuntimeError('Cloudflare operation failed: ' + method + ' ' + path)
        return data
    print(json.dumps(rollback(api, args.apply), indent=2))

if __name__ == '__main__': main()
