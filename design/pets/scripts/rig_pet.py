# Bake a pet from scene "Pets" into one skinned mesh + armature with clips
# Idle / Happy / Eat / Sleep / Sad and accessory sockets, then export GLB.
# Usage inside Blender:
#   bake(species, stage) -> (scene, armature, mesh); add_clips(arm, species); export_glb(scene, path)
# stage "baby" keeps the modelled proportions, "cub" grows the body and legs.
import bpy, math
from mathutils import Vector

R = math.radians
HEAD_C = Vector((0, 0, 0.47))

# Sockets shared by every species (accessories attach to these joints).
SOCKETS = {
    "Socket_Head": ((0, 0, 0.64), (0, 0, 0.7), "Head"),
    "Socket_Neck": ((0, -0.02, 0.32), (0, -0.02, 0.36), "Body"),
    "Socket_Back": ((0, 0.12, 0.3), (0, 0.12, 0.34), "Body"),
}

BASE = {
    "Root": ((0, 0, 0), (0, 0, 0.1), None),
    "Body": ((0, 0.02, 0.06), (0, 0.02, 0.32), "Root"),
    "Head": ((0, 0, 0.33), (0, 0, 0.62), "Body"),
    "EarL": ((-0.12, 0, 0.6), (-0.14, 0, 0.72), "Head"),
    "EarR": ((0.12, 0, 0.6), (0.14, 0, 0.72), "Head"),
}

TAILS = {
    "cat": [(0, 0.19, 0.12), (0.06, 0.27, 0.2), (0.1, 0.29, 0.38), (0.07, 0.24, 0.52)],
    "fox": [(0.03, 0.2, 0.13), (0.14, 0.32, 0.22), (0.2, 0.36, 0.36), (0.19, 0.32, 0.56)],
    "dragon": [(0, 0.19, 0.1), (0.1, 0.32, 0.07), (0.2, 0.37, 0.08), (0.33, 0.37, 0.12)],
}

SPECIES = {"cat": "Cat", "fox": "Fox", "dragon": "Dragon"}


def bones_for(species):
    b = dict(BASE)
    t = TAILS[species]
    b["Tail1"] = (t[0], t[1], "Body")
    b["Tail2"] = (t[1], t[2], "Tail1")
    b["Tail3"] = (t[2], t[3], "Tail2")
    if species == "fox":
        b["EarL"] = ((-0.12, 0, 0.6), (-0.15, 0, 0.8), "Head")
        b["EarR"] = ((0.12, 0, 0.6), (0.15, 0, 0.8), "Head")
    if species == "dragon":
        b["EarL"] = ((-0.17, 0.02, 0.5), (-0.26, 0.02, 0.53), "Head")
        b["EarR"] = ((0.17, 0.02, 0.5), (0.26, 0.02, 0.53), "Head")
        b["WingL"] = ((-0.1, 0.12, 0.34), (-0.3, 0.2, 0.42), "Body")
        b["WingR"] = ((0.1, 0.12, 0.34), (0.3, 0.2, 0.42), "Body")
    b.update(SOCKETS)
    return b


