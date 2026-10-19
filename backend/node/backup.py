import datetime
import os
import pathlib
import sqlite3

os.umask(0o077)
root = pathlib.Path.home() / '.local/share/newswire-server'
destination = root / 'backups' / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
destination.mkdir(parents=True, exist_ok=True)
for name in ('newswire', 'brain'):
    with sqlite3.connect(root / (name + '.sqlite')) as source:
        with sqlite3.connect(destination / (name + '.sqlite')) as backup:
            source.backup(backup)
            if backup.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                raise RuntimeError(name + ' backup failed integrity check')
print('Verified database backup:', destination)
for directory in sorted(destination.parent.iterdir())[:-14]:
    if directory.is_dir() and directory.name.isalnum():
        for name in ('newswire.sqlite', 'brain.sqlite'):
            (directory / name).unlink(missing_ok=True)
        directory.rmdir()
