# Ten chibi pets built from primitives. Exec after lib.py.
# Every pet lives in its own collection "Pet_<Name>" with a root empty "<Name>_Root";
# parts are parented to the root, pet faces -Y, feet on z=0, height ~0.55-0.7 m.
import bpy, math
from mathutils import Vector

def chain(prefix, pts, radii, m, scale_xy=1.0):
    out = []
    for i, (p, r) in enumerate(zip(pts, radii)):
        out.append(ball(prefix + "%d" % i, r, p, m, scale=(scale_xy, scale_xy, 1), segs=20, rings=10))
    return out

def eyes(N, z, x, y, m_eye, m_white, r=0.036, sy=0.55):
    for s in (-1, 1):
        ball(N + "Eye" + ("L" if s < 0 else "R"), r, (s * x, y, z), m_eye, scale=(0.9, sy, 1.2), segs=20, rings=10)
        ball(N + "EyeHi" + ("L" if s < 0 else "R"), r * 0.33, (s * x - 0.012, y - r * sy * 0.8, z + r * 0.45), m_white, segs=12, rings=6)

def cheeks(N, z, x, y, m):
    for s in (-1, 1):
        ball(N + "Cheek" + ("L" if s < 0 else "R"), 0.03, (s * x, y, z), m, scale=(1.1, 0.35, 0.7), segs=16, rings=8)

def feet(N, m, front_y=-0.1, back_y=0.08, fx=0.09, bx=0.12, r=0.06):
    for s in (-1, 1):
        ball(N + "FootF" + ("L" if s < 0 else "R"), r, (s * fx, front_y, r * 0.7), m, scale=(1, 1.3, 0.7), segs=20, rings=10)
        ball(N + "FootB" + ("L" if s < 0 else "R"), r * 1.1, (s * bx, back_y, r * 0.75), m, scale=(1, 1.4, 0.7), segs=20, rings=10)

class Pal:
    def __init__(self, key, **cols):
        self.m = {k: M("Pet%s_%s" % (key, k), v[0] if isinstance(v, tuple) else v,
                       v[1] if isinstance(v, tuple) else 0.75) for k, v in cols.items()}
    def __getitem__(self, k):
        return self.m[k]

COMMON = {}
def common():
    if not COMMON:
        COMMON["eye"] = M("Pet_Eye", "#1E1A1C", 0.15)
        COMMON["white"] = M("Pet_EyeHi", "#FFFFFF", 0.2, emit=(1, 1, 1), emit_strength=0.5)
        COMMON["blush"] = M("Pet_Blush", "#F59A9A", 0.8)
        COMMON["nose"] = M("Pet_Nose", "#3A2A2A", 0.3)
    return COMMON

def start(name, pets_coll, loc):
    c = coll("Pet_" + name, parent=pets_coll)
    use(c)
    root = empty(name + "_Root", loc)
    root.empty_display_type = "PLAIN_AXES"
    use(c, root)
    c.instance_offset = loc
    return name + "_", c

def mammal(N, p, C, head_z=0.47, body_sc=(1, 0.9, 1.05), head_sc=(1.12, 0.95, 0.95), muzzle=True, belly=True):
    ball(N + "Body", 0.18, (0, 0.02, 0.2), p["body"], scale=body_sc)
    if belly:
        ball(N + "Belly", 0.13, (0, -0.07, 0.19), p["light"], scale=(1, 0.65, 1.1))
    ball(N + "Head", 0.2, (0, 0, head_z), p["body"], scale=head_sc)
    if muzzle:
        ball(N + "Muzzle", 0.075, (0, -0.15, head_z - 0.06), p["light"], scale=(1.3, 0.75, 0.8))
        ball(N + "Nose", 0.022, (0, -0.205, head_z - 0.035), C["nose"], scale=(1.3, 0.8, 0.9), segs=16, rings=8)
    eyes(N, head_z + 0.02, 0.085, -0.165, C["eye"], C["white"])
    cheeks(N, head_z - 0.04, 0.145, -0.135, C["blush"])
    feet(N, p["light"] if "paw" not in p.m else p["paw"])

