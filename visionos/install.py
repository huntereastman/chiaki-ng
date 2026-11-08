#!/usr/bin/env python3
"""Install only a freshly qualified, signed physical-device prototype."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import build

HERE = Path(__file__).resolve().parent

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--host', help='Initial local PS5 address; never an account ID or pairing secret')
    parser.add_argument('--no-launch', action='store_true', help='Install the qualified app without launching it (for a locked headset)')
    args = parser.parse_args()
    manifest = json.loads((HERE / 'build/xros/build-manifest.json').read_text())
    app = Path(manifest['appPath'])
    current_sha = build.output('git', 'rev-parse', 'HEAD')
    if manifest['sourceSHA'] != current_sha or manifest['sourceDigest'] != build.source_digest():
        raise SystemExit('Source changed after qualification; rebuild before installing.')
    executable = app / 'VisionRemotePlay'
    if hashlib.sha256(executable.read_bytes()).hexdigest() != manifest['executableSHA256']:
        raise SystemExit('The signed executable differs from the qualification receipt.')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('PrototypeSourceSHA') != current_sha or info.get('PrototypeSourceDigest') != manifest['sourceDigest']:
        raise SystemExit('The app does not carry the qualified source identity.')
    build.run('codesign', '--verify', '--strict', '--deep', app)
    build.run('xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device,
              '--json-output', HERE / 'build/xros/device-install.json', app)
    if args.no_launch:
        print('Installed qualified app; launch was not requested.')
        return
    command = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
               '--json-output', HERE / 'build/xros/device-launch.json']
    if args.host: command += ['--environment-variables', json.dumps({'VRP_CONSOLE_HOST': args.host})]
    command += ['dev.hunter.visionremoteplay']
    build.run(*command)

if __name__ == '__main__': main()
