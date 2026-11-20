# Two new room dioramas for the PepeHub "Дом" screen. Exec after lib.py.
import bpy, math, random
from mathutils import Vector

def checker_mat(name, c1, c2, scale=8.0, rough=0.5):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    for n in list(nt.nodes):
        if n.type in ("TEX_CHECKER", "TEX_COORD"):
            nt.nodes.remove(n)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    ck = nt.nodes.new("ShaderNodeTexChecker")
    ck.inputs["Scale"].default_value = scale
    ck.inputs["Color1"].default_value = (*hexc(c1), 1)
    ck.inputs["Color2"].default_value = (*hexc(c2), 1)
    nt.links.new(tc.outputs["Object"], ck.inputs["Vector"])
    nt.links.new(ck.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*hexc(c1), 1)
    return m

def plank_mat(name, c1, c2, rough=0.55):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (1.0, 5.0, 1.0)
    br = nt.nodes.new("ShaderNodeTexBrick")
    br.inputs["Color1"].default_value = (*hexc(c1), 1)
    br.inputs["Color2"].default_value = (*hexc(c2), 1)
    br.inputs["Mortar"].default_value = (*[v * 0.6 for v in hexc(c2)], 1)
    br.inputs["Scale"].default_value = 2.5
    br.inputs["Mortar Size"].default_value = 0.008
    br.inputs["Brick Width"].default_value = 1.2
    br.inputs["Row Height"].default_value = 0.25
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], br.inputs["Vector"])
    nt.links.new(br.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*hexc(c1), 1)
    return m

def shell(prefix, floor_m, wall_back_m, wall_left_m, trim_m, base_m, size=4.0, h=2.8):
    s = size / 2
    box(prefix + "Base", (size + 0.2, size + 0.2, 0.25), (0, 0, -0.125 - 0.04), base_m, bevel=0.04)
    box(prefix + "Floor", (size, size, 0.08), (0, 0, -0.04), floor_m, bevel=0.01)
    box(prefix + "WallBack", (size + 0.15, 0.15, h), (-0.075, s + 0.075, h / 2), wall_back_m, bevel=0.02)
    box(prefix + "WallLeft", (0.15, size, h), (-s - 0.075, 0, h / 2), wall_left_m, bevel=0.02)
    box(prefix + "TrimBack", (size, 0.04, 0.12), (0, s - 0.02, 0.06), trim_m, bevel=0.01)
    box(prefix + "TrimLeft", (0.04, size, 0.12), (-s + 0.02, 0, 0.06), trim_m, bevel=0.01)
    box(prefix + "CapBack", (size + 0.19, 0.19, 0.05), (-0.075, s + 0.075, h + 0.025), trim_m, bevel=0.01)
    box(prefix + "CapLeft", (0.19, size + 0.04, 0.05), (-s - 0.075, 0.0, h + 0.025), trim_m, bevel=0.01)

def window(prefix, center, axis, w, hgt, frame_m, glass_m, sill_m, panes=(2, 2)):
    # axis 'y' = on back wall (faces -y); 'x' = on left wall (faces +x)
    cx, cy, cz = center
    t = 0.06
    def B(n, sx, sz, dx, dz, depth=t, m=frame_m, dn=0.0):
        if axis == "y":
            box(prefix + n, (sx, depth, sz), (cx + dx, cy - dn, cz + dz), m, bevel=0.008)
        else:
            box(prefix + n, (depth, sx, sz), (cx + dn, cy + dx, cz + dz), m, bevel=0.008)
    B("Glass", w, hgt, 0, 0, depth=0.02, m=glass_m, dn=0.0)
    B("FrameT", w + 0.1, 0.08, 0, hgt / 2 + 0.04)
    B("FrameB", w + 0.1, 0.08, 0, -hgt / 2 - 0.04)
    B("FrameL", 0.08, hgt, -w / 2 - 0.04, 0)
    B("FrameR", 0.08, hgt, w / 2 + 0.04, 0)
    for i in range(1, panes[0]):
        B("MullV%d" % i, 0.04, hgt, -w / 2 + w * i / panes[0], 0)
    for i in range(1, panes[1]):
        B("MullH%d" % i, w, 0.04, 0, -hgt / 2 + hgt * i / panes[1])
    B("Sill", w + 0.3, 0.05, 0, -hgt / 2 - 0.1, depth=0.22, m=sill_m, dn=0.1)

