#!/usr/bin/env python3
"""Keep the App Store version listing in step with TestFlight.

    asc-listing.py attach <marketing-version> <build-number>   # attach a processed build to the listing
    asc-listing.py screenshots                                  # replace the iPhone screenshots from
                                                                #   Tools/release/screenshots/*.png (sorted)

The App Store version with the given version string is created if it does not exist (state
"Prepare for Submission"; nothing is ever submitted to the App Store here). Screenshots are
uploaded as the 6.9-inch iPhone set; PNGs of any iPhone size are scaled to 1320×2868.
Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH in Tools/release/.env and `sips` (macOS).
"""
import hashlib, json, os, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = '6814980297'
API = 'https://api.appstoreconnect.apple.com/v1'
SHOTS = os.path.join(ROOT, 'Tools', 'release', 'screenshots')

env = {}
for line in open(os.path.join(ROOT, 'Tools/release/.env')):
    line = line.strip()
    if line.startswith('export '): line = line[7:]
    if '=' in line and not line.startswith('#'):
        k, v = line.split('=', 1); env[k] = os.path.expandvars(v.strip().strip('"').strip("'"))

def token():
    return subprocess.check_output(['swift', os.path.join(ROOT, 'Tools/release/asc-jwt.swift')],
                                   env={**os.environ, 'ASC_KEY_ID': env['ASC_KEY_ID'], 'ASC_ISSUER_ID': env['ASC_ISSUER_ID'], 'ASC_KEY_PATH': env['ASC_KEY_PATH']}).decode().strip()

def call(method, path, body=None, raw=None, headers=None):
    h = {'Authorization': f'Bearer {token()}'}
    if body is not None: h['Content-Type'] = 'application/json'
    if headers: h.update(headers)
    data = json.dumps(body).encode() if body is not None else raw
    req = urllib.request.Request(path if path.startswith('http') else API + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read()
            return r.status, (json.loads(txt) if txt and r.headers.get('Content-Type', '').startswith('application/json') else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')

def fail(msg): print('error:', msg); sys.exit(1)

def version_id(version):
    st, d = call('GET', f'/apps/{APP}/appStoreVersions?filter[platform]=IOS&filter[versionString]={version}')
    if d.get('data'): return d['data'][0]['id']
    st, r = call('POST', '/appStoreVersions', {'data': {'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': version},
                                                     'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}}}})
    if st >= 400: fail(f'could not create version {version}: {r.get("errors")}')
    print(f'created App Store version {version}')
    return r['data']['id']

def attach(version, build):
    for _ in range(60):
        st, d = call('GET', f'/builds?filter[app]={APP}&filter[version]={build}&filter[preReleaseVersion.version]={version}&limit=1')
        rows = d.get('data', [])
        if rows and rows[0]['attributes']['processingState'] == 'VALID': break
        print('waiting for build to process…', rows[0]['attributes']['processingState'] if rows else 'not seen yet'); time.sleep(60)
    else: fail('build never became VALID')
    vid = version_id(version)
    st, r = call('PATCH', f'/appStoreVersions/{vid}/relationships/build', {'data': {'type': 'builds', 'id': rows[0]['id']}})
    if st >= 400: fail(f'attach failed: {r.get("errors")}')
    print(f'attached {version} ({build}) to the App Store listing')

def screenshots():
    files = sorted(f for f in os.listdir(SHOTS) if f.lower().endswith('.png'))
    if not files: fail(f'no PNGs in {SHOTS}')
    st, d = call('GET', f'/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=1')
    vid = d['data'][0]['id'] if d.get('data') else fail('no App Store version; run attach first')
    st, d = call('GET', f'/appStoreVersions/{vid}/appStoreVersionLocalizations')
    locs = [l for l in d.get('data', []) if l['attributes']['locale'] == 'en-US']
    if locs: lid = locs[0]['id']
    else:
        st, r = call('POST', '/appStoreVersionLocalizations', {'data': {'type': 'appStoreVersionLocalizations', 'attributes': {'locale': 'en-US'},
                                                                        'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}})
        lid = r['data']['id']
    st, d = call('GET', f'/appStoreVersionLocalizations/{lid}/appScreenshotSets')
    sets = [s for s in d.get('data', []) if s['attributes']['screenshotDisplayType'] == 'APP_IPHONE_67']
    if sets: sid = sets[0]['id']
    else:
        st, r = call('POST', '/appScreenshotSets', {'data': {'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': 'APP_IPHONE_67'},
                                                            'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': lid}}}}})
        sid = r['data']['id']
    # Replace: delete what is there, upload the folder in order.
    st, d = call('GET', f'/appScreenshotSets/{sid}/appScreenshots')
    for s in d.get('data', []): call('DELETE', f'/appScreenshots/{s["id"]}')
    tmp = '/tmp/kitty-shots'; os.makedirs(tmp, exist_ok=True)
    ids = []
    for f in files:
        src = os.path.join(SHOTS, f); dst = os.path.join(tmp, f)
        subprocess.run(['sips', '-z', '2868', '1320', src, '--out', dst], check=True, capture_output=True)
        data = open(dst, 'rb').read()
        st, r = call('POST', '/appScreenshots', {'data': {'type': 'appScreenshots', 'attributes': {'fileName': f, 'fileSize': len(data)},
                                                        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': sid}}}}})
        if st >= 400: fail(f'reserve {f}: {r.get("errors")}')
        shot = r['data']
        for op in shot['attributes']['uploadOperations']:
            chunk = data[op['offset']:op['offset'] + op['length']]
            hdrs = {h['name']: h['value'] for h in op['requestHeaders']}
            req = urllib.request.Request(op['url'], method=op['method'], data=chunk, headers=hdrs)
            urllib.request.urlopen(req).read()
        st, r = call('PATCH', f'/appScreenshots/{shot["id"]}', {'data': {'type': 'appScreenshots', 'id': shot['id'],
                                                                         'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
        if st >= 400: fail(f'commit {f}: {r.get("errors")}')
        ids.append(shot['id']); print('uploaded', f)
    call('PATCH', f'/appScreenshotSets/{sid}/relationships/appScreenshots', {'data': [{'type': 'appScreenshots', 'id': i} for i in ids]})
    print(f'{len(ids)} screenshots on the listing')

if __name__ == '__main__':
    cmd = sys.argv[1:] or ['help']
    if cmd[0] == 'attach' and len(cmd) == 3: attach(cmd[1], cmd[2])
    elif cmd[0] == 'screenshots': screenshots()
    else: print(__doc__)
