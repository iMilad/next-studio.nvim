"""Run portable, local checks with synthetic projects and no external plugins."""
import os
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

plugin = Path(__file__).resolve().parents[1]
nvim = os.environ.get('NVIM_BIN') or shutil.which('nvim')
assert nvim, 'Neovim 0.12+ is required'
with tempfile.TemporaryDirectory(prefix='next-studio-plugin-') as directory:
    root = Path(directory)
    project = root / 'projects' / 'ALPHA'
    project.mkdir(parents=True)
    (project / 'example.txt').write_text('Synthetic fixture\n')
    legacy = root / 'projects' / 'LEGACY'
    legacy.mkdir()
    (legacy / 'example.txt').write_text('Synthetic legacy editor\n')
    env = {'PATH': os.defpath, 'TERM': 'xterm-256color', 'NEXT_STUDIO_TEST_ROOT': str(root),
           'NEXT_STUDIO_PLUGIN': str(plugin), 'XDG_CONFIG_HOME': str(root / 'config'),
           'XDG_DATA_HOME': str(root / 'data'), 'XDG_CACHE_HOME': str(root / 'cache'), 'XDG_STATE_HOME': str(root / 'xdg-state')}
    for phase in ['first', 'restart', 'migration', 'migration-restart']:
        env['NEXT_STUDIO_PHASE'] = phase
        script = json.dumps(str(plugin / ('tests/migration.lua' if phase.startswith('migration') else 'tests/functional.lua')), ensure_ascii=False)
        result = subprocess.run([nvim, '--headless', '-i', 'NONE', '-u', str(plugin / 'tests/init.lua'),
                                 '-c', "lua local ok,e=pcall(dofile, " + script + "); if not ok then print(e); vim.cmd('cquit') end"],
                                cwd=project, env=env, capture_output=True, text=True, timeout=25)
        print((result.stdout + result.stderr).strip(), flush=True)
        assert result.returncode == 0, phase + ' failed'
print('PASS portable plugin checks')
