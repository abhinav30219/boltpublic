# Usage: Blender -b --factory-startup -P poses.py -- <rig.blend> <outdir> [suffix]
# Renders the rigged model in several poses (Workbench) for eyeballing: pose_<pose>_<view>_<color|grey>.png
# Axis: +X rotation on a hip swings the foot toward +Y (BACK); negative = foot forward. Knee +X = shin folds backward.
import bpy, sys, math
from mathutils import Vector
args = sys.argv[sys.argv.index('--')+1:]
bpy.ops.wm.open_mainfile(filepath=args[0]); OUT = __import__('os').path.abspath(args[1]); SUF = args[2] if len(args) > 2 else ''
D = math.radians
O = bpy.data.objects
LEGS = ['FL', 'FR', 'BL', 'BR']
HUE = {'FL': (0.9, 0.2, 0.2), 'FR': (0.2, 0.75, 0.2), 'BL': (0.25, 0.35, 0.95), 'BR': (0.95, 0.8, 0.1)}
BR = {'upperLeg': 0.55, 'lowerLeg': 0.85, 'foot': 1.2, 'kneeSleeve': 1.5}
def colorize(mode):
    for ob in O:
        if ob.type != 'MESH' or ob.name == 'floorplane': continue
        if mode == 'grey': ob.color = (0.7, 0.7, 0.72, 1); continue
        if ob.name == 'body': ob.color = (0.55, 0.62, 0.62, 1); continue
        kind, L = ob.name.split('_'); h = HUE[L]; b = BR[kind]
        ob.color = (min(1, h[0]*b), min(1, h[1]*b), min(1, h[2]*b), 1)
BODY_REST = O['body'].location.copy()
def reset():
    for ob in O:
        if ob.type == 'EMPTY': ob.rotation_euler = (0, 0, 0)
    O['body'].location = BODY_REST
def rx(name, deg): O[name].rotation_euler = (D(deg), 0, 0)
def lowest():
    dg = bpy.context.evaluated_depsgraph_get(); m = 9
    for ob in O:
        if ob.type == 'MESH' and ob.name != 'floorplane':
            e = ob.evaluated_get(dg)
            m = min(m, min((e.matrix_world @ v.co).z for v in e.data.vertices))
    return m
def ground():
    bpy.context.view_layer.update()
    z = lowest(); O['body'].location.z -= z; bpy.context.view_layer.update()
POSES = {}
def rest(): pass
def walk():
    for L in ['FL', 'BR']:  # forward-swinging legs: foot forward (-X rot), knee bent
        rx('hip_'+L, -25); rx('knee_'+L, 30)
    for L in ['FR', 'BL']: rx('hip_'+L, 25)
def crouch():
    for L in LEGS: rx('hip_'+L, -20); rx('knee_'+L, 35)
def hop():   # celebrate: legs tucked, body lifted clear of the floor
    for L in ['FL', 'FR']: rx('hip_'+L, -35); rx('knee_'+L, 50)
    for L in ['BL', 'BR']: rx('hip_'+L, -25); rx('knee_'+L, 40)
def knee25():  # gap check: front knees at 25 deg
    for L in ['FL', 'FR']: rx('knee_'+L, 25)
def hip_fwd():  # rod check: every hip -30
    for L in LEGS: rx('hip_'+L, -30)
def hip_back():  # rod check: every hip +30
    for L in LEGS: rx('hip_'+L, 30)
POSES = dict(rest=rest, walk=walk, crouch=crouch, hop=hop, knee25=knee25, hipfwd=hip_fwd, hipback=hip_back)
LIFT = dict(hop=0.2)

sc = bpy.context.scene
sc.render.engine = 'BLENDER_WORKBENCH'
sc.display.shading.color_type = 'OBJECT'; sc.display.shading.light = 'STUDIO'; sc.display.shading.show_cavity = False
sc.render.resolution_x = 900; sc.render.resolution_y = 700
bpy.ops.mesh.primitive_plane_add(size=3, location=(0, 0, -0.002)); bpy.context.object.color = (0.9, 0.9, 0.9, 1); bpy.context.object.name = 'floorplane'
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam'))
sc.collection.objects.link(cam); sc.camera = cam
VIEWS = {'persp': ((1.5, -1.5, 1.1), None), 'side': ((3.0, 0, 0.45), 1.5)}
CLOSEUPS = {'kneeR': ((3.0, -0.36, 0.45), 0.55), 'kneeL': ((-3.0, -0.36, 0.45), 0.55)}   # front knees, ortho from each side
target = Vector((0, 0, 0.4))
for pname, fn in POSES.items():
    reset(); fn(); ground(); O['body'].location.z += LIFT.get(pname, 0); bpy.context.view_layer.update()
    for mode in ('color', 'grey'):
        colorize(mode); O['floorplane'].color = (0.93, 0.93, 0.93, 1)
        views = dict(VIEWS); views.update(CLOSEUPS if pname == 'knee25' else {})
        for vn, (pos, ortho) in views.items():
            cam.location = Vector(pos); tgt = Vector((0, pos[1], 0.45)) if vn in CLOSEUPS else target
            cam.rotation_euler = (tgt - cam.location).to_track_quat('-Z', 'Y').to_euler()
            cam.data.type = 'ORTHO' if ortho else 'PERSP'
            if ortho: cam.data.ortho_scale = ortho if vn in CLOSEUPS else 1.6
            sc.render.filepath = f"{OUT}/pose_{pname}_{vn}_{mode}{SUF}.png"; bpy.ops.render.render(write_still=True)
