#!/usr/bin/env python3
"""Build a local device candidate from unchanged, digest-verified native archives."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import build

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--device', required=True)
args = parser.parse_args()
baseline = json.loads(args.baseline.read_text())
native_paths = ['lib', 'visionos/Native', 'visionos/CMakeLists.txt', '.gitmodules',
                'third-party/nanopb', 'third-party/jerasure', 'third-party/gf-complete',
                'visionos/Dependencies/mbedtls', 'visionos/Dependencies/opus']
build.run('git', 'diff', '--exit-code', baseline['sourceSHA'], 'HEAD', '--', *native_paths)
build.run('git', 'diff', '--exit-code', 'HEAD', '--', *native_paths)
assert not build.output('git', 'ls-files', '--others', '--exclude-standard', '--', *native_paths), 'Unreviewed native input'
assert build.output('git', 'submodule', 'status', '--recursive') == baseline['submodules'], 'Native submodule identity changed'
output = build.HERE / 'build/xros'
digests = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest() for p in build.core_archives(output)}
assert digests == baseline['nativeArchives'], 'Native archive bytes changed'
combined = hashlib.sha256((output/'libChiakiVisionCore.a').read_bytes()).hexdigest()
assert combined == baseline['combinedNativeArchiveSHA256'], 'Combined archive bytes changed'
assert (build.HERE/'Sources/GeneratedPSN.swift').is_file(), 'Missing generated public upstream configuration'

build.run('xcodegen', 'generate', '--spec', build.HERE/'project.yml', '--project', build.HERE)
sha = build.output('git', 'rev-parse', 'HEAD')
fingerprint = build.source_digest()
build.run('xcodebuild', '-jobs', '2', '-project', build.HERE/'VisionRemotePlay.xcodeproj',
    '-scheme', 'VisionRemotePlay', '-configuration', 'Debug', '-destination', 'generic/platform=visionOS',
    '-derivedDataPath', build.HERE/'DerivedData', 'build', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
    f'PROTOTYPE_SOURCE_SHA={sha}', f'PROTOTYPE_SOURCE_DIGEST={fingerprint}')
assert build.output('git', 'rev-parse', 'HEAD') == sha
assert build.source_digest() == fingerprint, 'Source changed during build'
assert hashlib.sha256((output/'libChiakiVisionCore.a').read_bytes()).hexdigest() == combined
cache = build.ROOT.parent
stage = Path(tempfile.mkdtemp(prefix=sha[:12]+'-extreme-', dir=cache))
app = stage/'VisionRemotePlay.app'
build.run('ditto', '--norsrc', '--noextattr', build.HERE/'DerivedData/Build/Products/Debug-xros/VisionRemotePlay.app', app)
build.sign_app(app, args.device)
info = plistlib.loads((app/'Info.plist').read_bytes())
assert info['PrototypeSourceSHA'] == sha and info['PrototypeSourceDigest'] == fingerprint
manifest = dict(baseline)
manifest.update(sourceSHA=sha, sourceTree=build.output('git','rev-parse','HEAD^{tree}'), sourceDigest=fingerprint,
    trackedChanges=build.output('git','status','--porcelain','--untracked-files=all'), appPath=str(app),
    executableSHA256=hashlib.sha256((app/'VisionRemotePlay').read_bytes()).hexdigest(),
    metalLibrarySHA256=hashlib.sha256((app/'default.metallib').read_bytes()).hexdigest(),
    nativeCoreReusedFromSource=baseline['sourceSHA'], nativeCoreInputsVerifiedUnchanged=True,
    nativeArchives=digests, combinedNativeArchiveSHA256=combined,
    xcode=build.output('xcodebuild','-version'), distribution='local development only')
(output/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Qualified Extreme candidate:',sha,fingerprint,manifest['executableSHA256'],flush=True)