# ------------------------------------------------------------------ pets
def cat(pc, loc):
    N, c = start("Cat", pc, loc); C = common()
    p = Pal("Cat", body=("#9AA3B0", 0.8), light=("#EEF0F2", 0.8), dark=("#5F6775", 0.8), inner=("#F3B3B8", 0.8))
    mammal(N, p, C)
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        e = cone(N + "Ear" + sd, 0.075, 0.15, (s * 0.12, 0.0, 0.66), p["body"], rot=(0, s * -18, 0), scale=(1, 0.6, 1))
        cone(N + "EarIn" + sd, 0.045, 0.1, (s * 0.118, -0.02, 0.65), p["inner"], rot=(0, s * -18, 0), scale=(1, 0.4, 1))
    for i, dx in enumerate((-0.05, 0.0, 0.05)):
        ball(N + "Stripe%d" % i, 0.025, (dx, -0.04, 0.655), p["dark"], scale=(0.6, 1.6, 0.4))
    chain(N + "Tail", [(0.0, 0.2, 0.12), (0.06, 0.27, 0.2), (0.1, 0.3, 0.32), (0.1, 0.28, 0.43), (0.07, 0.24, 0.5)],
          [0.05, 0.048, 0.045, 0.043, 0.045], p["body"])
    ball(N + "TailTip", 0.046, (0.07, 0.24, 0.5), p["dark"])
    for s in (-1, 1):
        for k in range(2):
            cyl(N + "Whisker%d%d" % (s + 1, k), 0.003, 0.12, (s * 0.12, -0.18, 0.42 + k * 0.02), C["nose"], rot=(0, 90 + s * k * 10, s * 15), verts=6)

def puppy(pc, loc):
    N, c = start("Puppy", pc, loc); C = common()
    p = Pal("Puppy", body=("#F4EBDD", 0.8), light=("#FFFFFF", 0.8), ear=("#9B6A43", 0.8), spot=("#C48A55", 0.8), collar=("#D84B4B", 0.5), tag=("#E7C04F", 0.3))
    mammal(N, p, C)
    ball(N + "EyePatch", 0.075, (0.08, -0.12, 0.53), p["spot"], scale=(1, 0.6, 0.9))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "Ear" + sd, 0.08, (s * 0.21, 0.0, 0.45), p["ear"], scale=(0.45, 0.8, 1.5), rot=(0, s * 15, 0))
    ball(N + "BackSpot", 0.1, (0.05, 0.1, 0.27), p["spot"], scale=(1, 0.8, 0.6))
    torus(N + "Collar", 0.13, 0.02, (0, 0, 0.32), p["collar"], scale=(1, 0.95, 1))
    cyl(N + "Tag", 0.025, 0.01, (0, -0.15, 0.28), p["tag"], rot=(90, 0, 0))
    chain(N + "Tail", [(0, 0.2, 0.2), (0, 0.25, 0.27), (0, 0.27, 0.35)], [0.04, 0.035, 0.03], p["body"])

