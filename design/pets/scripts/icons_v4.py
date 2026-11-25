# 3D item icons for «Питомник», version 4 (2026-11-25): detailed models, Cycles.
# Exec inside Blender after lib.py and rooms_v3.py (shared helpers/materials):
#   build_icons4(); render_icons4()            # all icons
#   render_icons4(only=["food_fish"])          # some icons
# Scene "Icons4": one collection "I4_<id>" per item, laid out on shelves by
# category; labels live in "I4_Labels" and never render. Output:
# design/pets/icons_v4/<id>.png — 512×512 RGBA with a soft contact shadow.
import bpy, bmesh, math, random, os
from mathutils import Vector, Matrix, Euler

ICON4_DIR = r"F:\project\PepeHub\design\pets\icons_v4"
SCENE4 = "Icons4"
VIEW4 = Vector((0.42, -1.0, 0.62)).normalized()      # camera direction from the item
FACE4 = math.radians(-68)                             # azimuth of the side that faces the camera

# ------------------------------------------------------------------ materials
def ceramic(name, c, rough=0.22, coat=0.7):
    m = soft(name, c, rough, coat=coat, sss=0.05)
    return m

def no_shadow(o):
    """Glass/water: let light through to what is inside (caustics are off)."""
    o.visible_shadow = False
    return o

def gold4(name="J_Gold"):
    return soft(name, "#E6B75A", 0.18, metal=1.0)

