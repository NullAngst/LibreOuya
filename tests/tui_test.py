#!/usr/bin/env python3
"""Drive the menus like a person would, against the fake adb.

Needs pexpect, plus whiptail or dialog for the TUI runs.
  python3 tests/tui_test.py whiptail   TUI under whiptail
  python3 tests/tui_test.py dialog     TUI under dialog
  python3 tests/tui_test.py list       plain list in LibreOuya.sh
TUI walk: status, result screen, dry run toggle, store on (chooser, confirm
with preview, default-No question), result screen, Quit item.
List walk: status, then live logcat stopped with Ctrl+C, back to the list.
"""
import os
import sys
import tempfile

import pexpect

ui = sys.argv[1] if len(sys.argv) > 1 else 'whiptail'
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp(prefix='libreouya-tui.')
env = dict(os.environ)
env.update(LIBREOUYA_TUI=ui, PATH=os.path.join(root, 'tests', 'fakebin') + ':' + env['PATH'],
           XDG_STATE_HOME=tmp + '/state', XDG_CACHE_HOME=tmp + '/cache', XDG_CONFIG_HOME=tmp + '/config',
           NO_COLOR='1', TERM='xterm', FAKE_ADB_LOG=tmp + '/adb.log')
for f in ('adb', 'fastboot'):
    os.chmod(os.path.join(root, 'tests', 'fakebin', f), 0o755)

if ui == 'list':
    c = pexpect.spawn('bash', [os.path.join(root, 'LibreOuya.sh')], cwd=root, env=env,
                      dimensions=(45, 110), encoding='utf-8', timeout=20)
    c.expect('Choose a number')
    c.sendline('1')
    c.expect('Firmware: 1.2.1427')
    c.expect('Back to the list')
    c.sendline('')
    print('ok   list status, back to the list')
    c.expect('Choose a number')
    c.sendline('28')
    c.expect('Ctrl.C to stop')
    c.sendcontrol('c')
    c.expect('Back to the list')
    print('ok   list Ctrl+C stops logcat, not the menu')
    c.sendline('')
    c.expect('Choose a number')
    c.sendline('q')
    c.expect(pexpect.EOF)
    c.close()
    if c.exitstatus != 0:
        print('FAIL exit status', c.exitstatus)
        sys.exit(1)
    print('ok   list clean exit')
    sys.exit(0)

# dialog puts the terminal in application key mode, whiptail accepts either.
if ui == 'dialog':
    DOWN, LEFT = '\x1bOB', '\x1bOD'
else:
    DOWN, LEFT = '\x1b[B', '\x1b[D'

c = pexpect.spawn('bash', [os.path.join(root, 'LibreOuyaTUI.sh')], cwd=root, env=env,
                  dimensions=(45, 110), encoding='utf-8', timeout=20)


def step(pattern, keys, what):
    c.expect(pattern)
    print('ok  ', ui, what)
    c.send(keys)


step('pick a step', '\r', 'menu shows, run status')
step('status: finished', '\r', 'status result shown, back to menu')
step('pick a step', DOWN * 6 + '\r', 'pick dry run toggle (item 7)')
# 26 items and 7 section headers between item 7 and item 33 (store on)
step('Dry run: ON', DOWN * (26 + 7) + '\r', 'dry run on, pick store on')
step('Which server', '\r', 'server chooser, pick the first')
step('OUYA_SERVER_URL=http://ouya.cweiske.de', '', 'confirm box shows the config preview')
step('Write it to /sdcard/ouya_config.properties', LEFT + '\r', 'answer yes')
step('Also map devs.ouya.tv', '\r', 'Enter on a question means no')
step('Store on.*finished', '\r', 'result screen, back to menu')
step('pick a step', DOWN * 80 + '\r', 'Quit item')
c.expect(pexpect.EOF)
c.close()
if c.exitstatus != 0:
    print('FAIL exit status', c.exitstatus)
    sys.exit(1)
with open(tmp + '/adb.log') as f:
    if 'push' in f.read():
        print('FAIL dry run pushed a file')
        sys.exit(1)
print('ok  ', ui, 'clean exit, nothing pushed in dry run')
