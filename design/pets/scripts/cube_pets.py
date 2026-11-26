# Кубические питомцы (2026-11-26): свои модели в «блочном» стиле — скруглённые кубы,
# большие квадратные глаза с бликом, короткие лапки. Каждая часть жёстко привязана
# к одной кости (без весов-переходов), поэтому анимация «игрушечная», как у блочных персонажей.
#
# Контракт приложения (pet_scene.dart) соблюдён:
#   клипы    Idle Happy Eat Sleep Sad Spin Jump Stretch Wave Pet (NLA-дорожки → анимации glb)
#   сокеты   Socket_Head Socket_Face Socket_Neck Socket_Back (кости)
#   материал "<Вид>_body" — основной мех, приложение его перекрашивает
#
# Запуск в Blender:
#   exec(open(r"F:/project/PepeHub/design/pets/scripts/cube_pets.py", encoding="utf-8").read())
#   build_cube_pets()        # сцена CubePets: все виды в ряд
#   export_cube_pets()       # glb в design/pets/cube_pets/export/<вид>.glb
#   render_cube_pets()       # превью в design/pets/cube_pets/
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix, Euler

HERE = r"F:\project\PepeHub\design\pets\scripts"
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import importlib, rig_pet as rp
importlib.reload(rp)

OUT = r"F:\project\PepeHub\design\pets\cube_pets"
SCENE = "CubePets"
INK = "#2B2140"


