# Stage 4 of the pets section: every growth model, talent clips, the face
# socket, reading glasses, the egg and rank effects. Runs headless:
#   blender -b design/pets/pets_rooms_v2.blend --python design/pets/scripts/stage4.py
# Exports to apps/pepehub/assets/pets/ and design/pets/export/. The .blend is
# not saved: this script plus rig_pet.py rebuild everything from scene "Pets".
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = [os.path.join(ROOT, "apps", "pepehub", "assets", "pets"),
       os.path.join(ROOT, "design", "pets", "export")]
ONLY = os.environ.get("PETS_ONLY")  # e.g. "cat" or "fx" to rebuild a part

sys.path.insert(0, HERE)
import rig_pet as rp

R = math.radians
HEAD_C = rp.HEAD_C

# Accessory socket in front of the eyes (glasses).
rp.SOCKETS["Socket_Face"] = ((0, -0.2, 0.49), (0, -0.2, 0.55), "Head")

# ------------------------------------------------------------- proportions

# stage -> (head centre z, head scale, feet scale xyz, body scale xyz, body lift)
STAGES = {
    "baby": None,
    "cub": ((0.57), 0.9, (1.1, 1.15, 1.6), (1.08, 1.12, 1.28), 0.03),
    "teen": (0.66, 0.84, (1.15, 1.2, 2.0), (1.12, 1.2, 1.45), 0.05),
    "adult": (0.8, 0.8, (1.2, 1.28, 2.4), (1.18, 1.3, 1.6), 0.06),
}


def stage_point(p, group, stage):
    p = Vector(p)
    s = STAGES[stage]
    if s is None:
        return p
    hz, hs, feet, body, lift = s
    if group == "head":
        return Vector((0, 0, hz)) + (p - HEAD_C) * hs
    if group == "feet":
        return Vector((p.x * feet[0], p.y * feet[1], p.z * feet[2]))
    return Vector((p.x * body[0], p.y * body[1], p.z * body[2] + lift))


rp.stage_point = lambda p, g, st: stage_point(p, g, st.split("_")[0])

# ---------------------------------------------------------------- materials