def plant(prefix, loc, pot_m, leaf_m, soil_m, scale=1.0, kind="round"):
    x, y, z = loc
    s = scale
    cyl(prefix + "Pot", 0.13 * s, 0.24 * s, (x, y, z + 0.12 * s), pot_m, r2=0.16 * s, bevel=0.01)
    cyl(prefix + "PotRim", 0.17 * s, 0.04 * s, (x, y, z + 0.24 * s), pot_m)
    cyl(prefix + "Soil", 0.145 * s, 0.02 * s, (x, y, z + 0.25 * s), soil_m)
    rnd = random.Random(hash(prefix) & 0xffff)
    if kind == "round":
        for i in range(5):
            a = i * 2 * math.pi / 5
            ball(prefix + "Leaf%d" % i, 0.11 * s,
                 (x + math.cos(a) * 0.07 * s, y + math.sin(a) * 0.07 * s, z + (0.38 + rnd.uniform(0, 0.12)) * s),
                 leaf_m, scale=(0.8, 0.8, 1.5))
        ball(prefix + "LeafTop", 0.12 * s, (x, y, z + 0.55 * s), leaf_m, scale=(0.9, 0.9, 1.4))
    else:  # tall leaves
        for i in range(7):
            a = i * 2 * math.pi / 7
            o = ball(prefix + "Leaf%d" % i, 0.08 * s,
                     (x + math.cos(a) * 0.1 * s, y + math.sin(a) * 0.1 * s, z + 0.5 * s),
                     leaf_m, scale=(0.5, 1.0, 3.0))
            o.rotation_euler = (math.cos(a + math.pi / 2) * 0.35, math.sin(a + math.pi / 2) * -0.35, a)
            o.rotation_euler = (-math.sin(a) * 0.4, math.cos(a) * 0.4, 0)

def books(prefix, x0, x1, y, z, depth, mats, rnd, tilt_last=True):
    x = x0
    i = 0
    while x < x1 - 0.03:
        w = rnd.uniform(0.025, 0.05)
        hgt = rnd.uniform(0.17, 0.26)
        box(prefix + "Book%d" % i, (w, depth, hgt), (x + w / 2, y, z + hgt / 2), rnd.choice(mats), bevel=0.004, segs=1)
        x += w + 0.003
        i += 1

def pet_spot(prefix, loc):
    e = empty(prefix + "PetSpot", loc)
    e.empty_display_type = "SINGLE_ARROW"
    return e

