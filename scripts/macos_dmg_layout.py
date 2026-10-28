"""Write and read back the DMG layout without sending Finder Apple Events."""
import argparse
from contextlib import contextmanager
from pathlib import Path
import subprocess
import sys
import tempfile


@contextmanager
def layout_tools():
    # No global installs or desktop permissions. pip verifies both wheel hashes.
    with tempfile.TemporaryDirectory(prefix='ssrvpn-dmg-tools-') as folder:
        subprocess.run([
            sys.executable, '-m', 'pip', 'install', '--disable-pip-version-check',
            '--only-binary=:all:', '--require-hashes', '--no-compile',
            '--target', folder, '-r', str(Path(__file__).with_name('dmg-requirements.txt')),
        ], check=True, timeout=120)
        sys.path.insert(0, folder)
        try:
            yield
        finally:
            sys.path.remove(folder)


WINDOW = {
    'WindowBounds': '{{100, 100}, {720, 492}}',
    'ShowToolbar': False, 'ShowStatusBar': False, 'ShowSidebar': False,
    'ShowTabView': False, 'ShowPathbar': False, 'ContainerShowSidebar': False,
    'PreviewPaneVisibility': False,
}
# Finder discards icon-view preferences when RGB fallback fields are missing,
# even with backgroundType=2. A successful plist round trip is not a UI check.
ICONS = {
    'viewOptionsVersion': 1, 'backgroundType': 2,
    'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0,
    'backgroundColorBlue': 1.0,
    'iconSize': 96.0, 'textSize': 14.0, 'arrangeBy': 'none',
    'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': False,
    'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
    'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
}
POSITIONS = {'SSRVPN.app': (190, 240), 'Applications': (530, 240)}


def check_contents(root):
    if {p.name for p in root.iterdir() if not p.name.startswith('.')} != set(POSITIONS):
        raise ValueError('DMG must contain exactly the application and Applications link')
    link = root / 'Applications'
    app = root / 'SSRVPN.app'
    if not app.is_dir() or app.is_symlink() or not link.is_symlink() or link.readlink() != Path('/Applications'):
        raise ValueError('Invalid drag-to-Applications contents')
    background = root / '.background/background.png'
    if not background.is_file() or background.is_symlink() or background.parent.is_symlink():
        raise ValueError('Missing local background image')
    return background


def verify_layout(root):
    from ds_store import DSStore
    from mac_alias import Alias

    check_contents(root)
    if (root / '.DS_Store').is_symlink():
        raise ValueError('DMG layout must be stored inside the image')
    with (root / '.DS_Store').open('rb') as stream, DSStore.open(stream, 'r') as store:
        if (store['.']['bwsp'] != WINDOW or store['.']['icvl'] != (b'type', b'icnv')
                or store['.']['vSrn'] != (b'long', 1)):
            raise ValueError('Incorrect DMG window layout')
        icons = store['.']['icvp']
        if any(type(icons.get(key)) is not type(value) or icons.get(key) != value
               for key, value in ICONS.items()):
            raise ValueError('Incorrect DMG icon view')
        alias = Alias.from_bytes(icons['backgroundImageAlias'])
        if alias.target.posix_path != '/.background/background.png' or alias.volume.name != 'SSRVPN':
            raise ValueError('Background alias does not point inside the DMG')
        for name, position in POSITIONS.items():
            if store[name]['Iloc'] != position:
                raise ValueError('Incorrect DMG icon position')


def write_layout(root):
    from ds_store import DSStore
    from mac_alias import Alias

    background = check_contents(root)
    alias = Alias.for_file(str(background))
    # The alias is generated from the mounted image's real catalog IDs. It must
    # not embed the build host's writable-image path or private job directory.
    alias.volume.posix_path = '/Volumes/SSRVPN'
    alias.volume.disk_image_alias = None
    icons = dict(ICONS, backgroundImageAlias=alias.to_bytes())
    with tempfile.TemporaryDirectory(prefix='.layout-', dir=root) as folder:
        candidate = Path(folder) / '.DS_Store'
        with DSStore.open(str(candidate), 'w+') as store:
            store['.']['bwsp'] = WINDOW
            store['.']['icvp'] = icons
            store['.']['icvl'] = (b'type', b'icnv')
            store['.']['vSrn'] = ('long', 1)
            for name, position in POSITIONS.items():
                store[name]['Iloc'] = position
        candidate.replace(root / '.DS_Store')
    verify_layout(root)
    print('DMG layout verified: background, window and two icon positions.')


def verify_native_background(root):
    """Resolve through macOS itself, without UI, networking or mounting another volume."""
    from ds_store import DSStore
    if sys.platform != 'darwin':
        raise RuntimeError('Native DMG acceptance requires macOS')
    with DSStore.open(str(root / '.DS_Store'), 'r') as store:
        alias = store['.']['icvp']['backgroundImageAlias']
    with tempfile.TemporaryDirectory(prefix='ssrvpn-dmg-alias-') as folder:
        path = Path(folder) / 'background.alias'
        path.write_bytes(alias)
        subprocess.run(['swift', str(Path(__file__).with_name('verify_macos_dmg_background.swift')),
                        str(root), str(path)], check=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mount', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    with layout_tools():
        root = args.mount.resolve()
        (verify_layout if args.verify_only else write_layout)(root)
        verify_native_background(root)


if __name__ == '__main__':
    main()