def material(name, color, emission=None, strength=2.0, rough=0.6, metal=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emission:
        b.inputs["Emission Color"].default_value = (*emission, 1)
        b.inputs["Emission Strength"].default_value = strength
    return m


def mesh_part(name, build, mat, matrix=Matrix()):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    build(bm)
    bmesh.ops.transform(bm, matrix=matrix, verts=bm.verts)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    for poly in me.polygons:
        poly.use_smooth = True
    return me


def cone(r1, r2, depth, segs=10):
    return lambda bm: bmesh.ops.create_cone(
        bm, cap_ends=True, segments=segs, radius1=r1, radius2=r2, depth=depth)


def ball(r, sub=2):
    return lambda bm: bmesh.ops.create_icosphere(bm, subdivisions=sub, radius=r)


def torus(major, minor, seg=24, ring=8):
    def build(bm):
        verts = []
        for i in range(seg):
            a = 2 * math.pi * i / seg
            row = []
            for j in range(ring):
                b = 2 * math.pi * j / ring
                r = major + minor * math.cos(b)
                row.append(bm.verts.new((r * math.cos(a), r * math.sin(a), minor * math.sin(b))))
            verts.append(row)
        for i in range(seg):
            for j in range(ring):
                bm.faces.new((verts[i][j], verts[(i + 1) % seg][j],
                              verts[(i + 1) % seg][(j + 1) % ring], verts[i][(j + 1) % ring]))
    return build


def cube(sx, sy, sz):
    def build(bm):
        bmesh.ops.create_cube(bm, size=1)
        bmesh.ops.scale(bm, vec=(sx, sy, sz), verts=bm.verts)
    return build


def at(loc, rot=(0, 0, 0), scale=(1, 1, 1)):
    return (Matrix.Translation(Vector(loc)) @ rot_m(rot) @
            Matrix.Diagonal((*scale, 1)))


def rot_m(rot):
    return (Matrix.Rotation(R(rot[2]), 4, "Z") @ Matrix.Rotation(R(rot[1]), 4, "Y")
            @ Matrix.Rotation(R(rot[0]), 4, "X"))

# -------------------------------------------------------------------- paths
# Each path: per-part vertex edits (baby coordinates, before the stage
# transform) and extra parts (name, mesh, bone).


def scale_about(c, k):
    c = Vector(c)
    if isinstance(k, (int, float)):
        k = (k, k, k)
    return lambda v: Vector((c.x + (v.x - c.x) * k[0], c.y + (v.y - c.y) * k[1],
                             c.z + (v.z - c.z) * k[2]))


def centre(me):
    n = len(me.vertices)
    return sum((v.co for v in me.vertices), Vector()) / max(n, 1)


def path_edit(species, path, part, me):
    """Changes a part of the baby mesh for an adult path, in place."""
    def apply(f):
        for v in me.vertices:
            v.co = f(v.co)
    tail = part.startswith("Tail")
    if path == "bookish" and tail:
        apply(scale_about(centre(me), 1.35))
    elif path == "night":
        if tail:
            base = Vector((0, 0.19, 0.12))
            off = (centre(me) - base) * 0.3
            apply(lambda v: v + off)
            apply(scale_about(centre(me), (0.85, 0.85, 0.85)))
        elif part in ("Body", "Belly"):
            apply(lambda v: Vector((v.x * 0.9, v.y, v.z)))
    elif path == "forest" and tail:
        apply(scale_about(centre(me), 1.45))
    elif path == "fire":
        if part.startswith(("Ear", "EarTip", "EarIn")):
            apply(scale_about((0, 0, 0.58), (1, 1, 1.0)))
            apply(lambda v: Vector((v.x, v.y, 0.58 + (v.z - 0.58) * 1.35)) if v.z > 0.58 else v)
        if part == "TailTip":
            apply(scale_about(centre(me), (1.2, 1.2, 1.6)))
    elif path == "star":
        if part.startswith(("Wing", "WingBone")):
            side = -1 if part.endswith("L") else 1
            apply(scale_about((side * 0.1, 0.12, 0.34), 1.3))
        if part.startswith("Horn"):
            apply(lambda v: Vector((v.x, v.y, 0.6 + (v.z - 0.6) * 1.6)) if v.z > 0.6 else v)
    elif path == "stone":
        if part in ("Body", "Belly") or part.startswith("BellyPlate"):
            apply(lambda v: Vector((v.x * 1.12, v.y * 1.05, v.z)))
        if part.startswith("Horn"):
            apply(scale_about(centre(me), 1.45))
        if part.startswith("Spike"):
            apply(scale_about(centre(me), 1.7))


def path_extras(species, path):
    """Extra parts for a path: (part name, mesh, bone)."""
    out = []
    if path == "bookish":
        tuft = material("PetCat_dark", (0.12, 0.12, 0.14))
        for side, x in (("L", -0.15), ("R", 0.15)):
            out.append(("Tuft" + side, mesh_part("Tuft" + side, cone(0.024, 0.0, 0.08, 8), tuft,
                                                 at((x * 1.1, 0, 0.745), (0, 14 if x > 0 else -14, 0))), "Ear" + side))
    if path == "fire":
        fire = material("PetFox_fire", (1.0, 0.35, 0.05), emission=(1.0, 0.4, 0.05), strength=3)
        out.append(("Flame", mesh_part("Flame", cone(0.05, 0.0, 0.16, 10), fire,
                                       at((0.2, 0.33, 0.66), (-15, 10, 0))), "Tail3"))
    if path == "star":
        star = material("PetDragon_star", (1.0, 0.85, 0.3), emission=(1.0, 0.8, 0.25), strength=4)
        out.append(("Star", mesh_part("Star", ball(0.04, 1), star, at((0.36, 0.38, 0.14))), "Tail3"))
    if path == "stone":
        rock = material("PetDragon_stone", (0.32, 0.3, 0.3), rough=0.95)
        for i, (y, z) in enumerate(((0.17, 0.33), (0.2, 0.25), (0.21, 0.16))):
            out.append(("Crest%d" % i, mesh_part("Crest%d" % i, cone(0.035, 0.0, 0.08, 6), rock,
                                                 at((0, y, z), (-60, 0, 0))), "Body"))
    return out


# -------------------------------------------------------------------- bake

def bake(species, stage, path=None):
    pet = rp.SPECIES[species]
    bones = rp.bones_for(species)
    src = bpy.data.collections["Pet_" + pet]
    root = bpy.data.objects[pet + "_Root"]
    key = stage if path is None else "%s_%s" % (stage, path)
    name = "Export_%s_%s" % (pet, key)
    sc = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
    for o in list(sc.collection.objects):
        bpy.data.objects.remove(o)
    bpy.context.window.scene = bpy.data.scenes["Pets"]
    dg = bpy.context.evaluated_depsgraph_get()
    inv = root.matrix_world.inverted()
    meshes = []
    for o in src.objects:
        if o.type != "MESH":
            continue
        me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
        me.transform(inv @ o.matrix_world)
        part = o.name[len(pet) + 1:]
        if path:
            path_edit(species, path, part, me)
        meshes.append((part, me, rp.bone_for(species, part)))
    if path:
        meshes += path_extras(species, path)
    parts = []
    for part, me, bone in meshes:
        grp = rp.group_of(bone, bones)
        for v in me.vertices:
            v.co = stage_point(v.co, grp, stage)
        no = bpy.data.objects.new("%s_%s_part_%s" % (pet, key, part), me)
        sc.collection.objects.link(no)
        no.vertex_groups.new(name=bone).add(range(len(me.vertices)), 1.0, "REPLACE")
        parts.append(no)
    bpy.context.window.scene = sc
    with bpy.context.temp_override(active_object=parts[0], object=parts[0],
                                   selected_editable_objects=parts):
        bpy.ops.object.join()
    body = parts[0]
    body.name = body.data.name = "%s_%s" % (pet, key)
    ad = bpy.data.armatures.new("%s_%s_Rig" % (pet, key))
    arm = bpy.data.objects.new(ad.name, ad)
    sc.collection.objects.link(arm)
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    vl.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for bn, (h, t, p) in bones.items():
        grp = rp.group_of(bn, bones)
        h2, t2 = Vector(h), Vector(t)
        if path == "star" and bn.startswith("Wing"):
            side = -1 if bn.endswith("L") else 1
            t2 = scale_about((side * 0.1, 0.12, 0.34), 1.3)(t2)
        eb = ad.edit_bones.new(bn)
        eb.head, eb.tail = stage_point(h2, grp, stage), stage_point(t2, grp, stage)
        if p:
            eb.parent = ad.edit_bones[p]
    bpy.ops.object.mode_set(mode="OBJECT")
    body.parent = arm
    body.modifiers.new("Armature", "ARMATURE").object = arm
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
    return sc, arm, body


def talent_clips(arm):
    """Clips unlocked by talents: Spin, Jump, Stretch."""
    rp.clip(arm, "Spin", 31, [
        ("Root", "rotation_euler", [(1, (0, 0, 0)), (31, (0, R(360), 0))]),
        ("Body", "scale", [(1, (1, 1, 1)), (16, (1.04, 0.95, 1.04)), (31, (1, 1, 1))]),
        ("Tail1", "rotation_euler", [(1, (0, 0, 0)), (16, (0, 0, R(35))), (31, (0, 0, 0))]),
    ], cyclic=False)
    rp.clip(arm, "Jump", 25, [
        ("Root", "location", [(1, (0, 0, 0)), (4, (0, -0.02, 0)), (12, (0, 0.38, 0)), (21, (0, 0, 0)), (25, (0, 0, 0))]),
        ("Body", "scale", [(1, (1, 1, 1)), (4, (1.08, 0.88, 1.08)), (10, (0.95, 1.1, 0.95)), (21, (1.08, 0.9, 1.08)), (25, (1, 1, 1))]),
        ("EarL", "rotation_euler", [(1, (0, 0, 0)), (12, (0, 0, R(25))), (25, (0, 0, 0))]),
        ("EarR", "rotation_euler", [(1, (0, 0, 0)), (12, (0, 0, R(-25))), (25, (0, 0, 0))]),
        ("WingL", "rotation_euler", [(1, (0, 0, 0)), (12, (0, 0, R(-40))), (25, (0, 0, 0))]),
        ("WingR", "rotation_euler", [(1, (0, 0, 0)), (12, (0, 0, R(40))), (25, (0, 0, 0))]),
    ], cyclic=False)
    rp.clip(arm, "Stretch", 49, [
        ("Body", "scale", [(1, (1, 1, 1)), (18, (0.94, 1.14, 0.94)), (34, (0.94, 1.14, 0.94)), (49, (1, 1, 1))]),
        ("Head", "rotation_euler", [(1, (0, 0, 0)), (18, (R(-18), 0, 0)), (34, (R(-18), 0, R(6))), (49, (0, 0, 0))]),
        ("Tail1", "rotation_euler", [(1, (0, 0, 0)), (18, (R(-30), 0, 0)), (34, (R(-30), 0, 0)), (49, (0, 0, 0))]),
        ("WingL", "rotation_euler", [(1, (0, 0, 0)), (18, (0, 0, R(-35))), (34, (0, 0, R(-35))), (49, (0, 0, 0))]),
        ("WingR", "rotation_euler", [(1, (0, 0, 0)), (18, (0, 0, R(35))), (34, (0, 0, R(35))), (49, (0, 0, 0))]),
    ], cyclic=False)


def export(sc, file):
    for d in OUT:
        os.makedirs(d, exist_ok=True)
        rp.export_glb(sc, os.path.join(d, file))
    print("EXPORTED", file)


PATHS = {"cat": ("bookish", "night"), "fox": ("forest", "fire"), "dragon": ("star", "stone")}


def bake_pets():
    for species in ("cat", "fox", "dragon"):
        if ONLY and ONLY not in (species, "pets"):
            continue
        jobs = [("baby", None), ("cub", None), ("teen", None)] + [("adult", p) for p in PATHS[species]]
        for stage, path in jobs:
            sc, arm, _ = bake(species, stage, path)
            rp.add_clips(arm, species)
            talent_clips(arm)
            export(sc, "%s_%s.glb" % (species, stage if path is None else "adult_" + path))

# --------------------------------------------------------------- one-offs


def scene_of(name):
    sc = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
    for o in list(sc.collection.objects):
        bpy.data.objects.remove(o)
    return sc


def add(sc, name, me):
    o = bpy.data.objects.new(name, me)
    sc.collection.objects.link(o)
    return o


def glasses():
    sc = scene_of("Acc_glasses")
    frame = material("Acc_glasses", (0.08, 0.06, 0.05), rough=0.35, metal=0.6)
    lens = material("Acc_glasses_lens", (0.75, 0.85, 0.95), rough=0.05)
    for side, x in (("L", -0.072), ("R", 0.072)):
        add(sc, "Glasses_Rim" + side, mesh_part("Rim" + side, torus(0.042, 0.007), frame,
                                                 at((x, -0.012, 0), (90, 0, 0))))
        add(sc, "Glasses_Lens" + side, mesh_part("Lens" + side, cube(0.075, 0.004, 0.075), lens,
                                                  at((x, -0.01, 0), (0, 0, 0), (1, 1, 1))))
        add(sc, "Glasses_Temple" + side, mesh_part("Temple" + side, cube(0.008, 0.2, 0.008), frame,
                                                    at((x * 1.6, 0.09, 0.01))))
    add(sc, "Glasses_Bridge", mesh_part("Bridge", cube(0.04, 0.008, 0.008), frame, at((0, -0.012, 0.012))))
    export(sc, "acc_glasses.glb")


def egg():
    """Shell (tinted per species in the app), spots and three cracks that
    appear as the egg gathers minutes."""
    sc = scene_of("Egg")
    shell = material("Egg_shell", (0.95, 0.92, 0.85), rough=0.45)
    spot = material("Egg_spot", (0.7, 0.62, 0.5), rough=0.5)
    crack = material("Egg_crack", (0.15, 0.1, 0.08), rough=0.9)
    nest = material("Egg_nest", (0.55, 0.38, 0.2), rough=0.95)
    add(sc, "Egg", mesh_part("Egg", ball(0.13, 3), shell, at((0, 0, 0.17), scale=(1, 1, 1.3))))
    for i, (a, z) in enumerate(((20, 0.22), (140, 0.12), (250, 0.26), (320, 0.1))):
        x, y = 0.128 * math.cos(R(a)), 0.128 * math.sin(R(a))
        add(sc, "Egg_Spot%d" % i, mesh_part("Spot%d" % i, ball(0.025, 1), spot, at((x, y, z), scale=(1, 1, 0.6))))
    # Zigzag cracks on the front (-Y).
    zig = [[(-0.06, 0.24), (-0.03, 0.21), (-0.05, 0.18)],
           [(0.02, 0.26), (0.05, 0.22), (0.02, 0.19), (0.06, 0.16)],
           [(-0.04, 0.14), (0.0, 0.12), (0.04, 0.15), (0.07, 0.12)]]
    for i, pts in enumerate(zig):
        def build(bm, pts=pts):
            for (x0, z0), (x1, z1) in zip(pts, pts[1:]):
                mid = Vector(((x0 + x1) / 2, 0, (z0 + z1) / 2))
                ln = math.hypot(x1 - x0, z1 - z0)
                ang = math.atan2(z1 - z0, x1 - x0)
                g = bmesh.ops.create_cube(bm, size=1)
                vs = g["verts"]
                bmesh.ops.scale(bm, vec=(ln, 0.01, 0.008), verts=vs)
                bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=Matrix.Rotation(-ang, 3, "Y"), verts=vs)
                # Sit on the shell surface.
                r = 0.13 * math.sqrt(max(0.0, 1 - ((mid.z - 0.17) / 0.169) ** 2))
                y = -math.sqrt(max(0.0, r * r - mid.x * mid.x)) - 0.003
                bmesh.ops.translate(bm, vec=(mid.x, y, mid.z), verts=vs)
        add(sc, "Crack_%d" % (i + 1), mesh_part("Crack%d" % i, build, crack))
    add(sc, "Egg_Nest", mesh_part("Nest", torus(0.12, 0.04, 24, 8), nest, at((0, 0, 0.03), scale=(1, 1, 0.7))))
    export(sc, "egg.glb")