# ---------------------------------------------------------------- KITCHEN
def build_kitchen():
    sc = new_scene("Room_Kitchen")
    setup_render(sc)
    root = coll("Kitchen", scene=sc)
    use(root)
    random.seed(7)
    P = "K_"
    floor = checker_mat("K_FloorTiles", "#E9DCC6", "#C9B79A", scale=9.0)
    wall_b = M("K_WallSage", "#A9BFA0", 0.85)
    wall_l = M("K_WallCream", "#EFE3CC", 0.85)
    trim = M("K_TrimWhite", "#F4EFE6", 0.5)
    base = M("K_BaseWood", "#7A5236", 0.6)
    shell(P, floor, wall_b, wall_l, trim, base)

    cab = M("K_CabinetMint", "#7FB3A6", 0.45)
    top = M("K_Counter", "#D9CBB4", 0.35)
    steel = M("K_Steel", "#B8BCC2", 0.3, metal=0.8)
    knob = M("K_Brass", "#C9A04A", 0.3, metal=0.9)
    dark = M("K_Dark", "#2E2B2A", 0.5)
    wood = M("K_WoodLight", "#C08A5A", 0.55)
    wood_d = M("K_WoodDark", "#8A5A38", 0.55)
    red = M("K_Red", "#D0533F", 0.5)
    yellow = M("K_Yellow", "#E9B949", 0.5)
    blue = M("K_Blue", "#5B7FB8", 0.5)
    glass = M("K_Glass", "#BFE0F0", 0.05, emit=hexc("#DDF1FF"), emit_strength=0.6)
    fridge_m = M("K_FridgeCream", "#F1E8D6", 0.35)
    leaf = M("K_Leaf", "#5E9B55", 0.6)
    terracotta = M("K_Terracotta", "#C46F4A", 0.7)
    soil = M("K_Soil", "#4A3426", 0.9)

    # fridge in back-left corner
    box(P + "Fridge", (0.75, 0.7, 1.9), (-1.58, 1.6, 0.95), fridge_m, bevel=0.06)
    box(P + "FridgeGap", (0.76, 0.02, 0.02), (-1.58, 1.245, 1.25), dark, bevel=0)
    box(P + "FridgeHandle1", (0.04, 0.05, 0.35), (-1.3, 1.23, 1.5), steel, bevel=0.015)
    box(P + "FridgeHandle2", (0.04, 0.05, 0.25), (-1.3, 1.23, 1.05), steel, bevel=0.015)
    for i, (c, xx, zz) in enumerate([(red, -1.75, 1.6), (yellow, -1.62, 1.45), (blue, -1.82, 1.38)]):
        cyl(P + "Magnet%d" % i, 0.035, 0.02, (xx, 1.24, zz), c, rot=(90, 0, 0))

    # lower cabinets along back wall
    x0, x1 = -1.15, 1.0
    W = x1 - x0
    box(P + "CabLower", (W, 0.6, 0.82), ((x0 + x1) / 2, 1.68, 0.46), cab, bevel=0.02)
    box(P + "Toe", (W - 0.04, 0.55, 0.08), ((x0 + x1) / 2, 1.7, 0.04), dark, bevel=0)
    box(P + "Countertop", (W + 0.04, 0.66, 0.06), ((x0 + x1) / 2, 1.66, 0.9), top, bevel=0.015)
    n = 4
    for i in range(n):
        cx = x0 + W * (i + 0.5) / n
        box(P + "Door%d" % i, (W / n - 0.04, 0.03, 0.55), (cx, 1.37, 0.4), cab, bevel=0.012)
        box(P + "Drawer%d" % i, (W / n - 0.04, 0.03, 0.14), (cx, 1.37, 0.78), cab, bevel=0.012)
        ball(P + "Knob%d" % i, 0.018, (cx + (0.15 if i % 2 else -0.15), 1.345, 0.55), knob)
        box(P + "Pull%d" % i, (0.12, 0.02, 0.02), (cx, 1.345, 0.78), knob, bevel=0.006)
    # sink
    box(P + "Sink", (0.5, 0.4, 0.02), (0.35, 1.68, 0.932), steel, bevel=0.01)
    box(P + "SinkHole", (0.44, 0.34, 0.01), (0.35, 1.68, 0.944), dark, bevel=0.005)
    cyl(P + "FaucetBase", 0.03, 0.06, (0.35, 1.93, 0.96), steel)
    cyl(P + "FaucetPipe", 0.018, 0.3, (0.35, 1.93, 1.1), steel)
    cyl(P + "FaucetSpout", 0.018, 0.2, (0.35, 1.84, 1.25), steel, rot=(90, 0, 0))
    # stove top
    box(P + "Hob", (0.55, 0.45, 0.015), (-0.6, 1.68, 0.938), dark, bevel=0.01)
    for i, (dx, dy) in enumerate([(-0.13, -0.1), (0.13, -0.1), (-0.13, 0.1), (0.13, 0.1)]):
        torus(P + "Burner%d" % i, 0.065, 0.008, (-0.6 + dx, 1.68 + dy, 0.95), steel, seg=24, ring=8)
    # pot with lid on hob
    cyl(P + "Pot", 0.12, 0.16, (-0.73, 1.58, 1.03), red, bevel=0.01)
    cyl(P + "PotLid", 0.125, 0.02, (-0.73, 1.58, 1.12), red)
    ball(P + "PotKnob", 0.025, (-0.73, 1.58, 1.14), dark)
    # hood
    box(P + "Hood", (0.6, 0.45, 0.18), (-0.6, 1.76, 1.75), steel, bevel=0.02)
    box(P + "HoodChimney", (0.25, 0.25, 0.9), (-0.6, 1.85, 2.3), steel, bevel=0.02)
    # backsplash tiles
    box(P + "Backsplash", (W, 0.02, 0.6), ((x0 + x1) / 2, 1.99, 1.23), checker_mat("K_Splash", "#F7F2EA", "#DDE9E4", 14.0, 0.3), bevel=0)
    # open shelves with jars
    for k, z in enumerate([1.6, 2.05]):
        box(P + "Shelf%d" % k, (0.75, 0.25, 0.04), (0.4, 1.86, z), wood, bevel=0.01)
        box(P + "ShelfBr%dL" % k, (0.03, 0.18, 0.1), (0.1, 1.9, z - 0.07), wood_d, bevel=0.005)
        box(P + "ShelfBr%dR" % k, (0.03, 0.18, 0.1), (0.7, 1.9, z - 0.07), wood_d, bevel=0.005)
    jar_m = M("K_JarGlass", "#E6EEF0", 0.15)
    lid_cols = [red, yellow, blue, wood]
    for i in range(4):
        x = 0.13 + i * 0.18
        hh = 0.14 + 0.04 * (i % 2)
        cyl(P + "Jar%d" % i, 0.055, hh, (x, 1.86, 1.62 + hh / 2), jar_m, bevel=0.01)
        cyl(P + "JarLid%d" % i, 0.058, 0.03, (x, 1.86, 1.62 + hh + 0.015), lid_cols[i])
    # plates on upper shelf
    for i in range(3):
        cyl(P + "Plate%d" % i, 0.09, 0.015, (0.2 + i * 0.03, 1.9, 2.16), M("K_Plate", "#FAFAF5", 0.3), rot=(80, 0, 0))
    cyl(P + "Teapot", 0.08, 0.13, (0.55, 1.86, 2.14), blue, bevel=0.02)
    ball(P + "TeapotLid", 0.05, (0.55, 1.86, 2.2), blue, scale=(1, 1, 0.5))
    cyl(P + "TeapotSpout", 0.015, 0.1, (0.64, 1.86, 2.15), blue, rot=(0, 55, 0))
    # utensil crock + cutting board
    cyl(P + "Crock", 0.06, 0.15, (-0.95, 1.8, 1.0), terracotta, bevel=0.01)
    for i in range(3):
        cyl(P + "Spoon%d" % i, 0.008, 0.26, (-0.95 + (i - 1) * 0.02, 1.8, 1.15), wood, rot=(0, (i - 1) * 10, 0))
    box(P + "Board", (0.3, 0.02, 0.4), (-0.1, 1.95, 1.13), wood, rot=(-8, 0, 0), bevel=0.01)
    # clock on back wall
    cyl(P + "Clock", 0.17, 0.04, (1.45, 1.98, 2.1), trim, rot=(90, 0, 0), bevel=0.01)
    torus(P + "ClockRim", 0.17, 0.02, (1.45, 1.96, 2.1), red, rot=(90, 0, 0))
    box(P + "ClockH", (0.015, 0.01, 0.09), (1.45, 1.955, 2.13), dark, bevel=0)
    box(P + "ClockM", (0.012, 0.01, 0.13), (1.49, 1.955, 2.1), dark, rot=(0, 70, 0), bevel=0)

    # window on left wall
    window(P + "Win", (-1.99, -0.2, 1.55), "x", 1.1, 0.95, trim, glass, trim, panes=(2, 2))
    # curtains
    curtain = M("K_Curtain", "#F2C6B4", 0.8)
    for side, dy in (("L", -0.82), ("R", 0.42)):
        for j in range(4):
            ball(P + "Curtain%s%d" % (side, j), 0.06, (-1.9, -0.2 + dy + j * 0.07, 1.55), curtain, scale=(0.6, 1, 8.5))
    cyl(P + "CurtainRod", 0.015, 1.7, (-1.9, -0.2, 2.15), knob, rot=(90, 0, 0))
    plant(P + "SillPlant", (-1.85, -0.45, 1.0), terracotta, leaf, soil, scale=0.6)
    plant(P + "SillPlant2", (-1.85, 0.1, 1.0), M("K_PotBlue", "#6C8FC7", 0.5), M("K_Leaf2", "#7DB06A", 0.6), soil, scale=0.5, kind="tall")

    # round table + 2 chairs
    tx, ty = 1.15, 0.2
    cyl(P + "TableTop", 0.48, 0.05, (tx, ty, 0.74), wood, bevel=0.015, verts=48)
    cyl(P + "TableStem", 0.05, 0.66, (tx, ty, 0.39), wood_d)
    cyl(P + "TableFoot", 0.24, 0.05, (tx, ty, 0.03), wood_d, bevel=0.01)
    cloth = checker_mat("K_ClothCheck", "#D85B4A", "#F6EDE2", 18.0, 0.8)
    cyl(P + "TableCloth", 0.3, 0.008, (tx, ty, 0.77), cloth, rot=(0, 0, 45), verts=4)
    for i, (dx, dy, rz) in enumerate([(0.0, 0.72, 180), (-0.7, -0.15, 285)]):
        g = empty(P + "Chair%d" % i, (tx + dx, ty + dy, 0))
        g.rotation_euler = (0, 0, math.radians(rz))
        box(P + "ChairSeat%d" % i, (0.42, 0.42, 0.05), (0, 0, 0.46), yellow, bevel=0.02, parent=g)
        for j, (lx, ly) in enumerate([(-0.17, -0.17), (0.17, -0.17), (-0.17, 0.17), (0.17, 0.17)]):
            cyl(P + "ChairLeg%d_%d" % (i, j), 0.02, 0.44, (lx, ly, 0.22), wood_d, parent=g)
        box(P + "ChairBack%d" % i, (0.42, 0.04, 0.42), (0, 0.19, 0.72), yellow, bevel=0.02, parent=g)
        for j in range(3):
            box(P + "ChairSlot%d_%d" % (i, j), (0.06, 0.05, 0.25), (-0.12 + j * 0.12, 0.19, 0.7), wood_d, bevel=0.005, parent=g)
    # fruit bowl + mug
    cyl(P + "FruitBowl", 0.15, 0.08, (tx - 0.05, ty + 0.05, 0.81), M("K_BowlWhite", "#FAF6EE", 0.3), r2=0.1, bevel=0.01)
    for i, (c, dx, dy) in enumerate([(red, -0.05, 0.0), (yellow, 0.04, 0.03), (M("K_Green", "#8CBF4E", 0.5), 0.0, -0.05), (red, 0.05, -0.03)]):
        ball(P + "Fruit%d" % i, 0.045, (tx - 0.05 + dx, ty + 0.05 + dy, 0.88), c)
    cyl(P + "Mug", 0.04, 0.09, (tx + 0.22, ty - 0.18, 0.82), blue)
    torus(P + "MugHandle", 0.03, 0.008, (tx + 0.27, ty - 0.18, 0.82), blue, rot=(90, 0, 0))

    # pendant lamp
    cyl(P + "LampCord", 0.006, 0.9, (tx, ty, 2.35), dark)
    cone(P + "LampShade", 0.24, 0.22, (tx, ty, 1.85), M("K_LampShade", "#E9B949", 0.5), rot=(0, 0, 0))
    ball(P + "LampBulb", 0.05, (tx, ty, 1.76), M("K_Bulb", "#FFF3D0", 0.2, emit=hexc("#FFE7B0"), emit_strength=8))
    light(P + "LampLight", "POINT", (tx, ty, 1.7), 60, color=(1, 0.85, 0.6), size=0.1)

    # pet area: basket + bowls + rug
    rug = M("K_Rug", "#E7A86B", 0.95)
    cyl(P + "Rug", 0.75, 0.015, (-0.3, -0.35, 0.008), rug, verts=64, smooth=True).scale = (1.25, 0.9, 1)
    torus(P + "RugEdge", 0.75, 0.025, (-0.3, -0.35, 0.012), red, scale=(1.25, 0.9, 0.3))
    basket = M("K_Wicker", "#C99858", 0.85)
    cyl(P + "BasketBase", 0.5, 0.08, (-0.3, -0.35, 0.06), basket, verts=48)
    torus(P + "BasketRim", 0.48, 0.09, (-0.3, -0.35, 0.16), basket)
    cyl(P + "BasketCushion", 0.43, 0.08, (-0.3, -0.35, 0.12), M("K_Cushion", "#9DC3D9", 0.85), bevel=0.03, verts=48)
    cyl(P + "BowlFood", 0.11, 0.06, (0.65, -0.7, 0.04), red, r2=0.08, bevel=0.01)
    ball(P + "Kibble", 0.08, (0.65, -0.7, 0.07), wood_d, scale=(1, 1, 0.3))
    cyl(P + "BowlWater", 0.11, 0.06, (0.9, -0.55, 0.04), blue, r2=0.08, bevel=0.01)
    cyl(P + "Water", 0.085, 0.01, (0.9, -0.55, 0.065), glass)
    pet_spot(P, (-0.3, -0.35, 0.2))

    # lights + camera
    light(P + "Sun", "SUN", (0, 0, 5), 3.0, rot=(50, -10, -40))
    light(P + "Fill", "AREA", (2.5, -3.5, 3.0), 400, size=4, rot=(60, 0, 35))
    light(P + "WindowGlow", "AREA", (-1.7, -0.2, 1.55), 120, color=(0.85, 0.93, 1), size=1.0, rot=(0, -90, 0))
    camera(P + "Cam", (5.2, -6.0, 4.3), (0.0, 0.2, 0.9), lens=40, scene=sc)
    return sc

