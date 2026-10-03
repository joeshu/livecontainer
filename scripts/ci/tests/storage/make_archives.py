import pathlib
import stat
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
for name, path in [('valid', 'Payload/Test.app/data'), ('traversal', '../outside'), ('absolute', '/tmp/lc-archive-escape')]:
    with zipfile.ZipFile(root / (name + '.zip'), 'w') as archive:
        archive.writestr(path, 'test')
for name, target in [('safe-link', 'data'), ('safe-link-up', '../Test.app/data'), ('unsafe-link', '../../../outside')]:
    with zipfile.ZipFile(root / (name + '.zip'), 'w') as archive:
        archive.writestr('Payload/Test.app/data', 'test')
        link = zipfile.ZipInfo('Payload/Test.app/link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(link, target)
(root / 'broken.zip').write_bytes(b'not an archive')
