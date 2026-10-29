# Usage: Blender -b --factory-startup -P rig.py -- <in.fbx> <out.usdz> [knee_cut_z]
# Writes <out.usdz> (Y-up, the asset contract) plus out/robot_rigged.blend + out/pivots.json next to this script.
# Convention: F = y<0 (front, eyes at -Y), B = y>0, L = x<0, R = x>0. Z up.
import bpy, bmesh, sys, math, json, os
from mathutils.bvhtree import BVHTree
from mathutils import Vector
args = sys.argv[sys.argv.index('--')+1:]
FBX, USDZ = args[0], os.path.abspath(args[1])
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out'); os.makedirs(OUT, exist_ok=True)
KNEE_CUT_Z = float(args[2]) if len(args) > 2 else 0.46

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=FBX)
o = [x for x in bpy.data.objects if x.type == 'MESH'][0]
bpy.context.view_layer.objects.active = o; o.select_set(True)
bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.separate(type='LOOSE'); bpy.ops.object.mode_set(mode='OBJECT')
meshes = [x for x in bpy.data.objects if x.type == 'MESH']
bpy.ops.object.select_all(action='DESELECT')
for m in meshes: m.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)   # bake FBX axis fix: verts now in Z-up world

def info(m):
    ws = [v.co.copy() for v in m.data.vertices]
    mn = Vector([min(v[i] for v in ws) for i in range(3)]); mx = Vector([max(v[i] for v in ws) for i in range(3)])
    c = sum(ws, Vector()) / len(ws)
    return len(m.data.polygons), mn, mx, c
def leg(c):  # leg id from centroid
    return ('F' if c.y < 0 else 'B') + ('L' if c.x < 0 else 'R')

HIP_ROD_X = 0.28   # body-classified islands reaching farther out than this are hip linkage rods
groups = {}   # part name -> list of objects
main = {}     # (kind, leg) -> main island object (for pivot computation)
knobs = {}
rods = {}     # leg -> islands riding with the upper leg that are not its main blob
def add(name, m):
    groups.setdefault(name, []).append(m)
    n_, mn_, mx_, c_ = info(m)
    if name != 'body' or n_ < 1000: print('ISLAND', name, n_, [round(x,2) for x in mn_], [round(x,2) for x in mx_])
fused = []
for m in meshes:
    n, mn, mx, c = info(m)
    L = leg(c)
    if n > 1000: add('body', m)
    elif n >= 500: fused.append((m, L))
    elif mx.z < 0.17 and n > 50: add('foot_'+L, m)
    elif n >= 250 and mx.z > 0.7: add('upperLeg_'+L, m); main[('upper', L)] = m
    elif n >= 150 and mx.z < 0.46: add('lowerLeg_'+L, m); main[('lower', L)] = m
    elif abs(c.x) < 0.235 and max(-mn.x, mx.x) > HIP_ROD_X and n >= 8:   # linkage rod spanning body -> hip: rides with that leg
        L = ('F' if c.y < 0 else 'B') + ('L' if (mn.x if -mn.x > mx.x else mx.x) < 0 else 'R')
        add('upperLeg_'+L, m); rods.setdefault(L, []).append(m)
    elif abs(c.x) < 0.235 or n < 8: add('body', m)
    elif n == 14 and mx.z < 0.46: add('lowerLeg_'+L, m); knobs[L] = m     # knee knob
    else: add('upperLeg_'+L, m); rods.setdefault(L, []).append(m)   # linkage rods, pistons, hip motor housings

# ---- cut fused front legs at the knee
def cut(m, L, z):
    res = {}
    for kind, keep_pos in (('upper', True), ('lower', False)):
        me = m.data.copy()
        bm = bmesh.new(); bm.from_mesh(me)
        g = bm.verts[:] + bm.edges[:] + bm.faces[:]
        r = bmesh.ops.bisect_plane(bm, geom=g, dist=1e-6, plane_co=(0, 0, z), plane_no=(0, 0, 1),
                                   clear_inner=keep_pos, clear_outer=not keep_pos)
        bnd = [e for e in bm.edges if e.is_boundary]
        try: bmesh.ops.holes_fill(bm, edges=bnd, sides=0)
        except Exception as ex: print("holes_fill failed", ex)
        bm.to_mesh(me); bm.free()
        ob = bpy.data.objects.new(f'{kind}Leg_{L}_cut', me); bpy.context.scene.collection.objects.link(ob)
        res[kind] = ob
    bpy.data.objects.remove(m)
    return res
for m, L in fused:
    r = cut(m, L, KNEE_CUT_Z)
    add('upperLeg_'+L, r['upper']); main[('upper', L)] = r['upper']
    add('lowerLeg_'+L, r['lower']); main[('lower', L)] = r['lower']

