#!/usr/bin/env python3
"""Turns a UTM v5.0.8 checkout into the "VM" app.

Run from the repository root (or pass it as the first argument). Every edit checks that the
code it replaces is still there, so a changed upstream fails loudly instead of building
something half patched.
"""
import glob
import hashlib
import os
import plistlib
import re
import shutil
import struct
import sys
import zlib

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
HERE = os.path.dirname(os.path.abspath(__file__))
IOS_TARGET_SOURCES = 'CE2D926924AD46670059923A'  # PBXSourcesBuildPhase of the "iOS" target
BUNDLE_PREFIX = 'app.vmios'


def path(*p):
    return os.path.join(ROOT, *p)


def read(p):
    with open(path(p), encoding='utf-8') as f:
        return f.read()


def write(p, text):
    with open(path(p), 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def replace_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f'patch_utm: expected exactly one match for {what}, found {n}')
    return text.replace(old, new)


def object_id(name):
    return hashlib.md5(('vm-shell:' + name).encode()).hexdigest()[:24].upper()


# 1. our sources --------------------------------------------------------------------------
dst = path('Platform', 'iOS', 'VM')
os.makedirs(dst, exist_ok=True)
sources = sorted(os.path.basename(p) for p in glob.glob(os.path.join(HERE, 'Sources', '*.swift')))
if not sources:
    sys.exit('patch_utm: no sources in vm/Sources')
for name in sources:
    shutil.copyfile(os.path.join(HERE, 'Sources', name), os.path.join(dst, name))
print('sources:', ', '.join(sources))

# 2. Xcode project ------------------------------------------------------------------------
pbx_path = os.path.join('UTM.xcodeproj', 'project.pbxproj')
pbx = read(pbx_path)
if 'vm-shell group' not in pbx:
    build_files = ''
    file_refs = ''
    children = ''
    phase_entries = ''
    for name in sources:
        ref = object_id('ref:' + name)
        bf = object_id('build:' + name)
        build_files += f'\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n'
        file_refs += f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
        children += f'\t\t\t\t{ref} /* {name} */,\n'
        phase_entries += f'\t\t\t\t{bf} /* {name} in Sources */,\n'
    group_id = object_id('group')
    group = (f'\t\t{group_id} /* VM */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n'
             f'\t\t\tname = VM;\n\t\t\tpath = Platform/iOS/VM;\n\t\t\tsourceTree = SOURCE_ROOT;\n\t\t}}; /* vm-shell group */\n')

    pbx = replace_once(pbx, '/* Begin PBXBuildFile section */\n', '/* Begin PBXBuildFile section */\n' + build_files, 'PBXBuildFile section')
    pbx = replace_once(pbx, '/* Begin PBXFileReference section */\n', '/* Begin PBXFileReference section */\n' + file_refs, 'PBXFileReference section')
    pbx = replace_once(pbx, '/* Begin PBXGroup section */\n', '/* Begin PBXGroup section */\n' + group, 'PBXGroup section')

    main_group = re.search(r'mainGroup = ([0-9A-F]{24})', pbx).group(1)
    m = re.search(r'\t\t' + main_group + r' (?:/\* [^*]* \*/ )?= \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n', pbx)
    if not m:
        sys.exit('patch_utm: main group not found')
    pbx = pbx[:m.end()] + f'\t\t\t\t{group_id} /* VM */,\n' + pbx[m.end():]

    m = re.search(r'\t\t' + IOS_TARGET_SOURCES + r' /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n', pbx)
    if not m:
        sys.exit('patch_utm: iOS sources build phase not found')
    pbx = pbx[:m.end()] + phase_entries + pbx[m.end():]

    old_ids = ['"$(PRODUCT_BUNDLE_PREFIX:default=com.utmapp).UTM";']
    n = pbx.count(old_ids[0])
    if n < 2:
        sys.exit(f'patch_utm: bundle identifier settings not found ({n})')
    pbx = pbx.replace(old_ids[0], f'"$(PRODUCT_BUNDLE_PREFIX:default={BUNDLE_PREFIX}).VM";')
    write(pbx_path, pbx)
    print('project: added', len(sources), 'files to the iOS target, bundle id', BUNDLE_PREFIX + '.VM')

# 3. UI entry points ----------------------------------------------------------------------
p = os.path.join('Platform', 'iOS', 'UTMSingleWindowView.swift')
t = read(p)
if 'VMHomeView' not in t:
    t = replace_once(t, '                ContentView().environmentObject(data!)\n',
                     '                VMHomeView().environmentObject(data!)\n', 'ContentView in UTMSingleWindowView')
    write(p, t)

p = os.path.join('Platform', 'iOS', 'VMWindowView.swift')
t = read(p)
if 'VM: no toolbar' not in t:
    t = replace_once(t, '            if isInteractive && state.isRunning {\n                VMToolbarView(state: $state)\n            }\n',
                     '            // VM: no toolbar, the screen belongs to Android only\n', 'VMToolbarView in VMWindowView')
    write(p, t)

# 4. Info.plist: name and portrait phone only ---------------------------------------------
p = path('Platform', 'iOS', 'Info.plist')
with open(p, 'rb') as f:
    info = plistlib.load(f)
info['CFBundleDisplayName'] = 'VM'
info['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait']
info['UIRequiresFullScreen'] = True
info['UIStatusBarStyle'] = 'UIStatusBarStyleDefault'
schemes = info.setdefault('LSApplicationQueriesSchemes', [])
if 'stikdebug' not in schemes:
    schemes.append('stikdebug')
with open(p, 'wb') as f:
    plistlib.dump(info, f)

for p in glob.glob(path('Platform', 'iOS', '*.lproj', 'InfoPlist.strings')):
    raw = open(p, 'rb').read()
    if raw.startswith(b'\xff\xfe') or raw.startswith(b'\xfe\xff'):
        enc = 'utf-16'
    else:
        enc = 'utf-8-sig' if raw.startswith(b'\xef\xbb\xbf') else 'utf-8'
    text = raw.decode(enc)
    text = re.sub(r'"CFBundleName"\s*=\s*"[^"]*";', '"CFBundleName" = "VM";', text)
    text = re.sub(r'"CFBundleDisplayName"\s*=\s*"[^"]*";\n?', '', text)
    text = text.rstrip('\n') + '\n"CFBundleDisplayName" = "VM";\n'
    with open(p, 'w', encoding=enc, newline='\n') as f:
        f.write(text)
print('info: display name VM, portrait only')

# 5. plain icon ---------------------------------------------------------------------------
def png(width, height, rgb):
    row = b'\x00' + bytes(rgb) * width
    raw = row * height

    def chunk(kind, data):
        c = struct.pack('>I', len(data)) + kind + data
        return c + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


GRAY = (142, 142, 147)
for p in glob.glob(path('Platform', 'Assets.xcassets', 'AppIcon.appiconset', '*.png')):
    with open(p, 'rb') as f:
        head = f.read(24)
    w, h = struct.unpack('>II', head[16:24])
    with open(p, 'wb') as f:
        f.write(png(w, h, GRAY))

icon_json = path('Platform', 'AppIcon.icon', 'icon.json')
if os.path.exists(icon_json):
    import json
    with open(icon_json, encoding='utf-8') as f:
        icon = json.load(f)
    icon['fill-specializations'] = [{'value': {'solid': 'srgb:0.55686,0.55686,0.57647,1.00000'}}]
    for g in icon.get('groups', []):
        g['hidden'] = True
    with open(icon_json, 'w', encoding='utf-8') as f:
        json.dump(icon, f, indent=2)
print('icon: plain')
print('patch_utm: done')
