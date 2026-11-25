# Pets v5 (2026-11-25): new chibi models for cat, fox and dragon, every
# growth stage and adult path, plus matching accessories. Replaces the models
# of pets.py / stage4.py but keeps the app contract (pet_scene.dart):
#   files      assets/pets/<species>_<baby|cub|teen|adult_<path>>.glb
#   bones      Root Body Head EarL EarR Tail1-3 (WingL WingR for the dragon)
#   sockets    Socket_Head Socket_Face Socket_Neck Socket_Back (bones, pointing up)
#   clips      Idle Happy Eat Sleep Sad Spin Jump Stretch (rig_pet.add_clips + talents)
#   material   "<Species>_body" is the fur the app tints with a bought colour
# Exec inside Blender after lib.py, rooms_v3.py and icons_v4.py:
#   build_pets5()          # scene "PetsV5": every variant on a lineup
#   export_pets5()         # bake + export all glb (and the accessories)
#   render_pets5()         # Cycles previews to design/pets/pets_v5/
import bpy, bmesh, math, os, sys, random
from mathutils import Vector, Matrix, Euler

HERE5 = r"F:\project\PepeHub\design\pets\scripts"
if HERE5 not in sys.path:
    sys.path.insert(0, HERE5)
import importlib, rig_pet as rp
importlib.reload(rp)

OUT5 = [r"F:\project\PepeHub\apps\pepehub\assets\pets", r"F:\project\PepeHub\design\pets\export"]
PREVIEW5 = r"F:\project\PepeHub\design\pets\pets_v5"
SCENE5 = "PetsV5"
K5 = 1.2          # global scale: keeps the heights close to the old models
LID_D = 0.055     # how deep an open eyelid hides inside the head (before K5)
TAIL_N = 5        # tail bones Tail1..Tail5
PATHS5 = {"cat": ("bookish", "night"), "fox": ("forest", "fire"), "dragon": ("star", "stone")}
STAGES5 = ("baby", "cub", "teen", "adult")

# ------------------------------------------------------------------ palette
PAL = {
    "cat": dict(body="#F6D3CC", cream="#FFF5EF", inner="#F3A3B6", tip="#8CC0EA", iris="#3FA9C2", iris2="#A6E6EC",
                nose="#EE8BA2", blush="#F6A3BC", pad="#F3A3B6"),
    "fox": dict(body="#F2994E", cream="#FFF2E4", inner="#FFD8BF", tip="#5A3A2E", iris="#C9781E", iris2="#F7C766",
                nose="#3A2A2A", blush="#F7A3A0", pad="#5A3A2E"),
    "dragon": dict(body="#8FD6C0", cream="#F6E6BC", inner="#C9B6EE", tip="#8E76C2", iris="#7A5FC0", iris2="#C9B6F2",
                   nose="#5E9C88", blush="#F4A9C0", pad="#7ABFA9", horn="#FBE6B2", wing="#BBA6E6"),
}
PATH_PAL = {
    "night": dict(body="#5D5A93", cream="#ECE6FA", inner="#9C8FD8", tip="#2E2A5E", iris="#E3A93A", iris2="#FFE08A", blush="#B98FD6"),
    "bookish": dict(body="#F2CDBE"),
    "forest": dict(body="#D9884C", tip="#4E6B3A"),
    "fire": dict(body="#F07A36", tip="#B8301E"),
    "star": dict(body="#7FA6E6", cream="#F2E8C6", tip="#3E4E9E", wing="#A9B8F2", horn="#F6D27A"),
    "stone": dict(body="#8EA39A", cream="#D9D2C0", tip="#5E6B66", wing="#A6B2AC", horn="#D6CDBA"),
}
INK = "#2B2140"

def pal(species, path):
    p = dict(PAL[species])
    if path:
        p.update(PATH_PAL.get(path, {}))
    return p

_MAT5 = {}
def pm(name, c, rough=0.55, sss=0.0, emit=0.0, coat=0.0, metal=0.0):
    key = (name, c, rough, emit)
    if key in _MAT5 and _MAT5[key].name == name:
        return _MAT5[key]
    m = soft(name, c, rough, coat=coat, sss=sss, metal=metal)
    if emit:
        b = m.node_tree.nodes["Principled BSDF"]
        b.inputs["Emission Color"].default_value = (*hexc(c), 1)
        b.inputs["Emission Strength"].default_value = emit
    _MAT5[key] = m
    return m

# ------------------------------------------------------------------ stage proportions
def dims(species, stage):
    """Sizes in metres before K5. Heads stay big (chibi) while bodies grow."""
    i = STAGES5.index(stage)
    d = dict(
        hr=0.2 + 0.005 * i,                      # head radius
        bh=0.19 + 0.065 * i,                     # body (sitting) height
        br=0.135 + 0.012 * i,                    # body radius
        eye=1.12 - 0.07 * i,                     # eye size factor
        ear=0.9 + 0.1 * i,                       # ear size factor
        tail=0.75 + 0.12 * i,                    # tail length factor
        leg=1.0 + 0.12 * i,
        i=i,
    )
    return d

# ------------------------------------------------------------------ mesh helpers
def _bm_sphere(rx, ry, rz, segs=32, rings=16):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0)
    bmesh.ops.scale(bm, vec=(rx, ry, rz), verts=bm.verts)
    return bm

def _bm_cone(r1, r2, depth, segs=24):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r1, radius2=r2, depth=depth)
    bmesh.ops.translate(bm, vec=(0, 0, depth / 2), verts=bm.verts)   # base at z=0, tip at z=depth
    return bm