def glass4(name, tint="#FFFFFF", rough=0.01, ior=1.45):
    m, nt, b = _nm(name)
    b.inputs["Base Color"].default_value = (*hexc(tint), 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Transmission Weight"].default_value = 1.0
    b.inputs["IOR"].default_value = ior
    return m

def liquid(name, c, c_top=None, trans=0.8, sss=0.0, emit=0.0):
    """Coloured liquid; with c_top the colour runs bottom→top (object Z)."""
    m, nt, b = _nm(name)
    if c_top:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(tc.outputs["Generated"], sep.inputs[0])
        r = _ramp(nt, sep.outputs["Z"], c, c_top, 0.1, 0.9)
        nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
        if emit:
            nt.links.new(r.outputs["Color"], b.inputs["Emission Color"])
    else:
        b.inputs["Base Color"].default_value = (*hexc(c), 1)
        b.inputs["Emission Color"].default_value = (*hexc(c), 1)
    b.inputs["Emission Strength"].default_value = emit
    b.inputs["Roughness"].default_value = 0.08
    b.inputs["Transmission Weight"].default_value = trans
    b.inputs["Subsurface Weight"].default_value = sss
    b.inputs["IOR"].default_value = 1.33
    m.diffuse_color = (*hexc(c), 1)
    return m

def gradient_mat(name, axis, stops, rough=0.35, coat=0.4, thin_film=0.0, sss=0.0, bump=None):
    """Colour ramp along an object-space axis. stops = [(pos, '#hex'), ...]."""
    m, nt, b = _nm(name)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    r = nt.nodes.new("ShaderNodeValToRGB")
    els = r.color_ramp.elements
    els[0].position, els[0].color = stops[0][0], (*hexc(stops[0][1]), 1)
    els[1].position, els[1].color = stops[-1][0], (*hexc(stops[-1][1]), 1)
    for pos, c in stops[1:-1]:
        e = els.new(pos); e.color = (*hexc(c), 1)
    nt.links.new(sep.outputs[axis], r.inputs["Fac"])
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Subsurface Weight"].default_value = sss
    if thin_film:
        b.inputs["Thin Film Thickness"].default_value = thin_film
    if bump:
        kind, scale, strength = bump
        tex = nt.nodes.new("ShaderNodeTexVoronoi" if kind == "voronoi" else "ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = scale
        nt.links.new(tc.outputs["Object"], tex.inputs["Vector"])
        out = tex.outputs["Distance"] if kind == "voronoi" else tex.outputs["Fac"]
        _bump(nt, b, out, strength, 0.002)
    m.diffuse_color = (*hexc(stops[len(stops) // 2][1]), 1)
    return m

def knit_stripes(name, c1, c2, c_dark, stripe=0.03, scale=95.0, strength=0.9):
    """Knit stitches (V rows) plus colour stripes every `stripe` metres along object X."""
    m = knit(name, c1, c_dark, scale=scale, strength=strength)
    nt = m.node_tree
    b = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    ramp = next(n for n in nt.nodes if n.type == "VALTORGB")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    mo = nt.nodes.new("ShaderNodeMath"); mo.operation = "PINGPONG"; mo.inputs[1].default_value = stripe
    nt.links.new(sep.outputs["X"], mo.inputs[0])
    gt = nt.nodes.new("ShaderNodeMath"); gt.operation = "GREATER_THAN"; gt.inputs[1].default_value = stripe * 0.62
    nt.links.new(mo.outputs[0], gt.inputs[0])
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"
    nt.links.new(gt.outputs[0], mix.inputs["Factor"])
    nt.links.new(ramp.outputs["Color"], mix.inputs[6])
    mix.inputs[7].default_value = (*hexc(c2), 1)
    nt.links.new(mix.outputs[2], b.inputs["Base Color"])
    return m

def cork(name="J_Cork"):
    m, nt, b = _nm(name)
    v = _coords(nt)
    n = nt.nodes.new("ShaderNodeTexNoise"); n.inputs["Scale"].default_value = 350.0; n.inputs["Detail"].default_value = 6
    nt.links.new(v, n.inputs["Vector"])
    r = _ramp(nt, n.outputs["Fac"], "#9C7048", "#D8AE7E", 0.35, 0.65)
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.85
    _bump(nt, b, n.outputs["Fac"], 0.6, 0.002)
    return m

def sparkle_mat():
    return glow("J_Sparkle", "#FFF6D8", 12.0, base="#FFFFFF")

# ------------------------------------------------------------------ geometry
def slab(name, pts, thick, m, loc=(0, 0, 0), rot=(0, 0, 0), parent=None, bevel=0.0015):
    """2D outline (XY) extruded along Z and bevelled: fins, leaves, labels."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    vs = [bm.verts.new((x, y, -thick / 2)) for x, y in pts]
    f = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    top = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=(0, 0, thick), verts=top)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free()
    me.shade_smooth()
    try:
        me.set_sharp_from_angle(angle=math.radians(50))
    except Exception:
        pass
    o = _link(name, me, m, loc, rot, parent=parent)
    if bevel:
        b = o.modifiers.new("Bevel", "BEVEL"); b.width = bevel; b.segments = 3; b.limit_method = "ANGLE"
    return o

def leaf_pts(L, W, n=14, tip=1.0):
    up = [(L * i / (n - 1), W * max(math.sin(math.pi * i / (n - 1)), 0.0) ** 0.85 * (1 - 0.25 * i / (n - 1))) for i in range(n)]
    lo = [(x, -y) for x, y in reversed(up[1:-1])]
    return up + lo

def loft(name, rings, m, loc=(0, 0, 0), rot=(0, 0, 0), parent=None, subd=1):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    vr = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    for i in range(len(vr) - 1):
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((vr[i][j], vr[i][k], vr[i + 1][k], vr[i + 1][j]))
    for ring, rev in ((vr[0], True), (vr[-1], False)):
        c = bm.verts.new(sum((v.co for v in ring), Vector()) / n)
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((ring[k], ring[j], c) if rev else (ring[j], ring[k], c))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free(); me.shade_smooth()
    o = _link(name, me, m, loc, rot, parent=parent)
    if subd:
        s = o.modifiers.new("Subd", "SUBSURF"); s.levels = subd; s.render_levels = subd
    return o

def fish_rings(L, H, W, n=36, seg=24, lying=True, belly=0.85):
    rings = []
    for i in range(n + 1):
        t = i / n
        u = (t - 0.38) / 0.38 if t < 0.38 else (t - 0.38) / 0.62
        s = max((1 - abs(u) ** 2.1), 0.0) ** 0.55
        if t > 0.38:
            s = max(s, 0.16 * (t - 0.38) / 0.62)
        x = -L / 2 + L * t
        h, w = max(H * s, 0.0008), max(W * s, 0.0008)
        ring = []
        for j in range(seg):
            a = 2 * math.pi * j / seg
            sa, ca = math.sin(a), math.cos(a)
            vert = h * ca * (1.0 if ca > 0 else belly)
            side = w * sa
            ring.append((x, vert, side) if lying else (x, side, vert))
        rings.append(ring)
    return rings

def arc_tube(name, R, r_mid, a0, a1, m, segs=56, ring=18, r_end=0.2, loc=(0, 0, 0), rot=(0, 0, 0), parent=None):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    rings = []
    for i in range(segs + 1):
        t = i / segs
        a = math.radians(a0 + (a1 - a0) * t)
        c = Vector((R * math.cos(a), 0, R * math.sin(a)))
        nrm = Vector((math.cos(a), 0, math.sin(a)))
        b = Vector((0, 1, 0))
        rr = r_mid * (r_end + (1 - r_end) * max(math.sin(math.pi * t), 0.0) ** 0.7) if r_end < 1 else r_mid
        rings.append([bm.verts.new(c + (nrm * math.cos(2 * math.pi * j / ring) + b * math.sin(2 * math.pi * j / ring)) * rr) for j in range(ring)])
    for i in range(segs):
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    bm.faces.new(list(reversed(rings[0]))); bm.faces.new(rings[-1])
    bm.normal_update(); bm.to_mesh(me); bm.free(); me.shade_smooth()
    return _link(name, me, m, loc, rot, parent=parent)

def star4(name, r=0.012, m=None, loc=(0, 0, 0), rot=(0, 0, 0)):
    """Four-point twinkle, faces the camera roughly (XZ plane)."""
    pts = []
    for i in range(8):
        a = math.pi / 2 + i * math.pi / 4
        rr = r if i % 2 == 0 else r * 0.22
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    o = slab(name, pts, 0.001, m or sparkle_mat(), loc, (90 + rot[0], rot[1], math.degrees(FACE4) + 90 + rot[2]), bevel=0)
    return o

def star5(name, r1, r2, thick, m, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.002, parent=None):
    pts = []
    for i in range(10):
        a = math.pi / 2 + i * math.pi / 5
        rr = r1 if i % 2 == 0 else r2
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    return slab(name, pts, thick, m, loc, rot, parent=parent, bevel=bevel)

def on_front(r, z, a=None):
    """Point on a vertical surface of radius r facing the camera."""
    a = FACE4 if a is None else a
    return (r * math.cos(a), r * math.sin(a), z)

def paw_decal(prefix, center_r, z, m, s=1.0, a=None, outward=0.0012, slope=0.0):
    """Paw print stuck on a round wall (radius center_r at height z), facing the camera.
    slope: how much the wall leans outward from vertical, degrees."""
    a = FACE4 if a is None else a
    ph = math.radians(slope)
    out = Vector((math.cos(a), math.sin(a), 0))
    tang = Vector((-math.sin(a), math.cos(a), 0))
    nrm = (out * math.cos(ph) - Vector((0, 0, 1)) * math.sin(ph)).normalized()
    up = nrm.cross(tang).normalized() * -1
    if up.z < 0:
        up = -up
    rot = Matrix((tang, up, nrm)).transposed().to_euler()
    rdeg = tuple(math.degrees(v) for v in rot)
    base = out * center_r + Vector((0, 0, z))
    bt = Batch(prefix + "Paw")
    def put(dx, dz, rad, sz):
        p = base + tang * dx * s + up * dz * s + nrm * outward
        bt.sphere(m, rad * s, tuple(p), scale=(1, 1, sz), rot=rdeg, segs=16, rings=10)
    put(0, -0.006, 0.013, 0.3)
    for dx, dz in [(-0.015, 0.008), (-0.005, 0.016), (0.005, 0.016), (0.015, 0.008)]:
        put(dx, dz, 0.0055, 0.35)
    return bt.build()

def bowl4(prefix, m, r=0.13, h=0.075, wall=0.012, foot=0.6):
    """Thick ceramic bowl with a foot ring and rounded rim."""
    prof = [(0.0, 0.004), (r * foot, 0.0), (r * foot + 0.004, 0.006), (r * 0.8, h * 0.35), (r * 0.97, h * 0.8),
            (r, h), (r - wall * 0.5, h + wall * 0.35), (r - wall, h * 0.98), (r * 0.83 - wall, h * 0.5),
            (r * 0.55, wall * 1.3), (0.0, wall * 1.2)]
    o = revolve(prefix + "Bowl", prof, (0, 0, 0), m, segs=96)
    s = o.modifiers.new("Subd", "SUBSURF"); s.levels = 1; s.render_levels = 2
    return o

def plate4(prefix, m, rim_m, r=0.19):
    prof = [(0.0, 0.006), (r * 0.55, 0.0), (r * 0.6, 0.004), (r * 0.66, 0.008), (r * 0.92, 0.02), (r, 0.026),
            (r - 0.006, 0.029), (r * 0.9, 0.024), (r * 0.64, 0.012), (0.0, 0.012)]
    o = revolve(prefix + "Plate", prof, (0, 0, 0), m, segs=96)
    s = o.modifiers.new("Subd", "SUBSURF"); s.levels = 1; s.render_levels = 2
    torus(prefix + "PlateBand", r * 0.93, 0.0022, (0, 0, 0.0232), rim_m, seg=96, ring=8, scale=(1, 1, 0.5))
    return o

def twig_nest(prefix, R=0.078, rnd=None, h=0.045, n=56):
    rnd = rnd or random.Random(1)
    mats = [soft(prefix + "Twig%d" % i, c, 0.8) for i, c in enumerate(["#8A6448", "#A57C57", "#6F4E36", "#C9A274"])]
    cyl(prefix + "NestBed", R * 0.92, 0.014, (0, 0, 0.008), soft(prefix + "NestBedM", "#B08A62", 0.9), verts=48)
    for i in range(n):
        a0 = rnd.uniform(0, 2 * math.pi)
        span = rnd.uniform(1.0, 2.4)
        z = rnd.uniform(0.006, h)
        rr = R * (0.9 + 0.35 * (z / h)) + rnd.uniform(-0.006, 0.006)
        pts = []
        for k in range(5):
            a = a0 + span * k / 4
            pts.append((rr * math.cos(a), rr * math.sin(a), z + rnd.uniform(-0.006, 0.006)))
        tube(prefix + "Twig%d" % i, pts, rnd.uniform(0.0022, 0.0038), rnd.choice(mats), res=6)
    leaf = soft(prefix + "NestLeaf", "#7FAE5E", 0.5, sss=0.2)
    for i in range(3):
        a = rnd.uniform(-1.6, -0.6)
        slab(prefix + "NestLeaf%d" % i, leaf_pts(0.03, 0.009), 0.0015, leaf,
             (R * 1.05 * math.cos(a), R * 1.05 * math.sin(a), h * 0.8), (rnd.uniform(-30, 30), rnd.uniform(-40, -10), math.degrees(a)))

def sparkles(prefix, pts, size=0.012):
    m = sparkle_mat()
    for i, p in enumerate(pts):
        star4(prefix + "Spark%d" % i, size * (0.6 + 0.5 * (i % 2)), m, p)

# ------------------------------------------------------------------ items
def _coll4(item_id):
    root = bpy.data.scenes[SCENE4].collection
    c = bpy.data.collections.get("I4_" + item_id)
    if c is None:
        c = bpy.data.collections.new("I4_" + item_id)
        root.children.link(c)
    use(c)
    return c

def j_kibble(rnd):
    _coll4("food_kibble")
    bowl4("Kb4_", ceramic("J_BowlLav", "#9C84C8"), r=0.13, h=0.07)
    paw_decal("Kb4_", 0.1155, 0.042, ceramic("J_PawCream", "#FBF1E2", 0.3), s=1.15, slope=35)
    kib = [soft("J_Kib%d" % i, c, 0.45, coat=0.25) for i, c in enumerate(["#B9783C", "#9E6130", "#CF9152", "#8A5328"])]
    bt = Batch("Kb4_Kibble")
    for i in range(150):
        a = rnd.uniform(0, 2 * math.pi); r = math.sqrt(rnd.random()) * 0.105
        z = 0.03 + 0.055 * (1 - (r / 0.11) ** 2) + rnd.uniform(-0.004, 0.01)
        kind = rnd.random()
        if kind < 0.55:   # round pellets
            bt.cyl(rnd.choice(kib), 0.011, 0.008, (math.cos(a) * r, math.sin(a) * r, z), rot=(rnd.uniform(0, 180), rnd.uniform(0, 180), 0), segs=14)
        elif kind < 0.85:  # little bones
            rz = rnd.uniform(0, 180); m = rnd.choice(kib)
            c = Vector((math.cos(a) * r, math.sin(a) * r, z))
            d = Vector((math.cos(math.radians(rz)), math.sin(math.radians(rz)), 0)) * 0.008
            bt.cyl(m, 0.004, 0.017, tuple(c), rot=(90, 0, rz + 90), segs=10)
            for s in (-1, 1):
                for q in (-1, 1):
                    off = Vector((-d.y, d.x, 0)).normalized() * 0.0035 * q
                    bt.sphere(m, 0.0045, tuple(c + d * s + off), segs=10, rings=6)
        else:              # fish-shaped triangles
            bt.cyl(rnd.choice(kib), 0.011, 0.007, (math.cos(a) * r, math.sin(a) * r, z), rot=(rnd.uniform(-30, 30), rnd.uniform(-30, 30), rnd.uniform(0, 360)), r2=0.004, segs=3)
    for o in bt.build():
        b = o.modifiers.new("Bevel", "BEVEL"); b.width = 0.0018; b.segments = 2; b.limit_method = "ANGLE"
    sparkles("Kb4_", [(0.1, -0.06, 0.13), (-0.12, -0.02, 0.1)])

def j_fish(rnd):
    _coll4("food_fish")
    plate4("Fi4_", ceramic("J_Plate", "#FBF7F0"), ceramic("J_PlateRim", "#9C84C8"), r=0.175)
    body = gradient_mat("J_FishBody", "Y", [(0.0, "#DCE7F2"), (0.3, "#86A8D6"), (0.6, "#4F75B3"), (1.0, "#2E4C86")],
                        rough=0.3, coat=0.7, thin_film=380, bump=("voronoi", 260.0, 0.35))
    fin = soft("J_FishFin", "#7F9FD0", 0.35, coat=0.4, sss=0.4)
    g = empty("Fi4_Fish", (-0.01, 0.0, 0.032)); g.rotation_euler = (0, 0, math.radians(-12))
    L, H, W = 0.27, 0.078, 0.04
    loft("Fi4_Body", fish_rings(L, H, W), body, parent=g)
    tail = [(0.0, 0.01), (0.03, 0.03), (0.062, 0.058), (0.07, 0.052), (0.052, 0.012), (0.05, 0.0), (0.052, -0.012), (0.07, -0.052), (0.062, -0.058), (0.03, -0.03), (0.0, -0.01)]
    slab("Fi4_Tail", tail, 0.006, fin, (L / 2 - 0.008, 0, 0), parent=g)
    dorsal = [(-0.06, 0.0), (-0.04, 0.03), (0.0, 0.038), (0.04, 0.024), (0.06, 0.0)]
    slab("Fi4_Dorsal", dorsal, 0.004, fin, (0.01, H * 0.82, 0), parent=g)
    anal = [(-0.02, 0.0), (0.0, -0.018), (0.03, -0.016), (0.04, 0.0)]
    slab("Fi4_Anal", anal, 0.004, fin, (0.05, -H * 0.62, 0), parent=g)
    slab("Fi4_Pectoral", leaf_pts(0.04, 0.012), 0.003, fin, (-0.05, -0.008, W * 0.85), (0, -12, 200), parent=g)
    # gill line, eye, mouth
    arc_tube("Fi4_Gill", 0.04, 0.0018, -60, 60, soft("J_FishGill", "#6E8DB3", 0.4), r_end=0.3, loc=(-0.105, 0.0, W * 0.72), rot=(90, 0, 0), parent=g)
    ball("Fi4_Eye", 0.018, (-0.092, 0.008, W * 0.62), ceramic("J_EyeWhite", "#FFFFFF", 0.1), parent=g)
    ball("Fi4_Pupil", 0.012, (-0.094, 0.008, W * 0.62 + 0.009), soft("J_Ink", "#1F1830", 0.1, coat=1.0), parent=g)
    ball("Fi4_Shine", 0.004, (-0.098, 0.013, W * 0.62 + 0.019), glow("J_Shine", "#FFFFFF", 4.0), parent=g)
    for k in range(3):
        arc_tube("Fi4_Stripe%d" % k, 0.05, 0.0028, -38, 38, soft("J_FishStripe", "#2E4C86", 0.4), r_end=0.25,
                 loc=(-0.02 + k * 0.035, 0.0, W * (0.86 - 0.08 * k)), rot=(90, 0, 0), parent=g)
    ball("Fi4_Blush", 0.008, (-0.105, -0.018, W * 0.55), soft("J_Blush", "#F2A6B8", 0.6), scale=(1.2, 1, 0.3), parent=g)
    arc_tube("Fi4_Mouth", 0.008, 0.0015, 200, 300, soft("J_Mouth", "#4E3E58", 0.4), r_end=1.0, loc=(-0.127, -0.006, W * 0.25), rot=(90, 0, 0), parent=g)
    # lemon slice + herbs
    lg = empty("Fi4_Lemon", (0.1, 0.09, 0.022)); lg.rotation_euler = (math.radians(12), 0, math.radians(20))
    cyl("Fi4_Rind", 0.034, 0.008, (0, 0, 0), soft("J_Rind", "#F2D33E", 0.35, coat=0.4), verts=48, parent=lg)
    cyl("Fi4_Pith", 0.031, 0.0085, (0, 0, 0), soft("J_Pith", "#FBF3D2", 0.5), verts=48, parent=lg)
    pulp = soft("J_Pulp", "#F7DF5E", 0.15, sss=0.6, coat=0.5)
    for k in range(8):
        a = 2 * math.pi * k / 8
        pts = [(0.003, 0.0)] + [(0.026 * math.cos(q), 0.026 * math.sin(q)) for q in (a - 0.32, a - 0.16, a, a + 0.16, a + 0.32)]
        pts = [(0.003 * math.cos(a), 0.003 * math.sin(a))] + pts[1:]
        slab("Fi4_Seg%d" % k, pts, 0.009, pulp, (0, 0, 0.0005), parent=lg, bevel=0.0012)
    herb = soft("J_Parsley", "#5FA348", 0.45, sss=0.3)
    for i in range(7):
        a = rnd.uniform(1.6, 2.6)
        slab("Fi4_Herb%d" % i, leaf_pts(0.026, 0.011), 0.0012, herb,
             (-0.09 + rnd.uniform(-0.02, 0.02), 0.1 + rnd.uniform(-0.015, 0.015), 0.027), (rnd.uniform(-15, 15), rnd.uniform(-15, 15), math.degrees(a) + rnd.uniform(-60, 60)))
    sparkles("Fi4_", [(0.12, -0.12, 0.09), (-0.16, -0.08, 0.06)])

def _strawberry4(name, loc, s, rot, rnd):
    red = soft("J_Straw", "#D82C3A", 0.22, coat=0.8, sss=0.35)
    seed = soft("J_Seed", "#F5D46A", 0.35)
    calyx = soft("J_Calyx", "#4E9A3A", 0.45, sss=0.2)
    g = empty(name, loc); g.rotation_euler = [math.radians(a) for a in rot]
    prof = [(0, 0), (0.005 * s, 0.002 * s), (0.015 * s, 0.012 * s), (0.023 * s, 0.028 * s), (0.026 * s, 0.042 * s), (0.023 * s, 0.052 * s), (0.013 * s, 0.058 * s), (0, 0.06 * s)]
    revolve(name + "_B", prof, (0, 0, 0), red, segs=40, parent=g)
    bt = Batch(name + "_S")
    for k in range(44):
        t = 0.08 + 0.78 * (k / 44)
        z = 0.06 * s * t
        # interpolate radius on the profile
        rr = 0
        for (r1, z1), (r2, z2) in zip(prof, prof[1:]):
            if z1 <= z <= z2:
                rr = r1 + (r2 - r1) * (z - z1) / max(z2 - z1, 1e-6); break
        a = k * 2.39996
        bt.sphere(seed, 0.0016 * s, (math.cos(a) * rr * 0.99, math.sin(a) * rr * 0.99, z), scale=(1, 1, 1.6), segs=6, rings=4)
    bt.build(parent=g)
    for k in range(7):
        a = 2 * math.pi * k / 7
        slab(name + "_L%d" % k, leaf_pts(0.022 * s, 0.008 * s), 0.0012, calyx,
             (math.cos(a) * 0.004 * s, math.sin(a) * 0.004 * s, 0.059 * s), (0, -25, math.degrees(a)), parent=g)
    tube(name + "_Stem", [(0, 0, 0.058 * s), (0.002 * s, 0, 0.068 * s), (0.005 * s, 0, 0.074 * s)], 0.0018 * s, calyx)
    bpy.data.objects[name + "_Stem"].parent = g

def _raspberry4(prefix, bt, m, c, s=1.0, rnd=None):
    n = 46
    for k in range(n):
        t = (k + 0.5) / n
        th = math.acos(1 - 1.7 * t)
        ph = k * 2.39996
        R, Hh = 0.015 * s, 0.02 * s
        p = (c[0] + R * math.sin(th) * math.cos(ph), c[1] + R * math.sin(th) * math.sin(ph), c[2] + Hh * math.cos(th) * 0.9)
        bt.sphere(m, 0.0052 * s, p, segs=10, rings=8)

def _blueberry4(prefix, i, loc, s=1.0):
    blue = soft("J_Blue", "#34407E", 0.5, sss=0.1)
    blue.node_tree.nodes["Principled BSDF"].inputs["Sheen Weight"].default_value = 0.9
    blue.node_tree.nodes["Principled BSDF"].inputs["Sheen Tint"].default_value = (*hexc("#C9D6F2"), 1)
    ball(prefix + "Blue%d" % i, 0.014 * s, loc, blue, scale=(1, 1, 0.86), segs=24, rings=16)
    star5(prefix + "BlueCrown%d" % i, 0.0045 * s, 0.002 * s, 0.002, soft("J_BlueCrown", "#20264F", 0.6), (loc[0], loc[1], loc[2] + 0.0118 * s), (0, 0, 0), bevel=0.0005)

def j_berries(rnd):
    _coll4("food_berries")
    bowl4("Be4_", ceramic("J_BowlCream", "#F7EFE3"), r=0.13, h=0.075)
    torus("Be4_Band", 0.126, 0.0025, (0, 0, 0.062), ceramic("J_BowlBand", "#9C84C8"), seg=96, ring=8, scale=(1, 1, 0.6))
    rasp = soft("J_Rasp", "#D8416A", 0.32, sss=0.5, coat=0.4)
    bt = Batch("Be4_Rasp")
    spots = []
    for i in range(48):
        a = rnd.uniform(0, 2 * math.pi); r = math.sqrt(rnd.random()) * 0.1
        z = 0.072 + 0.055 * (1 - (r / 0.105) ** 2) + rnd.uniform(-0.006, 0.006)
        spots.append((math.cos(a) * r, math.sin(a) * r, z))
    for i, p in enumerate(spots):
        if i % 3 == 0:
            _raspberry4("Be4_", bt, rasp, p, 1.0, rnd)
        else:
            _blueberry4("Be4_", i, p, 1.0)
    bt.build()
    _strawberry4("Be4_StrawA", (0.02, -0.035, 0.118), 1.35, (40, 0, 25), rnd)
    _strawberry4("Be4_StrawB", (-0.05, 0.03, 0.118), 1.2, (-30, 20, 0), rnd)
    _strawberry4("Be4_StrawC", (0.165, -0.07, 0.024), 1.15, (95, 0, -40), rnd)
    _blueberry4("Be4_Out", 1, (0.12, -0.12, 0.014), 1.0)
    _blueberry4("Be4_Out", 2, (0.145, -0.1, 0.014), 1.0)
    mint = soft("J_Mint", "#5DB04E", 0.4, sss=0.35)
    for i, (x, y, rz) in enumerate([(0.04, 0.05, 30), (0.055, 0.035, -20), (0.05, 0.06, 80)]):
        slab("Be4_Mint%d" % i, leaf_pts(0.04, 0.014), 0.0012, mint, (x, y, 0.14), (rnd.uniform(-20, 20), -15, rz))
    sparkles("Be4_", [(0.1, -0.08, 0.16), (-0.13, -0.05, 0.12)])

def _star_profile(name, r1=0.011, r2=0.0058, points=7):
    """Closed star outline used as a bevel object: piping-bag tip."""
    helpers = bpy.data.collections.get("I4_Helpers")
    cu = bpy.data.curves.new(name, "CURVE"); cu.dimensions = "2D"
    sp = cu.splines.new("POLY")
    n = points * 2
    sp.points.add(n - 1)
    for i in range(n):
        a = 2 * math.pi * i / n
        r = r1 if i % 2 == 0 else r2
        sp.points[i].co = (r * math.cos(a), r * math.sin(a), 0, 1)
    sp.use_cyclic_u = True
    o = bpy.data.objects.new(name, cu)
    helpers.objects.link(o)
    return o

def j_cake(rnd):
    _coll4("food_cake")
    wrap = soft("J_Wrapper", "#A58ED0", 0.35, coat=0.5)
    me = bpy.data.meshes.new("Ck4_Wrap")
    bm = bmesh.new()
    segs, rows = 160, 10
    grid = []
    for k in range(rows + 1):
        z = 0.075 * k / rows
        rr = 0.058 + 0.024 * k / rows
        row = []
        for i in range(segs):
            a = 2 * math.pi * i / segs
            rad = rr * (1 + 0.03 * math.cos(a * 32))
            row.append(bm.verts.new((rad * math.cos(a), rad * math.sin(a), z)))
        grid.append(row)
    for k in range(rows):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((grid[k][i], grid[k][j], grid[k + 1][j], grid[k + 1][i]))
    bm.faces.new(list(reversed(grid[0])))
    bm.to_mesh(me); bm.free(); me.shade_smooth()
    w = _link("Ck4_Wrap", me, wrap)
    so = w.modifiers.new("Solid", "SOLIDIFY"); so.thickness = 0.0015
    # white polka dots on the wrapper
    db = Batch("Ck4_Dots")
    for k in range(14):
        a = 2 * math.pi * k / 14 + (0.2 if k % 2 else 0)
        z = 0.022 + (0.03 if k % 2 else 0)
        rr = 0.058 + 0.024 * z / 0.075 + 0.0015
        db.sphere(ceramic("J_Dot", "#FFF8F0", 0.4), 0.0045, (rr * math.cos(a), rr * math.sin(a), z), scale=(1, 1, 1), segs=10, rings=6)
    db.build()
    sponge = soft("J_Sponge", "#B87436", 0.75)
    revolve("Ck4_Cake", [(0, 0.07), (0.084, 0.073), (0.09, 0.085), (0.08, 0.098), (0, 0.104)], (0, 0, 0), sponge)
    # piped frosting: a spiral swept with a star-shaped piping tip
    prof = _star_profile("Ck4_Tip")
    cu = bpy.data.curves.new("Ck4_Frost", "CURVE"); cu.dimensions = "3D"
    cu.bevel_mode = "OBJECT"; cu.bevel_object = prof; cu.use_fill_caps = True
    cu.resolution_u = 4
    sp = cu.splines.new("POLY")
    N = 220
    sp.points.add(N - 1)
    pts = []
    for i in range(N):
        t = i / (N - 1)
        a = t * 2 * math.pi * 3.1
        r = 0.062 * (1 - t) ** 0.9
        z = 0.103 + 0.085 * t ** 0.85
        sp.points[i].co = (r * math.cos(a), r * math.sin(a), z, 1)
        sp.points[i].radius = 2.0 - 0.95 * t
        pts.append((r, a, z, 2.0 - 0.95 * t))
    fo = bpy.data.objects.new("Ck4_Frost", cu); _CTX["coll"].objects.link(fo)
    frost = soft("J_Frost", "#F6BFD2", 0.3, sss=0.3, coat=0.3)
    cu.materials.append(frost)
    ball("Ck4_FrostTip", 0.012, (0, 0, 0.192), frost, scale=(1, 1, 1.4))
    sp_m = [soft("J_Spr%d" % i, c, 0.3, coat=0.7) for i, c in enumerate(["#F27DA0", "#7FD1B8", "#F6D45E", "#8E76C2", "#FFFFFF", "#7FB7E9"])]
    bt = Batch("Ck4_Sprinkles")
    for i in range(70):
        k = rnd.randint(5, len(pts) - 20)
        r, a, z, rad = pts[k]
        off = 0.011 * rad * 0.95
        q = rnd.uniform(-1.2, 1.2)
        pos = ((r + off * math.cos(q)) * math.cos(a), (r + off * math.cos(q)) * math.sin(a), z + off * math.sin(q))
        bt.cyl(rnd.choice(sp_m), 0.0018, 0.008, pos, rot=(rnd.uniform(0, 180), rnd.uniform(0, 180), 0), segs=8)
    bt.build()
    star5("Ck4_Star", 0.03, 0.014, 0.012, gold4(), (0, 0, 0.228), (90, 0, math.degrees(FACE4) + 90 + 12), bevel=0.003)
    sparkles("Ck4_", [(0.07, -0.08, 0.24), (-0.08, -0.05, 0.2)])

def _flask_profile(s=1.0):
    return [(0, 0), (0.03 * s, 0.0), (0.05 * s, 0.008 * s), (0.062 * s, 0.028 * s), (0.065 * s, 0.05 * s), (0.06 * s, 0.075 * s),
            (0.042 * s, 0.095 * s), (0.022 * s, 0.107 * s), (0.018 * s, 0.114 * s), (0.018 * s, 0.15 * s), (0.023 * s, 0.155 * s), (0.023 * s, 0.163 * s), (0.017 * s, 0.163 * s)]

def _prof_r(prof, z):
    for (r1, z1), (r2, z2) in zip(prof, prof[1:]):
        if z1 <= z <= z2 and z2 > z1:
            return r1 + (r2 - r1) * (z - z1) / (z2 - z1)
    return 0.0

def j_potion(item_id, c, c_top=None, emit=0.0, trans=0.75, sss=0.0, reward=False, inner_stars=False, rnd=None):
    _coll4(item_id)
    P = "Po4_" + item_id + "_"
    prof = _flask_profile()
    gl = no_shadow(revolve(P + "Glass", prof, (0, 0, 0), glass4("J_FlaskGlass", "#F6FAFF"), segs=64))
    so = gl.modifiers.new("Solid", "SOLIDIFY"); so.thickness = 0.0025; so.offset = -1
    fill = 0.08
    zs = [0.004 + (fill - 0.004) * k / 14 for k in range(15)]
    lp = [(0.0, 0.004)] + [(_prof_r(prof, z) - 0.0035, z) for z in zs] + [(0.0, fill)]
    no_shadow(revolve(P + "Liquid", lp, (0, 0, 0), liquid("J_Liq_" + item_id, c, c_top, trans=trans, sss=sss, emit=emit), segs=64))
    if inner_stars:
        bt = Batch(P + "Glitter")
        gm = glow("J_Glitter", "#FFF2C4", 8.0)
        for i in range(26):
            a = rnd.uniform(0, 2 * math.pi); z = rnd.uniform(0.012, fill - 0.008)
            r = (_prof_r(prof, z) - 0.01) * math.sqrt(rnd.random())
            bt.sphere(gm, rnd.uniform(0.0012, 0.0024), (r * math.cos(a), r * math.sin(a), z), segs=6, rings=4)
        bt.build()
    revolve(P + "Cork", [(0, 0.146), (0.0155, 0.146), (0.019, 0.172), (0.0195, 0.178), (0, 0.18)], (0, 0, 0), cork())
    if reward:
        revolve(P + "Cap", [(0, 0.176), (0.021, 0.176), (0.022, 0.184), (0.012, 0.19), (0, 0.191)], (0, 0, 0), gold4())
        star5(P + "CapStar", 0.012, 0.0055, 0.004, gold4(), (0, 0, 0.2), (90, 0, math.degrees(FACE4) + 90), bevel=0.001)
    ribbon = soft("J_Ribbon", "#9C84C8", 0.45, sheen=0.6)
    torus(P + "Ribbon", 0.0195, 0.0028, (0, 0, 0.128), ribbon, seg=48, ring=10, scale=(1, 1, 0.8))
    for s in (-1, 1):
        torus(P + "Bow%d" % s, 0.008, 0.0022, on_front(0.021, 0.128, FACE4 + s * 0.42), ribbon, rot=(90, 0, math.degrees(FACE4) + s * 35), seg=24, ring=8, scale=(1.4, 1, 0.7))
    # little tag on a string with a paw in the potion colour
    tx, ty, tz = on_front(0.088, 0.07, FACE4 + 0.62)
    tube(P + "String", [on_front(0.021, 0.128, FACE4 + 0.3), on_front(0.06, 0.11, FACE4 + 0.5), (tx, ty, tz + 0.016)], 0.0007, soft("J_String", "#C9B49A", 0.8))
    tag = empty(P + "Tag", (tx, ty, tz)); tag.rotation_euler = (math.radians(90), 0, math.radians(math.degrees(FACE4 + 0.55) + 90))
    cyl(P + "TagDisc", 0.016, 0.0025, (0, 0, 0), ceramic("J_TagCream", "#FBF1E2", 0.5, 0.2), verts=40, rot=(0, 0, 0), parent=tag)
    pb = Batch(P + "TagPaw")
    pm = soft("J_TagPaw_" + item_id, c, 0.4)
    pb.sphere(pm, 0.0055, (0, -0.003, 0.0016), scale=(1.15, 1, 0.3), segs=12, rings=6)
    for dx, dy in [(-0.0065, 0.004), (-0.0022, 0.0075), (0.0022, 0.0075), (0.0065, 0.004)]:
        pb.sphere(pm, 0.0022, (dx, dy, 0.0016), scale=(1, 1.15, 0.35), segs=8, rings=6)
    pb.build(parent=tag)
    sparkles(P, [(0.07, -0.05, 0.15), (-0.07, -0.04, 0.11), (0.06, -0.07, 0.05)], 0.011)

def j_books(rnd):
    _coll4("decor_book_stack")
    page = gradient_mat("J_Pages", "Z", [(0.0, "#EFE3CB"), (1.0, "#FBF4E6")], rough=0.8, coat=0.0)
    nt = page.node_tree; b = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    w = nt.nodes.new("ShaderNodeTexWave"); w.bands_direction = "Z"; w.inputs["Scale"].default_value = 300
    nt.links.new(_coords(nt), w.inputs["Vector"]); _bump(nt, b, w.outputs["Fac"], 0.25, 0.0005)
    gold = gold4()
    covers = [("#5B3F78", 0.25, 0.18, 0.045, 6), ("#6F8F72", 0.23, 0.17, 0.04, -9), ("#B59AD8", 0.21, 0.16, 0.038, 13)]
    z = 0.0
    for i, (c, w_, d, h, rz) in enumerate(covers):
        g = empty("Bk4_%d" % i, (0, 0, z + h / 2)); g.rotation_euler = (0, 0, math.radians(rz))
        cov = soft("J_Cover%d" % i, c, 0.45, coat=0.35, sheen=0.3)
        rbox("Bk4_Top%d" % i, (w_, d, 0.005), (0, 0, h / 2 - 0.0025), cov, r=0.0015, parent=g)
        rbox("Bk4_Bot%d" % i, (w_, d, 0.005), (0, 0, -h / 2 + 0.0025), cov, r=0.0015, parent=g)
        cyl("Bk4_Spine%d" % i, h / 2, w_, (0, d / 2 - h / 4, 0), cov, rot=(0, 90, 0), parent=g)
        rbox("Bk4_Pages%d" % i, (w_ - 0.01, d - 0.008, h - 0.008), (0, -0.004, 0), page, r=0.002, parent=g)
        for gx in (-w_ * 0.32, w_ * 0.32):
            cyl("Bk4_Band%d_%+.2f" % (i, gx), h / 2 + 0.0008, 0.006, (gx, d / 2 - h / 4, 0), gold, rot=(0, 90, 0), parent=g)
        z += h + 0.001
    star5("Bk4_CoverStar", 0.02, 0.009, 0.0015, gold, (0.06, -0.035, z), (0, 0, 13), bevel=0.0006)
    teacup("Bk4_Tea", (-0.02, 0.015, z), ceramic("J_Cup", "#FBF7F0", 0.15), soft("J_Tea", "#9A5326", 0.05, coat=1.0), s=1.0)
    tube("Bk4_Ribbon", [(-0.06, -0.06, z - 0.03), (-0.064, -0.085, z - 0.06), (-0.06, -0.092, z - 0.1)], 0.0035, soft("J_RibbonRed", "#D4506E", 0.5, sheen=0.5))
    # lavender sprig on the cover
    lav = soft("J_LavFlower", "#8E76C2", 0.5, sss=0.3)
    tube("Bk4_LavStem", [(0.0, -0.07, z + 0.004), (0.06, -0.06, z + 0.006), (0.11, -0.045, z + 0.008)], 0.0015, soft("J_LavStem", "#6E9A5A", 0.6))
    lb = Batch("Bk4_LavBuds")
    for k in range(14):
        t = 0.45 + 0.55 * k / 14
        lb.sphere(lav, 0.0045, (0.11 * t, -0.07 + 0.025 * t + (0.003 if k % 2 else -0.003), z + 0.008), scale=(1.3, 1, 1), segs=8, rings=6)
    lb.build()
    sparkles("Bk4_", [(0.1, -0.08, 0.2), (-0.12, -0.04, 0.16)])

def j_moon(rnd):
    _coll4("decor_moon_lamp")
    revolve("Ml4_Base", [(0, 0), (0.075, 0), (0.078, 0.006), (0.075, 0.02), (0.06, 0.028), (0, 0.029)], (0, 0, 0), wood("J_WoodHoney", "#C08D5C", "#9C6C42", scale=3.0, coat=0.4))
    brass = gold4()
    tube("Ml4_Rod", [(0.0, 0, 0.028), (0.0, 0, 0.07), (-0.012, 0, 0.088)], 0.004, brass)
    moon = soft("J_MoonGlass", "#F0BD4E", 0.35, sss=0.4)
    b = moon.node_tree.nodes["Principled BSDF"]
    b.inputs["Emission Color"].default_value = (*hexc("#FFB23A"), 1); b.inputs["Emission Strength"].default_value = 0.35
    arc_tube("Ml4_Moon", 0.072, 0.036, 45, 315, moon, r_end=0.12, loc=(0.0, 0, 0.16), rot=(0, 0, 0))
    # crater dimples
    cb = Batch("Ml4_Craters")
    for a, s in [(160, 0.008), (200, 0.006), (130, 0.005)]:
        ar = math.radians(a)
        cb.sphere(soft("J_Crater", "#F5D79A", 0.4, sss=0.4), s, (0.072 * math.cos(ar), -0.028, 0.16 + 0.072 * math.sin(ar)), scale=(1, 0.35, 1), segs=12, rings=8)
    cb.build()
    tx, tz = 0.072 * math.cos(math.radians(45)), 0.16 + 0.072 * math.sin(math.radians(45))
    tube("Ml4_Thread", [(tx + 0.004, 0, tz - 0.004), (tx + 0.006, 0, tz - 0.05)], 0.0006, soft("J_Thread", "#E6D2A8", 0.6))
    star5("Ml4_Star", 0.014, 0.006, 0.004, glow("J_StarGlow", "#FFD36A", 2.0, base="#F2C04E"), (tx + 0.006, 0, tz - 0.058), (90, 0, math.degrees(FACE4) + 90), bevel=0.0012)
    light("Ml4_Light", "POINT", (0.02, -0.06, 0.15), 1.5, color=(1.0, 0.82, 0.5), size=0.03)
    sparkles("Ml4_", [(0.09, -0.04, 0.26), (-0.1, -0.03, 0.2)])

def j_globe(rnd):
    _coll4("decor_globe")
    m, nt, b = _nm("J_GlobeMap")
    v = _coords(nt, (1, 1, 1.3))
    n = nt.nodes.new("ShaderNodeTexNoise"); n.inputs["Scale"].default_value = 11.0; n.inputs["Detail"].default_value = 5
    nt.links.new(v, n.inputs["Vector"])
    r = nt.nodes.new("ShaderNodeValToRGB")
    els = r.color_ramp.elements
    els[0].position, els[0].color = 0.0, (*hexc("#5E9CCB"), 1)
    els[1].position, els[1].color = 1.0, (*hexc("#7FB067"), 1)
    for pos, c in [(0.5, "#8EC2E6"), (0.53, "#E9D9A6"), (0.56, "#9CC97A")]:
        e = els.new(pos); e.color = (*hexc(c), 1)
    r.color_ramp.interpolation = "LINEAR"
    nt.links.new(n.outputs["Fac"], r.inputs["Fac"])
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.25; b.inputs["Coat Weight"].default_value = 0.8
    _bump(nt, b, n.outputs["Fac"], 0.15, 0.002)
    brass = gold4()
    g = empty("Gl4_Axis", (0, 0, 0.15)); g.rotation_euler = (0, math.radians(23), 0)
    ball("Gl4_Sphere", 0.085, (0, 0, 0), m, segs=64, rings=32, parent=g)
    arc_tube("Gl4_Meridian", 0.095, 0.0045, -100, 100, brass, r_end=1.0, rot=(0, 0, 90 + math.degrees(FACE4) * 0), parent=g)
    ball("Gl4_PinTop", 0.006, (0, 0, 0.1), brass, parent=g)
    ball("Gl4_PinBot", 0.006, (0, 0, -0.1), brass, parent=g)
    revolve("Gl4_Stand", [(0, 0), (0.07, 0), (0.072, 0.008), (0.065, 0.016), (0.03, 0.022), (0.014, 0.03), (0.012, 0.045), (0.018, 0.055), (0, 0.056)], (0, 0, 0), wood("J_WoodWalnut", "#714B33", "#563624", scale=3.0, coat=0.5))
    sparkles("Gl4_", [(0.11, -0.05, 0.26), (-0.11, -0.04, 0.2)])

def _goldfish(name, loc, rz, s=1.0):
    orange = gradient_mat("J_Goldfish", "Z", [(0.0, "#FFE2C2"), (0.5, "#F8964A"), (1.0, "#E9702C")], rough=0.25, coat=0.6, thin_film=250)
    fin = soft("J_GoldFin", "#FFB07A", 0.3, sss=0.5)
    g = empty(name, loc); g.rotation_euler = (0, 0, math.radians(rz)); g.scale = (s, s, s)
    loft(name + "_Body", fish_rings(0.05, 0.016, 0.009, n=20, seg=16, lying=False), orange, parent=g)
    slab(name + "_Tail", [(0, 0.004), (0.02, 0.018), (0.026, 0.012), (0.018, 0.0), (0.026, -0.012), (0.02, -0.018), (0, -0.004)], 0.002, fin, (0.022, 0, 0), (90, 0, 0), parent=g)
    slab(name + "_Dorsal", [(-0.01, 0), (0.0, 0.01), (0.012, 0.006), (0.016, 0)], 0.0015, fin, (0.0, 0, 0.014), (90, 0, 0), parent=g)
    for sd in (-1, 1):
        ball(name + "_Eye%d" % sd, 0.003, (-0.016, sd * 0.0065, 0.003), soft("J_Ink", "#1F1830", 0.1, coat=1.0), parent=g)

def j_aquarium(rnd):
    _coll4("decor_aquarium")
    R = 0.11
    prof = []
    for k in range(25):
        a = math.radians(-82 + k * (82 + 58) / 24)
        prof.append((R * math.cos(a), R + R * math.sin(a)))
    prof = [(0.0, R + R * math.sin(math.radians(-82)))] + prof
    lip_z = prof[-1][1]
    prof += [(prof[-1][0] + 0.006, lip_z + 0.004), (prof[-1][0] + 0.004, lip_z + 0.008)]
    gl = no_shadow(revolve("Aq4_Glass", prof, (0, 0, 0), glass4("J_BowlGlass", "#F4FBFF"), segs=80))
    so = gl.modifiers.new("Solid", "SOLIDIFY"); so.thickness = 0.003; so.offset = -1
    wz = R * 1.55
    zs = [prof[1][1] + (wz - prof[1][1]) * k / 20 for k in range(21)]
    wprof = [(0.0, prof[0][1] + 0.003)]
    for z in zs:
        # radius of the sphere at height z, minus the glass
        dz = z - R
        wprof.append((max(math.sqrt(max(R * R - dz * dz, 0)) - 0.004, 0.0), z))
    wprof.append((0.0, wz))
    water = glass4("J_Water", "#D8F0FA", rough=0.02, ior=1.33)
    no_shadow(revolve("Aq4_Water", wprof, (0, 0, 0), water, segs=80))
    pb = Batch("Aq4_Pebbles")
    pcols = [soft("J_Peb%d" % i, c, 0.4, coat=0.5) for i, c in enumerate(["#F2C6D6", "#C9B6EE", "#BFE3D6", "#FBEBC9", "#F6F1EA"])]
    for i in range(70):
        a = rnd.uniform(0, 2 * math.pi); r = math.sqrt(rnd.random()) * 0.06
        pb.sphere(rnd.choice(pcols), rnd.uniform(0.006, 0.01), (r * math.cos(a), r * math.sin(a), 0.018 + rnd.uniform(0, 0.012) + (r / 0.06) ** 2 * 0.012), scale=(1.2, 1, 0.7), segs=10, rings=6)
    pb.build()
    weed = soft("J_Weed", "#58A35A", 0.4, sss=0.4)
    for i, (x, y) in enumerate([(-0.03, 0.03), (-0.015, 0.04), (0.035, 0.03)]):
        pts = [(x, y, 0.025)]
        for k in range(1, 6):
            pts.append((x + 0.01 * math.sin(k * 1.3 + i), y, 0.025 + k * 0.026))
        tube("Aq4_Weed%d" % i, pts, 0.004, weed, res=8)
    _goldfish("Aq4_FishA", (-0.02, -0.02, 0.1), 15, 1.0)
    _goldfish("Aq4_FishB", (0.035, 0.01, 0.14), 200, 0.85)
    _goldfish("Aq4_FishC", (0.01, 0.035, 0.065), 160, 0.75)
    bub = glass4("J_Bubble", "#FFFFFF", ior=1.1)
    for i in range(5):
        no_shadow(ball("Aq4_Bubble%d" % i, 0.0035 + 0.001 * (i % 3), (-0.045 + 0.004 * i, -0.02, 0.12 + 0.017 * i), bub, segs=16, rings=10))
    sparkles("Aq4_", [(0.12, -0.06, 0.24), (-0.13, -0.04, 0.18)])

def j_mushroom(rnd):
    _coll4("decor_mushroom_lamp")
    moss = fabric("J_Moss", "#6E9E57", 0.9, sheen=0.8, scale=600)
    revolve("Mu4_Base", [(0, 0), (0.085, 0), (0.088, 0.008), (0.075, 0.018), (0, 0.022)], (0, 0, 0), moss)
    gb = Batch("Mu4_Grass")
    gm = soft("J_Grass", "#7DB862", 0.5, sss=0.3)
    for i in range(40):
        a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0.04, 0.085)
        gb.cone(gm, 0.003, rnd.uniform(0.015, 0.03), (r * math.cos(a), r * math.sin(a), 0.02), rot=(rnd.uniform(-20, 20), rnd.uniform(-20, 20), 0), segs=5) if hasattr(gb, "cone") else gb.cyl(gm, 0.002, 0.02, (r * math.cos(a), r * math.sin(a), 0.028), rot=(rnd.uniform(-20, 20), rnd.uniform(-20, 20), 0), r2=0.0002, segs=5)
    gb.build()
    stem = soft("J_MushStem", "#F6EADA", 0.5, sss=0.6)
    revolve("Mu4_Stem", [(0, 0.015), (0.045, 0.015), (0.04, 0.04), (0.032, 0.09), (0.034, 0.12), (0, 0.12)], (0, 0, 0), stem)
    gl = Batch("Mu4_Gills")
    for k in range(48):
        a = 2 * math.pi * k / 48
        gl.cube(stem, (0.075, 0.0012, 0.012), (0.07 * math.cos(a), 0.07 * math.sin(a), 0.113), rot=(0, 0, math.degrees(a)))
    gl.build()
    cap = soft("J_MushCap", "#F07E74", 0.35, sss=0.7, coat=0.4)
    cb = cap.node_tree.nodes["Principled BSDF"]
    cb.inputs["Emission Color"].default_value = (*hexc("#FF9A82"), 1); cb.inputs["Emission Strength"].default_value = 0.9
    revolve("Mu4_Cap", [(0.0, 0.0), (0.12, 0.0), (0.128, 0.008), (0.122, 0.03), (0.1, 0.06), (0.06, 0.09), (0.02, 0.102), (0, 0.104)], (0, 0, 0.11), cap, segs=80)
    sb = Batch("Mu4_Spots")
    spot = soft("J_MushSpot", "#FFF6EA", 0.45, sss=0.3)
    for k in range(13):
        a = k * 2.39996 + 0.3
        t = 0.2 + 0.75 * ((k * 0.618) % 1)
        rr = 0.12 * t
        z = 0.11 + 0.104 * (1 - t ** 2.2) + 0.002
        sb.sphere(spot, 0.016 * (1.1 - 0.4 * t), (rr * math.cos(a), rr * math.sin(a), z), scale=(1, 1, 0.38), segs=14, rings=8)
    sb.build()
    light("Mu4_Light", "POINT", (0, -0.06, 0.1), 2.5, color=(1.0, 0.62, 0.48), size=0.03)
    sparkles("Mu4_", [(0.12, -0.06, 0.24), (-0.13, -0.04, 0.17)])

def j_lantern(rnd):
    _coll4("decor_lantern")
    navy = soft("J_LanternNavy", "#58679E", 0.3, coat=0.6, metal=0.2)
    brass = gold4()
    rbox("Ln4_Base", (0.12, 0.12, 0.018), (0, 0, 0.009), navy, r=0.005)
    rbox("Ln4_BaseTrim", (0.126, 0.126, 0.005), (0, 0, 0.02), brass, r=0.002)
    rbox("Ln4_Top", (0.13, 0.13, 0.016), (0, 0, 0.19), navy, r=0.005)
    me = bpy.data.meshes.new("Ln4_RoofM")
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=4, radius1=0.1, radius2=0.012, depth=0.06)
    bm.to_mesh(me); bm.free()
    roof = _link("Ln4_Roof", me, navy, (0, 0, 0.228), (0, 0, 45))
    bv = roof.modifiers.new("Bevel", "BEVEL"); bv.width = 0.004; bv.segments = 3
    ball("Ln4_Knob", 0.012, (0, 0, 0.262), brass)
    arc_tube("Ln4_Handle", 0.028, 0.0035, 0, 180, brass, r_end=1.0, loc=(0, 0, 0.27))
    for sx, sy in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
        cyl("Ln4_Post%d%d" % (sx, sy), 0.0055, 0.17, (sx * 0.055, sy * 0.055, 0.1), navy, verts=16)
    gls = glass4("J_LanternGlass", "#FFF3DE", rough=0.08)
    for s in (-1, 1):
        no_shadow(box("Ln4_GlassX%d" % s, (0.003, 0.104, 0.16), (s * 0.052, 0, 0.1), gls, bevel=0))
        no_shadow(box("Ln4_GlassY%d" % s, (0.104, 0.003, 0.16), (0, s * 0.052, 0.1), gls, bevel=0))
    wax = soft("J_Wax", "#FFF1DC", 0.45, sss=0.7)
    revolve("Ln4_Candle", [(0, 0.018), (0.022, 0.018), (0.022, 0.075), (0.019, 0.08), (0, 0.078)], (0, 0, 0), wax)
    tube("Ln4_Drip", [(0.02, -0.008, 0.078), (0.023, -0.009, 0.06), (0.022, -0.009, 0.05)], 0.0035, wax)
    tube("Ln4_Wick", [(0, 0, 0.078), (0.001, 0, 0.088)], 0.0012, soft("J_Wick", "#2E2620", 0.8))
    flame = gradient_mat("J_Flame", "Z", [(0.0, "#FF8A2A"), (0.5, "#FFC15A"), (1.0, "#FFF3C8")], rough=0.5, coat=0)
    fb = flame.node_tree.nodes["Principled BSDF"]
    fr = next(n for n in flame.node_tree.nodes if n.type == "VALTORGB")
    flame.node_tree.links.new(fr.outputs["Color"], fb.inputs["Emission Color"]); fb.inputs["Emission Strength"].default_value = 18.0
    revolve("Ln4_Flame", [(0, 0.086), (0.007, 0.092), (0.006, 0.104), (0.0025, 0.114), (0, 0.12)], (0, 0, 0), flame, segs=24)
    star5("Ln4_Star", 0.014, 0.006, 0.0025, brass, on_front(0.056, 0.15), (90, 0, math.degrees(FACE4) + 90), bevel=0.0008)
    light("Ln4_Light", "POINT", (0, 0, 0.1), 3.0, color=(1.0, 0.65, 0.32), size=0.01)
    sparkles("Ln4_", [(0.1, -0.05, 0.27), (-0.1, -0.04, 0.2)])

def j_tulip(rnd):
    _coll4("decor_tulip_lamp")
    brass = gold4()
    revolve("Tl4_Base", [(0, 0), (0.07, 0), (0.072, 0.006), (0.06, 0.014), (0.02, 0.02), (0, 0.021)], (0, 0, 0), brass)
    tube("Tl4_Neck", [(0, 0, 0.02), (0.0, 0, 0.17), (-0.02, 0, 0.24), (-0.07, 0, 0.265), (-0.105, 0, 0.245)], 0.0055, brass)
    shade = soft("J_TulipGlass", "#F9D7B2", 0.3, sss=0.5)
    sb_ = shade.node_tree.nodes["Principled BSDF"]
    sb_.inputs["Emission Color"].default_value = (*hexc("#FFB866"), 1); sb_.inputs["Emission Strength"].default_value = 0.7
    scallop_shade("Tl4_Shade", (-0.105, 0, 0.155), shade, r_top=0.022, r_bot=0.075, h=0.085, lobes=6)
    revolve("Tl4_Cap", [(0, 0.24), (0.024, 0.24), (0.02, 0.25), (0, 0.255)], (-0.105, 0, 0), brass)
    ball("Tl4_Bulb", 0.016, (-0.105, 0, 0.18), glow("J_Bulb", "#FFE2B0", 20.0))
    tube("Tl4_Chain", [(-0.075, 0, 0.21), (-0.073, 0, 0.17)], 0.0012, brass)
    ball("Tl4_ChainBall", 0.004, (-0.073, 0, 0.166), brass)
    light("Tl4_Light", "POINT", (-0.105, -0.02, 0.165), 2.5, color=(1.0, 0.78, 0.5), size=0.02)
    sparkles("Tl4_", [(0.06, -0.06, 0.28), (-0.16, -0.04, 0.12)])

def j_scarf(rnd):
    _coll4("acc_scarf")
    m = knit_stripes("J_ScarfKnit", "#9C84C8", "#F4EBDD", "#7E66AC", stripe=0.045, scale=110, strength=1.0)
    # rolled body: a fat torus, slightly squashed
    torus("Sc4_Roll", 0.068, 0.032, (0, 0, 0.034), m, seg=96, ring=28, scale=(1.15, 1, 0.75))
    # two ends hanging toward the camera
    for i, (dx, rz, L, w) in enumerate([(-0.02, 6, 0.13, 0.052), (0.035, -8, 0.115, 0.05)]):
        g = empty("Sc4_End%d" % i, on_front(0.07, 0.05, FACE4 + 0.25 * (1 if i else -1)))
        g.rotation_euler = (math.radians(-72), 0, math.radians(math.degrees(FACE4) + 90 + rz))
        rbox("Sc4_EndB%d" % i, (w, 0.016, L), (0, 0, -L / 2), m, r=0.007, parent=g, subd=1)
        fb = Batch("Sc4_Fringe%d" % i)
        for k in range(7):
            x = -w / 2 + 0.004 + k * (w - 0.008) / 6
            fb.cyl(m, 0.0028, 0.028, (x, 0, -L - 0.012), segs=8)
            fb.sphere(m, 0.0034, (x, 0, -L - 0.027), segs=8, rings=6)
        fb.build(parent=g)
    star5("Sc4_Pin", 0.016, 0.007, 0.004, gold4(), on_front(0.11, 0.05, FACE4 - 0.35), (90, 0, math.degrees(FACE4) + 80), bevel=0.0012)
    sparkles("Sc4_", [(0.12, -0.06, 0.12), (-0.13, -0.03, 0.09)])

def j_beanie(rnd):
    _coll4("acc_beanie")
    k = knit("J_BeanieKnit", "#86ABD6", "#6C91BE", scale=105, strength=1.0)
    revolve("Bn4_Cap", [(0.088, 0.035), (0.091, 0.06), (0.084, 0.1), (0.066, 0.135), (0.035, 0.155), (0, 0.16)], (0, 0, 0), k, segs=80)
    # ribbed cuff: radius ripples around the circumference
    rib = knit("J_BeanieRib", "#7BA0CC", "#5F84B2", scale=140, strength=1.2)
    me = bpy.data.meshes.new("Bn4_Cuff")
    bm = bmesh.new()
    segs = 192
    prof = [(0.088, 0.0), (0.096, 0.004), (0.098, 0.02), (0.097, 0.038), (0.09, 0.044)]
    rows = []
    for (r, z) in prof:
        rows.append([bm.verts.new(((r * (1 + 0.025 * math.cos(a * 48))) * math.cos(a), (r * (1 + 0.025 * math.cos(a * 48))) * math.sin(a), z)) for a in [2 * math.pi * i / segs for i in range(segs)]])
    for i in range(len(rows) - 1):
        for j in range(segs):
            q = (j + 1) % segs
            bm.faces.new((rows[i][j], rows[i][q], rows[i + 1][q], rows[i + 1][j]))
    bm.to_mesh(me); bm.free(); me.shade_smooth()
    cu = _link("Bn4_Cuff", me, rib)
    s = cu.modifiers.new("Subd", "SUBSURF"); s.levels = 1; s.render_levels = 1
    # fluffy pompom: displaced sphere
    pm = fabric("J_Pompom", "#F5EFE6", 0.95, sheen=1.0, scale=900)
    pom = ball("Bn4_Pom", 0.04, (0, 0, 0.19), pm, segs=96, rings=64)
    tx = bpy.data.textures.get("J_PomFuzz") or bpy.data.textures.new("J_PomFuzz", "CLOUDS")
    tx.noise_scale = 0.12; tx.noise_depth = 2
    d = pom.modifiers.new("Fuzz", "DISPLACE"); d.texture = tx; d.strength = 0.012; d.mid_level = 0.5
    star5("Bn4_Star", 0.018, 0.008, 0.004, gold4(), on_front(0.1, 0.024), (90, 0, math.degrees(FACE4) + 90), bevel=0.0012)
    sparkles("Bn4_", [(0.12, -0.06, 0.2), (-0.13, -0.03, 0.12)])

def j_glasses(rnd):
    _coll4("acc_glasses")
    g = empty("Gs4_Frame", (0, 0, 0.045)); g.rotation_euler = (math.radians(12), 0, math.radians(math.degrees(FACE4) + 90))
    gold = gold4()
    lens = glass4("J_Lens", "#DCE8FF", rough=0.03, ior=1.5)
    for s in (-1, 1):
        torus("Gs4_Rim%d" % s, 0.038, 0.005, (s * 0.048, 0, 0), gold, rot=(90, 0, 0), seg=72, ring=14, parent=g)
        no_shadow(cyl("Gs4_Lens%d" % s, 0.037, 0.003, (s * 0.048, 0, 0), lens, rot=(90, 0, 0), verts=64, parent=g))
        ball("Gs4_Pad%d" % s, 0.005, (s * 0.014, 0.008, -0.012), ceramic("J_Pad", "#F4EEE6", 0.2), scale=(0.6, 0.4, 1), parent=g)
        tube("Gs4_Temple%d" % s, [(s * 0.086, 0, 0.004), (s * 0.09, 0.03, 0.004), (s * 0.06, 0.07, 0.0), (s * 0.02, 0.085, -0.004)], 0.0032, gold)
        bpy.data.objects["Gs4_Temple%d" % s].parent = g
    arc_tube("Gs4_Bridge", 0.012, 0.0035, 25, 155, gold, r_end=1.0, loc=(0, 0, 0.004), parent=g)
    sparkles("Gs4_", [(0.1, -0.06, 0.1), (-0.09, -0.05, 0.08)])

def _egg_mat(item_id, kind):
    m, nt, b = _nm("J_Egg_" + item_id)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    v = tc.outputs["Object"]
    if kind == "cat":
        n = nt.nodes.new("ShaderNodeTexNoise"); n.inputs["Scale"].default_value = 30
        nt.links.new(v, n.inputs["Vector"])
        vo = nt.nodes.new("ShaderNodeTexVoronoi"); vo.inputs["Scale"].default_value = 26.0; vo.inputs["Randomness"].default_value = 0.9
        mix = nt.nodes.new("ShaderNodeVectorMath"); mix.operation = "ADD"
        sc = nt.nodes.new("ShaderNodeVectorMath"); sc.operation = "SCALE"; sc.inputs["Scale"].default_value = 0.015
        nt.links.new(n.outputs["Color"], sc.inputs[0]); nt.links.new(v, mix.inputs[0]); nt.links.new(sc.outputs[0], mix.inputs[1])
        nt.links.new(mix.outputs[0], vo.inputs["Vector"])
        r = _ramp(nt, vo.outputs["Distance"], "#EE8FAA", "#FBEFE2", 0.33, 0.36)
    elif kind == "fox":
        sep = nt.nodes.new("ShaderNodeSeparateXYZ"); nt.links.new(v, sep.inputs[0])
        at = nt.nodes.new("ShaderNodeMath"); at.operation = "ARCTAN2"
        nt.links.new(sep.outputs["Y"], at.inputs[0]); nt.links.new(sep.outputs["X"], at.inputs[1])
        mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"; mul.inputs[1].default_value = 9.0
        nt.links.new(at.outputs[0], mul.inputs[0])
        sn = nt.nodes.new("ShaderNodeMath"); sn.operation = "SINE"; nt.links.new(mul.outputs[0], sn.inputs[0])
        zig = nt.nodes.new("ShaderNodeMath"); zig.operation = "MULTIPLY_ADD"; zig.inputs[1].default_value = 0.008; zig.inputs[2].default_value = 0.0
        nt.links.new(sn.outputs[0], zig.inputs[0])
        add = nt.nodes.new("ShaderNodeMath"); add.operation = "ADD"
        nt.links.new(sep.outputs["Z"], add.inputs[0]); nt.links.new(zig.outputs[0], add.inputs[1])
        r = nt.nodes.new("ShaderNodeValToRGB")
        els = r.color_ramp.elements
        els[0].position, els[0].color = 0.0, (*hexc("#E9783A"), 1)
        els[1].position, els[1].color = 1.0, (*hexc("#FFF6EA"), 1)
        e = els.new(0.104); e.color = (*hexc("#F59A52"), 1)
        e2 = els.new(0.106); e2.color = (*hexc("#FFF6EA"), 1)
        nt.links.new(add.outputs[0], r.inputs["Fac"])
    else:
        vo = nt.nodes.new("ShaderNodeTexVoronoi"); vo.inputs["Scale"].default_value = 60.0
        vo.feature = "DISTANCE_TO_EDGE"
        nt.links.new(v, vo.inputs["Vector"])
        r = _ramp(nt, vo.outputs["Distance"], "#4E9C84", "#9FDCC4", 0.0, 0.06)
        _bump(nt, b, vo.outputs["Distance"], 0.6, 0.002)
        b.inputs["Thin Film Thickness"].default_value = 420
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.22; b.inputs["Coat Weight"].default_value = 0.8
    b.inputs["Subsurface Weight"].default_value = 0.15
    return m

def j_egg(item_id, kind, rnd):
    _coll4(item_id)
    P = "Eg4_" + item_id + "_"
    twig_nest(P, R=0.078, rnd=random.Random(hash(item_id) & 0xffff))
    prof = []
    for i in range(33):
        t = i / 32
        z = 0.16 * t
        q = 2 * t - 1      # egg: round ends, wider at the bottom
        r_ = 0.058 * math.sqrt(max(1 - q * q, 0.0)) * (1 - 0.2 * q)
        prof.append((max(r_, 0.0), z))
    prof[0] = (0.0, 0.0); prof[-1] = (0.0, 0.16)
    revolve(P + "Egg", prof, (0, 0, 0.018), _egg_mat(item_id, kind), segs=80, rot=(8, -6, 0))
    if kind == "cat":
        paw_decal(P, 0.064, 0.075, ceramic("J_EggPaw", "#E98FA8", 0.3), s=0.9)
    if kind == "dragon":
        for k in range(3):
            star4(P + "Glint%d" % k, 0.008 + 0.003 * k, None, on_front(0.08 + 0.02 * k, 0.12 + 0.03 * k, FACE4 + 0.5 - 0.4 * k))
    light(P + "Warm", "POINT", (0, -0.06, 0.06), 1.2, color=(1.0, 0.84, 0.6), size=0.03)
    sparkles(P, [(0.1, -0.06, 0.18), (-0.1, -0.04, 0.13)])

def j_freeze(rnd):
    _coll4("freeze")
    ice = glass4("J_Ice", "#CFEFFC", rough=0.08, ior=1.08)   # low IOR: the flame inside is not flipped
    ib = ice.node_tree.nodes["Principled BSDF"]
    n = ice.node_tree.nodes.new("ShaderNodeTexNoise"); n.inputs["Scale"].default_value = 60
    ice.node_tree.links.new(_coords(ice.node_tree), n.inputs["Vector"]); _bump(ice.node_tree, ib, n.outputs["Fac"], 0.25, 0.002)
    no_shadow(rbox("Fz4_Cube", (0.15, 0.15, 0.15), (0, 0, 0.075), ice, r=0.02, rot=(0, 0, 18)))
    flame = gradient_mat("J_FrozenFlame", "Z", [(0.0, "#FF7A2A"), (0.55, "#FFB64E"), (1.0, "#FFE9A8")], rough=0.4, coat=0)
    fb = flame.node_tree.nodes["Principled BSDF"]
    fr = next(x for x in flame.node_tree.nodes if x.type == "VALTORGB")
    flame.node_tree.links.new(fr.outputs["Color"], fb.inputs["Emission Color"]); fb.inputs["Emission Strength"].default_value = 2.5
    fl = revolve("Fz4_Flame", [(0, 0.022), (0.02, 0.028), (0.03, 0.045), (0.028, 0.065), (0.019, 0.09), (0.009, 0.112), (0.002, 0.128), (0, 0.132)], (0, 0, 0), flame, segs=40)
    tw = fl.modifiers.new("Flicker", "SIMPLE_DEFORM"); tw.deform_method = "TWIST"; tw.angle = math.radians(40)
    revolve("Fz4_FlameIn", [(0, 0.03), (0.012, 0.038), (0.015, 0.052), (0.01, 0.072), (0.003, 0.088), (0, 0.092)], (0, -0.01, 0), glow("J_FlameCore", "#FFD27A", 3.0), segs=32)
    light("Fz4_Light", "POINT", (0, 0, 0.07), 2.5, color=(1.0, 0.6, 0.3), size=0.02)
    # frost on the top edges + snow at the foot
    snow = soft("J_Snow", "#FFFFFF", 0.6, sss=0.8)
    sb = Batch("Fz4_Snow")
    rot = math.radians(18)
    # a soft snow cap on top of the cube: a pillow with lumpy displacement
    cap = puff("Fz4_SnowCap", (0.15, 0.15, 0.03), (0, 0, 0.155), snow, rot=(0, 0, 18), level=3)
    tx = bpy.data.textures.get("J_SnowLumps") or bpy.data.textures.new("J_SnowLumps", "CLOUDS")
    tx.noise_scale = 0.03
    dsp = cap.modifiers.new("Lumps", "DISPLACE"); dsp.texture = tx; dsp.strength = 0.008
    # small drifts hugging the foot of the cube
    for i in range(0):   # foot drifts read as coins at icon size: off
        u = rnd.uniform(-0.06, 0.06)
        side = rnd.choice([(1, 0), (0, -1)])
        x, y = (side[0] * 0.08, u) if side[0] else (u, side[1] * 0.08)
        xr, yr = x * math.cos(rot) - y * math.sin(rot), x * math.sin(rot) + y * math.cos(rot)
        sb.sphere(snow, rnd.uniform(0.01, 0.015), (xr, yr, 0.003), scale=(1.5, 1.5, 0.55), segs=12, rings=8)
    sb.build()
    sparkles("Fz4_", [(0.11, -0.07, 0.2), (-0.12, -0.04, 0.16), (0.09, -0.06, 0.04)])

def j_incubator(rnd):
    _coll4("incubator_slot")
    cream = ceramic("J_IncCream", "#F6EDE0", 0.3)
    brass = gold4()
    revolve("In4_Base", [(0, 0), (0.12, 0), (0.124, 0.008), (0.122, 0.045), (0.112, 0.055), (0, 0.055)], (0, 0, 0), cream, segs=96)
    torus("In4_Trim", 0.121, 0.004, (0, 0, 0.05), brass, seg=96, ring=10)
    torus("In4_Glow", 0.1, 0.004, (0, 0, 0.057), glow("J_IncGlow", "#FFD27A", 6.0), seg=96, ring=10)
    rbox("In4_Panel", (0.06, 0.006, 0.026), on_front(0.121, 0.026), soft("J_Panel", "#9C84C8", 0.35, coat=0.6), r=0.004, rot=(0, 0, math.degrees(FACE4) + 90))
    for k, d in enumerate((-0.015, 0.0, 0.015)):
        p = Vector(on_front(0.126, 0.026)) + Vector((-math.sin(FACE4), math.cos(FACE4), 0)) * d
        ball("In4_Btn%d" % k, 0.004, tuple(p), glow("J_Btn%d" % k, ["#7FD1B8", "#FFD27A", "#F2A6B8"][k], 3.0))
    use(bpy.data.collections["I4_incubator_slot"])
    twig_nest("In4_", R=0.06, rnd=random.Random(7), h=0.03, n=36)
    for o in [o for o in bpy.data.collections["I4_incubator_slot"].objects if o.name.startswith("In4_Twig") or o.name.startswith("In4_Nest")]:
        o.location.z += 0.055
    dome = glass4("J_Dome", "#FAFCFF", rough=0.01)
    d = no_shadow(revolve("In4_Dome", [(0.105, 0.055), (0.106, 0.09), (0.098, 0.14), (0.078, 0.18), (0.046, 0.205), (0, 0.212)], (0, 0, 0), dome, segs=96))
    so = d.modifiers.new("Solid", "SOLIDIFY"); so.thickness = 0.003; so.offset = -1
    ball("In4_Knob", 0.011, (0, 0, 0.218), brass)
    # glowing "+" badge in front: second slot
    bx, by, bz = on_front(0.13, 0.125)
    g = empty("In4_Badge", (bx, by, bz)); g.rotation_euler = (math.radians(90), 0, math.radians(math.degrees(FACE4) + 90))
    cyl("In4_BadgeDisc", 0.028, 0.008, (0, 0, 0), soft("J_BadgeLav", "#8E76C2", 0.3, coat=0.8), verts=48, parent=g)
    torus("In4_BadgeRing", 0.028, 0.003, (0, 0, 0), brass, parent=g, seg=48, ring=8)
    rbox("In4_PlusH", (0.03, 0.008, 0.006), (0, 0, 0.005), glow("J_Plus", "#FFFFFF", 3.0), r=0.0025, parent=g)
    rbox("In4_PlusV", (0.008, 0.03, 0.006), (0, 0, 0.005), glow("J_Plus", "#FFFFFF", 3.0), r=0.0025, parent=g)
    light("In4_Light", "POINT", (0, 0, 0.1), 2.0, color=(1.0, 0.82, 0.55), size=0.03)
    sparkles("In4_", [(0.13, -0.08, 0.22), (-0.14, -0.04, 0.17)])

# ------------------------------------------------------------------ catalogue
ITEMS4 = [
    ("Еда", [("food_kibble", j_kibble), ("food_fish", j_fish), ("food_berries", j_berries), ("food_cake", j_cake)]),
    ("Окрасы", [
        ("color_midnight", lambda r: j_potion("color_midnight", "#231F52", "#3F3590", trans=0.3, sss=0.2, inner_stars=True, rnd=r)),
        ("color_snow", lambda r: j_potion("color_snow", "#F4F1EC", None, trans=0.2, sss=0.6, rnd=r)),
        ("color_mint", lambda r: j_potion("color_mint", "#3FBF94", "#8EE6C6", trans=0.4, rnd=r)),
        ("color_amber", lambda r: j_potion("color_amber", "#D47A12", "#F5BD3C", trans=0.4, emit=0.4, reward=True, rnd=r)),
        ("color_sunset", lambda r: j_potion("color_sunset", "#D93F68", "#F79A4E", trans=0.4, emit=0.4, reward=True, rnd=r)),
        ("color_aurora", lambda r: j_potion("color_aurora", "#4B62D6", "#5FD8B8", trans=0.4, emit=0.6, reward=True, inner_stars=True, rnd=r)),
    ]),
    ("Декор", [("decor_book_stack", j_books), ("decor_moon_lamp", j_moon), ("decor_globe", j_globe),
               ("decor_aquarium", j_aquarium), ("decor_mushroom_lamp", j_mushroom), ("decor_lantern", j_lantern),
               ("decor_tulip_lamp", j_tulip)]),
    ("Аксессуары", [("acc_scarf", j_scarf), ("acc_beanie", j_beanie), ("acc_glasses", j_glasses)]),
    ("Яйца", [("egg_cat", lambda r: j_egg("egg_cat", "cat", r)), ("egg_fox", lambda r: j_egg("egg_fox", "fox", r)),
              ("egg_dragon", lambda r: j_egg("egg_dragon", "dragon", r))]),
    ("Разное", [("freeze", j_freeze), ("incubator_slot", j_incubator)]),
]
STEP4 = 0.5

def _cycles_gpu():
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "OPTIX"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = d.type == "OPTIX"
    except Exception as e:
        print("GPU setup failed", e)

def _setup_scene4():
    s = bpy.data.scenes.get(SCENE4) or bpy.data.scenes.new(SCENE4)
    for c in list(s.collection.children):
        for o in list(c.all_objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(c)
    _cycles_gpu()
    s.render.engine = "CYCLES"
    s.cycles.device = "GPU"
    s.cycles.samples = 160
    s.cycles.use_adaptive_sampling = True
    s.cycles.use_denoising = True
    try:
        s.cycles.denoiser = "OPTIX"
    except TypeError:
        pass
    s.cycles.max_bounces = 16
    s.cycles.transmission_bounces = 16
    s.cycles.transparent_max_bounces = 16
    s.cycles.caustics_reflective = False
    s.cycles.caustics_refractive = False
    s.render.film_transparent = True
    s.cycles.film_transparent_glass = True
    s.render.resolution_x = s.render.resolution_y = 512
    s.render.resolution_percentage = 100
    s.render.image_settings.file_format = "PNG"
    s.render.image_settings.color_mode = "RGBA"
    s.view_settings.view_transform = "AgX"
    for look in ("AgX - Punchy", "Punchy", "AgX - Medium High Contrast"):
        try:
            s.view_settings.look = look
            break
        except TypeError:
            continue
    if s.world is None:
        w = bpy.data.worlds.new(SCENE4 + "_World"); w.use_nodes = True; s.world = w
    world_color(s, "#F3EAF4", 0.28)
    post_fx(s, bloom=0.25, threshold=1.2, size=0.5)
    for n in ("I4_Studio", "I4_Helpers", "I4_Labels"):
        c = bpy.data.collections.new(n); s.collection.children.link(c)
    bpy.data.collections["I4_Helpers"].hide_render = True
    bpy.data.collections["I4_Helpers"].hide_viewport = True
    bpy.data.collections["I4_Labels"].hide_render = True
    use(bpy.data.collections["I4_Studio"])
    light("I4_Key", "AREA", (-0.5, -0.6, 0.8), 38, color=(1.0, 0.94, 0.86), size=0.7, rot=(48, 0, -38))
    light("I4_Rim", "AREA", (0.45, 0.6, 0.55), 26, color=(0.88, 0.85, 1.0), size=0.5, rot=(-58, 0, 145))
    light("I4_Fill", "AREA", (0.7, -0.55, 0.25), 8, color=(1.0, 0.9, 0.82), size=0.9, rot=(78, 0, 52))
    light("I4_Top", "AREA", (0.0, 0.0, 0.9), 5, color=(1.0, 0.97, 0.94), size=1.2, rot=(0, 0, 0))
    for n in ("I4_Key", "I4_Rim", "I4_Fill", "I4_Top"):
        o = bpy.data.objects[n]; o["base_loc"] = list(o.location)
    catcher = box("I4_ShadowCatcher", (3.0, 3.0, 0.002), (0, 0, -0.001), soft("J_Catcher", "#FFFFFF", 0.8), bevel=0)
    catcher.is_shadow_catcher = True
    cd = bpy.data.cameras.new("I4_Cam"); cd.lens = 70
    cam = bpy.data.objects.new("I4_Cam", cd); bpy.data.collections["I4_Studio"].objects.link(cam); s.camera = cam
    return s

def _label(name, body, loc, size, color):
    cu = bpy.data.curves.new(name, "FONT"); cu.body = body; cu.size = size; cu.align_x = "CENTER"
    o = bpy.data.objects.new(name, cu); bpy.data.collections["I4_Labels"].objects.link(o)
    o.location = loc; o.rotation_euler = (math.radians(60), 0, 0)
    cu.materials.append(soft("J_LabelInk", color, 0.6))
    return o

def build_icons4():
    s = _setup_scene4()
    bpy.context.window.scene = s
    rnd = random.Random(42)
    rows = len(ITEMS4)
    for r, (title, items) in enumerate(ITEMS4):
        y = (rows - 1 - r) * STEP4 * 1.2
        _label("I4_Row_" + title, title, (-0.4, y, 0.0), 0.09, "#3E2F4A").data.align_x = "RIGHT"
        for k, (item_id, fn) in enumerate(items):
            fn(rnd)
            c = bpy.data.collections["I4_" + item_id]
            off = Vector((k * STEP4, y, 0))
            for o in c.objects:
                if o.parent is None:
                    o.location = Vector(o.location) + off
            _label("I4_Lbl_" + item_id, item_id, (k * STEP4, y - 0.2, 0.0), 0.04, "#7A6A86")
    bpy.data.objects["I4_ShadowCatcher"].hide_viewport = True
    _view_all4(s)
    return s

def _item_points(coll):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in coll.all_objects:
        if o.type not in ("MESH", "CURVE") or o.hide_render:
            continue
        oe = o.evaluated_get(dg)
        me = oe.to_mesh()
        if me is not None:
            step = max(1, len(me.vertices) // 1500)
            pts.extend(oe.matrix_world @ me.vertices[i].co for i in range(0, len(me.vertices), step))
        oe.to_mesh_clear()
    return pts

def _frame4(s, coll, pad=1.12):
    from bpy_extras.object_utils import world_to_camera_view
    cam = s.camera
    pts = _item_points(coll)
    if not pts:
        return
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    center = (lo + hi) / 2
    d = 2.0
    cam.rotation_euler = (-VIEW4).to_track_quat("-Z", "Y").to_euler()
    cam.data.shift_x = cam.data.shift_y = 0
    for _ in range(4):
        cam.location = center + VIEW4 * d
        bpy.context.view_layer.update()
        ndc = [world_to_camera_view(s, cam, p) for p in pts]
        xs = [v.x for v in ndc]; ys = [v.y for v in ndc]
        ext = max(max(xs) - min(xs), max(ys) - min(ys))
        d *= ext * pad
    cam.location = center + VIEW4 * d
    bpy.context.view_layer.update()
    ndc = [world_to_camera_view(s, cam, p) for p in pts]
    xs = [v.x for v in ndc]; ys = [v.y for v in ndc]
    cam.data.shift_x = (max(xs) + min(xs)) / 2 - 0.5
    cam.data.shift_y = (max(ys) + min(ys)) / 2 - 0.5
    base = Vector((center.x, center.y, 0.0))
    for n in ("I4_Key", "I4_Rim", "I4_Fill", "I4_Top"):
        o = bpy.data.objects[n]
        o.location = base + Vector(o["base_loc"])
    bpy.data.objects["I4_ShadowCatcher"].location = (center.x, center.y, -0.001)

def _view_all4(s):
    """Overview camera for the viewport: orthographic look at the whole shelf."""
    w = 6 * STEP4; h = (len(ITEMS4) - 1) * STEP4 * 1.2
    ov = bpy.data.objects.get("I4_Overview")
    if ov is None:
        cd = bpy.data.cameras.new("I4_Overview"); cd.type = "ORTHO"
        ov = bpy.data.objects.new("I4_Overview", cd)
        bpy.data.collections["I4_Studio"].objects.link(ov)
    ov.data.ortho_scale = max(w + 1.6, (h + 1.2) * 1.15)
    ov.rotation_euler = (math.radians(50), 0, 0)
    ov.location = (w / 2 - 0.35, h / 2 - 3.0, 2.6)
    s.camera = ov
    fl = bpy.data.objects.get("I4_Board")
    if fl is None:
        use(bpy.data.collections["I4_Labels"])
        fl = box("I4_Board", (w + 1.4, h + 0.9, 0.01), (0, 0, -0.008), soft("J_Board", "#F1E8DA", 0.9), bevel=0)
    fl.location = (w / 2 - 0.45, h / 2 - 0.1, -0.008)

def render_icons4(only=None, folder=ICON4_DIR, samples=None):
    os.makedirs(folder, exist_ok=True)
    s = bpy.data.scenes[SCENE4]
    if samples:
        s.cycles.samples = samples
    cam = bpy.data.objects["I4_Cam"]
    s.camera = cam
    items = [c for c in s.collection.children if c.name.startswith("I4_") and c.name not in ("I4_Studio", "I4_Helpers", "I4_Labels")]
    cat = bpy.data.objects["I4_ShadowCatcher"]
    cat.hide_viewport = False
    cam.data.lens = 70
    done = []
    for c in items:
        item_id = c.name[3:]
        if only and item_id not in only:
            continue
        for other in items:
            other.hide_render = other is not c
        _frame4(s, c)
        s.render.filepath = os.path.join(folder, item_id + ".png")
        bpy.ops.render.render(write_still=True, scene=s.name)
        done.append(item_id)
    for other in items:
        other.hide_render = False
    cat.hide_viewport = True
    _view_all4(s)
    return done