def fox(pc, loc):
    N, c = start("Fox", pc, loc); C = common()
    p = Pal("Fox", body=("#E8803A", 0.8), light=("#FFF4E6", 0.8), dark=("#3B2A22", 0.8), inner=("#FFE2C8", 0.8))
    mammal(N, p, C, head_sc=(1.2, 0.95, 0.92))
    ball(N + "MuzzleTip", 0.05, (0, -0.2, 0.42), p["light"], scale=(1, 1.2, 0.7))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        cone(N + "Ear" + sd, 0.085, 0.22, (s * 0.12, 0.0, 0.69), p["body"], rot=(0, s * -15, 0), scale=(1, 0.55, 1))
        cone(N + "EarTip" + sd, 0.04, 0.07, (s * 0.12 + 0.075 * math.sin(math.radians(s * -15)), 0.0, 0.69 + 0.075 * math.cos(math.radians(15))), p["dark"], rot=(0, s * -15, 0), scale=(1, 0.58, 1))
        cone(N + "EarIn" + sd, 0.05, 0.13, (s * 0.115, -0.02, 0.67), p["inner"], rot=(0, s * -15, 0), scale=(1, 0.4, 1))
    for s in (-1, 1):
        ball(N + "PawDark" + ("L" if s < 0 else "R"), 0.061, (s * 0.09, -0.1, 0.045), p["dark"], scale=(1, 1.3, 0.6))
    chain(N + "Tail", [(0.05, 0.22, 0.14), (0.14, 0.32, 0.22), (0.2, 0.36, 0.34), (0.2, 0.34, 0.46)],
          [0.08, 0.1, 0.1, 0.08], p["body"])
    ball(N + "TailTip", 0.07, (0.19, 0.32, 0.54), p["light"], scale=(1, 1, 1.2))

def bunny(pc, loc):
    N, c = start("Bunny", pc, loc); C = common()
    p = Pal("Bunny", body=("#F7F1EA", 0.85), light=("#FFFFFF", 0.85), inner=("#F6B6C4", 0.8), carrot=("#F08A2C", 0.6), leaf=("#6FB35A", 0.6))
    mammal(N, p, C, muzzle=False)
    ball(N + "Muzzle", 0.06, (0, -0.16, 0.42), p["light"], scale=(1.3, 0.75, 0.8))
    ball(N + "Nose", 0.018, (0, -0.205, 0.44), p["inner"], scale=(1.3, 0.8, 0.9))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "Ear" + sd, 0.06, (s * 0.08, 0.02, 0.78), p["body"], scale=(0.75, 0.45, 2.6), rot=(0, s * -12, 0))
        ball(N + "EarIn" + sd, 0.04, (s * 0.079, -0.006, 0.78), p["inner"], scale=(0.7, 0.3, 2.5), rot=(0, s * -12, 0))
    ball(N + "Tail", 0.07, (0, 0.2, 0.16), p["light"])
    # carrot held between front feet
    cone(N + "Carrot", 0.035, 0.17, (0.0, -0.2, 0.12), p["carrot"], rot=(180 - 30, 0, 0))
    for k in range(3):
        cone(N + "CarrotLeaf%d" % k, 0.012, 0.07, (-0.012 + k * 0.012, -0.15, 0.2), p["leaf"], rot=(-30, (k - 1) * 20, 0))

def bear(pc, loc):
    N, c = start("Bear", pc, loc); C = common()
    p = Pal("Bear", body=("#9A6A45", 0.85), light=("#E2C29C", 0.85), inner=("#E2C29C", 0.85), scarf=("#3F8F7F", 0.8))
    mammal(N, p, C, body_sc=(1.12, 1.0, 1.08), head_sc=(1.15, 1.0, 0.95))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "Ear" + sd, 0.06, (s * 0.16, 0.01, 0.63), p["body"], scale=(1, 0.6, 1))
        ball(N + "EarIn" + sd, 0.035, (s * 0.16, -0.02, 0.63), p["inner"], scale=(1, 0.4, 1))
    torus(N + "Scarf", 0.15, 0.035, (0, 0, 0.32), p["scarf"], scale=(1, 0.95, 0.9))
    ball(N + "ScarfEnd", 0.05, (0.08, -0.15, 0.24), p["scarf"], scale=(0.7, 0.4, 1.4), rot=(0, -15, 0))
    ball(N + "Tail", 0.045, (0, 0.2, 0.14), p["body"])

