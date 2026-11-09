#!/usr/bin/env python3
"""Build the local-only core, run host protocol tests, or build the physical-device app.

No simulator, emulator, App Store upload or provider-account mutation is performed.
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# Only named CMake target outputs are eligible. File Provider backup copies in
# the build tree must never become additional linker inputs.
CORE_ARCHIVES = (
    'libchiaki.a', 'libnanopb.a', 'libjerasure.a', 'libgf_complete.a',
    'Dependencies/mbedtls/library/libmbedcrypto.a',
    'Dependencies/mbedtls/3rdparty/everest/libeverest.a',
    'Dependencies/mbedtls/3rdparty/p256-m/libp256m.a',
    'Dependencies/opus/libopus.a',
)

def core_archives(build):
    paths = [build / name for name in CORE_ARCHIVES]
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise RuntimeError('Missing CMake target archives: ' + ', '.join(missing))
    return paths

def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs)

def output(*args):
    return subprocess.check_output([str(x) for x in args], cwd=ROOT, text=True).strip()

def source_digest():
    digest = hashlib.sha256()
    paths = [p for base in [ROOT / 'lib', HERE / 'Sources', HERE / 'Native'] for p in base.rglob('*')
             if p.is_file() and p.suffix in ['.c', '.h', '.swift', '.proto', '.metal']]
    paths += [HERE / 'CMakeLists.txt', HERE / 'project.yml', HERE / 'Info.plist', HERE / 'build.py', ROOT / '.gitmodules']
    if (HERE / 'build-reusing-native.py').exists(): paths += [HERE / 'build-reusing-native.py']
    paths += [p for p in (HERE / 'Resources').rglob('*') if p.is_file()]
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes() + b'\0')
    digest.update(output('git', 'submodule', 'status', '--recursive').encode())
    return digest.hexdigest()

def sign_app(app, device):
    """Use an existing valid development profile and matching local identity.

    This deliberately does not create an App ID, register a device, update
    provisioning profiles, or contact App Store Connect.
    """
    if not device:
        raise SystemExit('Device builds require --device UDID for existing-profile eligibility checks.')
    identities = set(re.findall(r'\b[0-9A-F]{40}\b', output('security', 'find-identity', '-v', '-p', 'codesigning')))
    candidates = []
    profiles = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
    for path in profiles.glob('*.mobileprovision'):
        result = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
        if result.returncode: continue
        try: profile = plistlib.loads(result.stdout)
        except Exception: continue
        entitlements = profile.get('Entitlements', {})
        if entitlements.get('application-identifier') != '36V7M6X3D6.*': continue
        if not entitlements.get('get-task-allow') or device not in profile.get('ProvisionedDevices', []): continue
        expires = profile['ExpirationDate'].replace(tzinfo=timezone.utc)
        if expires <= datetime.now(timezone.utc): continue
        matches = identities.intersection(hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', []))
        if matches: candidates.append((expires, path, profile, sorted(matches)[0]))
    if not candidates:
        raise SystemExit('No existing valid wildcard development profile covers this device and a local signing identity.')
    _, path, profile, identity = max(candidates, key=lambda x: x[0])
    (app / 'embedded.mobileprovision').write_bytes(path.read_bytes())
    team = profile['TeamIdentifier'][0]
    bundle_id = 'dev.hunter.visionremoteplay'
    entitlements = {'application-identifier': f'{team}.{bundle_id}',
        'com.apple.developer.team-identifier': team, 'get-task-allow': True,
        'keychain-access-groups': [f'{team}.{bundle_id}']}
    entitlements_path = HERE / 'build/xros/development-entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    # Finder metadata can be attached to build products under Documents. Remove
    # only the two attributes prohibited by codesign, only inside this new app.
    for item in [app, *app.rglob('*')]:
        attributes = output('xattr', item).splitlines()
        for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
            if attribute in attributes: run('xattr', '-d', attribute, item)
    for item in sorted(app.rglob('*.dylib')):
        run('codesign', '--force', '--sign', identity, item)
    for item in sorted((app / 'Frameworks').glob('*.framework')):
        run('codesign', '--force', '--sign', identity, item)
    run('codesign', '--force', '--sign', identity, '--entitlements', entitlements_path, '--generate-entitlement-der', app)
    run('codesign', '--verify', '--strict', '--deep', app)
    print('Signed using existing development profile:', profile.get('Name'))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['host', 'device'])
    parser.add_argument('--jobs', type=int, default=6)
    parser.add_argument('--device', help='Physical Vision Pro UDID; must already be covered by a local development profile')
    args = parser.parse_args()
    python = HERE / '.build-tools/bin/python'
    if not python.exists():
        run(sys.executable, '-m', 'venv', HERE / '.build-tools')
        run(python, '-m', 'pip', 'install', '-r', HERE / 'requirements-build.txt')
    cmake = HERE / '.build-tools/bin/cmake'
    if not cmake.exists():
        run(python, '-m', 'pip', 'install', '-r', HERE / 'requirements-build.txt')
    configuration = 'Debug' if args.mode == 'host' else 'RelWithDebInfo'
    build = HERE / 'build' / ('host' if args.mode == 'host' else 'xros')
    build.mkdir(parents=True, exist_ok=True)
    command = [cmake, '-S', HERE, '-B', build, f'-DCMAKE_BUILD_TYPE={configuration}', f'-DPython3_EXECUTABLE={python}']
    if args.mode == 'device':
        command += ['-DCMAKE_SYSTEM_NAME=visionOS', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                    '-DCMAKE_OSX_DEPLOYMENT_TARGET=2.0', '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
                    '-DCMAKE_OSX_SYSROOT=' + output('xcrun', '--sdk', 'xros', '--show-sdk-path')]
    run(*command)
    run(cmake, '--build', build, '--parallel', args.jobs)
    if args.mode == 'host':
        run(HERE / '.build-tools/bin/ctest', '--test-dir', build, '--output-on-failure')
        run('xcrun', 'swiftc', HERE / 'Sources/AnnexB.swift', HERE / 'Tests/BitstreamTests.swift', '-o', build / 'bitstream-tests')
        run(build / 'bitstream-tests')
        run('xcrun', 'swiftc', HERE / 'Sources/AnnexB.swift', HERE / 'Sources/VideoPipeline.swift',
            HERE / 'Sources/AmbientPalette.swift', HERE / 'Sources/AmbientLighting.swift',
            HERE / 'Tests/AmbientPaletteTests.swift', '-o', build / 'ambient-palette-tests')
        run(build / 'ambient-palette-tests')
        run('xcrun', 'swiftc', HERE / 'Sources/AnnexB.swift', HERE / 'Sources/VideoPipeline.swift',
            HERE / 'Sources/AmbientPalette.swift', HERE / 'Sources/AmbientLighting.swift', HERE / 'Tests/RendererReadbackTests.swift',
            '-o', build / 'renderer-readback-tests')
        run(build / 'renderer-readback-tests', HERE / 'Resources/AmbientProof.h264frames')
        run(sys.executable, HERE / 'Tests/BuildTests.py')
        return
    archives = core_archives(build)
    archive_digests = {str(path.relative_to(build)): hashlib.sha256(path.read_bytes()).hexdigest() for path in archives}
    run('xcrun', '--sdk', 'xros', 'libtool', '-static', '-o', build / 'libChiakiVisionCore.a', *archives)
    # Reuse the public upstream OAuth application constants without duplicating
    # them in another committed source file. User tokens never enter this file.
    upstream = (ROOT / 'gui/include/psnaccountid.h').read_text()
    values = {name: re.search(rf'{source} = "([^"]+)"', upstream).group(1)
              for name, source in [('clientID', 'CLIENT_ID'), ('clientSecret', 'CLIENT_SECRET')]}
    generated = '// Generated from upstream public Remote Play client configuration.\n'
    generated += '// SPDX-License-Identifier: AGPL-3.0-only\nenum PSNEndpoints {\n'
    for key, value in values.items(): generated += f'    static let {key} = {json.dumps(value)}\n'
    generated += '    static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"\n}\n'
    (HERE / 'Sources/GeneratedPSN.swift').write_text(generated)
    run('xcodegen', 'generate', '--spec', HERE / 'project.yml', '--project', HERE)
    sha = output('git', 'rev-parse', 'HEAD')
    fingerprint = source_digest()
    run('xcodebuild', '-project', HERE / 'VisionRemotePlay.xcodeproj', '-scheme', 'VisionRemotePlay',
        '-configuration', 'Debug', '-destination', 'generic/platform=visionOS',
        '-derivedDataPath', HERE / 'DerivedData', 'build',
        'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
        f'PROTOTYPE_SOURCE_SHA={sha}', f'PROTOTYPE_SOURCE_DIGEST={fingerprint}')
    unsigned_app = HERE / 'DerivedData/Build/Products/Debug-xros/VisionRemotePlay.app'
    # Documents can be File Provider managed and acquire Finder metadata while
    # codesign is running. Stage only the built app in a task-owned native cache.
    cache = Path.home() / 'Library/Caches/codex-vision-remote-play/01a1b9d2-1401-7f01-bc65-11542d6eb456'
    cache.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=sha[:12] + '-', dir=cache))
    app = stage / 'VisionRemotePlay.app'
    run('ditto', '--norsrc', '--noextattr', unsigned_app, app)
    executable = app / 'VisionRemotePlay'
    sign_app(app, args.device)
    manifest = {'upstreamBase': '43728af2e639fecb8a7af1cd68c29820a40de973',
        'sourceSHA': sha, 'sourceDigest': fingerprint,
        'trackedChanges': output('git', 'status', '--porcelain', '--untracked-files=all'),
        'submodules': output('git', 'submodule', 'status', '--recursive'),
        'appPath': str(app), 'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'nativeArchives': archive_digests,
        'combinedNativeArchiveSHA256': hashlib.sha256((build / 'libChiakiVisionCore.a').read_bytes()).hexdigest(),
        'xcode': output('xcodebuild', '-version'), 'target': 'physical visionOS arm64', 'distribution': 'local development only'}
    (build / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Built physical-device app:', app)
    print('Source digest:', fingerprint)
    print('Executable digest:', manifest['executableSHA256'])

if __name__ == '__main__':
    main()
