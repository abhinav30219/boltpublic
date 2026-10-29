# Usage: Blender -b --factory-startup -P verify.py -- <Robot.usdz>
# Re-imports the USDZ and checks the asset contract. Exit 1 listing violations, else print OK.
import bpy, sys, re, math, os, subprocess, tempfile, zipfile
from collections import Counter

path = sys.argv[sys.argv.index('--') + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=path)

LEGS = ['FL', 'FR', 'BL', 'BR']
JOINTS = [f'{j}_{L}' for L in LEGS for j in ('hip', 'knee', 'ankle')]
EMPTIES = ['face_anchor'] + JOINTS
# Mesh parts: the contract name is a transform prim; its geometry is the child Mesh prim '<name>_mesh'.
MESHES = ['body'] + [f'{k}_{L}' for L in LEGS for k in ('upperLeg', 'lowerLeg', 'foot')] + ['kneeSleeve_FL', 'kneeSleeve_FR']
CONTRACT = ['robot'] + EMPTIES + MESHES
MATS = ['mat_shell', 'mat_limb', 'mat_joint', 'mat_foot', 'mat_accent']

bad = []
names = Counter(o.name for o in bpy.data.objects)
# (Blender's importer folds a leaf transform prim into its Mesh child, so only 'body' and the joints survive by name.)
for n in EMPTIES + ['body'] + [m + '_mesh' for m in MESHES]:
    if names[n] != 1: bad.append(f'{n}: found {names[n]} times after Blender re-import (want 1)')
for n in names:
    if re.search(r'\.\d{3}$', n): bad.append(f'{n}: has numeric suffix')
# Blender's importer drops the exporter's top-level wrapper prim, so the stage structure is checked in the USD text.
with tempfile.TemporaryDirectory() as td:
    with zipfile.ZipFile(path) as z:
        z.extractall(td)
        layer = next(n for n in z.namelist() if n.endswith(('.usdc', '.usd', '.usda')))
    r = subprocess.run(['usdcat', '--flatten', os.path.join(td, layer)], capture_output=True, text=True)
    txt = r.stdout
if r.returncode != 0 or not txt: bad.append(f'usdcat failed: {r.stderr.strip()[:200]}')
# Every contract name must be exactly one prim in the USD itself (no Xform/Mesh twins, no suffixes).
prims = Counter(re.findall(r'^\s*def \w+ "([^"]+)"', txt, re.M))
for n in CONTRACT:
    if prims[n] != 1: bad.append(f'USD prim {n}: found {prims[n]} times (want 1)')
for n in prims:
    if re.search(r'\.\d{3}$', n): bad.append(f'USD prim {n}: has numeric suffix')
tops = re.findall(r'^def \w+ "([^"]+)"', txt, re.M)
if tops != ['robot']: bad.append(f'top-level prims are {tops}, want exactly [robot]')
if 'defaultPrim = "robot"' not in txt: bad.append('defaultPrim is not robot')
if 'upAxis = "Y"' not in txt: bad.append('stage is not Y-up')
if re.search(r'^\s*def \w+ "root"', txt, re.M): bad.append('a prim named root exists')
if not re.search(r'^def Xform "robot"[^{]*\{?[\s\S]*?xformOp:rotateXYZ = \(-90, 0, 0\)', txt, re.M): bad.append('robot does not carry the -90 deg X Y-up conversion')
for n in EMPTIES[1:]:
    o = bpy.data.objects.get(n)
    if o and any(abs(a) > 1e-4 for a in o.rotation_euler): bad.append(f'{n}: rest rotation not identity {tuple(o.rotation_euler)}')
for n in MESHES:
    o = bpy.data.objects.get(n + '_mesh')
    if o and o.type != 'MESH': bad.append(f'{n}_mesh: not a mesh')
    owner = 'body' if n == 'body' else {'upperLeg': 'hip', 'lowerLeg': 'knee', 'foot': 'ankle', 'kneeSleeve': 'knee'}[n.split('_')[0]] + '_' + n.split('_')[1]
    if o and (o.parent is None or o.parent.name != owner): bad.append(f'{n}_mesh parent is {o.parent and o.parent.name}, want {owner}')
matnames = {m.name for m in bpy.data.materials}
for n in MATS:
    if n not in matnames: bad.append(f'material {n} missing')
expect = {'body': 'mat_shell', 'kneeSleeve_FL': 'mat_joint', 'kneeSleeve_FR': 'mat_joint'}
for L in LEGS:
    expect.update({f'upperLeg_{L}': 'mat_limb', f'lowerLeg_{L}': 'mat_joint', f'foot_{L}': 'mat_foot'})
for n, mat in expect.items():
    o = bpy.data.objects.get(n + '_mesh')
    got = [s_.material.name if s_.material else None for s_ in o.material_slots] if o else None
    if o and got[:1] != [mat]: bad.append(f'{n}_mesh: materials {got}, want first = {mat}')
fa = bpy.data.objects.get('face_anchor')
if fa and not fa.location.y < -0.3: bad.append(f'face_anchor local offset {tuple(fa.location)} not toward -Y of body')
if fa and fa.parent is not bpy.data.objects.get('body'): bad.append('face_anchor is not a child of body')
for L in LEGS:
    for j, par in (('hip', 'body'), ('knee', f'hip_{L}'), ('ankle', f'knee_{L}')):
        o = bpy.data.objects.get(f'{j}_{L}')
        if o and (o.parent is None or o.parent.name != par): bad.append(f'{j}_{L} parent is {o.parent and o.parent.name}, want {par}')

if bad:
    print('VIOLATIONS'); [print(' -', b) for b in bad]; sys.stdout.flush(); sys.exit(1)
print('OK')