def bone_for(species, part):
    side = "L" if part.endswith("L") else "R" if part.endswith("R") else ""
    if part.startswith(("Tail", "TailTip")):
        if part == "TailTip":
            return "Tail3"
        i = int(part[4:]) if part[4:].isdigit() else 0
        n = {"cat": 5, "fox": 4, "dragon": 4}[species]
        return ["Tail1", "Tail2", "Tail3"][min(2, i * 3 // n)]
    if part.startswith(("Foot", "PawDark")):
        return "Root"
    if part in ("Body", "Belly", "BackSpot", "Collar", "Tag", "Scarf", "ScarfEnd") or part.startswith("BellyPlate"):
        return "Body"
    if species == "dragon":
        if part.startswith(("Wing", "WingBone")):
            return "Wing" + side
        if part.startswith("EarFin"):
            return "Ear" + side
        if part.startswith("Spike"):
            return "Head" if part in ("Spike0", "Spike1") else "Body"
    if part.startswith(("Ear", "EarIn", "EarTip")) and side:
        return "Ear" + side
    return "Head"


def stage_point(p, group, stage):
    """Moves a point of the baby model into the cub proportions."""
    p = Vector(p)
    if stage == "baby":
        return p
    if group == "head":
        return Vector((0, 0.0, 0.57)) + (p - HEAD_C) * 0.9
    if group == "feet":
        return Vector((p.x * 1.1, p.y * 1.15, p.z * 1.6))
    # body, tail, wings
    return Vector((p.x * 1.08, p.y * 1.12, p.z * 1.28 + 0.03))


def group_of(bone, bones):
    while bone:
        if bone == "Head":
            return "head"
        if bone == "Root":
            return "feet"
        if bone == "Body":
            return "body"
        bone = bones[bone][2]
    return "body"


def bake(species, stage="baby"):
    pet = SPECIES[species]
    bones = bones_for(species)
    src = bpy.data.collections["Pet_" + pet]
    root = bpy.data.objects[pet + "_Root"]
    name = "Export_%s_%s" % (pet, stage)
    sc = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
    for o in list(sc.collection.objects):
        bpy.data.objects.remove(o)
    bpy.context.window.scene = bpy.data.scenes["Pets"]
    dg = bpy.context.evaluated_depsgraph_get()
    inv = root.matrix_world.inverted()
    parts = []
    for o in src.objects:
        if o.type != "MESH":
            continue
        me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
        me.transform(inv @ o.matrix_world)
        part = o.name[len(pet) + 1:]
        bone = bone_for(species, part)
        grp = group_of(bone, bones)
        if stage != "baby":
            for v in me.vertices:
                v.co = stage_point(v.co, grp, stage)
        no = bpy.data.objects.new("%s_%s_part_%s" % (pet, stage, part), me)
        sc.collection.objects.link(no)
        no.vertex_groups.new(name=bone).add(range(len(me.vertices)), 1.0, "REPLACE")
        parts.append(no)
    bpy.context.window.scene = sc
    with bpy.context.temp_override(active_object=parts[0], object=parts[0],
                                   selected_editable_objects=parts):
        bpy.ops.object.join()
    body = parts[0]
    body.name = body.data.name = "%s_%s" % (pet, stage)
    ad = bpy.data.armatures.new("%s_%s_Rig" % (pet, stage))
    arm = bpy.data.objects.new(ad.name, ad)
    sc.collection.objects.link(arm)
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    vl.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for bn, (h, t, p) in bones.items():
        grp = group_of(bn, bones)
        eb = ad.edit_bones.new(bn)
        eb.head, eb.tail = stage_point(h, grp, stage), stage_point(t, grp, stage)
        if p:
            eb.parent = ad.edit_bones[p]
    bpy.ops.object.mode_set(mode="OBJECT")
    body.parent = arm
    body.modifiers.new("Armature", "ARMATURE").object = arm
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
    return sc, arm, body


def clip(arm, name, length, keys, cyclic=True):
    """keys: list of (bone, path, [(frame, value), ...])"""
    full = arm.name.replace("_Rig", "") + "_" + name
    old = bpy.data.actions.get(full)
    if old:
        bpy.data.actions.remove(old)
    if arm.animation_data is None:
        arm.animation_data_create()
    act = bpy.data.actions.new(full)
    arm.animation_data.action = act
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0); pb.rotation_euler = (0, 0, 0); pb.scale = (1, 1, 1)
    for bone, path, pts in keys:
        if bone not in arm.pose.bones:
            continue
        pb = arm.pose.bones[bone]
        for f, v in pts:
            setattr(pb, path, v)
            pb.keyframe_insert(path, frame=f)
    act.frame_range = (1, length)
    act.use_frame_range = True
    act.use_cyclic = cyclic
    act.use_fake_user = True
    tr = arm.animation_data.nla_tracks.new()
    tr.name = name
    tr.strips.new(name, 1, act)
    tr.mute = True
    arm.animation_data.action = None
    return act


def add_clips(arm, species):
    wings = species == "dragon"
    flap = lambda s: [(f, (0, 0, R(s * (35 if i % 2 else 0)))) for i, f in enumerate((1, 4, 7, 10, 13, 16, 19, 22, 25))]
    clip(arm, "Idle", 49, [
        ("Body", "scale", [(1, (1, 1, 1)), (25, (1.03, 1.04, 1.03)), (49, (1, 1, 1))]),
        ("Head", "rotation_euler", [(1, (0, 0, R(-4))), (25, (R(-3), 0, R(4))), (49, (0, 0, R(-4)))]),
        ("Tail1", "rotation_euler", [(1, (0, 0, R(-12))), (25, (0, 0, R(12))), (49, (0, 0, R(-12)))]),
        ("Tail2", "rotation_euler", [(1, (0, 0, R(-10))), (25, (0, 0, R(10))), (49, (0, 0, R(-10)))]),
        ("EarL", "rotation_euler", [(1, (0, 0, 0)), (40, (0, 0, 0)), (43, (0, 0, R(15))), (46, (0, 0, 0))]),
        ("WingL", "rotation_euler", [(1, (0, 0, 0)), (25, (0, 0, R(-8))), (49, (0, 0, 0))]),
        ("WingR", "rotation_euler", [(1, (0, 0, 0)), (25, (0, 0, R(8))), (49, (0, 0, 0))]),
    ])
    clip(arm, "Happy", 25, [
        ("Root", "location", [(1, (0, 0, 0)), (7, (0, 0.16, 0)), (13, (0, 0, 0)), (19, (0, 0.08, 0)), (25, (0, 0, 0))]),
        ("Body", "scale", [(1, (1.05, 0.92, 1.05)), (5, (0.97, 1.06, 0.97)), (13, (1.05, 0.92, 1.05)), (25, (1, 1, 1))]),
        ("Head", "rotation_euler", [(1, (0, 0, 0)), (7, (R(-10), 0, R(8))), (19, (R(-6), 0, R(-8))), (25, (0, 0, 0))]),
        ("EarL", "rotation_euler", [(1, (0, 0, 0)), (7, (0, 0, R(20))), (13, (0, 0, 0)), (19, (0, 0, R(20))), (25, (0, 0, 0))]),
        ("EarR", "rotation_euler", [(1, (0, 0, 0)), (7, (0, 0, R(-20))), (13, (0, 0, 0)), (19, (0, 0, R(-20))), (25, (0, 0, 0))]),
        ("Tail1", "rotation_euler", [(f, (0, 0, R(25 if i % 2 else -25))) for i, f in enumerate((1, 5, 9, 13, 17, 21, 25))]),
    ] + ([("WingL", "rotation_euler", flap(-1)), ("WingR", "rotation_euler", flap(1))] if wings else []),
        cyclic=False)
    clip(arm, "Eat", 49, [
        ("Head", "rotation_euler", [(1, (0, 0, 0)), (9, (R(28), 0, 0)), (17, (R(18), 0, 0)), (25, (R(28), 0, 0)), (33, (R(18), 0, 0)), (41, (R(28), 0, 0)), (49, (0, 0, 0))]),
        ("Body", "rotation_euler", [(1, (0, 0, 0)), (9, (R(8), 0, 0)), (41, (R(8), 0, 0)), (49, (0, 0, 0))]),
        ("Tail1", "rotation_euler", [(1, (0, 0, R(-8))), (25, (0, 0, R(8))), (49, (0, 0, R(-8)))]),
    ], cyclic=False)
    clip(arm, "Sleep", 73, [
        ("Body", "scale", [(1, (1, 0.9, 1)), (37, (1.04, 0.94, 1.04)), (73, (1, 0.9, 1))]),
        ("Body", "location", [(1, (0, -0.02, 0)), (73, (0, -0.02, 0))]),
        ("Head", "rotation_euler", [(1, (R(22), 0, R(10))), (37, (R(25), 0, R(10))), (73, (R(22), 0, R(10)))]),
        ("EarL", "rotation_euler", [(1, (0, 0, R(-25))), (73, (0, 0, R(-25)))]),
        ("EarR", "rotation_euler", [(1, (0, 0, R(25))), (73, (0, 0, R(25)))]),
        ("Tail1", "rotation_euler", [(1, (0, 0, R(40))), (73, (0, 0, R(40)))]),
        ("Tail2", "rotation_euler", [(1, (R(-30), 0, R(20))), (73, (R(-30), 0, R(20)))]),
        ("WingL", "rotation_euler", [(1, (0, 0, R(20))), (73, (0, 0, R(20)))]),
        ("WingR", "rotation_euler", [(1, (0, 0, R(-20))), (73, (0, 0, R(-20)))]),
    ])
    # Hungry: slumped, head and ears down, a slow sigh.
    clip(arm, "Sad", 73, [
        ("Body", "scale", [(1, (1.02, 0.94, 1.02)), (37, (1.0, 0.92, 1.0)), (73, (1.02, 0.94, 1.02))]),
        ("Head", "rotation_euler", [(1, (R(14), 0, R(-6))), (37, (R(18), 0, R(-8))), (73, (R(14), 0, R(-6)))]),
        ("EarL", "rotation_euler", [(1, (0, 0, R(-30))), (73, (0, 0, R(-30)))]),
        ("EarR", "rotation_euler", [(1, (0, 0, R(30))), (73, (0, 0, R(30)))]),
        ("Tail1", "rotation_euler", [(1, (R(-25), 0, 0)), (73, (R(-25), 0, 0))]),
        ("WingL", "rotation_euler", [(1, (0, 0, R(15))), (73, (0, 0, R(15)))]),
        ("WingR", "rotation_euler", [(1, (0, 0, R(-15))), (73, (0, 0, R(-15)))]),
    ])


def export_glb(sc, path):
    with bpy.context.temp_override(scene=sc, view_layer=sc.view_layers[0]):
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_active_scene=True,
                                  export_animations=True, export_animation_mode="NLA_TRACKS",
                                  export_skins=True, export_apply=False, export_yup=True)