def mk(name, bm, mat, mx=Matrix(), bone="Head", smooth=True, subd=0):
    bmesh.ops.transform(bm, matrix=mx, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    if smooth:
        me.shade_smooth()
    o = _obj(name, me, (0, 0, 0), (0, 0, 0), mat)
    o["bone"] = bone
    if subd:
        s = o.modifiers.new("Subd", "SUBSURF"); s.levels = subd; s.render_levels = subd
    return o

def frame(z_axis, x_hint=Vector((1, 0, 0))):
    """Rotation whose local Z points along z_axis (local X as close to x_hint as possible)."""
    z = Vector(z_axis).normalized()
    x = (Vector(x_hint) - z * Vector(x_hint).dot(z))
    if x.length < 1e-6:
        x = Vector((0, 1, 0)) - z * z.y
    x.normalize()
    y = z.cross(x)
    return Matrix((x, y, z)).transposed().to_4x4()

def ell_surface(c, r, yaw, pitch):
    """Point and normal on an ellipsoid (centre c, radii r) seen along yaw/pitch; yaw 0 = front (-Y)."""
    d = Vector((math.sin(yaw) * math.cos(pitch), -math.cos(yaw) * math.cos(pitch), math.sin(pitch)))
    t = 1.0 / math.sqrt((d.x / r[0]) ** 2 + (d.y / r[1]) ** 2 + (d.z / r[2]) ** 2)
    p = Vector(c) + d * t
    q = p - Vector(c)
    n = Vector((q.x / r[0] ** 2, q.y / r[1] ** 2, q.z / r[2] ** 2)).normalized()
    return p, n

def decal(name, surf, size, mat, off=0.0, shift=(0, 0), thick=0.35, bone="Head", segs=24):
    """Flattened ellipsoid lying on a surface point (p, n); size = (w, h) half-sizes."""
    p, n = surf
    R = frame(n, Vector((1, 0, 0)) if abs(n.x) < 0.9 else Vector((0, 1, 0)))
    xa, ya = R.col[0].to_3d(), R.col[1].to_3d()
    pos = p + n * off + xa * shift[0] + ya * shift[1]
    bm = _bm_sphere(size[0], size[1], min(size) * thick, segs, max(8, segs // 2))
    return mk(name, bm, mat, Matrix.Translation(pos) @ R, bone)

def surface_tube(name, pts, r, mat, bone="Head"):
    o = tube(name, pts, r, mat, res=8)
    o["bone"] = bone
    return o

def tail_loft(name, pts, radii, mat, ring=16, t0=0.0, t1=1.0, bone_spec=("tail", 0.0, 1.0)):
    """Tube with a radius profile along a polyline (Catmull-Rom sampled)."""
    def cr(p0, p1, p2, p3, t):
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3)
    P = [Vector(p) for p in pts]
    P = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    samples = []
    N = 40
    for k in range(N + 1):
        u = k / N
        seg = min(int(u * (len(P) - 3)), len(P) - 4)
        lt = u * (len(P) - 3) - seg
        samples.append(cr(P[seg], P[seg + 1], P[seg + 2], P[seg + 3], lt))
    sel = [s for k, s in enumerate(samples) if t0 - 1e-6 <= k / N <= t1 + 1e-6]
    us = [k / N for k in range(N + 1) if t0 - 1e-6 <= k / N <= t1 + 1e-6]
    rings = []
    up = Vector((0, 0, 1))
    for j, (s, u) in enumerate(zip(sel, us)):
        tan = (sel[min(j + 1, len(sel) - 1)] - sel[max(j - 1, 0)]).normalized()
        side = tan.cross(up)
        if side.length < 1e-4:
            side = Vector((1, 0, 0))
        side.normalize()
        nrm = side.cross(tan).normalized()
        rr = radii(u)
        rings.append([s + (side * math.cos(2 * math.pi * q / ring) + nrm * math.sin(2 * math.pi * q / ring)) * rr for q in range(ring)])
    o = loft(name, rings, mat, subd=1)
    o["bone"] = "tail"
    o["tail_pts"] = [list(v) for v in samples]
    return o

def _adopt(coll, root):
    for o in coll.objects:
        if o is not root and o.parent is None:
            mw = o.matrix_basis.copy()
            o.parent = root
            o.matrix_parent_inverse = Matrix()
            o.matrix_basis = mw

# ------------------------------------------------------------------ the pet
def build_pet(species, stage, path=None, offset=(0, 0, 0), rnd=None):
    rnd = rnd or random.Random(7)
    key = stage if path is None else "adult_" + path
    cname = "P5_%s_%s" % (species, key)
    sc = bpy.data.scenes[SCENE5]
    old = bpy.data.collections.get(cname)
    if old:
        for o in list(old.all_objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(old)
    coll = bpy.data.collections.new(cname); sc.collection.children.link(coll)
    root = bpy.data.objects.new(cname + "_Root", None); coll.objects.link(root)
    root.location = offset
    root.scale = (K5, K5, K5)
    use(coll, parent=root)

    d = dims(species, stage)
    P = pal(species, path)
    pet = rp.SPECIES[species]
    hr, bh, br = d["hr"], d["bh"], d["br"]
    # one fur material per variant; the app tints every material named "*_body"
    body_m = pm("%s_%s_body" % (pet, key), P["body"], 0.6, sss=0.15)
    cream = pm("P5_%s_cream_%s" % (species, path or "base"), P["cream"], 0.65, sss=0.15)
    inner = pm("P5_%s_inner_%s" % (species, path or "base"), P["inner"], 0.6, sss=0.2)
    tipm = pm("P5_%s_tip_%s" % (species, path or "base"), P["tip"], 0.55,
              emit=(2.5 if path == "fire" else 0.0))
    ink = pm("P5_ink", INK, 0.25, coat=0.6)
    white = pm("P5_glint", "#FFFFFF", 0.2, emit=2.0)
    iris = pm("P5_%s_iris_%s" % (species, path or "base"), P["iris"], 0.2, coat=0.8)
    iris2 = pm("P5_%s_iris2_%s" % (species, path or "base"), P["iris2"], 0.2, coat=0.8, emit=0.3)
    nose = pm("P5_%s_nose" % species, P["nose"], 0.3, coat=0.5)
    blush = pm("P5_%s_blush_%s" % (species, path or "base"), P["blush"], 0.7)
    mouth = pm("P5_mouth", "#7A2E3E", 0.4)
    tongue = pm("P5_tongue", "#F28CA0", 0.45, sss=0.3)
    fang = pm("P5_fang", "#FFFFFF", 0.3)
    pad = pm("P5_%s_pad_%s" % (species, path or "base"), P["pad"], 0.55)

    # ---- body (sitting) -------------------------------------------------
    prof = [(0.0, 0.0), (br * 0.82, 0.0), (br * 0.98, bh * 0.12), (br, bh * 0.32), (br * 0.9, bh * 0.6), (br * 0.7, bh * 0.85), (br * 0.55, bh), (0.0, bh * 1.04)]
    b = revolve("Body", prof, (0, 0.015, 0), body_m, segs=40, scale=(1.0, 0.92, 1.0))
    b["bone"] = "spine"
    s = b.modifiers.new("Subd", "SUBSURF"); s.levels = 1; s.render_levels = 1
    mk("Belly", _bm_sphere(br * 0.58, br * 0.3, bh * 0.42), cream, Matrix.Translation((0, -br * 0.66, bh * 0.45)), "spine")
    # haunches and hind feet
    for sx in (-1, 1):
        mk("Haunch" + ("L" if sx < 0 else "R"), _bm_sphere(br * 0.42, br * 0.58, bh * 0.3 + 0.01),
           body_m, Matrix.Translation((sx * br * 0.78, 0.01, bh * 0.2)), "Hips")
        mk("HindFoot" + ("L" if sx < 0 else "R"), _bm_sphere(br * 0.2, br * 0.36, br * 0.13),
           pad if species == "fox" else body_m, Matrix.Translation((sx * br * 0.84, -br * 0.42, br * 0.1)), "Root")
    # front legs: capsules down to the floor, paws with toe beans
    leg_r = br * 0.2
    for sx in (-1, 1):
        sd = "L" if sx < 0 else "R"
        top = Vector((sx * br * 0.36, -br * 0.62, bh * 0.62))
        bot = Vector((sx * br * 0.4, -br * 0.8, leg_r * 0.9))
        L = (top - bot).length
        bm = _bm_cone(leg_r, leg_r * 1.08, L, 16)
        mk("Leg" + sd, bm, pad if species == "fox" and d["i"] >= 1 else body_m, Matrix.Translation(bot) @ frame(top - bot), "Leg" + sd)
        mk("Paw" + sd, _bm_sphere(leg_r * 1.25, leg_r * 1.45, leg_r * 0.95), pad if species == "fox" else body_m,
           Matrix.Translation(bot + Vector((0, -leg_r * 0.3, 0))), "Leg" + sd)
        if species != "dragon":
            for k, dx in enumerate((-0.55, 0.0, 0.55)):
                mk("Bean%s%d" % (sd, k), _bm_sphere(leg_r * 0.22, leg_r * 0.18, leg_r * 0.12), inner if species == "cat" else cream,
                   Matrix.Translation(bot + Vector((dx * leg_r * 0.9, -leg_r * 1.62, leg_r * 0.25))), "Leg" + sd)
        else:
            for k, dx in enumerate((-0.5, 0.0, 0.5)):
                mk("Claw%s%d" % (sd, k), _bm_cone(leg_r * 0.18, 0.0, leg_r * 0.4, 8), pm("P5_claw", P["horn"], 0.4),
                   Matrix.Translation(bot + Vector((dx * leg_r * 0.9, -leg_r * 1.3, 0.01))) @ Matrix.Rotation(math.radians(-80), 4, "X"), "Leg" + sd)

    # ---- neck ruff -------------------------------------------------------
    ruff_z = bh * 0.96
    nt = 22 if species != "dragon" else 0
    for k in range(nt):
        a = 2 * math.pi * k / nt + (0.07 if k % 2 else 0)
        front = max(0.0, -math.sin(a))          # fuller at the front (-Y)
        base = Vector((math.cos(a) * br * 0.55, math.sin(a) * br * 0.55, ruff_z - (0.012 if k % 2 else 0)))
        out = Vector((math.cos(a), math.sin(a), -0.9 - 0.4 * front)).normalized()
        ln = br * (0.3 + 0.22 * front) * (0.85 if k % 2 else 1.0)
        mk("Ruff%d" % k, _bm_cone(br * 0.2, br * 0.07, ln, 12), cream, Matrix.Translation(base) @ frame(out), "Chest", subd=2)
    if species == "dragon":
        # belly plates instead of a ruff
        for k in range(4):
            z = bh * (0.2 + 0.19 * k)
            mk("Plate%d" % k, _bm_sphere(br * (0.5 - 0.05 * k), br * 0.12, bh * 0.07), cream,
               Matrix.Translation((0, -br * (0.86 - 0.08 * k), z)), "spine")

    # ---- head ------------------------------------------------------------
    C = Vector((0, -0.01, bh + hr * 0.76))
    HR = (hr * 1.08, hr * 0.96, hr * 0.9)
    mk("Head", _bm_sphere(*HR, 48, 24), body_m, Matrix.Translation(C), "Head")
    # cheek tufts (reference: spiky cheeks)
    if species in ("cat", "fox"):
        for sx in (-1, 1):
            for k, (pitch, ln) in enumerate(((-0.05, 0.75), (-0.28, 1.0), (-0.48, 0.7))):
                p, n = ell_surface(C, HR, sx * 1.35, pitch)
                out = (n + Vector((0, 0, -0.35 - 0.2 * k))).normalized()
                mk("Cheek%s%d" % ("L" if sx < 0 else "R", k), _bm_cone(hr * 0.13, hr * 0.01, hr * 0.32 * ln, 10),
                   cream if species == "fox" else body_m, Matrix.Translation(p - n * hr * 0.06) @ frame(out), "Head", subd=1)
        # forehead cowlick
        for k, yaw in enumerate((-0.18, 0.0, 0.2)):
            p, n = ell_surface(C, HR, yaw, 1.15)
            out = (n + Vector((0, -0.5, 0.2))).normalized()
            mk("Cowlick%d" % k, _bm_cone(hr * 0.09, hr * 0.005, hr * (0.22 if k == 1 else 0.15), 8), body_m,
               Matrix.Translation(p - n * hr * 0.04) @ frame(out), "Head", subd=1)

    # snout
    if species == "fox":
        SC = C + Vector((0, -hr * 0.72, -hr * 0.3)); SR = (hr * 0.34, hr * 0.42, hr * 0.27)
        mk("Snout", _bm_sphere(*SR), cream, Matrix.Translation(SC), "Head")
    elif species == "dragon":
        SC = C + Vector((0, -hr * 0.66, -hr * 0.28)); SR = (hr * 0.5, hr * 0.42, hr * 0.33)
        mk("Snout", _bm_sphere(*SR), body_m, Matrix.Translation(SC), "Head")
    else:
        SC = C + Vector((0, -hr * 0.62, -hr * 0.36)); SR = (hr * 0.4, hr * 0.32, hr * 0.26)
        mk("Muzzle", _bm_sphere(*SR), cream, Matrix.Translation(SC), "Head")

    # eyes
    er = hr * 0.3 * d["eye"]
    for sx in (-1, 1):
        sd = "L" if sx < 0 else "R"
        surf = ell_surface(C, HR, sx * 0.36, -0.04)
        decal("EyeOut" + sd, surf, (er * 0.8, er), ink, off=-0.002 * K5, thick=0.3)
        decal("Iris" + sd, surf, (er * 0.68, er * 0.86), iris, off=0.0015, shift=(0, -er * 0.06), thick=0.3)
        decal("IrisLow" + sd, surf, (er * 0.52, er * 0.36), iris2, off=0.003, shift=(0, -er * 0.42), thick=0.3)
        decal("Pupil" + sd, surf, (er * 0.32, er * 0.42), ink, off=0.0045, shift=(0, -er * 0.02), thick=0.3)
        decal("Glint" + sd, surf, (er * 0.24, er * 0.28), white, off=0.0065, shift=(-sx * er * 0.24, er * 0.32), thick=0.3)
        decal("Glint2" + sd, surf, (er * 0.1, er * 0.1), white, off=0.0065, shift=(sx * er * 0.25, -er * 0.38), thick=0.3)
        # upper lash line with a flick at the outer corner
        p, n = surf
        R = frame(n, Vector((1, 0, 0)))
        xa, ya = R.col[0].to_3d(), R.col[1].to_3d()
        pts = []
        for k in range(9):
            a = math.radians(18 + 144 * k / 8)
            pts.append(tuple(p + n * 0.006 + xa * (er * 0.86 * math.cos(a)) + ya * (er * 1.04 * math.sin(a))))
        surface_tube("Lash" + sd, pts, er * 0.085, ink)
        outer = Vector(pts[0] if sx > 0 else pts[-1])
        flick = (xa * sx * 0.9 + ya * 0.6).normalized()
        mk("LashFlick" + sd, _bm_cone(er * 0.09, 0.0, er * 0.42, 8), ink, Matrix.Translation(outer) @ frame(flick), "Head")
        # brow
        bp, bn = ell_surface(C, HR, sx * 0.38, 0.4)
        R2 = frame(bn, Vector((1, 0, 0)))
        bx, by = R2.col[0].to_3d(), R2.col[1].to_3d()
        surface_tube("Brow" + sd, [tuple(bp + bn * 0.004 + bx * (er * t) + by * (er * 0.12 * (1 - t * t) + sx * er * 0.12 * t)) for t in (-0.5, 0.0, 0.5)], er * 0.07, ink)
        # blush
        decal("Blush" + sd, ell_surface(C, HR, sx * 0.72, -0.26), (hr * 0.13, hr * 0.075), blush, off=0.001, thick=0.25)
        # eyelid for blinking: a skin cap with a closed-eye lash curve. At rest it
        # hides inside the head; the Lid bone pushes it out along the normal.
        lid_d = LID_D
        cap = decal("Lid" + sd, surf, (er * 0.98, er * 1.16), body_m, off=0.017 - lid_d, thick=0.24, bone="Lid" + sd)
        lash_pts = []
        for k in range(9):
            a = math.radians(200 + 140 * k / 8)
            lash_pts.append(tuple(p + n * (0.033 - lid_d) + xa * (er * 0.78 * math.cos(a)) + ya * (er * 0.22 + er * 0.42 * math.sin(a))))
        surface_tube("LidLash" + sd, lash_pts, er * 0.075, ink, bone="Lid" + sd)
        root["lid_" + sd] = [list(p + n * (0.017 - lid_d)), list(n)]

    # nose, mouth, fang
    if species == "fox":
        nose_s = ell_surface(SC, SR, 0.0, 0.05)
        decal("Nose", nose_s, (hr * 0.1, hr * 0.07), nose, off=0.004, thick=0.7)
        mouth_s = ell_surface(SC, SR, 0.0, -0.65)
    elif species == "dragon":
        for sx in (-1, 1):
            decal("Nostril" + ("L" if sx < 0 else "R"), ell_surface(SC, SR, sx * 0.22, 0.25), (hr * 0.035, hr * 0.025), nose, off=0.001, thick=0.5)
        mouth_s = ell_surface(SC, SR, 0.0, -0.45)
    else:
        nose_s = ell_surface(SC, SR, 0.0, 0.35)
        decal("Nose", nose_s, (hr * 0.075, hr * 0.05), nose, off=0.002, thick=0.7)
        mouth_s = ell_surface(SC, SR, 0.0, -0.3)
    decal("Mouth", mouth_s, (hr * 0.11, hr * 0.075), mouth, off=0.0015, thick=0.4)
    decal("Tongue", mouth_s, (hr * 0.07, hr * 0.04), tongue, off=0.003, shift=(0, -hr * 0.03), thick=0.4)
    mp, mn = mouth_s
    Rm = frame(mn, Vector((1, 0, 0)))
    fang_pos = mp + mn * 0.004 + Rm.col[0].to_3d() * hr * 0.05 + Rm.col[1].to_3d() * hr * 0.055
    mk("Fang", _bm_cone(hr * 0.024, 0.0, hr * 0.05, 8), fang, Matrix.Translation(fang_pos) @ frame(-Rm.col[1].to_3d()), "Head")

    # ears / horns / frills
    for sx in (-1, 1):
        sd = "L" if sx < 0 else "R"
        if species in ("cat", "fox"):
            tall = 1.0 if species == "cat" else 1.3
            p, n = ell_surface(C, HR, sx * 0.55, 0.85)
            dirv = (n + Vector((sx * 0.15, 0.12, 0.55))).normalized()
            er_, eh = hr * 0.46 * d["ear"], hr * 0.82 * d["ear"] * tall
            Rm = Matrix.Translation(p - n * hr * 0.1) @ frame(dirv, Vector((1, 0, 0)))
            flat = Matrix.Diagonal((1.0, 0.5, 1.0, 1.0))
            mk("Ear" + sd, _bm_cone(er_, er_ * 0.08, eh, 24), body_m, Rm @ flat, "Ear" + sd, subd=1)
            mk("EarIn" + sd, _bm_cone(er_ * 0.62, er_ * 0.05, eh * 0.78, 20), inner,
               Rm @ Matrix.Translation((0, -er_ * 0.22, eh * 0.05)) @ Matrix.Diagonal((1.0, 0.35, 1.0, 1.0)), "Ear" + sd, subd=1)
            k_ = 0.5
            mk("EarTip" + sd, _bm_cone(er_ * k_ * 1.07, er_ * 0.06, eh * k_ * 1.02, 20), tipm,
               Rm @ Matrix.Translation((0, 0, eh * (1 - k_))) @ Matrix.Diagonal((1.0, 0.55, 1.0, 1.0)), "Ear" + sd, subd=1)
            if path == "bookish":   # lynx tufts
                mk("Tuft" + sd, _bm_cone(er_ * 0.12, 0.0, eh * 0.35, 8), pm("P5_tuft", INK, 0.6),
                   Rm @ Matrix.Translation((0, 0, eh * 0.95)), "Ear" + sd)
            if path == "fire":
                mk("EarFlame" + sd, _bm_cone(er_ * 0.3, 0.0, eh * 0.45, 12), pm("P5_flame", "#FFB23E", 0.5, emit=6.0),
                   Rm @ Matrix.Translation((0, 0, eh * 0.95)), "Ear" + sd)
        else:
            # horns: curved, cream/gold
            hp, hn = ell_surface(C, HR, sx * 0.42, 0.95)
            hl = hr * (0.35 + 0.12 * d["i"]) * (1.35 if path == "stone" else 1.0)
            pts = [tuple(hp - hn * 0.01), tuple(hp + hn * hl * 0.5 + Vector((sx * hl * 0.15, hl * 0.25, 0))),
                   tuple(hp + hn * hl * 0.8 + Vector((sx * hl * 0.25, hl * 0.6, 0)))]
            o = tail_loft("Horn" + sd, pts, lambda u, hr=hr: hr * 0.09 * (1 - 0.92 * u), pm("P5_horn_%s" % (path or "base"), P["horn"], 0.35, coat=0.5))
            o["bone"] = "Head"
            # ear frills (fins) on the Ear bones
            fp, fn = ell_surface(C, HR, sx * 1.25, 0.15)
            fl = hr * 0.42 * d["ear"]
            pts2 = [(0, 0), (fl * 0.4, fl * 0.35), (fl * 0.95, fl * 0.42), (fl * 0.7, fl * 0.12), (fl * 1.0, -0.0), (fl * 0.62, -fl * 0.12), (fl * 0.85, -fl * 0.36), (fl * 0.3, -fl * 0.25)]
            fo = slab("Frill" + sd, pts2, 0.012, pm("P5_frill_%s" % (path or "base"), P["wing"], 0.5, sss=0.3), (0, 0, 0), (0, 0, 0))
            fo.matrix_world = Matrix.Translation(fp - fn * hr * 0.05) @ frame(Vector((0, 1, 0)), Vector((sx, 0, 0.35))) @ Matrix.Rotation(math.radians(0), 4, "Z")
            fo.matrix_world = Matrix.Translation(fp - fn * hr * 0.05) @ Matrix.Rotation(math.radians(90), 4, "X") @ Matrix.Rotation(0, 4, "Z") @ Matrix.Diagonal((sx, 1, 1, 1))
            fo["bone"] = "Ear" + sd
    if path == "night":
        decal("Crescent", ell_surface(C, HR, 0.0, 0.62), (hr * 0.11, hr * 0.11), pm("P5_moonmark", "#F6D27A", 0.4, emit=1.5), off=0.002, thick=0.25)
    if path == "forest":
        for sx in (-1, 1):
            lp, ln = ell_surface(C, HR, sx * 0.2, 1.05)
            lo = slab("Leaf" + ("L" if sx < 0 else "R"), leaf_pts(hr * 0.5, hr * 0.17), 0.006, pm("P5_leaf", "#6FAE4E", 0.45, sss=0.3), (0, 0, 0), (0, 0, 0))
            lo.matrix_world = Matrix.Translation(lp) @ Matrix.Rotation(math.radians(sx * 50 + 90), 4, "Z") @ Matrix.Rotation(math.radians(-35), 4, "Y")
            lo["bone"] = "Head"

    # ---- tail ------------------------------------------------------------
    tl = d["tail"]
    base = Vector((0, br * 0.82, bh * 0.12))
    if species == "cat":
        pts = [base, base + Vector((0.06, 0.1, 0.03)) * tl, base + Vector((0.13, 0.13, 0.15)) * tl, base + Vector((0.14, 0.09, 0.3)) * tl, base + Vector((0.1, 0.05, 0.4)) * tl]
        rad = lambda u: br * (0.17 - 0.05 * u) * (1 + 0.25 * max(0, u - 0.75) / 0.25)
        tip_from = 0.7
    elif species == "fox":
        pts = [base, base + Vector((0.08, 0.12, 0.05)) * tl, base + Vector((0.18, 0.15, 0.18)) * tl, base + Vector((0.2, 0.1, 0.34)) * tl, base + Vector((0.15, 0.05, 0.44)) * tl]
        bush = 1.0 + 0.25 * d["i"] + (0.35 if path == "forest" else 0.0)
        rad = lambda u: br * (0.16 + 0.42 * math.sin(math.pi * min(1, u * 1.05)) ** 0.8 * bush) * (1 - 0.85 * max(0, u - 0.88) / 0.12)
        tip_from = 0.72
    else:
        pts = [base, base + Vector((0.08, 0.14, -0.06)) * tl, base + Vector((0.2, 0.18, -0.08)) * tl, base + Vector((0.33, 0.13, -0.04)) * tl]
        pts = [Vector((p.x, p.y, max(p.z, br * 0.12))) for p in pts]
        rad = lambda u: br * (0.24 - 0.2 * u)
        tip_from = 1.01
    tail_loft("Tail", pts, rad, body_m)
    if tip_from <= 1.0:
        tip_mat = pm("P5_tailtip_%s_%s" % (species, path or "base"), "#FFFFFF" if species == "fox" and path not in ("fire", "forest") else P["tip"], 0.6,
                     emit=(3.0 if path == "fire" else 0.0))
        tail_loft("TailTip", pts, lambda u, rad=rad: rad(u) * 1.06, tip_mat, t0=tip_from, t1=1.0)
    end = Vector(pts[-1])
    if species == "dragon":
        sp = [(0, 0), (0.05, 0.035), (0.07, 0.0), (0.05, -0.035)]
        spade_m = pm("P5_spade_%s" % (path or "base"), P["tip"], 0.45, emit=(2.5 if path == "star" else 0.0))
        so = slab("TailSpade", [(x * (1 + 0.2 * d["i"]), y * (1 + 0.2 * d["i"])) for x, y in sp], 0.014, spade_m, (0, 0, 0), (0, 0, 0))
        tan = (Vector(pts[-1]) - Vector(pts[-2])).normalized()
        so.matrix_world = Matrix.Translation(end) @ Matrix.Rotation(math.atan2(tan.y, tan.x), 4, "Z")
        so["bone"] = "Tail5"
        if path == "star":
            st = star5("TailStar", 0.045, 0.02, 0.012, pm("P5_starglow", "#FFE08A", 0.3, emit=5.0), (0, 0, 0), (0, 0, 0))
            st.matrix_world = Matrix.Translation(end + tan * 0.07 + Vector((0, 0, 0.02))) @ Matrix.Rotation(math.radians(90), 4, "X")
            st["bone"] = "Tail5"
    if path == "fire":
        fl = tail_loft("TailFlame", [end - Vector((0, 0, 0.02)), end + Vector((0.01, 0.0, 0.08)), end + Vector((-0.01, 0.0, 0.16))],
                       lambda u: br * 0.2 * (1 - u), pm("P5_flame", "#FFB23E", 0.5, emit=6.0))
        fl["bone"] = "Tail5"

    # ---- dragon: wings, back spikes ----------------------------------------
    if species == "dragon":
        wl = (0.07 + 0.045 * d["i"]) * (1.35 if path == "star" else 1.0)
        mem = pm("P5_wing_%s" % (path or "base"), P["wing"], 0.45, sss=0.4)
        bonem = pm("P5_wingbone_%s" % (path or "base"), P["tip"], 0.4)
        for sx in (-1, 1):
            sd = "L" if sx < 0 else "R"
            pts2 = [(0, 0), (wl * 0.5, wl * 0.62), (wl * 1.1, wl * 0.95), (wl * 0.95, wl * 0.55), (wl * 1.25, wl * 0.45),
                    (wl * 0.95, wl * 0.2), (wl * 1.1, -wl * 0.02), (wl * 0.55, wl * 0.02)]
            wo = slab("Wing" + sd, pts2, 0.01, mem, (0, 0, 0), (0, 0, 0))
            wo.matrix_world = (Matrix.Translation((sx * br * 0.3, br * 0.62, bh * 0.68)) @ Matrix.Rotation(math.radians(sx * 25), 4, "Z")
                               @ Matrix.Rotation(math.radians(90), 4, "X") @ Matrix.Rotation(math.radians(-15), 4, "Y") @ Matrix.Diagonal((sx, 1, 1, 1)))
            wo["bone"] = "Wing" + sd
            if path == "star":
                for k, (u, v) in enumerate(((0.55, 0.45), (0.85, 0.7), (0.8, 0.25))):
                    pos = wo.matrix_world @ Vector((wl * u, wl * v, 0.007))
                    ss = star5("WingStar%s%d" % (sd, k), 0.018, 0.008, 0.004, pm("P5_starglow", "#FFE08A", 0.3, emit=5.0), (0, 0, 0), (0, 0, 0))
                    ss.matrix_world = Matrix.Translation(pos) @ wo.matrix_world.to_3x3().normalized().to_4x4()
                    ss["bone"] = "Wing" + sd
        n_sp = 3 + d["i"]
        for k in range(n_sp):
            t = k / max(n_sp - 1, 1)
            z = bh * (0.95 - 0.65 * t)
            y = br * (0.45 + 0.4 * math.sin(math.pi * (0.2 + 0.5 * t)))
            size = br * (0.22 - 0.06 * t) * (1.4 if path == "stone" else 1.0)
            m_ = pm("P5_rock", "#6F7C78", 0.95) if path == "stone" else bonem
            mk("Spike%d" % k, _bm_cone(size * 0.55, 0.0, size, 6 if path == "stone" else 12), m_,
               Matrix.Translation((0, y, z)) @ frame(Vector((0, 0.8, 0.6))), "spine")

    # night cat: little stars on the body
    if path == "night":
        for k, (yaw, pz) in enumerate(((2.6, 0.55), (3.4, 0.35), (2.2, 0.25), (3.8, 0.7))):
            p, n = ell_surface(Vector((0, 0.015, bh * 0.45)), (br, br * 0.92, bh * 0.55), yaw, pz - 0.4)
            st = star5("BodyStar%d" % k, 0.022, 0.01, 0.004, pm("P5_starglow", "#FFE08A", 0.3, emit=4.0), (0, 0, 0), (0, 0, 0))
            st.matrix_world = Matrix.Translation(p + n * 0.003) @ frame(n)
            st["bone"] = "spine"
    # bookish cat: a ribbon bookmark tied on the tail
    if path == "bookish":
        rb = tail_loft("Ribbon", [Vector(pts[2]) + Vector((0, 0, 0.0)), Vector(pts[2]) + Vector((0.02, -0.03, -0.05)), Vector(pts[2]) + Vector((0.03, -0.04, -0.11))],
                       lambda u: 0.008, pm("P5_ribbon", "#D4506E", 0.5))
        rb["bone"] = "Tail3"

    # curves and slabs were created without a parent; their coordinates (points or
    # matrix_world) are already in root space, so parent them with an identity inverse
    _adopt(coll, root)
    root["dims"] = [hr, bh, br]
    root["species"] = species
    root["stage"] = stage
    root["path"] = path or ""
    root["tail_pts"] = [list(Vector(p)) for p in pts]
    return coll, root

# ------------------------------------------------------------------ rig
# Bones (Blender units after K5). Every bone that the clips bend points so that
# its local axes are found at runtime (_toward): clips name directions in the
# world ("tip toward the front"), not raw Euler signs.
#   Root ─ Hips ─ Chest ─ Head ─ EarL/R, LidL/R, Socket_Head, Socket_Face
#                   │      └─ LegL/R, WingL/R, Socket_Neck, Socket_Back
#                   └─ Tail1 ─ … ─ Tail5
def _along(tp, f):
    acc = [0.0]
    for a, b in zip(tp, tp[1:]):
        acc.append(acc[-1] + (b - a).length)
    L = acc[-1] * f
    for i in range(len(tp) - 1):
        if acc[i + 1] >= L - 1e-9:
            t = (L - acc[i]) / max(acc[i + 1] - acc[i], 1e-9)
            return tp[i].lerp(tp[i + 1], t)
    return tp[-1]

def bones5(species, root):
    hr, bh, br = root["dims"]
    tp = [Vector(p) for p in root["tail_pts"]]
    q = [_along(tp, k / TAIL_N) for k in range(TAIL_N + 1)]
    C = Vector((0, -0.01, bh + hr * 0.76))
    b = {
        "Root": ((0, 0, 0), (0, 0, 0.1), None),
        "Hips": ((0, 0.015, 0.02), (0, 0.015, bh * 0.45), "Root"),
        "Chest": ((0, 0.015, bh * 0.45), (0, 0.0, bh * 0.98), "Hips"),
        "Head": (tuple(C - Vector((0, 0, hr * 0.75))), tuple(C + Vector((0, 0, hr * 0.9))), "Chest"),
        "Socket_Head": (tuple(C + Vector((0, 0.01, hr * 0.86))), tuple(C + Vector((0, 0.01, hr * 0.86 + 0.06))), "Head"),
        "Socket_Face": (tuple(C + Vector((0, -hr * 0.98, -0.01))), tuple(C + Vector((0, -hr * 0.98, 0.05))), "Head"),
        "Socket_Neck": ((0, -br * 0.05, bh * 0.94), (0, -br * 0.05, bh * 0.94 + 0.06), "Chest"),
        "Socket_Back": ((0, br * 0.7, bh * 0.66), (0, br * 0.7, bh * 0.66 + 0.06), "Chest"),
    }
    for k in range(TAIL_N):
        b["Tail%d" % (k + 1)] = (tuple(q[k]), tuple(q[k + 1]), "Hips" if k == 0 else "Tail%d" % k)
    for sx, sd in ((-1, "L"), (1, "R")):
        b["Leg" + sd] = ((sx * br * 0.36, -br * 0.62, bh * 0.62), (sx * br * 0.4, -br * 0.8, 0.0), "Chest")
        lc, ln = Vector(root["lid_" + sd][0]), Vector(root["lid_" + sd][1])
        b["Lid" + sd] = (tuple(lc), tuple(lc + ln * 0.02), "Head")
        if species == "dragon":
            p, n = ell_surface(C, (hr * 1.08, hr * 0.96, hr * 0.9), sx * 1.25, 0.15)
            b["Ear" + sd] = (tuple(p), tuple(p + Vector((sx * 0.08, 0.02, 0.03))), "Head")
            b["Wing" + sd] = ((sx * br * 0.3, br * 0.62, bh * 0.68), (sx * (br * 0.3 + 0.18), br * 0.75, bh * 0.68 + 0.1), "Chest")
        else:
            p, n = ell_surface(C, (hr * 1.08, hr * 0.96, hr * 0.9), sx * 0.55, 0.85)
            b["Ear" + sd] = (tuple(p - n * hr * 0.1), tuple(p + n * hr * 0.5), "Head")
    return b

def _chain_weights(v, tp, names):
    """Smooth weights along a polyline split into len(names) equal stretches."""
    best, bt = 1e9, 0.0
    total = sum((b - a).length for a, b in zip(tp, tp[1:]))
    run = 0.0
    for a, b in zip(tp, tp[1:]):
        ab = b - a
        L = ab.length
        t = max(0.0, min(1.0, (v - a).dot(ab) / max(L * L, 1e-9)))
        dd = (a + ab * t - v).length
        if dd < best:
            best, bt = dd, (run + L * t) / total
        run += L
    n = len(names)
    cs = [(k + 0.5) / n for k in range(n)]
    if bt <= cs[0]:
        return {names[0]: 1.0}
    if bt >= cs[-1]:
        return {names[-1]: 1.0}
    w = {nm: max(0.0, 1 - abs(bt - c) * n) for nm, c in zip(names, cs)}
    s = sum(w.values())
    return {k: x / s for k, x in w.items() if x > 0}

def _spine_weights(z, bh):
    lo, hi = bh * 0.32, bh * 0.62
    if z <= lo:
        return {"Hips": 1.0}
    if z >= hi:
        return {"Chest": 1.0}
    t = (z - lo) / (hi - lo)
    t = t * t * (3 - 2 * t)
    return {"Hips": 1 - t, "Chest": t}

def bake5(species, stage, path=None):
    key = stage if path is None else "adult_" + path
    pet = rp.SPECIES[species]
    coll = bpy.data.collections["P5_%s_%s" % (species, key)]
    root = bpy.data.objects["P5_%s_%s_Root" % (species, key)]
    name = "Export5_%s_%s" % (pet, key)
    sc = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
    for o in list(sc.collection.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.context.window.scene = bpy.data.scenes[SCENE5]
    dg = bpy.context.evaluated_depsgraph_get()
    inv = root.matrix_world.inverted()
    tp = [Vector(p) for p in root["tail_pts"]]
    tails = ["Tail%d" % (k + 1) for k in range(TAIL_N)]
    bh = root["dims"][1]
    parts = []
    for o in coll.objects:
        if o.type not in ("MESH", "CURVE") or "bone" not in o:
            continue
        me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
        local = inv @ o.matrix_world
        me.transform(local)                       # root space, before K5: weights use these coords
        no = bpy.data.objects.new("%s_%s_part_%s" % (pet, key, o.name), me)
        sc.collection.objects.link(no)
        spec = o["bone"]
        if spec in ("tail", "spine"):
            groups = {}
            for v in me.vertices:
                ws = _chain_weights(v.co, tp, tails) if spec == "tail" else _spine_weights(v.co.z, bh)
                for nm, w in ws.items():
                    if nm not in groups:
                        groups[nm] = no.vertex_groups.new(name=nm)
                    groups[nm].add([v.index], w, "REPLACE")
        else:
            no.vertex_groups.new(name=spec).add(range(len(me.vertices)), 1.0, "REPLACE")
        me.transform(Matrix.Diagonal((K5, K5, K5, 1)))
        parts.append(no)
    bpy.context.window.scene = sc
    with bpy.context.temp_override(active_object=parts[0], object=parts[0], selected_editable_objects=parts):
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
    for bn, (h, t_, p) in bones5(species, root).items():
        eb = ad.edit_bones.new(bn)
        eb.head, eb.tail = Vector(h) * K5, Vector(t_) * K5
        if p:
            eb.parent = ad.edit_bones[p]
    bpy.ops.object.mode_set(mode="OBJECT")
    body.parent = arm
    body.modifiers.new("Armature", "ARMATURE").object = arm
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
    arm["lid_d"] = LID_D * K5
    arm["species"] = species
    return sc, arm, body

# ------------------------------------------------------------------ animation
R5 = math.radians

def _toward(arm, bone, world_dir):
    """(axis index, sign) of the local rotation that swings the bone tip toward world_dir.
    Rotation about local X moves +Y toward +Z; about local Z moves +Y toward -X."""
    m = arm.data.bones[bone].matrix_local.to_3x3()
    X, Z = m.col[0], m.col[2]
    d = Vector(world_dir).normalized()
    cand = [(0, Z.dot(d)), (2, -X.dot(d))]
    ax, v = max(cand, key=lambda c: abs(c[1]))
    return ax, (1 if v >= 0 else -1)

class Clip:
    """Collects keys as world-intent rotations and plain channels, then writes one action.
    Each swing is its own curve; curves on the same bone are sampled on the union of
    their frames and summed, so overlapping motions never zero each other."""
    def __init__(self, arm, name, length, cyclic=True):
        self.arm, self.name, self.length, self.cyclic = arm, name, length, cyclic
        self.curves = {}   # bone -> [(axis, sign, [(frame, degrees)])]
        self.chan = []     # (bone, path, [(f, value)])
    def has(self, bone):
        return bone in self.arm.pose.bones
    def swing(self, bone, world_dir, keys):
        """keys: [(frame, degrees)] swinging the tip toward world_dir."""
        if self.has(bone):
            ax, sg = _toward(self.arm, bone, world_dir)
            self.curves.setdefault(bone, []).append((ax, sg, keys))
        return self
    def twist(self, bone, keys):
        if self.has(bone):
            self.curves.setdefault(bone, []).append((1, 1, keys))
        return self
    def key(self, bone, path, keys):
        if self.has(bone):
            self.chan.append((bone, path, keys))
        return self
    @staticmethod
    def _at(keys, f):
        if f <= keys[0][0]:
            return keys[0][1]
        for (f0, v0), (f1, v1) in zip(keys, keys[1:]):
            if f0 <= f <= f1:
                t = (f - f0) / max(f1 - f0, 1e-9)
                t = t * t * (3 - 2 * t)          # ease, like Blender's bezier keys
                return v0 + (v1 - v0) * t
        return keys[-1][1]
    def write(self):
        keys = list(self.chan)
        for bone, curves in self.curves.items():
            frames = sorted({f for _, _, ks in curves for f, _ in ks})
            out = []
            for f in frames:
                v = [0.0, 0.0, 0.0]
                for ax, sg, ks in curves:
                    v[ax] += sg * self._at(ks, f)
                out.append((f, tuple(R5(x) for x in v)))
            keys.append((bone, "rotation_euler", out))
        return rp.clip(self.arm, self.name, self.length, keys, cyclic=self.cyclic)

def wave(length, amp, period, phase=0.0, step=4, base=0.0):
    fs = list(range(1, length + 1, step))
    if fs[-1] != length:
        fs.append(length)
    return [(f, base + amp * math.sin(2 * math.pi * (f - 1) / period + phase)) for f in fs]

def lids(c, frames_closed, length):
    """Lid keys: closed (pushed out) on the given frame spans, open elsewhere."""
    d = c.arm["lid_d"]
    pts = {1: 0.0, length: 0.0}
    for a, b in frames_closed:
        pts[max(1, a - 2)] = pts.get(max(1, a - 2), 0.0)
        pts[a] = d
        pts[b] = d
        pts[min(length, b + 2)] = 0.0
    keys = [(f, (0.0, v, 0.0)) for f, v in sorted(pts.items())]
    for sd in ("L", "R"):
        c.key("Lid" + sd, "location", keys)

def tail_wave(c, length, amp, period, lift=0.0, curl=0.0):
    for k in range(TAIL_N):
        bone = "Tail%d" % (k + 1)
        c.swing(bone, (1, 0, 0), wave(length, amp * (0.6 + 0.15 * k), period, phase=-0.7 * k))
        if lift:
            c.swing(bone, (0, 0, 1), [(1, lift), (length, lift)])
        if curl:
            c.swing(bone, (1, 0, 0), [(1, curl), (length, curl)])

FRONT, UP, SIDE = (0, -1, -0.25), (0, 0, 1), (1, 0, 0)

def clips5(arm):
    sp = arm["species"]
    dragon = sp == "dragon"
    # Idle: breathing, glances, a tail swish, an ear twitch and two blinks.
    c = Clip(arm, "Idle", 97)
    c.key("Chest", "scale", [(f, (1 + v, 1 + v * 0.8, 1 + v)) for f, v in wave(97, 0.018, 48, step=6)])
    c.swing("Head", FRONT, wave(97, 3, 96, step=6))
    c.swing("Head", SIDE, wave(97, 5, 96, phase=math.pi / 2, step=6))
    c.twist("Head", [(1, 0), (22, 0), (30, 14), (44, 14), (52, 0), (62, -12), (74, -12), (82, 0), (97, 0)])
    tail_wave(c, 97, 9, 48)
    c.swing("EarL", (-1, 0, 0.3), [(1, 0), (56, 0), (58, 16), (61, 0), (97, 0)])
    lids(c, [(36, 37), (86, 87)], 97)
    if dragon:
        c.swing("WingL", UP, wave(97, 6, 48, step=6)); c.swing("WingR", UP, wave(97, 6, 48, step=6))
    c.write()
    # Happy: two hops with paws up, eyes ^^, fast tail.
    c = Clip(arm, "Happy", 37, cyclic=False)
    c.key("Root", "location", [(1, (0, 0, 0)), (4, (0, -0.01, 0)), (9, (0, 0.13, 0)), (15, (0, 0, 0)), (20, (0, 0.09, 0)), (26, (0, 0, 0)), (37, (0, 0, 0))])
    c.key("Hips", "scale", [(1, (1, 1, 1)), (4, (1.07, 0.9, 1.07)), (9, (0.96, 1.07, 0.96)), (15, (1.07, 0.91, 1.07)), (20, (0.97, 1.05, 0.97)), (26, (1.04, 0.95, 1.04)), (33, (1, 1, 1))])
    for sd, sx in (("L", -1), ("R", 1)):
        c.swing("Leg" + sd, (0, -0.6, 1), [(1, 0), (6, 95), (12, 80), (18, 95), (24, 80), (31, 0), (37, 0)])
        c.swing("Leg" + sd, (sx, 0, 0), [(1, 0), (6, 18), (31, 0), (37, 0)])
        c.swing("Ear" + sd, (sx, 0, 0.5), [(1, 0), (7, 14), (13, 0), (19, 14), (26, 0), (37, 0)])
    c.swing("Head", SIDE, [(1, 0), (8, 10), (19, -10), (30, 0), (37, 0)])
    tail_wave(c, 37, 26, 8, lift=12)
    lids(c, [(4, 30)], 37)
    if dragon:
        c.swing("WingL", UP, wave(37, 35, 8, step=2)); c.swing("WingR", UP, wave(37, 35, 8, step=2))
    c.write()
    # Eat: lean to the bowl, three bites with closed happy eyes.
    c = Clip(arm, "Eat", 49, cyclic=False)
    c.swing("Chest", FRONT, [(1, 0), (8, 14), (41, 14), (49, 0)])
    c.swing("Head", FRONT, [(1, 0), (8, 22), (13, 12), (18, 24), (23, 12), (28, 24), (33, 12), (38, 22), (44, 0), (49, 0)])
    c.key("Chest", "scale", [(1, (1, 1, 1)), (13, (1.02, 0.98, 1.02)), (23, (1.02, 0.98, 1.02)), (33, (1.02, 0.98, 1.02)), (49, (1, 1, 1))])
    tail_wave(c, 49, 12, 16)
    lids(c, [(10, 38)], 49)
    c.write()
    # Sleep: slumped loaf, head down and tilted, tail curled forward, slow breath.
    c = Clip(arm, "Sleep", 97)
    c.key("Root", "location", [(1, (0, -0.025, 0)), (97, (0, -0.025, 0))])
    c.swing("Chest", FRONT, [(1, 14), (97, 14)])
    c.key("Chest", "scale", [(f, (1 + v, 1 - v * 0.5, 1 + v)) for f, v in wave(97, 0.035, 48, step=6)])
    c.swing("Head", FRONT, wave(97, 2, 48, step=8, base=12))
    c.swing("Head", SIDE, [(1, 14), (97, 14)])
    for sd, sx in (("L", -1), ("R", 1)):
        c.swing("Ear" + sd, (sx, 0, -0.6), [(1, 22), (97, 22)])
        c.swing("Wing" + sd, (0, 0, -1), [(1, 18), (97, 18)])
    tail_wave(c, 97, 2, 48, curl=34)
    lids(c, [(1, 97)], 97)
    c.write()
    # Sad (hungry): head and ears down, limp tail, slow sigh, one tired blink.
    c = Clip(arm, "Sad", 97)
    c.swing("Chest", FRONT, [(1, 8), (97, 8)])
    c.key("Chest", "scale", [(f, (1 + v, 1 - v, 1 + v)) for f, v in wave(97, 0.025, 96, step=8)])
    c.swing("Head", FRONT, wave(97, 3, 96, step=8, base=17))
    c.swing("Head", SIDE, [(1, -6), (97, -6)])
    for sd, sx in (("L", -1), ("R", 1)):
        c.swing("Ear" + sd, (sx, 0, -0.8), [(1, 34), (97, 34)])
        c.swing("Wing" + sd, (0, 0, -1), [(1, 14), (97, 14)])
    for k in range(TAIL_N):
        c.swing("Tail%d" % (k + 1), (0, 0, -1), [(1, 12 + 4 * k), (97, 12 + 4 * k)])
    lids(c, [(60, 66)], 97)
    c.write()
    # Spin: a full turn with a small hop.
    c = Clip(arm, "Spin", 31, cyclic=False)
    c.key("Root", "rotation_euler", [(1, (0, 0, 0)), (31, (0, R5(360), 0))])
    c.key("Root", "location", [(1, (0, 0, 0)), (16, (0, 0.06, 0)), (31, (0, 0, 0))])
    c.key("Hips", "scale", [(1, (1, 1, 1)), (16, (1.04, 0.95, 1.04)), (31, (1, 1, 1))])
    for sd, sx in (("L", -1), ("R", 1)):
        c.swing("Ear" + sd, (sx, 0, 0), [(1, 0), (16, 18), (31, 0)])
        c.swing("Leg" + sd, (sx, 0, 0.3), [(1, 0), (16, 35), (31, 0)])
    tail_wave(c, 31, 20, 15, lift=10)
    lids(c, [(10, 22)], 31)
    c.write()
    # Jump: crouch, big jump with tucked paws, landing squash.
    c = Clip(arm, "Jump", 25, cyclic=False)
    c.key("Root", "location", [(1, (0, 0, 0)), (4, (0, -0.02, 0)), (12, (0, 0.38, 0)), (21, (0, 0, 0)), (25, (0, 0, 0))])
    c.key("Hips", "scale", [(1, (1, 1, 1)), (4, (1.08, 0.88, 1.08)), (10, (0.95, 1.1, 0.95)), (21, (1.08, 0.9, 1.08)), (25, (1, 1, 1))])
    for sd, sx in (("L", -1), ("R", 1)):
        c.swing("Leg" + sd, (0, -1, 0.4), [(1, 0), (6, 40), (14, 40), (21, 0), (25, 0)])
        c.swing("Ear" + sd, (sx, 0, -0.3), [(1, 0), (8, -10), (14, 22), (22, 0), (25, 0)])
        c.swing("Wing" + sd, UP, [(1, 0), (12, 45), (25, 0)])
    tail_wave(c, 25, 6, 25, lift=25)
    c.write()
    # Stretch: a bow with paws forward, a yawn with closed eyes, tail up.
    c = Clip(arm, "Stretch", 49, cyclic=False)
    c.swing("Chest", FRONT, [(1, 0), (16, 34), (34, 34), (49, 0)])
    c.swing("Head", (0, 0, 1), [(1, 0), (16, 30), (34, 30), (49, 0)])
    for sd in ("L", "R"):
        c.swing("Leg" + sd, (0, -1, 0), [(1, 0), (16, 62), (34, 62), (49, 0)])
        c.swing("Wing" + sd, UP, [(1, 0), (16, 40), (34, 40), (49, 0)])
    c.key("Hips", "scale", [(1, (1, 1, 1)), (16, (0.96, 1.08, 0.96)), (34, (0.96, 1.08, 0.96)), (49, (1, 1, 1))])
    for k in range(TAIL_N):
        c.swing("Tail%d" % (k + 1), UP, [(1, 0), (16, 14), (34, 14), (49, 0)])
    lids(c, [(18, 34)], 49)
    c.write()
    # New, for later UI: Wave (paw wave hello) and Pet (leans into a stroke).
    c = Clip(arm, "Wave", 41, cyclic=False)
    c.swing("LegR", (0, -0.4, 1), [(1, 0), (8, 155), (34, 155), (41, 0)])
    c.swing("LegR", SIDE, [(1, 0), (8, 25), (12, 45), (16, 15), (20, 45), (24, 15), (28, 45), (34, 25), (41, 0)])
    c.swing("Head", SIDE, [(1, 0), (8, 12), (34, 12), (41, 0)])
    c.swing("Chest", SIDE, [(1, 0), (8, -5), (34, -5), (41, 0)])
    tail_wave(c, 41, 18, 10)
    lids(c, [(9, 33)], 41)
    c.write()
    c = Clip(arm, "Pet", 49, cyclic=False)
    c.swing("Head", SIDE, [(1, 0), (10, 16), (40, 16), (49, 0)])
    c.swing("Head", FRONT, [(1, 0), (10, -6), (40, -6), (49, 0)])
    c.swing("Chest", SIDE, [(1, 0), (10, 6), (40, 6), (49, 0)])
    for sd, sx in (("L", -1), ("R", 1)):
        c.swing("Ear" + sd, (sx, 0, -0.5), [(1, 0), (10, 20), (40, 20), (49, 0)])
    tail_wave(c, 49, 14, 12, lift=10)
    lids(c, [(8, 42)], 49)
    c.write()

def variants5():
    for species in ("cat", "fox", "dragon"):
        for stage in ("baby", "cub", "teen"):
            yield species, stage, None
        for path in PATHS5[species]:
            yield species, "adult", path

def build_pets5():
    sc = bpy.data.scenes.get(SCENE5) or bpy.data.scenes.new(SCENE5)
    bpy.context.window.scene = sc
    for c in list(sc.collection.children):
        for o in list(c.all_objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(c)
    rnd = random.Random(5)
    for row, species in enumerate(("cat", "fox", "dragon")):
        col = 0
        for sp, stage, path in variants5():
            if sp != species:
                continue
            build_pet(species, stage, path, offset=(col * 0.85, row * 1.1, 0), rnd=rnd)
            col += 1
    _accessories5(sc)
    _studio5(sc)
    return sc

# ------------------------------------------------------------------ accessories
def _acc_scene(name):
    s = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
    for o in list(s.collection.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    return s

def _accessories5(sc):
    """Accessories in socket space (origin = socket joint, front = -Y, up = +Z),
    sized for the teen head; heads change little between stages."""
    d = dims("cat", "teen")
    hr, bh, br = d["hr"] * K5, d["bh"] * K5, d["br"] * K5
    coll = bpy.data.collections.new("P5_Accessories"); sc.collection.children.link(coll)
    holder = bpy.data.objects.new("P5_Acc_Root", None); coll.objects.link(holder)
    holder.location = (-1.2, 0, 0)
    use(coll, parent=holder)
    # glasses: rims around the eyes. Socket_Face sits hr*0.98 in front of the head centre.
    gold = pm("Acc_glasses_frame", "#E2B45A", 0.2, metal=1.0)
    lens = pm("Acc_glasses_lens", "#DDE8FF", 0.05, coat=1.0)
    eye_x = hr * 1.08 * math.sin(0.36) * 0.98
    rim = hr * 0.3 * d["eye"] * 1.25
    g = []
    for sx in (-1, 1):
        g.append(torus("AccG_Rim%d" % sx, rim, rim * 0.12, (sx * eye_x, 0.012, 0.005), gold, rot=(90, 0, 0), seg=48, ring=10))
        o = cyl("AccG_Lens%d" % sx, rim * 0.96, 0.002, (sx * eye_x, 0.012, 0.005), lens, rot=(90, 0, 0), verts=40); g.append(o)
        g.append(tube("AccG_Temple%d" % sx, [(sx * (eye_x + rim), 0.012, 0.01), (sx * (eye_x + rim * 1.2), hr * 0.5, 0.02), (sx * hr * 0.95, hr * 0.9, 0.0)], rim * 0.09, gold))
    g.append(arc_tube("AccG_Bridge", eye_x - rim * 0.95, rim * 0.1, 30, 150, gold, r_end=1.0, loc=(0, 0.012, 0.01)))
    for o in g:
        o["acc"] = "glasses"
    # beanie: cap over the head top. Socket_Head sits hr*0.86 above the head centre.
    knit_b = pm("Acc_beanie_knit", "#86ABD6", 0.9, sss=0.1)
    cap_r = hr * 0.82
    b1 = revolve("AccB_Cap", [(cap_r, -hr * 0.22), (cap_r * 1.02, -hr * 0.08), (cap_r * 0.92, hr * 0.12), (cap_r * 0.65, hr * 0.3), (cap_r * 0.3, hr * 0.38), (0, hr * 0.4)], (0, 0, 0), knit_b, segs=48)
    b2 = torus("AccB_Cuff", cap_r * 1.0, hr * 0.08, (0, 0, -hr * 0.2), pm("Acc_beanie_rib", "#6F96C4", 0.9), seg=64, ring=12)
    b3 = ball("AccB_Pom", hr * 0.17, (0, 0, hr * 0.47), pm("Acc_beanie_pom", "#F5EFE6", 0.95, sss=0.2), segs=24, rings=16)
    for o in (b1, b2, b3):
        o["acc"] = "beanie"
    # scarf: a ring around the neck, two ends in front. Socket_Neck is the neck centre.
    sc_m = pm("Acc_scarf_knit", "#9C84C8", 0.9, sss=0.1)
    s1 = torus("AccS_Loop", br * 0.66, br * 0.16, (0, 0, -0.005), sc_m, seg=48, ring=14, scale=(1.1, 1.05, 0.8))
    s2 = rbox("AccS_End", (br * 0.32, br * 0.1, br * 0.75), (br * 0.25, -br * 0.72, -br * 0.38), sc_m, r=br * 0.05, rot=(12, 8, -6))
    s3 = rbox("AccS_Stripe", (br * 0.33, br * 0.105, br * 0.08), (br * 0.25, -br * 0.72, -br * 0.55), pm("Acc_scarf_stripe", "#F4EBDD", 0.9), r=br * 0.02, rot=(12, 8, -6))
    for o in (s1, s2, s3):
        o["acc"] = "scarf"
    _adopt(coll, holder)

def export_accessories5():
    for acc, file in (("glasses", "acc_glasses.glb"), ("beanie", "acc_beanie.glb"), ("scarf", "acc_scarf.glb")):
        s = _acc_scene("Export5_acc_" + acc)
        bpy.context.window.scene = bpy.data.scenes[SCENE5]
        dg = bpy.context.evaluated_depsgraph_get()
        holder = bpy.data.objects["P5_Acc_Root"]
        inv = holder.matrix_world.inverted()
        for o in bpy.data.collections["P5_Accessories"].objects:
            if o.get("acc") != acc:
                continue
            me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
            me.transform(inv @ o.matrix_world)
            no = bpy.data.objects.new(o.name, me); s.collection.objects.link(no)
        for d in OUT5:
            rp.export_glb(s, os.path.join(d, file))
        print("EXPORTED", file)

def export_pets5(only=None):
    done = []
    for species, stage, path in variants5():
        file = "%s_%s.glb" % (species, stage if path is None else "adult_" + path)
        if only and file not in only and species not in only:
            continue
        sc, arm, _ = bake5(species, stage, path)
        clips5(arm)
        for d in OUT5:
            os.makedirs(d, exist_ok=True)
            rp.export_glb(sc, os.path.join(d, file))
        done.append(file)
    if not only or "acc" in only:
        export_accessories5()
    bpy.context.window.scene = bpy.data.scenes[SCENE5]
    return done

# ------------------------------------------------------------------ previews
def _studio5(sc):
    coll = bpy.data.collections.new("P5_Studio"); sc.collection.children.link(coll)
    use(coll)
    _cycles_gpu()
    sc.render.engine = "CYCLES"; sc.cycles.device = "GPU"; sc.cycles.samples = 128
    sc.cycles.use_denoising = True
    sc.render.film_transparent = True
    sc.cycles.film_transparent_glass = True
    sc.render.resolution_x, sc.render.resolution_y = 768, 768
    sc.view_settings.view_transform = "AgX"
    for look in ("AgX - Punchy", "Punchy"):
        try:
            sc.view_settings.look = look; break
        except TypeError:
            continue
    if sc.world is None:
        w = bpy.data.worlds.new(SCENE5 + "_World"); w.use_nodes = True; sc.world = w
    world_color(sc, "#F3EAF4", 0.3)
    light("P5_Key", "AREA", (-1.2, -1.6, 2.2), 260, color=(1.0, 0.94, 0.86), size=1.6, rot=(45, 0, -35))
    light("P5_Rim", "AREA", (1.2, 1.6, 1.6), 180, color=(0.88, 0.85, 1.0), size=1.2, rot=(-55, 0, 145))
    light("P5_Fill", "AREA", (1.6, -1.2, 0.8), 60, color=(1.0, 0.9, 0.82), size=2.0, rot=(75, 0, 52))
    for n in ("P5_Key", "P5_Rim", "P5_Fill"):
        o = bpy.data.objects[n]; o["base_loc"] = list(o.location)
    c = box("P5_Catcher", (40, 40, 0.002), (0, 0, -0.001), soft("P5_CatcherM", "#FFFFFF", 0.8), bevel=0)
    c.is_shadow_catcher = True
    cd = bpy.data.cameras.new("P5_Cam"); cd.lens = 60
    cam = bpy.data.objects.new("P5_Cam", cd); coll.objects.link(cam); sc.camera = cam

def _frame_obj(sc, coll, view=Vector((0.35, -1.0, 0.32)), pad=1.1):
    from bpy_extras.object_utils import world_to_camera_view
    cam = sc.camera
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in coll.all_objects:
        if o.type in ("MESH", "CURVE"):
            oe = o.evaluated_get(dg); me = oe.to_mesh()
            if me:
                st = max(1, len(me.vertices) // 600)
                pts += [oe.matrix_world @ me.vertices[i].co for i in range(0, len(me.vertices), st)]
            oe.to_mesh_clear()
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    center = (lo + hi) / 2
    view = view.normalized()
    cam.rotation_euler = (-view).to_track_quat("-Z", "Y").to_euler()
    cam.data.shift_x = cam.data.shift_y = 0
    dist = 3.0
    for _ in range(4):
        cam.location = center + view * dist
        bpy.context.view_layer.update()
        ndc = [world_to_camera_view(sc, cam, p) for p in pts]
        ext = max(max(v.x for v in ndc) - min(v.x for v in ndc), max(v.y for v in ndc) - min(v.y for v in ndc))
        dist *= ext * pad
    cam.location = center + view * dist
    bpy.context.view_layer.update()
    ndc = [world_to_camera_view(sc, cam, p) for p in pts]
    cam.data.shift_x = (max(v.x for v in ndc) + min(v.x for v in ndc)) / 2 - 0.5
    cam.data.shift_y = (max(v.y for v in ndc) + min(v.y for v in ndc)) / 2 - 0.5
    base = Vector((center.x, center.y, 0))
    for n in ("P5_Key", "P5_Rim", "P5_Fill"):
        o = bpy.data.objects[n]; o.location = base + Vector(o["base_loc"])
    bpy.data.objects["P5_Catcher"].location = (center.x, center.y, -0.001)

def render_pets5(only=None, samples=128):
    os.makedirs(PREVIEW5, exist_ok=True)
    sc = bpy.data.scenes[SCENE5]
    bpy.context.window.scene = sc
    sc.cycles.samples = samples
    colls = [c for c in sc.collection.children if c.name.startswith("P5_") and c.name not in ("P5_Studio",)]
    done = []
    for c in colls:
        name = c.name[3:]
        if only and name not in only:
            continue
        for o in colls:
            o.hide_render = o is not c
        _frame_obj(sc, c)
        sc.render.filepath = os.path.join(PREVIEW5, name + ".png")
        bpy.ops.render.render(write_still=True, scene=sc.name)
        done.append(name)
    for o in colls:
        o.hide_render = False
    return done
