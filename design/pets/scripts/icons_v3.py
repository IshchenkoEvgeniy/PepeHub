# 3D item icons for the «Питомник» shop, kitchen tray, wardrobe and decor (v3).
# Exec inside Blender after lib.py and rooms_v3.py (shared materials/helpers):
#   build_icons(); render_icons()
# Every item is built at the origin in its own collection "Icon_<id>";
# render_icons() frames each one with an orthographic camera and writes
# design/pets/icons_v3/<id>.png (512×512, transparent background).
import bpy, bmesh, math, random, os
from mathutils import Vector, Matrix

ICON_DIR = r"F:\project\PepeHub\design\pets\icons_v3"

def _arc_tube(name, R, r_mid, a0, a1, m, segs=48, ring=16, r_end=0.2, loc=(0, 0, 0), rot=(0, 0, 0)):
    """Tube bent along an arc in the XZ plane; thick in the middle, thin at the ends (crescent)."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    rings = []
    for i in range(segs + 1):
        t = i / segs
        a = math.radians(a0 + (a1 - a0) * t)
        c = Vector((R * math.cos(a), 0, R * math.sin(a)))
        n = Vector((math.cos(a), 0, math.sin(a)))
        b = Vector((0, 1, 0))
        rr = r_mid * (r_end + (1 - r_end) * math.sin(math.pi * t))
        rows = []
        for j in range(ring):
            q = 2 * math.pi * j / ring
            rows.append(bm.verts.new(c + (n * math.cos(q) + b * math.sin(q)) * rr))
        rings.append(rows)
    for i in range(segs):
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    bm.faces.new(list(reversed(rings[0]))); bm.faces.new(rings[-1])
    bm.normal_update(); bm.to_mesh(me); bm.free(); me.shade_smooth()
    return _link(name, me, m, loc, rot)

def clear_glass(name, tint="#F4FBFF", alpha=0.22):
    m = soft(name, tint, 0.05, coat=1.0)
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Alpha"].default_value = alpha
    try:
        m.surface_render_method = "BLENDED"
    except Exception:
        pass
    return m

def _icon_coll(item_id):
    root = bpy.data.scenes["Icons"].collection
    c = bpy.data.collections.get("Icon_" + item_id)
    if c is None:
        c = bpy.data.collections.new("Icon_" + item_id)
        root.children.link(c)
    use(c)
    return c

def _paw(prefix, loc, m, s=1.0, rot=(90, 0, 0)):
    """Flat paw print, facing -Y by default."""
    g = empty(prefix + "Paw", loc)
    g.rotation_euler = [math.radians(a) for a in rot]
    bt = Batch(prefix + "PawB")
    bt.sphere(m, 0.02 * s, (0, 0, -0.006 * s), scale=(1.15, 1.0, 0.25), segs=16, rings=8)
    for (x, y) in [(-0.022, 0.018), (-0.008, 0.03), (0.008, 0.03), (0.022, 0.018)]:
        bt.sphere(m, 0.008 * s, (x * s, y * s, 0), scale=(1, 1.15, 0.3), segs=12, rings=6)
    for o in bt.build(parent=g):
        o.rotation_euler = (math.radians(-90), 0, 0)
    return g

def _bowl(prefix, m, r=0.13, h=0.07):
    return revolve(prefix + "Bowl", [(0, 0), (r * 0.55, 0), (r * 0.6, 0.008), (r * 0.98, h * 0.85), (r, h), (r * 0.93, h * 1.02), (r * 0.55, h * 0.3), (0, h * 0.26)], (0, 0, 0), m, segs=64)

# ------------------------------------------------------------------ items
def icon_food_kibble(rnd):
    _icon_coll("food_kibble")
    bowl = soft("I_BowlLav", "#A891C9", 0.3, coat=0.8)
    _bowl("Kb_", bowl, r=0.14, h=0.07)
    _paw("Kb_", (0, -0.128, 0.035), soft("I_PawCream", "#FBF4E8", 0.4), s=1.2, rot=(80, 0, 0))
    kib = [soft("I_Kib%d" % i, c, 0.6) for i, c in enumerate(["#B0763F", "#9A6232", "#C68A4E"])]
    bt = Batch("Kb_Kibble")
    for i in range(70):
        a = rnd.uniform(0, 2 * math.pi); r = math.sqrt(rnd.random()) * 0.11
        z = 0.03 + 0.05 * (1 - (r / 0.11) ** 2) + rnd.uniform(0, 0.012)
        bt.sphere(rnd.choice(kib), 0.014, (math.cos(a) * r, math.sin(a) * r, z), scale=(1.2, 1.0, 0.75),
                  rot=(rnd.uniform(0, 90), rnd.uniform(0, 90), 0), segs=10, rings=6)
    bt.build()

def icon_food_fish(rnd):
    _icon_coll("food_fish")
    revolve("Fi_Plate", [(0, 0), (0.12, 0), (0.17, 0.018), (0.18, 0.022), (0.17, 0.024), (0.12, 0.008), (0, 0.008)], (0, 0, 0), soft("I_Porcelain", "#FBF7F0", 0.2, coat=0.7), segs=64)
    fish = soft("I_FishBlue", "#8FB0CF", 0.35, coat=0.5)
    belly = soft("I_FishBelly", "#DDE7EF", 0.4, coat=0.4)
    g = empty("Fi_Fish", (0, 0, 0.055)); g.rotation_euler = (0, 0, math.radians(-18)); g.scale = (1.35, 1.35, 1.35)
    ball("Fi_Body", 0.07, (0, 0, 0), fish, scale=(1.7, 0.75, 0.6), parent=g)
    ball("Fi_Belly", 0.06, (0, -0.012, -0.012), belly, scale=(1.6, 0.7, 0.45), parent=g)
    cone("Fi_Tail", 0.05, 0.08, (0.15, 0, 0), fish, rot=(0, -90, 0), parent=g, scale=(0.35, 1, 1))
    cone("Fi_Fin", 0.025, 0.05, (0.0, 0, 0.045), fish, rot=(0, 20, 0), parent=g, scale=(1, 0.3, 1))
    ball("Fi_Eye", 0.013, (-0.085, -0.035, 0.012), soft("I_EyeWhite", "#FFFFFF", 0.2), parent=g)
    ball("Fi_Pupil", 0.008, (-0.089, -0.045, 0.013), soft("I_Ink", "#2B2140", 0.2), parent=g)
    leaf = soft("I_Herb", "#6FAF55", 0.5, sss=0.2)
    bt = Batch("Fi_Herb")
    for i in range(5):
        bt.sphere(leaf, 0.018, (-0.05 + i * 0.012, 0.09 + (i % 2) * 0.012, 0.03), scale=(1, 0.5, 0.2), rot=(0, 0, i * 35), segs=10, rings=6)
    bt.build()
    for i, (x, y) in enumerate([(0.08, 0.08), (0.1, 0.06)]):
        cyl("Fi_Lemon%d" % i, 0.025, 0.008, (x, y, 0.03), soft("I_LemonSlice", "#F2E36B", 0.3, sss=0.3), rot=(70, 0, 30 * i))

def _strawberry(name, loc, s, rot, red, seed, calyx):
    g = empty(name, loc); g.rotation_euler = [math.radians(a) for a in rot]
    revolve(name + "_B", [(0, 0), (0.012 * s, 0.004 * s), (0.026 * s, 0.025 * s), (0.028 * s, 0.04 * s), (0.02 * s, 0.05 * s), (0, 0.052 * s)], (0, 0, 0), red, segs=24, parent=g)
    bt = Batch(name + "_S")
    for i in range(18):
        a = i * 2.4; z = 0.01 + (i % 6) * 0.007
        rr = 0.026 * math.sin(math.pi * min(z / 0.05, 0.95)) * s
        bt.sphere(seed, 0.0022 * s, (math.cos(a) * rr, math.sin(a) * rr, z * s), segs=6, rings=4)
    for i in range(5):
        a = i * 2 * math.pi / 5
        bt.sphere(calyx, 0.012 * s, (math.cos(a) * 0.012 * s, math.sin(a) * 0.012 * s, 0.052 * s), scale=(1.3, 0.5, 0.2), rot=(0, 0, math.degrees(a)), segs=8, rings=4)
    bt.build(parent=g)

def icon_food_berries(rnd):
    _icon_coll("food_berries")
    _bowl("Be_", soft("I_BowlCream", "#F6EEE2", 0.25, coat=0.8), r=0.13, h=0.075)
    blue = soft("I_Blueberry", "#3F4A8A", 0.3, coat=0.6)
    rasp = soft("I_Raspberry", "#D9446A", 0.45, sss=0.4)
    red = soft("I_Strawberry", "#D3363A", 0.25, coat=0.7, sss=0.3)
    seed = soft("I_Seed", "#F2D36B", 0.4)
    calyx = soft("I_Calyx", "#4F8A3A", 0.5)
    bt = Batch("Be_Fruit")
    for i in range(16):
        a = rnd.uniform(0, 2 * math.pi); r = math.sqrt(rnd.random()) * 0.09
        z = 0.06 + 0.035 * (1 - r / 0.09)
        if i % 2 == 0:
            bt.sphere(blue, 0.017, (math.cos(a) * r, math.sin(a) * r, z), segs=16, rings=10)
        else:
            cx, cy = math.cos(a) * r, math.sin(a) * r
            for k in range(14):
                q = k * 2.4; zz = (k / 14) * 0.03
                rr2 = 0.013 * math.sin(math.pi * (0.15 + 0.8 * k / 14))
                bt.sphere(rasp, 0.0065, (cx + math.cos(q) * rr2, cy + math.sin(q) * rr2, z - 0.01 + zz), segs=8, rings=6)
    bt.build()
    _strawberry("Be_Straw1", (0.02, -0.02, 0.1), 1.3, (30, 0, 20), red, seed, calyx)
    _strawberry("Be_Straw2", (-0.04, 0.03, 0.095), 1.1, (-25, 15, 0), red, seed, calyx)
    mint = soft("I_Mint", "#6FB35A", 0.45, sss=0.3)
    ball("Be_Mint1", 0.022, (0.05, 0.04, 0.12), mint, scale=(1, 0.45, 0.15), rot=(20, 0, 40))
    ball("Be_Mint2", 0.018, (0.065, 0.025, 0.118), mint, scale=(1, 0.45, 0.15), rot=(10, 0, -20))

def icon_food_cake(rnd):
    _icon_coll("food_cake")
    wrap = soft("I_Wrapper", "#A891C9", 0.4, coat=0.4)
    me = bpy.data.meshes.new("Ck_Wrap")
    bm = bmesh.new()
    segs, rows = 96, 8
    grid = []
    for k in range(rows + 1):
        z = 0.07 * k / rows
        rr = 0.06 + 0.022 * k / rows
        row = []
        for i in range(segs):
            a = 2 * math.pi * i / segs
            rad = rr * (1 + 0.035 * math.cos(a * 24))
            row.append(bm.verts.new((rad * math.cos(a), rad * math.sin(a), z)))
        grid.append(row)
    for k in range(rows):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((grid[k][i], grid[k][j], grid[k + 1][j], grid[k + 1][i]))
    bm.faces.new(list(reversed(grid[0])))
    bm.to_mesh(me); bm.free(); me.shade_smooth()
    _link("Ck_Wrap", me, wrap)
    revolve("Ck_Cake", [(0, 0.06), (0.085, 0.07), (0.09, 0.085), (0.075, 0.1), (0, 0.105)], (0, 0, 0), soft("I_Sponge", "#E0A86A", 0.7))
    # frosting swirl: stacked tori that shrink
    cream = soft("I_Frost", "#FBF2F4", 0.35, sss=0.4, coat=0.3)
    for i, (R, r, z) in enumerate([(0.06, 0.03, 0.115), (0.045, 0.026, 0.15), (0.028, 0.022, 0.18)]):
        torus("Ck_Swirl%d" % i, R, r, (0, 0, z), cream, seg=48, ring=16)
    ball("Ck_Tip", 0.022, (0, 0, 0.205), cream, scale=(1, 1, 1.3))
    sp = [soft("I_Spr%d" % i, c, 0.3, coat=0.6) for i, c in enumerate(["#F2A6B8", "#8ED1B8", "#F2D36B", "#A891C9"])]
    bt = Batch("Ck_Sprinkles")
    for i in range(40):
        a = rnd.uniform(0, 2 * math.pi); z = rnd.uniform(0.11, 0.2)
        rr = 0.085 * (1 - (z - 0.1) / 0.12) + 0.01
        bt.cyl(rnd.choice(sp), 0.0025, 0.012, (math.cos(a) * rr, math.sin(a) * rr, z), rot=(rnd.uniform(0, 180), rnd.uniform(0, 180), 0), segs=6)
    bt.build()
    _link("Ck_Star", _star_mesh("Ck_StarMe", 0.035, 0.016, 0.012), glow("I_StarGold", "#F6C95A", 0.8, base="#E7B44E"), (0, 0, 0.255), (0, 0, 0))

def _paint(item_id, color, rnd):
    _icon_coll(item_id)
    tin = soft("I_Tin", "#E9E2D8", 0.3, metal=0.6)
    revolve("Pt_" + item_id + "_Can", [(0, 0), (0.08, 0), (0.082, 0.005), (0.082, 0.1), (0.086, 0.104), (0.086, 0.112), (0.078, 0.112), (0.078, 0.104), (0, 0.104)], (0, 0, 0), tin, segs=64)
    cyl("Pt_" + item_id + "_Label", 0.0835, 0.06, (0, 0, 0.05), soft("I_Label_" + item_id, "#FBF4E8", 0.6), verts=64)
    paint = soft("I_Paint_" + item_id, color, 0.15, coat=0.6)
    cyl("Pt_" + item_id + "_Paint", 0.076, 0.006, (0, 0, 0.106), paint, verts=64)
    # drips over the rim
    bt = Batch("Pt_" + item_id + "_Drip")
    for i, (a, L) in enumerate([(-100, 0.045), (-75, 0.025), (-120, 0.03)]):
        ar = math.radians(a)
        x, y = math.cos(ar) * 0.084, math.sin(ar) * 0.084
        bt.cyl(paint, 0.008, L, (x, y, 0.11 - L / 2), segs=10)
        bt.sphere(paint, 0.0095, (x, y, 0.11 - L), segs=10, rings=8)
    bt.sphere(paint, 0.012, (math.cos(math.radians(-90)) * 0.07, -0.07, 0.112), scale=(1.8, 1.2, 0.4), segs=12, rings=6)
    bt.build()
    _paw("Pt_" + item_id + "_", (0, -0.084, 0.05), paint, s=1.0)
    # brush resting on top
    g = empty("Pt_" + item_id + "_Brush", (0.02, 0.02, 0.12)); g.rotation_euler = (math.radians(10), math.radians(70), math.radians(30))
    cyl("Pt_" + item_id + "_Handle", 0.008, 0.16, (0, 0, 0.04), wood("I_BrushWood", "#C9945E", "#A9743F", scale=3.0), parent=g)
    cyl("Pt_" + item_id + "_Ferrule", 0.01, 0.03, (0, 0, -0.05), soft("I_Brass", "#D9AA5C", 0.25, metal=1.0), parent=g)
    cone("Pt_" + item_id + "_Bristle", 0.011, 0.04, (0, 0, -0.08), paint, rot=(180, 0, 0), parent=g)

def icon_book_stack(rnd):
    _icon_coll("decor_book_stack")
    page = soft("I_Paper", "#F6EEDC", 0.8)
    gold = soft("I_Brass", "#D9AA5C", 0.25, metal=1.0)
    for i, (c, w, d, h, rz) in enumerate([("#5B3F66", 0.24, 0.17, 0.04, 6), ("#6F8F72", 0.22, 0.16, 0.035, -8), ("#A893C2", 0.2, 0.15, 0.035, 14)]):
        z = 0.02 + i * 0.038
        book("Bk_%d" % i, (0, 0, z), (w, d, h), soft("I_Cover%d" % i, c, 0.5, coat=0.3), page, rot=(0, 0, rz))
        box("Bk_Band%d" % i, (0.012, d + 0.002, h + 0.002), (w * 0.3 * math.cos(math.radians(rz)), w * 0.3 * math.sin(math.radians(rz)), z), gold, bevel=0.002, rot=(0, 0, rz))
    tube("Bk_Ribbon", [(-0.05, -0.05, 0.13), (-0.06, -0.08, 0.1), (-0.055, -0.085, 0.06)], 0.004, soft("I_Ribbon", "#D9446A", 0.5))
    teacup("Bk_Tea", (0.0, 0.0, 0.112), soft("I_Porcelain", "#FBF7F0", 0.2, coat=0.7), soft("I_Tea", "#8A4B22", 0.1), s=0.9)

def icon_moon_lamp(rnd):
    _icon_coll("decor_moon_lamp")
    revolve("Ml_Base", [(0, 0), (0.07, 0), (0.07, 0.015), (0.05, 0.025), (0, 0.025)], (0, 0, 0), wood("I_WoodHoney", "#B98556", "#9A6A40", scale=3.0, coat=0.3))
    cyl("Ml_Stem", 0.005, 0.04, (0, 0, 0.045), soft("I_Brass", "#D9AA5C", 0.25, metal=1.0))
    _arc_tube("Ml_Moon", 0.07, 0.035, 40, 320, glow("I_MoonGlow", "#FFC860", 0.35, base="#F4CF78"), loc=(0.0, 0, 0.135), rot=(0, 0, 0), r_end=0.15)
    _link("Ml_Star", _star_mesh("Ml_StarMe", 0.02, 0.009, 0.006), glow("I_StarGold", "#F6C95A", 0.8, base="#E7B44E"), (0.03, 0, 0.14))
    light("Ml_Light", "POINT", (0, -0.08, 0.14), 3, color=(1.0, 0.85, 0.55), size=0.03)

def icon_globe(rnd):
    _icon_coll("decor_globe")
    m, nt, b = _nm("I_GlobeMap")
    v = _coords(nt)
    n = nt.nodes.new("ShaderNodeTexNoise"); n.inputs["Scale"].default_value = 9.0; n.inputs["Detail"].default_value = 4
    nt.links.new(v, n.inputs["Vector"])
    r = _ramp(nt, n.outputs["Fac"], "#7FB7D9", "#8DBE73", 0.52, 0.54)
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.3; b.inputs["Coat Weight"].default_value = 0.6
    brass = soft("I_Brass", "#D9AA5C", 0.25, metal=1.0)
    ball("Gl_Sphere", 0.08, (0, 0, 0.13), m, segs=48, rings=24)
    torus("Gl_Ring", 0.09, 0.005, (0, 0, 0.13), brass, rot=(90, -23, 0), seg=64, ring=10)
    cyl("Gl_Neck", 0.008, 0.04, (0, 0, 0.035), brass)
    revolve("Gl_Base", [(0, 0), (0.065, 0), (0.065, 0.012), (0.03, 0.025), (0, 0.025)], (0, 0, 0), wood("I_WoodWalnut", "#6E4A33", "#553624", scale=3.0, coat=0.3))

def icon_aquarium(rnd):
    _icon_coll("decor_aquarium")
    W, D, H = 0.26, 0.15, 0.17
    glass = clear_glass("I_GlassThin", alpha=0.08)
    water = clear_glass("I_WaterClear", "#7FC3E6", alpha=0.35)
    rbox("Aq_Water", (W - 0.01, D - 0.01, H * 0.8), (0, 0, H * 0.42), water, r=0.004)
    rbox("Aq_Sand", (W - 0.012, D - 0.012, 0.03), (0, 0, 0.018), soft("I_Sand", "#EBD7AE", 0.9), r=0.004)
    for s in (-1, 1):
        rbox("Aq_GlassX%d" % s, (0.004, D, H), (s * W / 2, 0, H / 2), glass, r=0.001)
        rbox("Aq_GlassY%d" % s, (W, 0.004, H), (0, s * D / 2, H / 2), glass, r=0.001)
    rim_m = wood("I_WoodHoney", "#B98556", "#9A6A40", scale=3.0, coat=0.3)
    for s in (-1, 1):
        rbox("Aq_RimX%d" % s, (0.012, D + 0.012, 0.012), (s * W / 2, 0, H), rim_m, r=0.003)
        rbox("Aq_RimY%d" % s, (W + 0.012, 0.012, 0.012), (0, s * D / 2, H), rim_m, r=0.003)
    rbox("Aq_Stand", (W + 0.01, D + 0.01, 0.02), (0, 0, 0.0), wood("I_WoodHoney", "#B98556", "#9A6A40", scale=3.0, coat=0.3), r=0.003)
    orange = soft("I_Goldfish", "#F08A3C", 0.3, coat=0.6)
    for i, (x, y, z, rz) in enumerate([(-0.05, -0.01, 0.09, 10), (0.06, 0.02, 0.06, 190), (0.0, 0.03, 0.12, -20)]):
        g = empty("Aq_Fish%d" % i, (x, y, z)); g.rotation_euler = (0, 0, math.radians(rz))
        ball("Aq_FishB%d" % i, 0.018, (0, 0, 0), orange, scale=(1.5, 0.6, 0.9), parent=g)
        cone("Aq_FishT%d" % i, 0.014, 0.022, (0.03, 0, 0), orange, rot=(0, -90, 0), scale=(0.3, 1, 1), parent=g)
    weed = soft("I_Weed", "#5E9B55", 0.5, sss=0.3)
    for i, x in enumerate([-0.09, -0.07, 0.08]):
        tube("Aq_Weed%d" % i, [(x, 0.04, 0.03), (x + 0.01, 0.04, 0.07), (x - 0.01, 0.04, 0.11), (x + 0.005, 0.04, 0.14)], 0.005, weed)
    for i in range(4):
        ball("Aq_Bubble%d" % i, 0.004 + 0.001 * i, (0.03, -0.02, 0.06 + i * 0.025), glass)

def icon_scarf(rnd):
    _icon_coll("acc_scarf")
    knit_l = knit("I_KnitLav", "#9A86C2", "#7F6AA8", scale=60, strength=1.0)
    torus("Sc_Loop", 0.07, 0.03, (0, 0, 0.05), knit_l, scale=(1.1, 1, 0.9), seg=64, ring=20)
    for i, (x, rz, L) in enumerate([(0.03, 8, 0.14), (0.065, -6, 0.12)]):
        g = empty("Sc_Tail%d" % i, (x, -0.075, 0.04)); g.rotation_euler = (math.radians(-14), math.radians(rz), 0)
        rbox("Sc_TailB%d" % i, (0.05, 0.02, L), (0, 0, -L / 2), knit_l, r=0.008, parent=g, subd=1)
        bt = Batch("Sc_Fringe%d" % i)
        for k in range(5):
            bt.cyl(knit_l, 0.004, 0.025, (-0.02 + k * 0.01, 0, -L - 0.012), segs=6)
        bt.build(parent=g)
    _link("Sc_Star", _star_mesh("Sc_StarMe", 0.014, 0.006, 0.004), glow("I_StarGold", "#F6C95A", 0.8, base="#E7B44E"), (0.03, -0.092, 0.0), (-14, 0, 0))

def icon_beanie(rnd):
    _icon_coll("acc_beanie")
    k = knit("I_KnitBlue", "#8FB7D9", "#749CC0", scale=55, strength=1.0)
    revolve("Bn_Cap", [(0.085, 0.03), (0.088, 0.06), (0.08, 0.1), (0.06, 0.13), (0.03, 0.145), (0, 0.15)], (0, 0, 0), k, segs=64)
    rib = knit("I_KnitRib", "#7FA6CB", "#6890B6", scale=90, strength=1.2)
    revolve("Bn_Rib", [(0.0, 0.0), (0.09, 0.0), (0.094, 0.005), (0.094, 0.035), (0.088, 0.04), (0.0, 0.04)], (0, 0, 0), rib, segs=64)
    ball("Bn_Pom", 0.035, (0, 0, 0.175), knit("I_KnitCreamPom", "#F3ECE2", "#DCD2C4", scale=120, strength=1.5), segs=24, rings=16)

def icon_glasses(rnd):
    _icon_coll("acc_glasses")
    gold = soft("I_GoldMetal", "#D9AA5C", 0.2, metal=1.0)
    lens = clear_glass("I_LensClear", alpha=0.15)
    for s in (-1, 1):
        torus("Gs_Rim%d" % s, 0.04, 0.0045, (s * 0.05, 0, 0.05), gold, rot=(90, 0, 0), seg=64, ring=10)
        cyl("Gs_Lens%d" % s, 0.039, 0.003, (s * 0.05, 0, 0.05), lens, rot=(90, 0, 0), verts=48)
        tube("Gs_Temple%d" % s, [(s * 0.09, 0, 0.055), (s * 0.095, 0.06, 0.055), (s * 0.093, 0.11, 0.04)], 0.0035, gold)
    _arc_tube("Gs_Bridge", 0.014, 0.0035, 20, 160, gold, segs=16, ring=8, r_end=1.0, loc=(0, 0, 0.055))

def _egg(item_id, base, spot, kind, rnd):
    _icon_coll(item_id)
    nest = knit("I_Nest", "#D9C8AE", "#BFA988", scale=40, strength=1.2)
    torus("Eg_" + item_id + "_Nest", 0.075, 0.03, (0, 0, 0.025), nest, seg=64, ring=20)
    cyl("Eg_" + item_id + "_NestIn", 0.075, 0.02, (0, 0, 0.012), nest, verts=48)
    m, nt, b = _nm("I_Egg_" + item_id)
    v = _coords(nt)
    if kind == "spots":
        tex = nt.nodes.new("ShaderNodeTexVoronoi"); tex.inputs["Scale"].default_value = 14.0
        nt.links.new(v, tex.inputs["Vector"])
        r = _ramp(nt, tex.outputs["Distance"], spot, base, 0.28, 0.3)
    elif kind == "band":
        sep = nt.nodes.new("ShaderNodeSeparateXYZ"); nt.links.new(v, sep.inputs[0])
        n = nt.nodes.new("ShaderNodeTexNoise"); n.inputs["Scale"].default_value = 18.0
        nt.links.new(v, n.inputs["Vector"])
        add = nt.nodes.new("ShaderNodeMath"); add.operation = "MULTIPLY_ADD"
        add.inputs[1].default_value = 0.02; add.inputs[2].default_value = -0.01
        nt.links.new(n.outputs["Fac"], add.inputs[0])
        s2 = nt.nodes.new("ShaderNodeMath"); s2.operation = "ADD"
        nt.links.new(sep.outputs["Z"], s2.inputs[0]); nt.links.new(add.outputs[0], s2.inputs[1])
        r = _ramp(nt, s2.outputs[0], base, spot, 0.105, 0.11)
    else:  # scales
        tex = nt.nodes.new("ShaderNodeTexVoronoi"); tex.inputs["Scale"].default_value = 30.0
        tex.feature = "DISTANCE_TO_EDGE"
        nt.links.new(v, tex.inputs["Vector"])
        r = _ramp(nt, tex.outputs["Distance"], spot, base, 0.0, 0.08)
        _bump(nt, b, tex.outputs["Distance"], 0.4, 0.004)
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.3; b.inputs["Coat Weight"].default_value = 0.6
    b.inputs["Subsurface Weight"].default_value = 0.2
    prof = []
    for i in range(25):
        t = i / 24
        z = 0.15 * t
        r_ = 0.058 * math.sin(math.pi * t) ** 0.8 * (1.08 - 0.25 * t)
        prof.append((max(r_, 0.0), z))
    prof[0] = (0.0, 0.0); prof[-1] = (0.0, 0.15)
    revolve("Eg_" + item_id + "_Egg", prof, (0, 0, 0.02), m, segs=64)
    light("Eg_" + item_id + "_Glow", "POINT", (0, -0.05, 0.05), 2, color=(1.0, 0.85, 0.6), size=0.03)

def icon_incubator(rnd):
    _icon_coll("incubator_slot")
    wood_h = wood("I_WoodHoney", "#B98556", "#9A6A40", scale=3.0, coat=0.3)
    revolve("In_Base", [(0, 0), (0.11, 0), (0.11, 0.03), (0.1, 0.04), (0, 0.04)], (0, 0, 0), wood_h, segs=64)
    nest = knit("I_Nest", "#D9C8AE", "#BFA988", scale=40, strength=1.2)
    torus("In_Nest", 0.075, 0.025, (0, 0, 0.06), nest, seg=64, ring=20)
    revolve("In_Dome", [(0.095, 0.04), (0.095, 0.08), (0.085, 0.13), (0.06, 0.17), (0.03, 0.188), (0, 0.192)], (0, 0, 0), clear_glass("I_DomeClear", alpha=0.25), segs=64)
    rbox("In_Plus", (0.05, 0.012, 0.012), (0, -0.0, 0.11), glow("I_PlusGlow", "#FFD27A", 3.0), r=0.004)
    rbox("In_Plus2", (0.012, 0.012, 0.05), (0, -0.0, 0.11), glow("I_PlusGlow", "#FFD27A", 3.0), r=0.004)
    torus("In_Knob", 0.012, 0.004, (0, 0, 0.196), soft("I_Brass", "#D9AA5C", 0.25, metal=1.0), seg=24, ring=8)
    light("In_Light", "POINT", (0, -0.03, 0.1), 3, color=(1.0, 0.8, 0.5), size=0.03)

def icon_freeze(rnd):
    _icon_coll("freeze")
    ice = soft("I_IceBlue", "#9FD6EE", 0.08, coat=1.0, sss=0.5)
    rbox("Fz_Cube", (0.14, 0.14, 0.14), (0, 0, 0.07), ice, r=0.02, rot=(0, 0, 20))
    flake = glow("I_Flake", "#FFFFFF", 1.5, base="#FFFFFF")
    # snowflake on the front face of the cube (cube is turned 20° around Z)
    g = empty("Fz_Flake", (math.sin(math.radians(20)) * 0.072, -math.cos(math.radians(20)) * 0.072, 0.07))
    g.rotation_euler = (0, 0, math.radians(20))
    bt = Batch("Fz_FlakeB")
    for i in range(6):
        a = math.radians(i * 60)
        dx, dz = math.cos(a), math.sin(a)
        bt.cyl(flake, 0.0035, 0.09, (dx * 0.022, 0, dz * 0.022), rot=(0, 90 - i * 60, 0), segs=8)
        for s in (-1, 1):
            b = a + s * math.radians(40)
            bt.cyl(flake, 0.0028, 0.022, (dx * 0.03 + math.cos(b) * 0.009, 0, dz * 0.03 + math.sin(b) * 0.009), rot=(0, 90 - math.degrees(b), 0), segs=6)
    bt.sphere(flake, 0.008, (0, 0, 0), segs=12, rings=8)
    bt.build(parent=g)

def icon_mushroom(rnd):
    _icon_coll("decor_mushroom_lamp")
    revolve("Mu_Stem", [(0, 0), (0.05, 0), (0.035, 0.03), (0.032, 0.11), (0, 0.11)], (0, 0, 0), soft("I_MushStem", "#F3E6D2", 0.5, sss=0.4))
    revolve("Mu_Cap", [(0.0, 0.0), (0.12, 0.0), (0.125, 0.012), (0.1, 0.06), (0.05, 0.095), (0, 0.105)], (0, 0, 0.1), glow("I_MushCap", "#FF9C8A", 1.2, base="#F08A7C"))
    bt = Batch("Mu_Dots")
    for i in range(10):
        a = i * 2 * math.pi / 7 + 0.4; rr = 0.08 if i < 7 else 0.035
        z = 0.1 + 0.105 * (1 - (rr / 0.125) ** 2) - 0.004
        bt.sphere(soft("I_MushDot", "#FFF6EA", 0.5), 0.014, (math.cos(a) * rr, math.sin(a) * rr, z), scale=(1, 1, 0.35), segs=10, rings=6)
    bt.build()
    light("Mu_Light", "POINT", (0, -0.05, 0.08), 4, color=(1.0, 0.6, 0.45), size=0.03)

def icon_lantern(rnd):
    _icon_coll("decor_lantern")
    brass = soft("I_Brass", "#D9AA5C", 0.25, metal=1.0)
    navy = soft("I_LanternNavy", "#5B6AA8", 0.35, coat=0.5)
    rbox("Ln_Base", (0.11, 0.11, 0.015), (0, 0, 0.008), navy, r=0.004)
    rbox("Ln_Top", (0.12, 0.12, 0.015), (0, 0, 0.17), navy, r=0.004)
    cone("Ln_Roof", 0.085, 0.05, (0, 0, 0.2), navy, verts=4, rot=(0, 0, 45))
    torus("Ln_Ring", 0.018, 0.004, (0, 0, 0.235), brass, rot=(90, 0, 0), seg=16, ring=8)
    for sx, sy in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
        cyl("Ln_Post%d%d" % (sx, sy), 0.005, 0.16, (sx * 0.05, sy * 0.05, 0.09), navy)
    box("Ln_Glass", (0.095, 0.095, 0.15), (0, 0, 0.09), soft("I_LanternGlass", "#FFE9C4", 0.1, coat=1.0), bevel=0)
    revolve("Ln_Candle", [(0, 0), (0.022, 0), (0.022, 0.06), (0, 0.06)], (0, 0, 0.016), soft("I_Wax", "#FFF1DC", 0.5, sss=0.5))
    ball("Ln_Flame", 0.009, (0, 0, 0.085), glow("I_Flame", "#FFB860", 30.0), scale=(1, 1, 1.8))
    _link("Ln_Star", _star_mesh("Ln_StarMe", 0.018, 0.008, 0.004), brass, (0, -0.049, 0.13))
    light("Ln_Light", "POINT", (0, -0.02, 0.09), 4, color=(1.0, 0.65, 0.35), size=0.02)

def icon_tulip_lamp(rnd):
    _icon_coll("decor_tulip_lamp")
    brass = soft("I_Brass", "#D9AA5C", 0.25, metal=1.0)
    revolve("Tl_Base", [(0, 0), (0.06, 0), (0.06, 0.01), (0.02, 0.02), (0, 0.02)], (0, 0, 0), brass)
    tube("Tl_Arc", [(0, 0, 0.02), (0, 0, 0.2), (-0.02, 0, 0.29), (-0.08, 0, 0.31), (-0.11, 0, 0.28)], 0.005, brass)
    scallop_shade("Tl_Shade", (-0.11, 0, 0.2), glow("I_TulipGlow", "#FFC98A", 2.0, base="#FFE7C7"), r_top=0.02, r_bot=0.065, h=0.075)
    ball("Tl_Bulb", 0.015, (-0.11, 0, 0.225), glow("I_Bulb", "#FFE2B0", 15.0))
    light("Tl_Light", "POINT", (-0.11, -0.03, 0.21), 3, color=(1.0, 0.8, 0.55), size=0.02)

ICONS = [
    ("food_kibble", icon_food_kibble), ("food_fish", icon_food_fish),
    ("food_berries", icon_food_berries), ("food_cake", icon_food_cake),
    ("decor_book_stack", icon_book_stack), ("decor_moon_lamp", icon_moon_lamp),
    ("decor_globe", icon_globe), ("decor_aquarium", icon_aquarium),
    ("decor_mushroom_lamp", icon_mushroom), ("decor_lantern", icon_lantern),
    ("decor_tulip_lamp", icon_tulip_lamp),
    ("acc_scarf", icon_scarf), ("acc_beanie", icon_beanie), ("acc_glasses", icon_glasses),
    ("incubator_slot", icon_incubator), ("freeze", icon_freeze),
]
PAINTS = [("color_midnight", "#3A3A50"), ("color_snow", "#F4F1EC"), ("color_mint", "#8ED1B8"),
          ("color_amber", "#E0A040"), ("color_sunset", "#E07A6A"), ("color_aurora", "#7FA8E8")]
EGGS = [("egg_cat", "#F6E7D3", "#E98FA8", "spots"), ("egg_fox", "#F09A50", "#FFF4E6", "band"),
        ("egg_dragon", "#8ED1B8", "#5FA68C", "scales")]


# Shelf layout in the Icons scene: one row per category, labels under items.
ROWS = [
    ("Еда", ["food_kibble", "food_fish", "food_berries", "food_cake"]),
    ("Окрасы", ["color_midnight", "color_snow", "color_mint", "color_amber", "color_sunset", "color_aurora"]),
    ("Декор", ["decor_book_stack", "decor_moon_lamp", "decor_globe", "decor_aquarium", "decor_mushroom_lamp", "decor_lantern", "decor_tulip_lamp"]),
    ("Аксессуары", ["acc_scarf", "acc_beanie", "acc_glasses"]),
    ("Яйца", ["egg_cat", "egg_fox", "egg_dragon"]),
    ("Разное", ["freeze", "incubator_slot"]),
]
STEP_X, STEP_Y = 0.45, 0.6

def _text(name, body, loc, size, coll, color="#3E2F4A"):
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.size = size
    cu.align_x = "CENTER"
    o = bpy.data.objects.new(name, cu)
    coll.objects.link(o)
    o.location = loc
    o.rotation_euler = (math.radians(70), 0, 0)
    cu.materials.append(soft("I_LabelInk", color, 0.6))
    return o

def arrange_icons(s):
    """Moves every item to its shelf cell and adds labels (labels never render)."""
    labels = bpy.data.collections.get("Icon_Labels")
    if labels is None:
        labels = bpy.data.collections.new("Icon_Labels"); s.collection.children.link(labels)
    for o in list(labels.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    labels.hide_render = True
    for r, (title, ids) in enumerate(ROWS):
        y = (len(ROWS) - 1 - r) * STEP_Y   # first category on top
        _text("Row_" + title, title, (-0.3, y, 0.0), 0.08, labels).data.align_x = "RIGHT"
        for k, item_id in enumerate(ids):
            c = bpy.data.collections.get("Icon_" + item_id)
            if c is None:
                continue
            off = Vector((k * STEP_X, y, 0))
            for o in c.objects:
                if o.parent is None:
                    o.location = Vector(o.location) + off
            _text("Lbl_" + item_id, item_id, (k * STEP_X, y - 0.18, 0.0), 0.04, labels, "#7A6A86")
    # a soft floor under the shelf so the viewport reads as one board
    studio = bpy.data.collections["Icon_Studio"]
    fl = bpy.data.objects.get("Icon_Floor")
    if fl is None:
        use(studio)
        fl = box("Icon_Floor", (7 * STEP_X + 1.2, len(ROWS) * STEP_Y + 0.4, 0.01), (0, 0, -0.006), soft("I_Floor", "#F1E8DA", 0.9), bevel=0)
    fl.location = ((6 * STEP_X) / 2 - 0.4, (len(ROWS) - 1) * STEP_Y / 2 - 0.05, -0.006)
    fl.hide_render = True

def build_icons():
    s = bpy.data.scenes.get("Icons") or bpy.data.scenes.new("Icons")
    for c in list(s.collection.children):
        for o in list(c.all_objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(c)
    try:
        s.render.engine = "BLENDER_EEVEE"
    except TypeError:
        pass
    s.render.resolution_x = s.render.resolution_y = 512
    s.render.resolution_percentage = 100
    s.render.film_transparent = True
    s.render.image_settings.file_format = "PNG"
    s.render.image_settings.color_mode = "RGBA"
    s.view_settings.view_transform = "AgX"
    try:
        s.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass
    s.eevee.use_raytracing = True
    s.eevee.use_fast_gi = True
    s.eevee.taa_render_samples = 64
    if s.world is None:
        w = bpy.data.worlds.new("Icons_World"); w.use_nodes = True; s.world = w
    world_color(s, "#F4ECF6", 0.4)
    post_fx(s, bloom=0.35, threshold=0.95)
    studio = bpy.data.collections.new("Icon_Studio"); s.collection.children.link(studio)
    use(studio)
    light("Key", "AREA", (-0.6, -0.8, 1.0), 60, color=(1.0, 0.95, 0.9), size=0.8, rot=(50, 0, -35))
    light("Rim", "AREA", (0.6, 0.7, 0.6), 30, color=(0.9, 0.88, 1.0), size=0.6, rot=(-60, 0, 140))
    light("Fill", "AREA", (0.8, -0.6, 0.3), 15, color=(1.0, 0.92, 0.85), size=1.0, rot=(75, 0, 55))
    cd = bpy.data.cameras.new("IconCam"); cd.type = "ORTHO"
    cam_o = bpy.data.objects.new("IconCam", cd); studio.objects.link(cam_o); s.camera = cam_o
    rnd = random.Random(3)
    for item_id, fn in ICONS:
        fn(rnd)
    for item_id, c in PAINTS:
        _paint(item_id, c, rnd)
    for item_id, base, spot, kind in EGGS:
        _egg(item_id, base, spot, kind, rnd)
    # remember studio light offsets: they follow the framed item when rendering
    for n in ("Key", "Rim", "Fill"):
        o = bpy.data.objects[n]
        o["base_loc"] = list(o.location)
    arrange_icons(s)
    return s

def _frame(s, coll, view=(0.55, -1.0, 0.62), pad=1.18):
    cam_o = s.camera
    d = Vector(view).normalized()
    pts = []
    dg = bpy.context.evaluated_depsgraph_get()
    for o in coll.all_objects:
        if o.type not in ("MESH", "CURVE"):
            continue
        oe = o.evaluated_get(dg)
        if o.type == "CURVE":
            # curve bound_box is unreliable: measure the evaluated mesh instead
            me = oe.to_mesh()
            pts.extend(oe.matrix_world @ v.co for v in me.vertices)
            oe.to_mesh_clear()
        else:
            for c in oe.bound_box:
                pts.append(oe.matrix_world @ Vector(c))
    if not pts:
        return
    center = sum(pts, Vector()) / len(pts)
    rot = (-d).to_track_quat("-Z", "Y")
    right = rot @ Vector((1, 0, 0)); up = rot @ Vector((0, 1, 0))
    xs = [(p - center).dot(right) for p in pts]; ys = [(p - center).dot(up) for p in pts]
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    center = center + right * cx + up * cy
    cam_o.location = center + d * 2.0
    item_base = Vector((center.x, center.y, 0.0))
    for n in ("Key", "Rim", "Fill"):
        o = bpy.data.objects.get(n)
        if o is not None and "base_loc" in o:
            o.location = item_base + Vector(o["base_loc"])
    cam_o.rotation_euler = rot.to_euler()
    cam_o.data.ortho_scale = max(max(xs) - min(xs), max(ys) - min(ys)) * pad
    cam_o.data.clip_end = 10

def render_icons(only=None, folder=ICON_DIR):
    os.makedirs(folder, exist_ok=True)
    s = bpy.data.scenes["Icons"]
    items = [c for c in s.collection.children if c.name.startswith("Icon_") and c.name not in ("Icon_Studio", "Icon_Labels")]
    for c in items:
        item_id = c.name[len("Icon_"):]
        if only and item_id not in only:
            continue
        for other in items:
            other.hide_render = other is not c
            other.hide_viewport = other is not c
        _frame(s, c)
        s.render.filepath = os.path.join(folder, item_id + ".png")
        bpy.ops.render.render(write_still=True, scene=s.name)
    for other in items:
        other.hide_render = False
        other.hide_viewport = False
    # leave the camera looking at the whole shelf
    _frame_all(s)

def _frame_all(s):
    cam_o = s.camera
    w = 6 * STEP_X; h = (len(ROWS) - 1) * STEP_Y
    cam_o.location = (w / 2 - 0.45, h / 2 - 2.4, 2.6)
    cam_o.rotation_euler = (math.radians(44), 0, 0)
    cam_o.data.ortho_scale = max(w, h) + 1.6