knob_c = {L: info(k)[3] for L, k in knobs.items()}
# ---- hip pivots from each leg's main upper blob (rods excluded), world rest pose
LEGS = ['FL', 'FR', 'BL', 'BR']
def hip_of(ob):
    uv = [v.co.copy() for v in ob.data.vertices]
    zmax = max(v.z for v in uv)
    top = [v for v in uv if v.z > zmax - 0.22 * (zmax - 0.55)]       # hip knob region (top of the upper-leg blob)
    return sum(top, Vector()) / len(top)
hips = {L: hip_of(main[('upper', L)]) for L in LEGS}

# ---- rods that would poke through the body when the hip swings: measured, then deleted
POSE_DEG = (-30, -20, -10, 0, 10, 20, 30)
def tri_bvh(objs, xform=None):
    vs, ps = [], []
    for o in objs:
        base = len(vs); vs += [(xform @ v.co) if xform else v.co.copy() for v in o.data.vertices]
        for p in o.data.polygons:
            idx = [base + i for i in p.vertices]
            for k in range(1, len(idx) - 1): ps.append((idx[0], idx[k], idx[k + 1]))
    return BVHTree.FromPolygons(vs, ps)
def rot_x_about(pivot, deg):
    from mathutils import Matrix
    return Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(deg), 4, 'X') @ Matrix.Translation(-pivot)
body_bvh = tri_bvh(groups['body'])
deleted = []
for L in LEGS:
    for r in list(rods.get(L, [])):
        hits = {d: len(body_bvh.overlap(tri_bvh([r], rot_x_about(hips[L], d)))) for d in POSE_DEG}
        n_, mn_, mx_, c_ = info(r)
        if any(hits.values()):
            print('ROD-DELETE', L, f'faces={n_}', 'bbox', [round(x, 2) for x in mn_], [round(x, 2) for x in mx_], 'overlaps', hits)
            deleted.append((L, n_, [round(x, 3) for x in mn_], [round(x, 3) for x in mx_]))
            groups['upperLeg_'+L].remove(r); bpy.data.objects.remove(r); rods[L].remove(r)
        else:
            print('ROD-KEEP', L, f'faces={n_}', 'bbox', [round(x, 2) for x in mn_], [round(x, 2) for x in mx_])

# ---- merge groups
parts = {}
for name, lst in groups.items():
    bpy.ops.object.select_all(action='DESELECT')
    for x in lst: x.select_set(True)
    bpy.context.view_layer.objects.active = lst[0]
    if len(lst) > 1: bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active; ob.name = name; ob.data.name = name
    parts[name] = ob
# merged main-island refs are stale; recompute from merged parts using vertex subsets
def verts(name): return [v.co.copy() for v in parts[name].data.vertices]
def avg(vs): return sum(vs, Vector()) / len(vs)

# ---- pivots (world, rest pose)
piv = {}
for L in LEGS:
    piv['hip_'+L] = hips[L]
    piv['knee_'+L] = knob_c.get(L)
    lv = verts('lowerLeg_'+L)
    low = [v for v in lv if v.z < 0.16]
    piv['ankle_'+L] = avg(low)
# Front legs: the knee pivots at the centre of the cut section (on the cut plane), so the two cut caps stay
# flush at rest and a bend opens only a small wedge, which the knee sleeve covers.
section = {}
for L in ('FL', 'FR'):
    sec = [v for v in verts('upperLeg_'+L) if abs(v.z - KNEE_CUT_Z) < 1e-4]
    xs, ys = [v.x for v in sec], [v.y for v in sec]
    section[L] = dict(cx=(min(xs) + max(xs)) / 2, cy=(min(ys) + max(ys)) / 2, wx=max(xs) - min(xs), wy=max(ys) - min(ys))
    piv['knee_'+L] = Vector((section[L]['cx'], section[L]['cy'], KNEE_CUT_Z))
    print('SECTION', L, {k: round(v, 4) for k, v in section[L].items()})
for k, v in sorted(piv.items()): print('PIVOT', k, tuple(round(x, 4) for x in v))

# ---- face anchor from the eye discs
body_v = verts('body')
eyes = [v for v in body_v if abs(v.x) < 0.14 and 0.62 < v.z < 0.75 and v.y < -0.40]
face_y = min(v.y for v in eyes)
face_z = avg(eyes).z
face = Vector((0, face_y, face_z))
print('FACE', tuple(face))

# ---- build hierarchy. All empties identity rotation. Mesh origin = its joint.
def empty(name, world, parent):
    e = bpy.data.objects.new(name, None); e.empty_display_type = 'ARROWS'; e.empty_display_size = 0.05
    bpy.context.scene.collection.objects.link(e)
    e.parent = parent
    e.location = world - (parent.matrix_world.translation if parent else Vector())
    bpy.context.view_layer.update()
    return e
def mesh_at(name, world, parent):
    ob = parts[name]
    for v in ob.data.vertices: v.co -= world
    ob.parent = parent if parent is not _World else None
    ob.location = world - parent.matrix_world.translation
    ob.rotation_euler = (0, 0, 0)
    bpy.context.view_layer.update()
    return ob