def lin(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def material(name, hexs, rough=0.6, emit=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*lin(hexs), 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Emission Color"].default_value = (*lin(hexs), 1)
    b.inputs["Emission Strength"].default_value = emit
    m.diffuse_color = (*lin(hexs), 1)
    return m


# ------------------------------------------------------------------ стадии роста
# Малыш — большая голова и глаза, маленькое тело, коротенькие лапки, маленькие уши и хвост;
# взрослый — длиннее тело и лапы, больше уши и хвост. k — общий масштаб.
STAGES = {
    "baby":  dict(k=0.62, head=1.0,  body=(0.80, 0.70, 0.80), leg=0.55, ear=0.72, tail=0.55, eye=1.14),
    "cub":   dict(k=0.75, head=1.0,  body=(0.90, 0.85, 0.90), leg=0.78, ear=0.86, tail=0.78, eye=1.07),
    "teen":  dict(k=0.88, head=0.97, body=(1.00, 1.00, 1.00), leg=1.00, ear=1.00, tail=1.00, eye=1.00),
    "adult": dict(k=1.00, head=0.93, body=(1.06, 1.20, 1.12), leg=1.25, ear=1.12, tail=1.18, eye=0.94),
}
STAGE_ORDER = ("baby", "cub", "teen", "adult")
STAGE_DEFAULT = dict(k=1.0, head=1.0, body=(1, 1, 1), leg=1.0, ear=1.0, tail=1.0, eye=1.0)
STAGED = ("fox", "puppy", "bunny")   # виды со стадиями роста


# ------------------------------------------------------------------ сборка из блоков

class Pet:
    """Набор блоков и костей одного вида."""

    def __init__(self, key, title, stage=None):
        self.key, self.stage = key, stage
        self.title = title if stage is None else f"{title}_{stage}"
        self.st = STAGES.get(stage, STAGE_DEFAULT)
        self.E, self.T = self.st["ear"], self.st["tail"]   # множители ушей и хвоста
        self.parts = []   # (bone, mat_key, kind, args)
        self.bones = {}   # name -> (head, tail, parent, roll_vec)
        self.mats = {}    # mat_key -> (hex, rough, emit)
        self.legs = []    # (bone, x, y, width)

    def scale_all(self, k):
        """Масштабирует готового питомца целиком (стадия роста)."""
        if abs(k - 1) < 1e-6:
            return
        self.parts = [(b, m, tuple(s * k for s in size), tuple(c * k for c in center), taper,
                       tuple(x * k for x in shift), rot, None if bev is None else bev * k)
                      for b, m, size, center, taper, shift, rot, bev in self.parts]
        self.bones = {n: (h * k, t * k, par, roll) for n, (h, t, par, roll) in self.bones.items()}
        self.leg_h *= k

    def mat(self, key, hexs, rough=0.6, emit=0.0):
        self.mats[key] = (hexs, rough, emit)

    def bone(self, name, head, tail, parent=None, roll=(0, -1, 0)):
        self.bones[name] = (Vector(head), Vector(tail), parent, Vector(roll))

    def box(self, bone, mat, size, center, taper=(1, 1), shift=(0, 0), rot=(0, 0, 0), bevel=None):
        self.parts.append((bone, mat, size, center, taper, shift, rot, bevel))

    def seg(self, bone, mat, a, b, w, taper=1.0, d=None):
        """Блок от точки a до точки b (ось Z блока вдоль a→b)."""
        a, b = Vector(a), Vector(b)
        v = b - a
        rot = Vector((0, 0, 1)).rotation_difference(v.normalized()).to_euler()
        self.box(bone, mat, (w, d or w, v.length), tuple((a + b) / 2), taper=(taper, taper),
                 rot=tuple(rot))


def _add_box(bm, size, center, taper, shift, rot, bevel):
    before = set(bm.faces)
    verts = bmesh.ops.create_cube(bm, size=1.0)["verts"]
    sx, sy, sz = size
    for v in verts:
        x, y, z = v.co
        if z > 0:
            x, y = x * taper[0] + shift[0] / sx, y * taper[1] + shift[1] / sy
        v.co = Vector((x * sx, y * sy, z * sz))
    w = bevel if bevel is not None else min(sx, sy, sz) * 0.2
    if w > 0:
        edges = list({e for v in verts for e in v.link_edges})
        bmesh.ops.bevel(bm, geom=edges, offset=w, offset_type="OFFSET", segments=3,
                        profile=0.5, affect="EDGES", clamp_overlap=True)
    faces = set(bm.faces) - before
    vs = list({v for f in faces for v in f.verts})
    m = Matrix.Translation(center) @ Euler(rot).to_matrix().to_4x4()
    bmesh.ops.transform(bm, matrix=m, verts=vs)
    return faces, vs


def build_pet(p, coll, x=0.0):
    p.scale_all(p.st["k"])
    name = p.title
    for o in list(coll.objects):
        if o.name in (name, name + "_Rig"):
            bpy.data.objects.remove(o)
    # Меш
    bm = bmesh.new()
    dl = bm.verts.layers.deform.verify()
    groups = list(p.bones.keys())
    mat_keys = list(p.mats.keys())
    for bone, mk, size, center, taper, shift, rot, bevel in p.parts:
        faces, vs = _add_box(bm, size, center, taper, shift, rot, bevel)
        gi = groups.index(bone)
        for v in vs:
            v[dl][gi] = 1.0
        for f in faces:
            f.material_index = mat_keys.index(mk)
            f.smooth = True
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    try:
        me.set_sharp_from_angle(angle=math.radians(35))
    except AttributeError:
        pass
    for mk in mat_keys:
        hexs, rough, emit = p.mats[mk]
        mname = f"{name}_body" if mk == "body" else f"{name}_{mk}"
        me.materials.append(material(mname, hexs, rough, emit))
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    for g in groups:
        ob.vertex_groups.new(name=g)
    # Скелет
    ad = bpy.data.armatures.new(name + "_Rig")
    arm = bpy.data.objects.new(name + "_Rig", ad)
    coll.objects.link(arm)
    arm["species"] = p.key
    arm["stage"] = p.stage or ""
    arm["k"] = p.st["k"]
    arm["leg_h"] = p.leg_h
    vl = bpy.context.view_layer
    vl.update()
    for o in list(vl.objects):
        if o is not None:
            o.select_set(False)
    vl.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for bn, (h, t, parent, roll) in p.bones.items():
        eb = ad.edit_bones.new(bn)
        eb.head, eb.tail = h, t
        eb.align_roll(roll)
        eb.use_deform = not bn.startswith("Socket_")
    for bn, (h, t, parent, roll) in p.bones.items():
        if parent:
            ad.edit_bones[bn].parent = ad.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
    ob.parent = arm
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    arm.location.x = x
    ad.display_type = "STICK"
    arm.show_in_front = True
    return arm, ob


# ------------------------------------------------------------------ общий каркас

def base(p, *, head=(0.44, 0.38, 0.36), head_z=0.40, head_y=-0.04, body=(0.32, 0.34, 0.22),
         body_z=0.20, body_y=0.06, leg=(0.10, 0.11), leg_x=0.10, leg_y=(-0.05, 0.17),
         eye=(0.075, 0.09), eye_x=0.10, eye_z=0.41, body_mat="body", leg_mat=None,
         sock=None):
    if p.stage is not None:
        # Пропорции стадии считаются от базовых размеров (они же у видов без стадий).
        st = p.st
        hf, (b0, b1, b2), lf, ef = st["head"], st["body"], st["leg"], st["eye"]
        lh = 0.11 * lf
        leg = (0.10 * (0.85 + 0.15 * lf), lh)
        body = (0.32 * b0, 0.34 * b1, 0.22 * b2)
        body_z = lh - 0.02 + body[2] / 2
        body_y = 0.06 + (body[1] - 0.34) / 2
        head = (0.44 * hf, 0.38 * hf, 0.36 * hf)
        head_z = body_z + body[2] / 2 - 0.09 * hf + head[2] / 2
        head_y = -0.04
        leg_x = 0.10 * b0
        leg_y = (-0.05, body_y + body[1] / 2 - 0.06)
        eye = (0.075 * hf * ef, 0.09 * hf * ef)
        eye_x = 0.10 * hf
        eye_z = head_z + 0.01 * hf
    hw, hd, hh = head
    bw, bd, bh = body
    lw, lh = leg
    p.leg_h = lh
    p.body_front = body_y - bd / 2
    p.legs = [("Leg" + fb + sd, sx * leg_x, ly, lw) for sd, sx in (("L", -1), ("R", 1))
              for fb, ly in (("F", leg_y[0]), ("B", leg_y[1]))]
    front = head_y - hd / 2
    p.front, p.head_top, p.head = front, head_z + hh / 2, (hw, hd, hh, head_y, head_z)
    p.body_back = body_y + bd / 2
    p.body_top = body_z + bh / 2
    p.bone("Root", (0, 0, 0), (0, 0, 0.1))
    p.bone("Body", (0, body_y, body_z - bh / 2), (0, body_y, body_z + bh / 2), "Root")
    p.bone("Head", (0, head_y, head_z - hh / 2), (0, head_y, head_z + hh / 2), "Body")
    p.box("Body", body_mat, body, (0, body_y, body_z))
    p.box("Head", body_mat, head, (0, head_y, head_z))
    for sd, sx in (("L", -1), ("R", 1)):
        for fb, ly in (("F", leg_y[0]), ("B", leg_y[1])):
            bn = "Leg" + fb + sd
            p.bone(bn, (sx * leg_x, ly, lh + 0.02), (sx * leg_x, ly, 0.0), "Body")
            p.box(bn, leg_mat or body_mat, (lw, lw, lh + 0.03), (sx * leg_x, ly, (lh + 0.03) / 2))
        # Глаза: тёмный блок + блик. Кость глаза вертикальная — моргание = сжатие по оси кости.
        ew, eh = eye
        ec = Vector((sx * eye_x, front - 0.006, eye_z))
        p.bone("Eye" + sd, tuple(ec - Vector((0, 0, eh / 2))), tuple(ec + Vector((0, 0, eh / 2))), "Head")
        p.box("Eye" + sd, "ink", (ew, 0.024, eh), tuple(ec), bevel=0.012)
        p.box("Eye" + sd, "shine", (ew * 0.34, 0.012, eh * 0.3),
              tuple(ec + Vector((-sx * ew * 0.18, -0.012, eh * 0.2))), bevel=0.004)
    s = sock or {}
    top = head_z + hh / 2
    p.bone("Socket_Head", (0, head_y, top), (0, head_y, top + 0.06), "Head")
    fz = s.get("face_z", eye_z)
    p.bone("Socket_Face", (0, front - 0.01, fz), (0, front - 0.01, fz + 0.06), "Head")
    nz = head_z - hh / 2 + 0.02
    p.bone("Socket_Neck", (0, front + 0.06, nz), (0, front + 0.06, nz + 0.06), "Body")
    p.bone("Socket_Back", (0, body_y + bd * 0.2, body_z + bh / 2), (0, body_y + bd * 0.2, body_z + bh / 2 + 0.06), "Body")
    p.mat("ink", INK, 0.35)
    p.mat("shine", "#FFFFFF", 0.3, 0.6)


def tail(p, pts, w, mat, tip_mat=None, taper=0.85, d=None):
    """Хвост из 3 блоков по точкам pts (4 точки) с костями Tail1..3."""
    for k in range(3):
        bn = f"Tail{k + 1}"
        p.bone(bn, pts[k], pts[k + 1], "Body" if k == 0 else f"Tail{k}")
        wk = w * (taper ** k)
        p.seg(bn, tip_mat if (tip_mat and k == 2) else mat, pts[k], pts[k + 1], wk, taper=0.92,
              d=(d * taper ** k) if d else None)


def face_bits(p, nose="nose", muzzle=None, blush=True, nose_size=(0.05, 0.035), mouth=True):
    hw, hd, hh, hy, hz = p.head
    f = p.front
    if muzzle:
        mw, mh, md, mat = muzzle
        p.box("Head", mat, (mw, md, mh), (0, f - md / 2 + 0.012, hz - hh * 0.16))
        f = f - md + 0.012
    nz = hz - hh * 0.08
    p.box("Head", nose, (nose_size[0], 0.022, nose_size[1]), (0, f - 0.006, nz), bevel=0.01)
    if mouth:
        p.box("Head", "ink", (0.05, 0.012, 0.012), (0, f - 0.002, nz - 0.045), bevel=0.004)
    if blush:
        for sx in (-1, 1):
            p.box("Head", "blush", (0.06, 0.012, 0.028), (sx * hw * 0.36, p.front - 0.002, hz - hh * 0.12),
                  bevel=0.006)


def ears_pointy(p, size, x, mat, inner=None, tip=None, lean=0.0, z_off=0.0):
    hw, hd, hh, hy, hz = p.head
    top = hz + hh / 2 + z_off
    for sd, sx in (("L", -1), ("R", 1)):
        bn = "Ear" + sd
        c = Vector((sx * x, hy + 0.02, top + size[2] / 2 - 0.02))
        p.bone(bn, tuple(c - Vector((0, 0, size[2] / 2))), tuple(c + Vector((0, 0, size[2] / 2))), "Head")
        p.box(bn, mat, size, tuple(c), taper=(0.38, 0.6), shift=(-sx * lean, 0))
        if inner:
            p.box(bn, inner, (size[0] * 0.5, 0.012, size[2] * 0.62),
                  tuple(c + Vector((-sx * lean * 0.3, -size[1] / 2 - 0.002, -size[2] * 0.08))),
                  taper=(0.45, 1), bevel=0.004)
        if tip:
            # Кончик продолжает конус уха с нижней границы r0 до верха, чуть шире него.
            r0, tx, ty = 0.6, 0.38, 0.6
            wx = size[0] * (1 - (1 - tx) * r0) * 1.08
            wy = size[1] * (1 - (1 - ty) * r0) * 1.08
            h = size[2] * (1 - r0) + 0.004
            rc = (r0 + 1) / 2
            p.box(bn, tip, (wx, wy, h),
                  (c.x - sx * lean * rc, c.y, c.z - size[2] / 2 + size[2] * rc + 0.002),
                  taper=(size[0] * tx * 1.08 / wx, size[1] * ty * 1.08 / wy), bevel=min(wx, h) * 0.15)


# ------------------------------------------------------------------ виды

def cat():
    p = Pet("cat", "Cat")
    p.mat("body", "#F7AFC4"); p.mat("cream", "#FFF3EE"); p.mat("inner", "#F28FAE")
    p.mat("tip", "#86BDEB"); p.mat("nose", "#EC6F92", 0.4); p.mat("blush", "#F59BB8")
    base(p)
    ears_pointy(p, (0.13, 0.08, 0.13), 0.14, "body", inner="inner", tip="tip", lean=0.01)
    face_bits(p, muzzle=(0.17, 0.08, 0.03, "cream"))
    p.box("Body", "cream", (0.2, 0.02, 0.14), (0, p.body_back - 0.34 - 0.002, 0.2))
    by, bt = p.body_back, p.body_top
    tail(p, [(0, by - 0.02, bt - 0.04), (0, by + 0.06, bt + 0.06), (0, by + 0.08, bt + 0.17),
             (0, by + 0.05, bt + 0.26)], 0.065, "body", tip_mat="tip", taper=1.0)
    return p


def _tail_pts(p, offs):
    """Точки хвоста: смещения от верха-зада тела, растянутые множителем стадии."""
    by, bt = p.body_back, p.body_top
    return [(0, by + dy * p.T, bt + dz * p.T) for dy, dz in offs]


def fox(stage=None):
    p = Pet("fox", "Fox", stage)
    p.mat("body", "#F08A45"); p.mat("cream", "#FFF1E3"); p.mat("dark", "#4A3530")
    p.mat("inner", "#FFD3B8"); p.mat("nose", INK, 0.35); p.mat("blush", "#F7A08E")
    base(p, leg_mat="body")
    hw, hd, hh, hy, hz = p.head
    ears_pointy(p, (0.13 * hw / 0.44, 0.08, 0.17 * p.E), 0.14 * hw / 0.44, "body", inner="inner",
                tip="dark", lean=0.015 * p.E)
    for sx in (-1, 1):   # белые щёки
        p.box("Head", "cream", (0.34 * hw, 0.03, 0.33 * hh), (sx * 0.3 * hw, p.front + 0.008, hz - hh * 0.22))
    face_bits(p, muzzle=(0.16, 0.07, 0.04, "cream"), blush=stage in ("baby", "cub"))
    for bn, x, y, lw in p.legs:   # тёмные «носочки»
        p.box(bn, "dark", (lw + 0.004, lw + 0.004, 0.045), (x, y, 0.022))
    tail(p, _tail_pts(p, [(-0.03, -0.06), (0.09, 0.0), (0.17, 0.10), (0.2, 0.22)]),
         0.13 * p.T ** 0.5, "body", tip_mat="cream", taper=1.0)
    return p


def dragon():
    p = Pet("dragon", "Dragon")
    p.mat("body", "#86D3BC"); p.mat("cream", "#F6E7BE"); p.mat("horn", "#FBEBC4")
    p.mat("wing", "#B9A3EA"); p.mat("spike", "#8E76C2"); p.mat("nose", "#4E8C79", 0.4)
    p.mat("blush", "#F4A9C0")
    base(p)
    hw, hd, hh, hy, hz = p.head
    top = hz + hh / 2
    for sd, sx in (("L", -1), ("R", 1)):   # рожки — «уши» (кости EarL/R)
        bn = "Ear" + sd
        c = Vector((sx * 0.12, hy + 0.06, top + 0.05))
        p.bone(bn, tuple(c - Vector((0, 0, 0.06))), tuple(c + Vector((0, 0, 0.06))), "Head")
        p.box(bn, "horn", (0.06, 0.06, 0.12), tuple(c), taper=(0.35, 0.35), shift=(0, 0.035))
        p.box("Head", "spike", (0.03, 0.09, 0.08), (sx * (hw / 2 + 0.01), hy + 0.04, hz + 0.02),
              taper=(0.6, 0.4), shift=(0, 0.02))
        # крылья
        bn = "Wing" + sd
        sh = Vector((sx * 0.13, 0.12, 0.30))
        tp = Vector((sx * 0.34, 0.16, 0.40))
        p.bone(bn, tuple(sh), tuple(tp), "Body", roll=(0, 0, 1))
        p.box(bn, "wing", (0.22, 0.025, 0.15), tuple((sh + tp) / 2 + Vector((0, 0, 0.02))),
              taper=(0.7, 1), rot=(0, -sx * math.radians(25), 0), bevel=0.008)
    face_bits(p, muzzle=(0.2, 0.08, 0.035, "body"), nose="nose", nose_size=(0.035, 0.02), mouth=True)
    p.box("Body", "cream", (0.2, 0.02, 0.16), (0, p.body_back - 0.34 - 0.002, 0.2))
    for k in range(3):   # гребень на спине
        p.box("Body", "spike", (0.04, 0.06, 0.06), (0, 0.0 + k * 0.08, p.body_top + 0.025), taper=(0.4, 0.4))
    by, bt = p.body_back, p.body_top
    tail(p, [(0, by - 0.04, 0.17), (0, by + 0.09, 0.15), (0, by + 0.2, 0.17), (0, by + 0.28, 0.25)],
         0.11, "body", taper=0.78)
    p.box("Tail3", "spike", (0.05, 0.07, 0.07), (0, by + 0.28, 0.28), taper=(0.4, 0.4))
    return p


def bunny(stage=None):
    p = Pet("bunny", "Bunny", stage)
    p.mat("body", "#F6F1EC"); p.mat("inner", "#F7A9BF"); p.mat("nose", "#EF7FA0", 0.4)
    p.mat("blush", "#F8B3C6"); p.mat("tooth", "#FFFFFF")
    base(p)
    hw, hd, hh, hy, hz = p.head
    top = hz + hh / 2
    eh = 0.27 * p.E          # у малыша ушки короче и чуть разведены
    for sd, sx in (("L", -1), ("R", 1)):
        bn = "Ear" + sd
        c = Vector((sx * 0.1 * hw / 0.44, hy + 0.04, top + eh / 2 - 0.015))
        p.bone(bn, tuple(c - Vector((0, 0, eh / 2))), tuple(c + Vector((0, 0, eh / 2))), "Head")
        p.box(bn, "body", (0.085, 0.05, eh), tuple(c), taper=(0.9, 0.9))
        p.box(bn, "inner", (0.045, 0.012, eh * 0.7), tuple(c + Vector((0, -0.027, 0.01 * p.E))), bevel=0.004)
    face_bits(p, nose_size=(0.045, 0.03))
    if stage != "baby":
        p.box("Head", "tooth", (0.04, 0.012, 0.03), (0, p.front - 0.004, hz - hh * 0.25), bevel=0.004)
    by = p.body_back
    tz = p.body_top - 0.07
    ts = 0.11 * p.T ** 0.5
    p.bone("Tail1", (0, by, tz), (0, by + 0.08, tz + 0.02), "Body")
    p.box("Tail1", "body", (ts, ts * 0.9, ts), (0, by + 0.03, tz + 0.01))
    return p


def puppy(stage=None):
    p = Pet("puppy", "Puppy", stage)
    p.mat("body", "#DCA46B"); p.mat("cream", "#FFF0DC"); p.mat("ear", "#8A5A3C")
    p.mat("nose", INK, 0.35); p.mat("blush", "#F3A08E"); p.mat("tongue", "#F27C93")
    base(p)
    hw, hd, hh, hy, hz = p.head
    el = 0.2 * p.E
    for sd, sx in (("L", -1), ("R", 1)):   # висячие уши
        bn = "Ear" + sd
        tp = Vector((sx * (hw / 2 + 0.03), hy - 0.02, hz + hh / 2 - 0.02))
        bt_ = tp - Vector((0, 0, el))
        p.bone(bn, tuple(tp), tuple(bt_), "Head")
        p.box(bn, "ear", (0.07, 0.13 * hd / 0.38, el), tuple((tp + bt_) / 2), taper=(1, 0.85))
    p.box("Head", "ear", (0.36 * hw, 0.02, 0.33 * hh), (-0.23 * hw, p.front - 0.002, hz + 0.05 * hh / 0.36),
          bevel=0.008)  # пятно у глаза
    face_bits(p, muzzle=(0.2, 0.1, 0.06, "cream"), nose_size=(0.07, 0.045))
    if stage not in ("baby",):
        p.box("Head", "tongue", (0.045, 0.02, 0.04), (0, p.front - 0.065, hz - hh * 0.33), bevel=0.008)
    tail(p, _tail_pts(p, [(-0.02, -0.04), (0.04, 0.04), (0.06, 0.11), (0.05, 0.17)]),
         0.06 * p.T ** 0.5, "body", taper=0.9)
    return p


def chick():
    p = Pet("chick", "Chick")
    p.mat("body", "#FFD34D"); p.mat("beak", "#FF9A3C", 0.45); p.mat("leg", "#F08A2E")
    p.mat("blush", "#FFA7A0"); p.mat("nose", "#FF9A3C")
    base(p, head=(0.42, 0.4, 0.38), head_z=0.36, head_y=0.0, body=(0.34, 0.34, 0.2), body_z=0.18,
         body_y=0.04, leg=(0.04, 0.09), leg_x=0.08, leg_y=(0.02, 0.02), leg_mat="leg", eye_z=0.4,
         eye=(0.07, 0.085))
    # у цыплёнка лапы попарно: задние прячем внутрь тела
    p.parts = [pt for pt in p.parts if not pt[0].startswith("LegB")]
    for sx in (-1, 1):
        p.box("LegF" + ("L" if sx < 0 else "R"), "leg", (0.08, 0.1, 0.02), (sx * 0.08, -0.01, 0.01), bevel=0.006)
    hw, hd, hh, hy, hz = p.head
    p.box("Head", "beak", (0.1, 0.07, 0.05), (0, p.front - 0.03, hz - 0.01), taper=(0.6, 0.6))
    p.box("Head", "blush", (0.05, 0.012, 0.025), (-0.14, p.front - 0.002, hz - 0.03), bevel=0.006)
    p.box("Head", "blush", (0.05, 0.012, 0.025), (0.14, p.front - 0.002, hz - 0.03), bevel=0.006)
    top = hz + hh / 2
    for sd, sx, h in (("L", -1, 0.09), ("R", 1, 0.07)):   # хохолок — «уши»
        bn = "Ear" + sd
        c = Vector((sx * 0.025, hy, top + h / 2 - 0.01))
        p.bone(bn, tuple(c - Vector((0, 0, h / 2))), tuple(c + Vector((0, 0, h / 2))), "Head")
        p.box(bn, "body", (0.04, 0.05, h), tuple(c), taper=(0.5, 0.6), shift=(sx * 0.02, 0.01))
    for sd, sx in (("L", -1), ("R", 1)):   # крылышки
        bn = "Wing" + sd
        sh = Vector((sx * (hw / 2 - 0.01), 0.04, 0.3))
        tp = Vector((sx * (hw / 2 + 0.05), 0.06, 0.2))
        p.bone(bn, tuple(sh), tuple(tp), "Body", roll=(0, 0, 1))
        p.box(bn, "body", (0.06, 0.14, 0.13), tuple((sh + tp) / 2), taper=(1, 0.7))
    p.bone("Tail1", (0, 0.2, 0.25), (0, 0.27, 0.32), "Body")
    p.box("Tail1", "body", (0.1, 0.06, 0.08), (0, 0.22, 0.28), taper=(0.5, 0.6))
    return p


def panda():
    p = Pet("panda", "Panda")
    p.mat("body", "#F7F5F2"); p.mat("black", "#34303A"); p.mat("nose", INK, 0.35)
    p.mat("blush", "#F6B0C2")
    base(p, leg_mat="black")
    hw, hd, hh, hy, hz = p.head
    p.parts = [pt for pt in p.parts if not (pt[0] == "Body" and pt[1] == "body")]
    p.box("Body", "black", (0.32, 0.34, 0.22), (0, 0.06, 0.2))
    p.box("Body", "body", (0.34, 0.2, 0.1), (0, 0.13, 0.27))       # белая спинка
    top = hz + hh / 2
    for sd, sx in (("L", -1), ("R", 1)):
        bn = "Ear" + sd
        c = Vector((sx * 0.15, hy + 0.04, top + 0.03))
        p.bone(bn, tuple(c - Vector((0, 0, 0.05))), tuple(c + Vector((0, 0, 0.05))), "Head")
        p.box(bn, "black", (0.11, 0.07, 0.1), tuple(c))
        p.box("Head", "black", (0.12, 0.014, 0.13), (sx * 0.1, p.front - 0.001, 0.405), bevel=0.012)
    face_bits(p, nose_size=(0.06, 0.035))
    by = p.body_back
    p.bone("Tail1", (0, by, 0.22), (0, by + 0.06, 0.24), "Body")
    p.box("Tail1", "body", (0.08, 0.07, 0.08), (0, by + 0.02, 0.23))
    return p


def frog():
    p = Pet("frog", "Frog")
    p.mat("body", "#86CF78"); p.mat("belly", "#E9F5C9"); p.mat("nose", "#4F8F49")
    p.mat("blush", "#F7A3B5"); p.mat("tongue", "#F27C93")
    base(p, head=(0.5, 0.38, 0.26), head_z=0.33, head_y=-0.02, eye_z=0.5, eye_x=0.14,
         eye=(0.07, 0.07), body=(0.36, 0.34, 0.18), body_z=0.17, leg=(0.11, 0.09), leg_x=0.13)
    hw, hd, hh, hy, hz = p.head
    # Глаза на «бугорках» — бугорки висят на костях EarL/R; переносим глаза вперёд бугорков.
    for sd, sx in (("L", -1), ("R", 1)):
        bn = "Ear" + sd
        c = Vector((sx * 0.14, hy - 0.06, hz + hh / 2 + 0.04))
        p.bone(bn, tuple(c - Vector((0, 0, 0.06))), tuple(c + Vector((0, 0, 0.06))), "Head")
        p.box(bn, "body", (0.15, 0.13, 0.13), tuple(c))
    p.parts = [pt for pt in p.parts if not pt[0].startswith("Eye")]
    for sd, sx in (("L", -1), ("R", 1)):
        ec = Vector((sx * 0.14, hy - 0.06 - 0.065 - 0.006, hz + hh / 2 + 0.045))
        p.bones["Eye" + sd] = (ec - Vector((0, 0, 0.035)), ec + Vector((0, 0, 0.035)), "Ear" + sd, Vector((0, -1, 0)))
        p.box("Eye" + sd, "ink", (0.07, 0.024, 0.07), tuple(ec), bevel=0.012)
        p.box("Eye" + sd, "shine", (0.024, 0.012, 0.022), tuple(ec + Vector((-sx * 0.013, -0.012, 0.014))), bevel=0.004)
    p.box("Head", "ink", (0.24, 0.012, 0.014), (0, p.front - 0.002, hz - 0.04), bevel=0.005)
    for sx in (-1, 1):
        p.box("Head", "blush", (0.06, 0.012, 0.03), (sx * 0.17, p.front - 0.002, hz - 0.01), bevel=0.006)
    p.box("Body", "belly", (0.24, 0.02, 0.13), (0, p.body_back - 0.34 - 0.002, 0.17))
    return p


SPECIES = [cat, fox, dragon, bunny, puppy, chick, panda, frog]


# ------------------------------------------------------------------ анимации

def _at(keys, f):
    if f <= keys[0][0]:
        return keys[0][1]
    for (f0, v0), (f1, v1) in zip(keys, keys[1:]):
        if f0 <= f <= f1:
            t = (f - f0) / max(f1 - f0, 1e-9)
            t = t * t * (3 - 2 * t)
            return v0 + (v1 - v0) * t
    return keys[-1][1]


def wave(length, amp, period, phase=0.0, step=4, base=0.0):
    fs = list(range(1, length + 1, step))
    if fs[-1] != length:
        fs.append(length)
    return [(f, base + amp * math.sin(2 * math.pi * (f - 1) / period + phase)) for f in fs]


class Clip:
    """Каналы задаются по осям кости: rot — градусы, loc — метры (ось Y кости = «вверх»
    для вертикальных костей), scl — множитель. Повороты: +X — кончик кости вперёд,
    +Z — кончик к -X мира (у вертикальных костей), Y — поворот вокруг кости."""

    def __init__(self, arm, name, length, cyclic=True):
        self.arm, self.name, self.length, self.cyclic = arm, name, length, cyclic
        self.tracks = {}

    def _add(self, bone, path, axes, keys):
        for a in axes:
            self.tracks.setdefault((bone, path), []).append(("XYZ".index(a), keys))
        return self

    def rot(self, bone, axis, keys):
        return self._add(bone, "rotation_euler", axis, [(f, math.radians(v)) for f, v in keys])

    def loc(self, bone, axis, keys):
        return self._add(bone, "location", axis, keys)

    def scl(self, bone, axes, keys):
        return self._add(bone, "scale", axes, keys)

    def both(self, prefix, axis, keys, mirror_z=False, kind="rot"):
        for sd, sg in (("L", 1), ("R", -1)):
            ks = [(f, v * sg) for f, v in keys] if mirror_z else keys
            getattr(self, kind)(prefix + sd, axis, ks)
        return self

    def write(self):
        out = []
        for (bone, path), comps in self.tracks.items():
            if bone not in self.arm.pose.bones:
                continue
            frames = sorted({f for _, ks in comps for f, _ in ks} | {1, self.length})
            keys = []
            for f in frames:
                v = [1.0, 1.0, 1.0] if path == "scale" else [0.0, 0.0, 0.0]
                for ax, ks in comps:
                    if path == "scale":
                        v[ax] *= _at(ks, f)
                    else:
                        v[ax] += _at(ks, f)
                keys.append((f, tuple(v)))
            out.append((bone, path, keys))
        return rp.clip(self.arm, self.name, self.length, out, cyclic=self.cyclic)


LEGS = ("LegFL", "LegFR", "LegBL", "LegBR")


def blink(c, spans, length, closed=0.12):
    pts = {1: 1.0, length: 1.0}
    for a, b in spans:
        pts[max(1, a - 2)] = 1.0
        pts[a] = closed
        pts[b] = closed
        pts[min(length, b + 2)] = 1.0
    ks = sorted(pts.items())
    c.both("Eye", "Y", ks, kind="scl")


def tail_wag(c, length, amp, period, curl=0.0):
    for k in range(3):
        c.rot(f"Tail{k + 1}", "Z", wave(length, amp * (0.7 + 0.2 * k), period, phase=-0.8 * k))
        if curl:
            c.rot(f"Tail{k + 1}", "X", [(1, curl), (length, curl)])


def wings(c, length, amp, period, base=0.0):
    c.rot("WingL", "X", wave(length, amp, period, base=base))
    c.rot("WingR", "X", wave(length, amp, period, base=base))


def add_clips(arm):
    K = arm.get("k", 1.0)

    def m(keys):          # метры анимации — под размер стадии
        return [(f, v * K) for f, v in keys]

    # Idle: дыхание, взгляды по сторонам, хвост, подёргивание уха, два моргания.
    c = Clip(arm, "Idle", 96)
    c.scl("Body", "XZ", wave(96, 0.02, 48, step=6, base=1.0))
    c.scl("Body", "Y", wave(96, -0.015, 48, step=6, base=1.0))
    c.rot("Head", "X", wave(96, 3, 96, step=6))
    c.rot("Head", "Y", [(1, 0), (20, 0), (28, 14), (42, 14), (50, 0), (60, -12), (72, -12), (80, 0), (96, 0)])
    tail_wag(c, 96, 10, 48)
    c.rot("EarL", "Z", [(1, 0), (54, 0), (57, 14), (60, 0), (96, 0)])
    wings(c, 96, 6, 48)
    blink(c, [(34, 36), (86, 88)], 96)
    c.write()
    # Happy: два прыжка с лапками вверх, глаза ^^, быстрый хвост.
    c = Clip(arm, "Happy", 36, cyclic=False)
    c.loc("Root", "Y", m([(1, 0), (4, -0.01), (9, 0.12), (15, 0), (20, 0.08), (26, 0), (36, 0)]))
    c.scl("Body", "XZ", [(1, 1), (4, 1.08), (9, 0.95), (15, 1.08), (20, 0.97), (26, 1.04), (32, 1)])
    c.scl("Body", "Y", [(1, 1), (4, 0.88), (9, 1.08), (15, 0.9), (20, 1.05), (26, 0.95), (32, 1)])
    c.both("LegF", "X", [(1, 0), (6, 100), (12, 85), (18, 100), (24, 85), (31, 0), (36, 0)])
    c.both("Ear", "Z", [(1, 0), (7, 14), (13, 0), (19, 14), (26, 0), (36, 0)], mirror_z=True)
    c.rot("Head", "Z", [(1, 0), (8, 8), (19, -8), (30, 0), (36, 0)])
    tail_wag(c, 36, 28, 8)
    wings(c, 36, 30, 6, base=10)
    c.both("Eye", "XY", [(1, 1), (5, 1.18), (30, 1.18), (34, 1), (36, 1)], kind="scl")
    c.write()
    # Eat: наклоны к миске и жевание.
    c = Clip(arm, "Eat", 48, cyclic=False)
    c.rot("Head", "X", [(1, 0), (8, 24), (14, 16), (20, 24), (26, 16), (32, 24), (38, 16), (44, 0), (48, 0)])
    c.rot("Body", "X", [(1, 0), (8, 6), (40, 6), (46, 0), (48, 0)])
    c.scl("Head", "Y", [(1, 1), (11, 0.94), (14, 1), (17, 0.94), (20, 1), (23, 0.94), (26, 1), (29, 0.94), (32, 1), (48, 1)])
    tail_wag(c, 48, 14, 12)
    c.write()
    # Sleep: лапы поджаты, голова опущена, глаза закрыты, медленное дыхание.
    c = Clip(arm, "Sleep", 96)
    drop = -arm.get("leg_h", 0.11) * 0.82
    c.loc("Root", "Y", [(1, drop), (96, drop)])
    for lg in LEGS:
        sg = 1 if lg.startswith("LegF") else -1
        c.rot(lg, "X", [(1, 85 * sg), (96, 85 * sg)])
    c.rot("Head", "X", [(f, 14 + v) for f, v in wave(96, 2.5, 96, step=8)])
    c.scl("Body", "XZ", wave(96, 0.03, 48, step=6, base=1.0))
    c.both("Eye", "Y", [(1, 0.1), (96, 0.1)], kind="scl")
    c.both("Ear", "Z", [(1, 12), (96, 12)], mirror_z=True)
    tail_wag(c, 96, 3, 96, curl=-10)
    wings(c, 96, 2, 96, base=-15)
    c.write()
    # Sad: голова вниз, уши опущены, хвост висит, глаза полуприкрыты.
    c = Clip(arm, "Sad", 72)
    c.rot("Head", "X", [(f, 18 + v) for f, v in wave(72, 2, 72, step=8)])
    c.rot("Head", "Z", wave(72, 4, 72, step=8))
    c.both("Ear", "Z", [(1, 30), (72, 30)], mirror_z=True)
    c.both("Ear", "X", [(1, -15), (72, -15)])
    c.both("Eye", "Y", [(1, 0.6), (72, 0.6)], kind="scl")
    tail_wag(c, 72, 4, 72, curl=25)
    wings(c, 72, 2, 72, base=-20)
    c.write()
    # Spin: прыжок с оборотом.
    c = Clip(arm, "Spin", 36, cyclic=False)
    c.rot("Root", "Y", [(1, 0), (6, 0), (26, 360), (36, 360)])
    c.loc("Root", "Y", m([(1, 0), (5, -0.02), (14, 0.14), (24, 0), (28, 0), (36, 0)]))
    c.scl("Body", "Y", [(1, 1), (5, 0.88), (12, 1.08), (24, 0.9), (30, 1), (36, 1)])
    tail_wag(c, 36, 20, 9)
    wings(c, 36, 25, 6, base=10)
    c.write()
    # Jump: присел — высокий прыжок — приземление.
    c = Clip(arm, "Jump", 40, cyclic=False)
    c.loc("Root", "Y", m([(1, 0), (8, -0.04), (12, 0.05), (19, 0.3), (26, 0.05), (29, -0.03), (34, 0), (40, 0)]))
    c.scl("Body", "Y", [(1, 1), (8, 0.84), (13, 1.12), (20, 1.0), (28, 0.86), (34, 1.03), (40, 1)])
    c.scl("Body", "XZ", [(1, 1), (8, 1.1), (13, 0.94), (20, 1.0), (28, 1.1), (34, 0.98), (40, 1)])
    c.both("LegF", "X", [(1, 0), (13, -25), (19, 30), (27, 0), (40, 0)])
    c.both("LegB", "X", [(1, 0), (13, 25), (19, -30), (27, 0), (40, 0)])
    c.both("Ear", "X", [(1, 0), (12, -20), (19, 10), (29, -15), (36, 0), (40, 0)])
    wings(c, 40, 30, 8, base=15)
    c.write()
    # Stretch: «поклон» — передние лапы вперёд, попа вверх, зевок (глаза закрыты).
    c = Clip(arm, "Stretch", 60, cyclic=False)
    c.rot("Body", "X", [(1, 0), (14, 22), (40, 22), (54, 0), (60, 0)])
    c.rot("Head", "X", [(1, 0), (14, -26), (40, -26), (54, 0), (60, 0)])
    c.both("LegF", "X", [(1, 0), (14, 45), (40, 45), (54, 0), (60, 0)])
    c.both("LegB", "X", [(1, 0), (14, -20), (40, -20), (54, 0), (60, 0)])
    c.both("Eye", "Y", [(1, 1), (16, 1), (20, 0.12), (38, 0.12), (42, 1), (60, 1)], kind="scl")
    tail_wag(c, 60, 6, 30, curl=-20)
    c.write()
    # Wave: правая лапка машет.
    c = Clip(arm, "Wave", 40, cyclic=False)
    # Лапа выносится вперёд-вбок (иначе её закрывает большая голова), потом машет.
    c.loc("LegFR", "X", m([(1, 0), (8, -0.1), (34, -0.1), (40, 0)]))
    c.loc("LegFR", "Y", m([(1, 0), (8, -0.14), (34, -0.14), (40, 0)]))
    c.loc("LegFR", "Z", m([(1, 0), (8, 0.17), (34, 0.17), (40, 0)]))
    c.rot("LegFR", "X", [(1, 0), (8, 165), (34, 165), (40, 0)])
    c.rot("LegFR", "Z", [(1, 0), (8, 0), (13, -25), (18, 15), (23, -25), (28, 15), (34, 0), (40, 0)])
    c.rot("Body", "Z", [(1, 0), (8, -6), (34, -6), (40, 0)])
    c.rot("Head", "Z", [(1, 0), (8, 8), (34, 8), (40, 0)])
    c.both("Eye", "XY", [(1, 1), (6, 1.12), (34, 1.12), (38, 1), (40, 1)], kind="scl")
    tail_wag(c, 40, 16, 10)
    c.write()
    # Pet: жмурится, трётся головой, уши прижаты, хвост виляет.
    c = Clip(arm, "Pet", 48, cyclic=False)
    c.rot("Head", "Z", [(1, 0), (10, 12), (22, -6), (34, 12), (44, 0), (48, 0)])
    c.rot("Head", "X", [(1, 0), (8, -8), (40, -8), (48, 0)])
    c.both("Ear", "X", [(1, 0), (6, -22), (42, -22), (48, 0)])
    c.both("Eye", "Y", [(1, 1), (5, 0.25), (42, 0.25), (47, 1), (48, 1)], kind="scl")
    c.scl("Body", "Y", [(1, 1), (10, 0.95), (22, 1.0), (34, 0.95), (46, 1), (48, 1)])
    tail_wag(c, 48, 18, 12)
    c.write()
    arm.animation_data.action = None


# ------------------------------------------------------------------ сцена, экспорт, рендер

SCENE_STAGES = "CubePets_Stages"


def _scene(name):
    sc = bpy.data.scenes.get(name)
    if sc is None:
        sc = bpy.data.scenes.new(name)
    win = bpy.context.window or bpy.context.window_manager.windows[0]
    win.scene = sc
    return sc


def _studio(sc, width, depth=0.0, res=(1920, 620)):
    tag = sc.name
    coll = bpy.data.collections.get(tag + "_Studio")
    if coll is None:
        coll = bpy.data.collections.new(tag + "_Studio")
        sc.collection.children.link(coll)
    for o in list(coll.objects):
        bpy.data.objects.remove(o)
    floor_m = material("cp_floor", "#F3E9F6", 0.9)
    me = bpy.data.meshes.new(tag + "_Floor")
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=20)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(floor_m)
    fl = bpy.data.objects.new(tag + "_Floor", me)
    coll.objects.link(fl)
    cy = depth / 2
    cam = bpy.data.objects.new(tag + "_Cam", bpy.data.cameras.new(tag + "_Cam"))
    cam.data.lens = 36
    dist = max(width * 0.95, 4.0) + 1.6
    cam.location = (width / 2, cy - dist, 0.55 + dist * 0.15)
    cam.rotation_euler = (math.radians(81.5), 0, 0)
    coll.objects.link(cam)
    sc.camera = cam
    key = bpy.data.objects.new(tag + "_Key", bpy.data.lights.new(tag + "_Key", "AREA"))
    key.data.energy = 900; key.data.size = 5; key.data.color = (1.0, 0.96, 0.92)
    key.location = (width / 2 - 2.5, cy - 4.0, 4.5)
    key.rotation_euler = (math.radians(45), 0, math.radians(-30))
    coll.objects.link(key)
    rim = bpy.data.objects.new(tag + "_Rim", bpy.data.lights.new(tag + "_Rim", "AREA"))
    rim.data.energy = 400; rim.data.size = 4; rim.data.color = (0.9, 0.9, 1.0)
    rim.location = (width / 2 + 3, cy + 3.0, 3.5)
    rim.rotation_euler = (math.radians(-50), 0, math.radians(140))
    coll.objects.link(rim)
    w = bpy.data.worlds.get("CP_World") or bpy.data.worlds.new("CP_World")
    sc.world = w
    w.use_nodes = True
    bg = next(n for n in w.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (*lin("#F7EEF7"), 1)
    bg.inputs["Strength"].default_value = 0.8
    sc.render.resolution_x, sc.render.resolution_y = res
    try:
        sc.view_settings.view_transform = "AgX"
    except TypeError:
        pass


def _pets_coll(sc, name):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
        sc.collection.children.link(coll)
    return coll


def build_cube_pets():
    """CubePets — виды без стадий; CubePets_Stages — лиса, щенок, кролик по стадиям роста."""
    made = []
    sc = _scene(SCENE)
    coll = _pets_coll(sc, "CP_Pets")
    for o in list(coll.objects):          # старые модели видов, у которых теперь есть стадии
        if o.get("species", "") in STAGED or o.name.split("_")[0].lower() in STAGED:
            bpy.data.objects.remove(o)
    plain = [fn for fn in SPECIES if fn.__name__ not in STAGED]
    for i, fn in enumerate(plain):
        arm, ob = build_pet(fn(), coll, x=i * 0.85)
        add_clips(arm)
        made.append(arm)
    _studio(sc, (len(plain) - 1) * 0.85, res=(1600, 620))
    sc = _scene(SCENE_STAGES)
    coll = _pets_coll(sc, "CP_Stages")
    for row, key in enumerate(STAGED):
        fn = next(f for f in SPECIES if f.__name__ == key)
        for col, stg in enumerate(STAGE_ORDER):
            arm, ob = build_pet(fn(stg), coll, x=col * 0.9)
            arm.location.y = row * 1.2
            add_clips(arm)
            made.append(arm)
    _studio(sc, 3 * 0.9, depth=2.2, res=(1400, 1000))
    cam = sc.camera
    cam.location = (1.35, -2.7, 2.35)
    cam.data.lens = 32
    cam.rotation_euler = (math.radians(61), 0, 0)
    return made


def _rigs(scene_name):
    sc = bpy.data.scenes.get(scene_name)
    return [o for o in sc.objects if o.type == "ARMATURE"] if sc else []


def pose_all(clip, frame, scene_name=SCENE):
    """Ставит всем питомцам сцены клип (по имени действия) и кадр — для превью."""
    sc = bpy.data.scenes[scene_name]
    for arm in _rigs(scene_name):
        act = bpy.data.actions.get(arm.name.replace("_Rig", "") + "_" + clip)
        arm.animation_data.action = act
        if act is not None:
            try:
                arm.animation_data.action_slot = act.slots[0]
            except (AttributeError, IndexError):
                pass
    sc.frame_set(frame)


def export_cube_pets():
    """glb в design/pets/cube_pets/export: <вид>.glb и <вид>_<стадия>.glb."""
    out = OUT + r"\export"
    os.makedirs(out, exist_ok=True)
    for key in STAGED:                      # прежние одиночные модели этих видов
        old = os.path.join(out, key + ".glb")
        if os.path.exists(old):
            os.remove(old)
    res = []
    for arm in _rigs(SCENE) + _rigs(SCENE_STAGES):
        mesh = next(o for o in arm.children if o.type == "MESH")
        keep = arm.location.copy()
        arm.location = (0, 0, 0)
        arm.animation_data.action = None
        tmp = bpy.data.scenes.new("CP_Export")
        tmp.collection.objects.link(arm)
        tmp.collection.objects.link(mesh)
        name = arm["species"] + ("_" + arm["stage"] if arm.get("stage") else "")
        path = os.path.join(out, name + ".glb")
        try:
            rp.export_glb(tmp, path)
        finally:
            bpy.data.scenes.remove(tmp)
            arm.location = keep
        res.append(path)
    return res


def render_cube_pets(shots=(("Idle", 1), ("Happy", 9), ("Sleep", 30), ("Wave", 13)), samples=64):
    os.makedirs(OUT, exist_ok=True)
    for scene_name, prefix in ((SCENE, "lineup"), (SCENE_STAGES, "stages")):
        sc = bpy.data.scenes[scene_name]
        try:
            sc.render.engine = "CYCLES"
            sc.cycles.samples = samples
            sc.cycles.use_denoising = True
        except (TypeError, AttributeError):
            pass
        for clip, f in shots:
            if prefix == "stages" and clip != "Idle":
                continue
            pose_all(clip, f, scene_name)
            sc.render.filepath = os.path.join(OUT, f"{prefix}_{clip.lower()}.png")
            bpy.ops.render.render(write_still=True, scene=sc.name)


ICONS = r"F:\project\PepeHub\apps\pepehub\assets\pets\icons"


def render_pet_icons(stage="cub", samples=64, res=512):
    """Портреты видов со стадиями (pet_<вид>.png, прозрачный фон) для выбора и магазина."""
    src = bpy.data.scenes[SCENE_STAGES]
    sc = bpy.data.scenes.get("CP_Icons") or bpy.data.scenes.new("CP_Icons")
    for o in list(sc.collection.objects):
        sc.collection.objects.unlink(o)
    cam = bpy.data.objects.get("CP_IconCam") or bpy.data.objects.new("CP_IconCam", bpy.data.cameras.new("CP_IconCam"))
    cam.data.lens = 60
    sc.collection.objects.link(cam)
    sc.camera = cam
    key = bpy.data.objects.get("CP_IconKey") or bpy.data.objects.new("CP_IconKey", bpy.data.lights.new("CP_IconKey", "AREA"))
    key.data.energy = 120; key.data.size = 1.5
    sc.collection.objects.link(key)
    sc.world = bpy.data.worlds.get("CP_World")
    sc.render.resolution_x = sc.render.resolution_y = res
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    try:
        sc.render.engine = "CYCLES"; sc.cycles.samples = samples; sc.cycles.use_denoising = True
        sc.view_settings.view_transform = "AgX"
    except (TypeError, AttributeError):
        pass
    os.makedirs(ICONS, exist_ok=True)
    out = []
    for arm in _rigs(SCENE_STAGES):
        if arm.get("stage") != stage:
            continue
        mesh = next(o for o in arm.children if o.type == "MESH")
        keep = arm.location.copy()
        arm.location = (0, 0, 0)
        sc.collection.objects.link(arm)
        sc.collection.objects.link(mesh)
        act = bpy.data.actions.get(arm.name.replace("_Rig", "") + "_Idle")
        arm.animation_data.action = act
        if act is not None and len(act.slots):
            arm.animation_data.action_slot = act.slots[0]
        win = bpy.context.window or bpy.context.window_manager.windows[0]
        win.scene = sc
        sc.frame_set(1)
        sc.view_layers[0].update()
        ev = mesh.evaluated_get(sc.view_layers[0].depsgraph)
        pts = [ev.matrix_world @ Vector(c) for c in ev.bound_box]
        lo = Vector(map(min, *pts)); hi = Vector(map(max, *pts))
        h = hi.z
        target = (lo + hi) / 2
        cam.location = target + Vector((0.38, -1.0, 0.22)).normalized() * 2.6 * max(hi - lo)
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        key.location = (-1.2 * h, -2.0 * h, 2.2 * h)
        key.rotation_euler = (math.radians(50), 0, math.radians(-30))
        path = os.path.join(ICONS, f"pet_{arm['species']}.png")
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True, scene=sc.name)
        sc.collection.objects.unlink(arm)
        sc.collection.objects.unlink(mesh)
        arm.location = keep
        arm.animation_data.action = None
        out.append(path)
    return out
