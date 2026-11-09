#!/usr/bin/env python3
"""Rebuild only the bridge object, with byte proof for every reused native input."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import build

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', required=True, type=Path)
parser.add_argument('--headers-from', required=True, type=Path)
parser.add_argument('--receipt', required=True, type=Path)
args = parser.parse_args()
baseline = json.loads(args.baseline.read_text())
assert not build.output('git', 'status', '--porcelain'), 'Commit reviewed source before qualification'
native_paths = ['lib', 'visionos/Native', 'visionos/CMakeLists.txt', '.gitmodules',
                'third-party', 'visionos/Dependencies']
changed = build.output('git', 'diff', '--name-only', baseline['sourceSHA'], 'HEAD', '--', *native_paths).splitlines()
assert changed == ['visionos/Native/RemotePlayBridge.c'], 'Only the bridge implementation may differ'
output = build.HERE/'build/xros'
archives = build.core_archives(output)
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
assert {str(p.relative_to(output)): digest(p) for p in archives} == baseline['nativeArchives']
assert digest(output/'libChiakiVisionCore.a') == baseline['combinedNativeArchiveSHA256']

headers = []
header_receipts = {}
for name in ['mbedtls', 'opus']:
    relative = 'visionos/Dependencies/'+name
    source = args.headers_from/relative
    expected = build.output('git', 'rev-parse', 'HEAD:'+relative)
    actual = subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    assert expected == actual
    assert not subprocess.check_output(['git','-C',str(source),'status','--porcelain','--untracked-files=all','--','include'],text=True).strip()
    headers.append(source/'include'); header_receipts[relative] = expected
include = output/'bridge-include/chiaki'
include.mkdir(parents=True, exist_ok=True)
config = '#pragma once\n#define CHIAKI_LIB_ENABLE_OPUS 1\n#define CHIAKI_LIB_ENABLE_PI_DECODER 0\n#define CHIAKI_LIB_ENABLE_FFMPEG_DECODER 0\n'
assert (args.headers_from/'visionos/build/xros/include/chiaki/config.h').read_text() == config
(include/'config.h').write_text(config)
scratch = output/'bridge-rebuild'; scratch.mkdir(exist_ok=True)
archive = output/'libchiaki.a'
before = scratch/'libchiaki-before.a'
if before.exists(): assert digest(before) == digest(archive)
else: shutil.copy2(archive,before)
def members(path):
    names = subprocess.check_output(['xcrun','ar','-t',str(path)],text=True).splitlines()
    assert len(names) == len(set(names)), 'Duplicate native object names'
    return {n: hashlib.sha256(subprocess.check_output(['xcrun','ar','-p',str(path),n])).hexdigest() for n in names}
old_members = members(archive)
source = build.HERE/'Native/RemotePlayBridge.c'
obj = scratch/'RemotePlayBridge.c.o'
command = ['xcrun','--sdk','xros','clang','--target=arm64-apple-xros2.0','-O2','-g','-DNDEBUG','-std=gnu11',
           '-DCHIAKI_LIB_ENABLE_MBEDTLS','-DCHIAKI_LOCAL_ONLY','-DMBEDTLS_ALLOW_PRIVATE_ACCESS','-DPB_C99_STATIC_ASSERT',
           '-I'+str(build.ROOT/'lib/include'),'-I'+str(include.parent)]
command += ['-I'+str(p) for p in headers]
command += ['-c',str(source),'-o',str(obj)]
build.run(*command)
build.run('xcrun','ar','-r',archive,obj)
build.run('xcrun','ranlib',archive)
new_members = members(archive)
assert old_members.keys() == new_members.keys()
assert [name for name in old_members if old_members[name] != new_members[name]] == ['RemotePlayBridge.c.o']
build.run('xcrun','--sdk','xros','libtool','-static','-o',output/'libChiakiVisionCore.a',*archives)
qualified = {key: baseline[key] for key in ['upstreamBase','submodules','xcode','target','distribution']}
qualified.update(sourceSHA=build.output('git','rev-parse','HEAD'),
    sourceTree=build.output('git','rev-parse','HEAD^{tree}'), sourceDigest=build.source_digest(),
    nativeArchives={str(p.relative_to(output)): digest(p) for p in archives},
    combinedNativeArchiveSHA256=digest(output/'libChiakiVisionCore.a'),
    nativeDerivation={'parentSourceSHA':baseline['sourceSHA'],'parentArchives':baseline['nativeArchives'],
        'rebuiltSource':'visionos/Native/RemotePlayBridge.c','rebuiltSourceSHA256':digest(source),
        'rebuiltObjectSHA256':digest(obj),'otherObjectDigestsUnchanged':True,
        'verifiedHeaderCommits':header_receipts,'compileCommand':command,
        'qualificationScriptSHA256':digest(Path(__file__))})
args.receipt.write_text(json.dumps(qualified,indent=2)+'\n')
print('Qualified fresh bridge object; every other native object is byte-identical.')
