#!/usr/bin/env python3
"""Exercise the archive-selection regression with real compiled symbols."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('vision_build', Path(__file__).parents[1] / 'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildTests(unittest.TestCase):
    def test_stale_duplicate_cannot_replace_native_code(self):
        with tempfile.TemporaryDirectory(prefix='vision-archive-regression-') as directory:
            root = Path(directory)
            for name in build.CORE_ARCHIVES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'!<arch>\n')
            for folder, value, archive in [('fresh', 7, 'libchiaki.a'), ('stale', 99, 'libchiaki 2.a')]:
                source = root / folder / 'probe.c'
                source.parent.mkdir()
                source.write_text(f'int native_probe(void) {{ return {value}; }}\n')
                obj = source.with_suffix('.o')
                subprocess.run(['xcrun', 'clang', '-c', str(source), '-o', str(obj)], check=True)
                subprocess.run(['xcrun', 'libtool', '-static', '-o', str(root / archive), str(obj)], check=True)
            combined = root / 'libChiakiVisionCore.a'
            subprocess.run(['xcrun', 'libtool', '-static', '-o', str(combined),
                            *map(str, build.core_archives(root))], check=True, capture_output=True)
            source = root / 'main.c'
            source.write_text('int native_probe(void); int main(void) { return native_probe(); }\n')
            executable = root / 'probe'
            subprocess.run(['xcrun', 'clang', str(source), str(combined), '-o', str(executable)], check=True)
            self.assertEqual(subprocess.run([str(executable)]).returncode, 7,
                             'A stale backup archive replaced the current native implementation.')

    def test_missing_target_archive_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix='vision-archive-missing-') as directory:
            with self.assertRaises(RuntimeError):
                build.core_archives(Path(directory))


if __name__ == '__main__':
    unittest.main()