def frog(pc, loc):
    N, c = start("Frog", pc, loc); C = common()
    p = Pal("Frog", body=("#7CC46A", 0.6), light=("#E6F2B6", 0.7), dark=("#4E9446", 0.6), mouth=("#C2455A", 0.6), crown=("#F2C14E", 0.3))
    ball(N + "Body", 0.2, (0, 0.02, 0.17), p["body"], scale=(1.15, 1.0, 0.9))
    ball(N + "Belly", 0.14, (0, -0.08, 0.16), p["light"], scale=(1.1, 0.6, 0.9))
    ball(N + "Head", 0.21, (0, -0.01, 0.38), p["body"], scale=(1.25, 0.95, 0.75))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "EyeBump" + sd, 0.075, (s * 0.12, -0.03, 0.5), p["body"])
        ball(N + "EyeWhite" + sd, 0.06, (s * 0.12, -0.065, 0.51), C["white"], scale=(1, 0.6, 1))
        ball(N + "Eye" + sd, 0.035, (s * 0.12, -0.1, 0.51), C["eye"], scale=(1, 0.5, 1.15))
        ball(N + "EyeHi" + sd, 0.011, (s * 0.12 - 0.01, -0.12, 0.525), C["white"])
        ball(N + "Spot" + sd, 0.04, (s * 0.15, 0.1, 0.27), p["dark"], scale=(1, 1, 0.5))
    torus(N + "Smile", 0.11, 0.008, (0, -0.07, 0.36), p["mouth"], rot=(-10, 0, 0), scale=(1.15, 1.0, 0.25))
    cheeks(N, 0.37, 0.18, -0.12, C["blush"])
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "FootF" + sd, 0.06, (s * 0.12, -0.15, 0.03), p["dark"], scale=(1.2, 1.4, 0.5))
        ball(N + "FootB" + sd, 0.09, (s * 0.2, 0.02, 0.06), p["body"], scale=(0.8, 1.4, 0.7))
    # tiny crown
    cyl(N + "Crown", 0.06, 0.04, (0.04, 0.0, 0.53), p["crown"], verts=10, r2=0.07)
    for k in range(5):
        a = k * 2 * math.pi / 5
        cone(N + "CrownTip%d" % k, 0.015, 0.035, (0.04 + math.cos(a) * 0.06, math.sin(a) * 0.06, 0.565), p["crown"], verts=8)

def owl(pc, loc):
    N, c = start("Owl", pc, loc); C = common()
    p = Pal("Owl", body=("#8C6BB0", 0.8), light=("#E9DDF5", 0.8), disc=("#FFF6E8", 0.8), beak=("#F2A93B", 0.5), feet=("#F2A93B", 0.5), wing=("#6E4F94", 0.8))
    ball(N + "Body", 0.25, (0, 0, 0.3), p["body"], scale=(1, 0.9, 1.15))
    ball(N + "Belly", 0.17, (0, -0.1, 0.24), p["light"], scale=(1, 0.6, 1.0))
    for k in range(3):
        for j in range(2 + (k % 2)):
            x = (j - (1 + (k % 2)) / 2) * 0.07
            cone(N + "Feather%d%d" % (k, j), 0.02, 0.03, (x, -0.2, 0.3 - k * 0.07), p["wing"], rot=(-90 + 180, 0, 0), scale=(1, 0.4, 1))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "Disc" + sd, 0.09, (s * 0.085, -0.17, 0.44), p["disc"], scale=(1, 0.35, 1))
        ball(N + "Eye" + sd, 0.05, (s * 0.085, -0.2, 0.44), C["eye"], scale=(1, 0.5, 1.05))
        ball(N + "EyeHi" + sd, 0.016, (s * 0.085 - 0.015, -0.22, 0.46), C["white"])
        cone(N + "Tuft" + sd, 0.06, 0.13, (s * 0.15, 0.0, 0.62), p["body"], rot=(0, s * -30, 0), scale=(1, 0.5, 1))
        ball(N + "Wing" + sd, 0.13, (s * 0.24, 0.02, 0.28), p["wing"], scale=(0.35, 0.9, 1.3), rot=(0, s * 15, 0))
        for k in range(3):
            ball(N + "Toe%s%d" % (sd, k), 0.025, (s * 0.09 + (k - 1) * 0.03, -0.15, 0.02), p["feet"], scale=(1, 1.5, 0.7))
    cone(N + "Beak", 0.035, 0.08, (0, -0.22, 0.38), p["beak"], rot=(180 + 25, 0, 0), scale=(1, 0.6, 1))
    cheeks(N, 0.38, 0.17, -0.17, C["blush"])
    # little graduation cap -> bookish owl
    box(N + "CapBoard", (0.22, 0.22, 0.02), (0, 0.0, 0.66), M("PetOwl_cap", "#2E2B3A", 0.5), rot=(0, 0, 45), bevel=0.004)
    cyl(N + "CapBase", 0.08, 0.06, (0, 0.0, 0.63), M("PetOwl_cap", "#2E2B3A", 0.5))
    ball(N + "CapTassel", 0.018, (0.1, -0.05, 0.6), p["beak"])

