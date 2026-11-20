# Helpers for procedural PepeHub pet rooms / pets. Exec'd inside Blender.
import bpy, bmesh, math
from mathutils import Vector, Matrix

_MATS = {}

def mat(name, color, rough=0.6, metal=0.0, emit=None, emit_strength=0.0, alpha=1.0):
    key = name
    m = bpy.data.materials.get(key)
    if m is None:
        m = bpy.data.materials.new(key)
        m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    c = (*color, 1.0) if len(color) == 3 else color
    bsdf.inputs["Base Color"].default_value = c
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit is not None:
        bsdf.inputs["Emission Color"].default_value = (*emit, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emit_strength
    if alpha < 1.0:
        bsdf.inputs["Alpha"].default_value = alpha
        try:
            m.surface_render_method = "BLENDED"
        except Exception:
            pass
    m.diffuse_color = c
    return m

def hexc(h):
    h = h.lstrip("#")
    srgb = [int(h[i:i+2], 16) / 255 for i in (0, 2, 4)]
    return tuple((v / 12.92) if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in srgb)

def M(name, h, rough=0.6, **kw):
    return mat(name, hexc(h), rough, **kw)

def coll(name, parent=None, scene=None):
    c = bpy.data.collections.get(name)
    if c is None:
        c = bpy.data.collections.new(name)
        (parent.children if parent else (scene or bpy.context.scene).collection.children).link(c)
    return c

_CTX = {"coll": None, "parent": None}

def use(collection, parent=None):
    _CTX["coll"] = collection
    _CTX["parent"] = parent

def _obj(name, me, loc, rot, m, parent=None):
    o = bpy.data.objects.new(name, me)
    _CTX["coll"].objects.link(o)
    o.location = loc
    o.rotation_euler = [math.radians(a) for a in rot]
    if m is not None:
        me.materials.append(m)
    p = parent if parent is not None else _CTX["parent"]
    if p is not None:
        o.parent = p
    return o

def empty(name, loc=(0, 0, 0), parent=None):
    o = bpy.data.objects.new(name, None)
    _CTX["coll"].objects.link(o)
    o.location = loc
    o.empty_display_size = 0.3
    if parent is not None:
        o.parent = parent
    return o

def box(name, size, loc, m, bevel=0.02, rot=(0, 0, 0), parent=None, segs=3):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    bm.to_mesh(me); bm.free()
    o = _obj(name, me, loc, rot, m, parent)
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = bevel; b.segments = segs; b.limit_method = "ANGLE"
        b.harden_normals = False
    return o

def cyl(name, r, depth, loc, m, verts=32, rot=(0, 0, 0), r2=None, bevel=0.0, parent=None, smooth=True):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=verts,
                          radius1=r, radius2=r if r2 is None else r2, depth=depth)
    bm.to_mesh(me); bm.free()
    o = _obj(name, me, loc, rot, m, parent)
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = bevel; b.segments = 3; b.limit_method = "ANGLE"
    if smooth:
        me.shade_smooth()
        try:
            me.set_sharp_from_angle(angle=math.radians(40))
        except Exception:
            pass
    return o

def ball(name, r, loc, m, scale=(1, 1, 1), rot=(0, 0, 0), parent=None, segs=32, rings=16):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r)
    bm.to_mesh(me); bm.free()
    me.shade_smooth()
    o = _obj(name, me, loc, rot, m, parent)
    o.scale = scale
    return o

def torus(name, R, r, loc, m, rot=(0, 0, 0), parent=None, seg=40, ring=16, scale=(1, 1, 1)):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    verts = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        row = []
        for j in range(ring):
            b = 2 * math.pi * j / ring
            x = (R + r * math.cos(b)) * math.cos(a)
            y = (R + r * math.cos(b)) * math.sin(a)
            z = r * math.sin(b)
            row.append(bm.verts.new((x, y, z)))
        verts.append(row)
    for i in range(seg):
        for j in range(ring):
            bm.faces.new((verts[i][j], verts[(i + 1) % seg][j],
                          verts[(i + 1) % seg][(j + 1) % ring], verts[i][(j + 1) % ring]))
    bm.normal_update()
    bm.to_mesh(me); bm.free()
    me.shade_smooth()
    o = _obj(name, me, loc, rot, m, parent)
    o.scale = scale
    return o

def cone(name, r, depth, loc, m, rot=(0, 0, 0), parent=None, verts=24, scale=(1, 1, 1)):
    o = cyl(name, r, depth, loc, m, verts=verts, rot=rot, r2=0.0, parent=parent)
    o.scale = scale
    return o

def new_scene(name):
    s = bpy.data.scenes.get(name)
    if s is None:
        s = bpy.data.scenes.new(name)
    return s

def setup_render(scene, res=(1080, 1080)):
    try:
        scene.render.engine = "BLENDER_EEVEE"
    except TypeError:
        pass
    scene.render.resolution_x, scene.render.resolution_y = res
    try:
        scene.view_settings.view_transform = "AgX"
    except TypeError:
        pass
    if scene.world is None:
        w = bpy.data.worlds.new(scene.name + "_World")
        w.use_nodes = True
        scene.world = w
    bg = next(n for n in scene.world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (0.55, 0.6, 0.7, 1)
    bg.inputs["Strength"].default_value = 0.6

def light(name, kind, loc, energy, color=(1, 0.95, 0.88), size=1.0, rot=(0, 0, 0)):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == "AREA":
        ld.size = size
    elif kind in ("POINT", "SPOT"):
        ld.shadow_soft_size = size
    o = bpy.data.objects.new(name, ld)
    _CTX["coll"].objects.link(o)
    o.location = loc
    o.rotation_euler = [math.radians(a) for a in rot]
    return o

def camera(name, loc, target, lens=45, scene=None):
    cd = bpy.data.cameras.new(name)
    cd.lens = lens
    o = bpy.data.objects.new(name, cd)
    _CTX["coll"].objects.link(o)
    o.location = loc
    d = Vector(target) - Vector(loc)
    o.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    if scene is not None:
        scene.camera = o
    return o
