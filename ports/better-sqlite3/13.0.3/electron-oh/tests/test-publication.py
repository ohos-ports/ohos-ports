#!/usr/bin/env python3
"""Exercise publish.sh with an isolated npm double; never contact a registry."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

PORT = Path(__file__).resolve().parents[2]


def main():
    cases = [('existing', '13.0.3', True, False),
             ('missing', '13.0.3', True, True),
             ('auth-error', '13.0.3', False, False),
             ('network-error', '13.0.3', False, False),
             ('unexpected', '13.0.3', False, False),
             ('missing', '13.0.3-electron-oh.0', False, False)]
    with tempfile.TemporaryDirectory(prefix='better-sqlite3-release-test-') as temp:
        root = Path(temp)
        package = root / 'better-sqlite3-13.0.3'
        package.mkdir()
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        npm = bin_dir / 'npm'
        npm.write_text('#!' + sys.executable + '\n' + '''
import json,os,sys
from pathlib import Path
with Path(os.environ['NPM_TRACE']).open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1]=='publish':sys.exit(0)
assert sys.argv[1]=='view'
mode=os.environ['NPM_TEST_MODE']
if mode=='existing':print(json.dumps('13.0.3'));sys.exit(0)
if mode=='unexpected':print(json.dumps('0.0.0'));sys.exit(0)
if mode=='network-error':sys.exit(1)
print(json.dumps({'error':{'code':'E404' if mode=='missing' else 'E401'}}));sys.exit(1)
''')
        npm.chmod(0o755)
        for mode, version, success, publish in cases:
            trace = root / 'trace.jsonl'
            trace.unlink(missing_ok=True)
            (package / 'package.json').write_text(json.dumps({'name':'@ohos-ports/better-sqlite3','version':version}))
            env = {**os.environ, 'PATH':str(bin_dir)+os.pathsep+os.environ['PATH'],
                   'NPM_TEST_MODE':mode,'NPM_TRACE':str(trace)}
            result = subprocess.run(['sh', str(PORT / 'publish.sh')], cwd=root, env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            published = [call for call in calls if call[0]=='publish']
            assert (result.returncode == 0) == success, (mode, version, result.stderr)
            assert bool(published) == publish, (mode, version, calls)
            if publish:
                assert published == [['publish','--ignore-scripts','--provenance','--tag','latest','--access','public']]
            print('PASS:', mode, version, 'publish-command='+str(publish))
    print('No real npm command or registry was used.')


if __name__ == '__main__':
    main()