# ---------------------------------------------------------------- BEDROOM
def build_bedroom():
    sc = new_scene("Room_Bedroom")
    setup_render(sc)
    root = coll("Bedroom", scene=sc)
    use(root)
    rnd = random.Random(11)
    P = "B_"
    floor = plank_mat("B_FloorPlanks", "#B98C63", "#A57A55")
    wall_b = M("B_WallLilac", "#B7A6CC", 0.85)
    wall_l = M("B_WallDusk", "#6E6390", 0.85)
    trim = M("B_Trim", "#F2ECF5", 0.5)
    base = M("B_Base", "#5C4232", 0.6)
    shell(P, floor, wall_b, wall_l, trim, base)

    wood = M("B_Wood", "#D7B48A", 0.55)
    wood_d = M("B_WoodDark", "#7D5639", 0.55)
    sheet = M("B_Sheet", "#F4F0E8", 0.8)
    blanket = M("B_Blanket", "#E58C8A", 0.85)
    pillow = M("B_Pillow", "#FFF7EC", 0.85)
    pillow2 = M("B_Pillow2", "#8FB9D9", 0.85)
    gold = M("B_Gold", "#D2AE5A", 0.3, metal=0.9)
    glass = M("B_Glass", "#1E2A55", 0.05, emit=hexc("#2B3A78"), emit_strength=0.8)
    star = M("B_Star", "#FFE89A", 0.3, emit=hexc("#FFE08A"), emit_strength=6)
    navy = M("B_Navy", "#2F3A66", 0.6)
    mint = M("B_Mint", "#8ED1B8", 0.6)
    pink = M("B_Pink", "#F2A6B8", 0.6)
    yellow = M("B_Yellow", "#F2C14E", 0.5)
    leaf = M("B_Leaf", "#4F8F5B", 0.6)
    pot = M("B_PotWhite", "#EDE6DA", 0.5)
    soil = M("B_Soil", "#3E2C22", 0.9)

    # bed against left wall
    bx, by = -1.0, 0.75
    box(P + "BedFrame", (1.9, 1.3, 0.3), (bx, by, 0.22), wood, bevel=0.03)
    for j, (lx, ly) in enumerate([(-0.88, -0.58), (0.88, -0.58), (-0.88, 0.58), (0.88, 0.58)]):
        cyl(P + "BedLeg%d" % j, 0.04, 0.08, (bx + lx, by + ly, 0.04), wood_d)
    box(P + "Headboard", (0.1, 1.4, 0.9), (-1.92, by, 0.6), wood_d, bevel=0.04)
    box(P + "Footboard", (0.08, 1.35, 0.5), (bx + 0.95, by, 0.4), wood_d, bevel=0.03)
    box(P + "Mattress", (1.82, 1.22, 0.22), (bx, by, 0.48), sheet, bevel=0.06)
    box(P + "Blanket", (1.25, 1.3, 0.08), (bx + 0.3, by, 0.6), blanket, bevel=0.035)
    box(P + "BlanketFold", (0.22, 1.3, 0.1), (bx - 0.27, by, 0.63), M("B_BlanketFold", "#F4C4B8", 0.85), bevel=0.04)
    ball(P + "Pillow1", 0.22, (-1.65, by - 0.3, 0.68), pillow, scale=(0.55, 1.15, 0.45))
    ball(P + "Pillow2", 0.22, (-1.65, by + 0.3, 0.68), pillow2, scale=(0.55, 1.15, 0.45))
    ball(P + "PlushBear", 0.08, (-1.5, by, 0.72), M("B_Plush", "#C79B6D", 0.9))
    ball(P + "PlushBearHead", 0.06, (-1.5, by, 0.82), M("B_Plush", "#C79B6D", 0.9))

    # nightstand + lamp
    nx, ny = -1.72, -0.15
    box(P + "Nightstand", (0.45, 0.45, 0.5), (nx, ny, 0.27), wood, bevel=0.02)
    box(P + "NightDrawer", (0.03, 0.38, 0.18), (nx + 0.235, ny, 0.37), wood_d, bevel=0.01)
    ball(P + "NightKnob", 0.02, (nx + 0.26, ny, 0.37), gold)
    cyl(P + "LampBase", 0.07, 0.04, (nx, ny + 0.05, 0.54), gold)
    cyl(P + "LampStem", 0.012, 0.25, (nx, ny + 0.05, 0.68), gold)
    cyl(P + "LampShade", 0.13, 0.15, (nx, ny + 0.05, 0.84), M("B_Shade", "#FBE3C4", 0.7, emit=hexc("#FFD9A0"), emit_strength=1.5), r2=0.08)
    light(P + "LampLight", "POINT", (nx, ny + 0.05, 0.82), 25, color=(1, 0.8, 0.55), size=0.08)
    box(P + "NightBook", (0.16, 0.12, 0.03), (nx - 0.05, ny - 0.12, 0.535), navy, bevel=0.005, rot=(0, 0, 15))
    cyl(P + "AlarmClock", 0.05, 0.04, (nx + 0.1, ny - 0.1, 0.57), pink, rot=(90, 0, 60))

    # wardrobe on back wall right
    wx = 1.35
    box(P + "Wardrobe", (1.0, 0.55, 2.0), (wx, 1.68, 1.0), M("B_WardrobeMint", "#A6D3C4", 0.5), bevel=0.03)
    box(P + "WardDoorL", (0.47, 0.03, 1.75), (wx - 0.245, 1.4, 1.05), M("B_WardrobeMint", "#A6D3C4", 0.5), bevel=0.015)
    box(P + "WardDoorR", (0.47, 0.03, 1.75), (wx + 0.245, 1.4, 1.05), M("B_WardrobeMint", "#A6D3C4", 0.5), bevel=0.015)
    for s in (-1, 1):
        cyl(P + "WardHandle%d" % s, 0.012, 0.25, (wx + s * 0.05, 1.37, 1.05), gold)
    box(P + "WardPlinth", (0.95, 0.5, 0.08), (wx, 1.7, 0.04), wood_d, bevel=0)
    # boxes on top of wardrobe
    box(P + "TopBox1", (0.4, 0.4, 0.25), (wx - 0.2, 1.7, 2.13), M("B_BoxKraft", "#C9A27A", 0.8), bevel=0.01)
    box(P + "TopBox2", (0.3, 0.3, 0.18), (wx + 0.25, 1.7, 2.09), pink, bevel=0.01)

    # window on back wall with night sky + curtains
    wcx = -0.15
    window(P + "Win", (wcx, 1.99, 1.6), "y", 1.0, 1.0, trim, glass, trim, panes=(2, 2))
    for i, (sx, sz) in enumerate([(-0.3, 1.85), (0.2, 1.95), (0.3, 1.4), (-0.15, 1.3), (0.05, 1.75)]):
        ball(P + "StarDot%d" % i, 0.015, (wcx + sx, 1.975, sz), star)
    ball(P + "Moon", 0.07, (wcx + 0.28, 1.975, 1.85), star, scale=(1, 0.2, 1))
    cyl(P + "CurtainRod", 0.015, 1.6, (wcx, 1.9, 2.2), gold, rot=(0, 90, 0))
    curtain = M("B_Curtain", "#5A4E86", 0.85)
    for side, dx in (("L", -0.75), ("R", 0.55)):
        for j in range(4):
            ball(P + "Curtain%s%d" % (side, j), 0.06, (wcx + dx + j * 0.065, 1.9, 1.5), curtain, scale=(1, 0.6, 11))
    # string lights over window
    bulb_cols = [yellow, pink, mint, M("B_Bulb", "#FFF3C8", 0.3, emit=hexc("#FFE6A0"), emit_strength=4)]
    for i in range(11):
        t = i / 10
        x = wcx - 0.8 + 1.6 * t
        z = 2.3 - 0.12 * math.sin(math.pi * t)
        ball(P + "Fairy%d" % i, 0.025, (x, 1.88, z), M("B_Fairy%d" % (i % 3), ["#FFD56B", "#FF9FB2", "#9BE3C9"][i % 3], 0.3, emit=hexc(["#FFD56B", "#FF9FB2", "#9BE3C9"][i % 3]), emit_strength=5))

    # wall shelf with books on left wall, above bed
    box(P + "WallShelf", (0.25, 1.0, 0.04), (-1.86, 0.75, 1.6), wood, bevel=0.01)
    books(P + "S", 0.3, 0.9, -1.86, 1.62, 0.18, [navy, mint, pink, yellow, M("B_BookRed", "#C8564B", 0.6)], rnd)
    # rotate the books: they were laid along x; move them to the shelf (along y)
    for o in list(bpy.data.collections["Bedroom"].objects):
        if o.name.startswith(P + "SBook"):
            x = o.location.x
            o.location = (-1.86, x, o.location.z)
            o.rotation_euler = (0, 0, math.radians(90))
    # posters on left wall
    for i, (py, pz, c, w, h) in enumerate([(-0.55, 1.65, M("B_PosterA", "#F2B880", 0.7), 0.45, 0.6), (-1.15, 1.45, M("B_PosterB", "#8FCFD1", 0.7), 0.4, 0.4)]):
        box(P + "PosterFrame%d" % i, (0.03, w + 0.05, h + 0.05), (-1.985, py, pz), wood_d, bevel=0.005)
        box(P + "Poster%d" % i, (0.02, w, h), (-1.97, py, pz), c, bevel=0)
    ball(P + "PosterSun", 0.08, (-1.955, -0.55, 1.75), yellow, scale=(0.2, 1, 1))
    cone(P + "PosterMountain", 0.17, 0.25, (-1.955, -0.55, 1.5), navy, scale=(0.15, 1, 1), verts=3)

    # round rug, toy box, toys, plant
    rug = M("B_Rug", "#E9D8F0", 0.95)
    cyl(P + "Rug", 0.9, 0.015, (0.35, -0.35, 0.008), rug, verts=64)
    torus(P + "RugRing1", 0.85, 0.02, (0.35, -0.35, 0.014), M("B_RugRing", "#C59AD8", 0.95), scale=(1, 1, 0.3))
    torus(P + "RugRing2", 0.55, 0.02, (0.35, -0.35, 0.014), M("B_RugRing", "#C59AD8", 0.95), scale=(1, 1, 0.3))
    # pet cushion (pouf)
    cyl(P + "PetPouf", 0.42, 0.14, (0.35, -0.35, 0.09), M("B_PetPouf", "#F29E8E", 0.9), bevel=0.06, verts=48)
    torus(P + "PetPoufRim", 0.4, 0.08, (0.35, -0.35, 0.17), M("B_PetPoufRim", "#F7C2B5", 0.9))
    pet_spot(P, (0.35, -0.35, 0.2))
    # toy chest
    tb = (1.55, 0.6)
    box(P + "ToyChest", (0.7, 0.45, 0.4), (tb[0], tb[1], 0.2), M("B_ToyChest", "#F2C14E", 0.5), bevel=0.03)
    box(P + "ToyChestLid", (0.74, 0.48, 0.07), (tb[0], tb[1], 0.43), M("B_ToyChestLid", "#E39B3A", 0.5), bevel=0.02)
    for i, (dx, c) in enumerate([(-0.2, pink), (0.0, mint), (0.2, navy)]):
        box(P + "ToyBlock%d" % i, (0.1, 0.1, 0.1), (tb[0] + dx, tb[1] - 0.05, 0.52), c, bevel=0.01, rot=(0, 0, i * 20))
    ball(P + "ToyBall", 0.09, (1.1, -0.9, 0.09), pink)
    torus(P + "ToyBallStripe", 0.09, 0.012, (1.1, -0.9, 0.09), yellow, rot=(60, 0, 20))
    ball(P + "Yarn", 0.07, (0.95, -1.25, 0.07), mint)
    torus(P + "YarnWrap", 0.065, 0.01, (0.95, -1.25, 0.07), M("B_YarnWrap", "#6FB89E", 0.8), rot=(30, 40, 0))
    plant(P + "Plant", (1.75, -0.3, 0.0), pot, leaf, soil, scale=1.4, kind="tall")
    # slippers
    for i, dx in enumerate((0.0, 0.14)):
        ball(P + "Slipper%d" % i, 0.07, (-0.0 + dx, 0.0, 0.03), pink, scale=(0.8, 1.7, 0.45))

    # lights + camera (evening mood)
    light(P + "Moonlight", "SUN", (0, 0, 5), 1.2, color=(0.7, 0.75, 1.0), rot=(55, 0, -35))
    light(P + "Fill", "AREA", (2.5, -3.5, 3.0), 300, color=(1, 0.88, 0.8), size=4, rot=(60, 0, 35))
    light(P + "Ceiling", "AREA", (0, 0, 2.7), 150, color=(1, 0.85, 0.7), size=2)
    camera(P + "Cam", (5.2, -6.0, 4.3), (0.0, 0.2, 0.9), lens=40, scene=sc)
    return sc
