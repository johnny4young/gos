#!/usr/bin/env python3
"""Exercise real ZLE/_arguments completion in an isolated, bounded PTY."""
import errno
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import sys
import tempfile
import time

completion = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / '_gos').write_text(completion.read_text())
    # Runner fpath entries can be insecure. Keep a hostile entry in the fixture
    # so compinit must exclude it rather than prompt or trust it with -u.
    insecure = root / 'insecure'
    insecure.mkdir()
    insecure.chmod(0o777)
    (insecure / '_gos_untrusted').write_text('#compdef gos-untrusted\n')
    (root / 'fixture-target').touch()
    capture = root / 'capture'
    setup = root / 'setup.zsh'
    setup.write_text(f'''
PS1='gos-test> '
RPROMPT=''
cd {shlex.quote(directory)}
fpath=({shlex.quote(directory)} {shlex.quote(str(insecure))} $fpath)
autoload -Uz compinit
compinit -i -D
if (( ${{+_comps[gos-untrusted]}} )); then
  print -r -- 'GOS_UNTRUSTED_COMPLETION_LOADED'
  exit 1
fi
compdef _gos gos
gos() {{ print -r -- 1.21.6; }}
gos-probe-command() {{ :; }}
_probe() {{ _arguments '--probe-flag[Probe option]' '*:file:_files'; }}
compdef _probe gos-probe-command
_capture() {{
  print -r -- "$BUFFER" > {shlex.quote(str(capture))}.tmp
  mv -- {shlex.quote(str(capture))}.tmp {shlex.quote(str(capture))}
  BUFFER=''
  zle reset-prompt
}}
zle -N _capture
bindkey '^X' _capture
bindkey '^I' expand-or-complete
unsetopt BEEP
print -r -- GOS_READY
''')
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm'
        os.execv(shutil.which('zsh'), ['zsh', '-f'])
    transcript = bytearray()

    def drain():
        if select.select([fd], [], [], 0.05)[0]:
            try:
                data = os.read(fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    raise RuntimeError('zsh PTY exited unexpectedly') from error
                raise
            if not data:
                raise RuntimeError('zsh PTY closed unexpectedly')
            transcript.extend(data)

    def wait_until(predicate, context):
        deadline = time.monotonic() + 15
        while not predicate():
            if time.monotonic() > deadline:
                raise AssertionError(f'{context}: timed out\n{transcript.decode(errors="replace")}')
            drain()

    try:
        os.write(fd, f'source {shlex.quote(str(setup))}\n'.encode())
        # Wait for the actual marker, not the echoed source command.
        wait_until(lambda: b'GOS_READY\r\n' in transcript, 'initialization')
        cases = [
            ('gos run -', 'gos run --'),
            ('gos each 1.21', 'gos each 1.21.6'),
            ('gos each -', 'gos each -'),
            ('gos pin 1.21', 'gos pin 1.21.6'),
            ('gos platforms 1.21', 'gos platforms 1.21.6'),
        ]
        for prefix in ('gos run --', 'gos run 1.21.6', 'gos run 1.21.6 --',
                       'gos each 1.21.6', 'gos each 1.21.6 --'):
            cases.extend([
                (prefix + ' gos-probe-', prefix + ' gos-probe-command'),
                (prefix + ' gos-probe-command --probe-', prefix + ' gos-probe-command --probe-flag'),
                (prefix + ' gos-probe-command fixture-t', prefix + ' gos-probe-command fixture-target'),
            ])
        for before, expected in cases:
            capture.unlink(missing_ok=True)
            os.write(fd, (before + '\t\x18').encode())
            wait_until(capture.exists, before)
            actual = capture.read_text().rstrip()
            if actual != expected:
                raise AssertionError(f'{before!r}: expected {expected!r}, got {actual!r}\n'
                                     + transcript.decode(errors='replace'))
        print(f'ok - real Zsh completion passes {len(cases)} version/command/option/file cases')
    finally:
        # Non-login interactive shells may ignore TERM; never leave a test shell.
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        os.close(fd)