def penguin(pc, loc):
    N, c = start("Penguin", pc, loc); C = common()
    p = Pal("Penguin", body=("#2D3542", 0.6), light=("#FAFAF7", 0.7), beak=("#F4A23B", 0.5), hat=("#5BA7D9", 0.85), pom=("#FFFFFF", 0.9))
    ball(N + "Body", 0.24, (0, 0, 0.3), p["body"], scale=(1, 0.92, 1.25))
    ball(N + "Belly", 0.19, (0, -0.07, 0.27), p["light"], scale=(0.95, 0.75, 1.1))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "Face" + sd, 0.09, (s * 0.06, -0.15, 0.46), p["light"], scale=(1, 0.6, 1))
        ball(N + "Wing" + sd, 0.12, (s * 0.24, 0.0, 0.3), p["body"], scale=(0.3, 0.7, 1.3), rot=(0, s * 25, 0))
        ball(N + "Foot" + sd, 0.06, (s * 0.08, -0.12, 0.02), p["beak"], scale=(1, 1.5, 0.4))
    eyes(N, 0.48, 0.07, -0.205, C["eye"], C["white"], r=0.03)
    cone(N + "Beak", 0.035, 0.07, (0, -0.24, 0.42), p["beak"], rot=(-90, 0, 0), scale=(1.3, 1, 0.7))
    cheeks(N, 0.42, 0.13, -0.18, C["blush"])
    # beanie
    ball(N + "Hat", 0.17, (0, 0.0, 0.58), p["hat"], scale=(1.15, 1.1, 0.8))
    torus(N + "HatRim", 0.16, 0.03, (0, 0.0, 0.55), p["pom"], scale=(1.15, 1.08, 1))
    ball(N + "HatPom", 0.05, (0, 0.0, 0.73), p["pom"])

def hamster(pc, loc):
    N, c = start("Hamster", pc, loc); C = common()
    p = Pal("Hamster", body=("#E9A55E", 0.85), light=("#FFF3E2", 0.85), inner=("#F5B2B0", 0.8), seed=("#5A4636", 0.6))
    ball(N + "Body", 0.25, (0, 0, 0.24), p["body"], scale=(1.05, 1.0, 0.95))
    ball(N + "Belly", 0.19, (0, -0.07, 0.2), p["light"], scale=(1, 0.75, 0.9))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "CheekPouch" + sd, 0.09, (s * 0.13, -0.13, 0.27), p["light"])
        ball(N + "Ear" + sd, 0.05, (s * 0.13, 0.0, 0.46), p["body"], scale=(1, 0.5, 1))
        ball(N + "EarIn" + sd, 0.03, (s * 0.13, -0.02, 0.46), p["inner"], scale=(1, 0.4, 1))
        ball(N + "Hand" + sd, 0.035, (s * 0.04, -0.23, 0.22), p["inner"])
        ball(N + "Foot" + sd, 0.04, (s * 0.1, -0.15, 0.02), p["inner"], scale=(1, 1.4, 0.5))
    eyes(N, 0.36, 0.08, -0.21, C["eye"], C["white"], r=0.032)
    ball(N + "Nose", 0.017, (0, -0.25, 0.31), p["inner"])
    cheeks(N, 0.29, 0.17, -0.18, C["blush"])
    ball(N + "Seed", 0.04, (0, -0.255, 0.22), p["seed"], scale=(0.7, 0.5, 1.2))
    ball(N + "Stripe", 0.1, (0, 0.05, 0.47), M("PetHamster_stripe", "#C9803F", 0.85), scale=(0.5, 1.3, 0.3))