def fx():
    """Rank effects: particles (★★) circle the pet, the aura ring (★★★)."""
    sc = scene_of("Fx_rank")
    gold = material("Fx_spark", (1.0, 0.85, 0.4), emission=(1.0, 0.8, 0.35), strength=5)
    aura = material("Fx_aura", (0.55, 0.75, 1.0), emission=(0.5, 0.7, 1.0), strength=4)
    parent = bpy.data.objects.new("Fx_Particles", None)
    sc.collection.objects.link(parent)
    for i in range(8):
        a = 2 * math.pi * i / 8
        o = add(sc, "Fx_Spark%d" % i, mesh_part("Spark%d" % i, ball(0.018 if i % 2 else 0.026, 1), gold,
                                                 at((0.42 * math.cos(a), 0.42 * math.sin(a), 0.3 + 0.18 * (i % 3) / 2))))
        o.parent = parent
    ring = bpy.data.objects.new("Fx_Aura", None)
    sc.collection.objects.link(ring)
    for i, (r, z) in enumerate(((0.46, 0.012), (0.38, 0.02))):
        o = add(sc, "Fx_AuraRing%d" % i, mesh_part("AuraRing%d" % i, torus(r, 0.012, 48, 6), aura,
                                                   at((0, 0, z), scale=(1, 1, 0.5))))
        o.parent = ring
    export(sc, "fx_rank.glb")


if __name__ == "__main__":
    if not ONLY or ONLY in ("cat", "fox", "dragon", "pets"):
        bake_pets()
    if not ONLY or ONLY == "glasses":
        glasses()
    if not ONLY or ONLY == "egg":
        egg()
    if not ONLY or ONLY == "fx":
        fx()
    print("STAGE4 DONE")