# No 'robot' object in Blender: the USD exporter's root_prim_path creates the single top-level 'robot' prim
# (and puts its _materials scope under it) and carries the Y-up conversion. `body` is the top-level object.
class _World: matrix_world = __import__('mathutils').Matrix.Identity(4)
body = mesh_at('body', Vector((0, 0, 0.59)), _World)
fa = empty('face_anchor', face, body)
fa.empty_display_type = 'SINGLE_ARROW'
SLEEVE_SCALE, SLEEVE_HEIGHT = 1.15, 0.05
def make_sleeve(L, knee):
    """Cylinder ring around the knee axis (model X): radius 1.15 x half-width of the leg section."""
    sc = section[L]
    r = SLEEVE_SCALE * max(sc['wx'], sc['wy']) / 2
    h = max(SLEEVE_HEIGHT, sc['wx'] * 1.05)      # long enough to span the leg across X (a 0.05 disc would not cover the gap)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=24, radius1=r, radius2=r, depth=h)
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=__import__('mathutils').Matrix.Rotation(math.radians(90), 3, 'Y'))
    me = bpy.data.meshes.new('kneeSleeve_'+L); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new('kneeSleeve_'+L, me); bpy.context.scene.collection.objects.link(ob)
    ob.parent = knee; ob.location = (0, 0, 0)
    for p in me.polygons: p.use_smooth = len(p.vertices) == 4      # smooth barrel, crisp flat end caps
    parts['kneeSleeve_'+L] = ob
for L in LEGS:
    hip = empty('hip_'+L, piv['hip_'+L], body)
    mesh_at('upperLeg_'+L, piv['hip_'+L], hip)
    knee = empty('knee_'+L, piv['knee_'+L], hip)
    mesh_at('lowerLeg_'+L, piv['knee_'+L], knee)
    if L in ('FL', 'FR'): make_sleeve(L, knee)
    ankle = empty('ankle_'+L, piv['ankle_'+L], knee)
    mesh_at('foot_'+L, piv['ankle_'+L], ankle)

# ---- materials: one per part kind; names are the renderer's contract (it swaps in palette colours)
PALETTE = {'mat_shell': (1.0, 0.945, 0.886), 'mat_joint': (1.0, 0.498, 0.431), 'mat_limb': (1.0, 0.706, 0.561),
           'mat_foot': (0.435, 0.812, 0.690), 'mat_accent': (1.0, 0.784, 0.341)}
mats = {}
for n, c in PALETTE.items():
    m = bpy.data.materials.new(n); m.use_nodes = True
    m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (*c, 1)
    m.diffuse_color = (*c, 1); mats[n] = m
def assign(ob, mat):
    ob.data.materials.clear(); ob.data.materials.append(mats[mat])
assign(parts['body'], 'mat_shell')
for L in LEGS:
    assign(parts['upperLeg_'+L], 'mat_limb'); assign(parts['lowerLeg_'+L], 'mat_joint'); assign(parts['foot_'+L], 'mat_foot')
for L in ('FL', 'FR'): assign(parts['kneeSleeve_'+L], 'mat_joint')
# mat_accent is reserved (no visible use yet). USD only writes materials some face uses, so one 1 mm
# triangle buried inside the body carries it. Invisible, but keeps the slot in the asset.
bm = bmesh.new(); bm.from_mesh(parts['body'].data)
tri = [bm.verts.new(p) for p in ((0, 0, 0), (0.001, 0, 0), (0, 0.001, 0))]
bm.faces.new(tri).material_index = 1
bm.to_mesh(parts['body'].data); bm.free()
parts['body'].data.materials.append(mats['mat_accent'])

# USD writes every mesh object as a transform prim (the contract name) plus a child Mesh prim named after the
# mesh data. Data named '<part>_mesh' keeps contract names unique at USD level (no 'body.001', no twins).
for ob in bpy.data.objects:
    if ob.type == 'MESH': ob.data.name = ob.name + '_mesh'
bpy.context.view_layer.update()

json.dump({k: list(v) for k, v in piv.items()} | {'face_anchor': list(face), 'knee_cut_z': KNEE_CUT_Z},
          open(OUT + '/pivots.json', 'w'), indent=1)
bpy.ops.wm.save_as_mainfile(filepath=OUT + '/robot_rigged.blend')

# ---- export: Y-up. 'robot' is the only top-level prim (root_prim_path=''); joint-local axes are unchanged.
bpy.ops.object.select_all(action='DESELECT')
os.makedirs(os.path.dirname(USDZ), exist_ok=True)
bpy.ops.wm.usd_export(filepath=USDZ, selected_objects_only=False, export_materials=True, root_prim_path='/robot', xform_op_mode='TRS',
                      convert_orientation=True, export_global_up_selection='Y', export_global_forward_selection='NEGATIVE_Z')
print('DELETED-PARTS', json.dumps(deleted))
print('DONE', USDZ)