def dragon(pc, loc):
    N, c = start("Dragon", pc, loc); C = common()
    p = Pal("Dragon", body=("#4FB3A9", 0.6), light=("#F7E3A1", 0.7), horn=("#FFF6E0", 0.5), wing=("#F28C8C", 0.7), spike=("#2F8C84", 0.6))
    mammal(N, p, C, muzzle=False, head_sc=(1.15, 1.0, 0.92))
    ball(N + "Snout", 0.09, (0, -0.15, 0.42), p["body"], scale=(1.2, 0.9, 0.75))
    for s in (-1, 1):
        sd = "L" if s < 0 else "R"
        ball(N + "Nostril" + sd, 0.012, (s * 0.035, -0.225, 0.44), C["nose"])
        cone(N + "Horn" + sd, 0.035, 0.12, (s * 0.1, 0.03, 0.66), p["horn"], rot=(-20, s * -20, 0))
        cone(N + "EarFin" + sd, 0.05, 0.12, (s * 0.21, 0.02, 0.5), p["wing"], rot=(0, s * -70, 0), scale=(1, 0.3, 1))
        w = cone(N + "Wing" + sd, 0.12, 0.26, (s * 0.2, 0.15, 0.36), p["wing"], rot=(-20, s * -55, 0), scale=(1, 0.2, 1), verts=3)
        cyl(N + "WingBone" + sd, 0.012, 0.26, (s * 0.2, 0.16, 0.36), p["spike"], rot=(-20, s * -55, 0), verts=8)
    for k in range(4):
        cone(N + "Spike%d" % k, 0.03, 0.06, (0, 0.17 - k * 0.0, 0.58 - k * 0.11), p["spike"], rot=(-60, 0, 0), scale=(0.5, 1, 1))
    pts = [(0, 0.2, 0.1), (0.07, 0.3, 0.07), (0.16, 0.36, 0.07), (0.25, 0.37, 0.1)]
    chain(N + "Tail", pts, [0.07, 0.055, 0.045, 0.035], p["body"])
    cone(N + "TailTip", 0.05, 0.1, (0.31, 0.37, 0.12), p["spike"], rot=(0, 80, 0), scale=(1, 0.4, 1))
    for k in range(3):
        box(N + "BellyPlate%d" % k, (0.13 - k * 0.02, 0.02, 0.035), (0, -0.155 + k * 0.005, 0.27 - k * 0.06), p["light"], bevel=0.01, rot=(-15, 0, 0))

PETS = [cat, puppy, fox, bunny, bear, frog, owl, penguin, hamster, dragon]

def build_pets():
    sc = new_scene("Pets")
    setup_render(sc, res=(1600, 900))
    pc = coll("Pets", scene=sc)
    for i, fn in enumerate(PETS):
        x = (i % 5 - 2) * 1.0
        y = (i // 5) * 1.4
        fn(pc, (x, y, 0.0))
    use(pc)
    box("Pets_Floor", (6, 3.5, 0.05), (0, 0.6, -0.025), M("Pets_Floor", "#E8E0D2", 0.9), bevel=0)
    light("Pets_Key", "SUN", (0, 0, 5), 3.0, rot=(45, 0, -30))
    light("Pets_Fill", "AREA", (0, -4, 3), 500, size=6, rot=(55, 0, 0))
    camera("Pets_Cam", (0.0, -5.2, 2.6), (0, 0.5, 0.25), lens=42, scene=sc)
    return sc
