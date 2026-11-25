# Cozy front-facing rooms for the full-screen «Питомник» (v3, 2026-11-25).
# Exec inside Blender after lib.py:
#   exec(open(r".../lib.py").read()); exec(open(r".../rooms_v3.py").read())
#   build_living(); build_kitchen3(); build_bedroom3()
# Camera looks along +Y at the back wall; the pet stands at PetSpot (x=0, y=0).
import bpy, bmesh, math, random
from mathutils import Vector, Matrix, Euler

# ------------------------------------------------------------------ materials
def _nm(name):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs[0], out.inputs["Surface"])
    return m, nt, bsdf

def _ramp(nt, fac_socket, c1, c2, p1=0.0, p2=1.0):
    r = nt.nodes.new("ShaderNodeValToRGB")
    r.color_ramp.elements[0].position = p1
    r.color_ramp.elements[0].color = (*hexc(c1), 1)
    r.color_ramp.elements[1].position = p2
    r.color_ramp.elements[1].color = (*hexc(c2), 1)
    nt.links.new(fac_socket, r.inputs["Fac"])
    return r

def _bump(nt, bsdf, height_socket, strength=0.2, dist=0.01):
    b = nt.nodes.new("ShaderNodeBump")
    b.inputs["Strength"].default_value = strength
    b.inputs["Distance"].default_value = dist
    nt.links.new(height_socket, b.inputs["Height"])
    nt.links.new(b.outputs["Normal"], bsdf.inputs["Normal"])

def _coords(nt, scale=(1, 1, 1), rot=(0, 0, 0)):
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = scale
    mp.inputs["Rotation"].default_value = [math.radians(a) for a in rot]
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    return mp.outputs["Vector"]

def soft(name, c, rough=0.6, sheen=0.0, coat=0.0, metal=0.0, sss=0.0):
    m, nt, b = _nm(name)
    b.inputs["Base Color"].default_value = (*hexc(c), 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    b.inputs["Sheen Weight"].default_value = sheen
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Subsurface Weight"].default_value = sss
    m.diffuse_color = (*hexc(c), 1)
    return m

def glow(name, c, strength=5.0, base=None):
    m, nt, b = _nm(name)
    b.inputs["Base Color"].default_value = (*hexc(base or c), 1)
    b.inputs["Emission Color"].default_value = (*hexc(c), 1)
    b.inputs["Emission Strength"].default_value = strength
    b.inputs["Roughness"].default_value = 0.5
    m.diffuse_color = (*hexc(c), 1)
    return m

def wood(name, c1, c2, scale=4.0, rough=0.5, stretch=(1, 1, 8), coat=0.0):
    m, nt, b = _nm(name)
    v = _coords(nt, stretch)
    w = nt.nodes.new("ShaderNodeTexWave")
    w.wave_type = "BANDS"; w.bands_direction = "Z"
    w.inputs["Scale"].default_value = scale
    w.inputs["Distortion"].default_value = 7.0
    w.inputs["Detail"].default_value = 3.0
    nt.links.new(v, w.inputs["Vector"])
    r = _ramp(nt, w.outputs["Fac"], c2, c1, 0.1, 0.9)
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = coat
    _bump(nt, b, w.outputs["Fac"], 0.08)
    m.diffuse_color = (*hexc(c1), 1)
    return m

def planks(name, c1, c2, rough=0.45, board=0.18, length=1.2):
    """Floor boards along Y with per-board tint and grain."""
    m, nt, b = _nm(name)
    v = _coords(nt, (1, 1, 1))
    br = nt.nodes.new("ShaderNodeTexBrick")
    br.offset = 0.5; br.offset_frequency = 1
    br.inputs["Color1"].default_value = (*hexc(c1), 1)
    br.inputs["Color2"].default_value = (*hexc(c2), 1)
    br.inputs["Mortar"].default_value = (*[x * 0.45 for x in hexc(c2)], 1)
    br.inputs["Scale"].default_value = 1.0
    br.inputs["Mortar Size"].default_value = 0.004
    br.inputs["Bias"].default_value = 0.0
    br.inputs["Brick Width"].default_value = length
    br.inputs["Row Height"].default_value = board
    # bricks run along X; rotate so boards run toward the camera (Y)
    sep = nt.nodes.new("ShaderNodeMapping")
    sep.inputs["Rotation"].default_value = (0, 0, math.radians(90))
    nt.links.new(v, sep.inputs["Vector"])
    nt.links.new(sep.outputs["Vector"], br.inputs["Vector"])
    w = nt.nodes.new("ShaderNodeTexWave")
    w.wave_type = "BANDS"; w.bands_direction = "X"
    w.inputs["Scale"].default_value = 9.0
    w.inputs["Distortion"].default_value = 9.0
    w.inputs["Detail"].default_value = 3.0
    nt.links.new(v, w.inputs["Vector"])
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"; mix.blend_type = "MULTIPLY"
    mix.inputs["Factor"].default_value = 0.25
    nt.links.new(br.outputs["Color"], mix.inputs[6])
    r = _ramp(nt, w.outputs["Fac"], "#CFCFCF", "#FFFFFF")
    nt.links.new(r.outputs["Color"], mix.inputs[7])
    nt.links.new(mix.outputs[2], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = 0.25
    inv = nt.nodes.new("ShaderNodeMath"); inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    nt.links.new(br.outputs["Fac"], inv.inputs[1])
    _bump(nt, b, inv.outputs[0], 0.35, 0.004)
    m.diffuse_color = (*hexc(c1), 1)
    return m

def tiles(name, c1, c2, grout, scale=6.0, rough=0.2, ratio=(1.0, 1.0)):
    m, nt, b = _nm(name)
    v = _coords(nt, (1, 1, 1), rot=(90, 0, 0))
    br = nt.nodes.new("ShaderNodeTexBrick")
    br.offset = 0.0
    br.inputs["Color1"].default_value = (*hexc(c1), 1)
    br.inputs["Color2"].default_value = (*hexc(c2), 1)
    br.inputs["Mortar"].default_value = (*hexc(grout), 1)
    br.inputs["Scale"].default_value = scale
    br.inputs["Mortar Size"].default_value = 0.012
    br.inputs["Mortar Smooth"].default_value = 0.4
    br.inputs["Brick Width"].default_value = 0.5 * ratio[0]
    br.inputs["Row Height"].default_value = 0.5 * ratio[1]
    nt.links.new(v, br.inputs["Vector"])
    nt.links.new(br.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = 0.4
    inv = nt.nodes.new("ShaderNodeMath"); inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    nt.links.new(br.outputs["Fac"], inv.inputs[1])
    _bump(nt, b, inv.outputs[0], 0.5, 0.005)
    m.diffuse_color = (*hexc(c1), 1)
    return m

def knit(name, c1, c2, scale=28.0, rough=0.95, strength=0.6):
    """Chunky knit / crochet: interlocking V rows."""
    m, nt, b = _nm(name)
    v = _coords(nt, (1, 1, 1))
    w1 = nt.nodes.new("ShaderNodeTexWave")
    w1.wave_type = "BANDS"; w1.bands_direction = "X"; w1.wave_profile = "SIN"
    w1.inputs["Scale"].default_value = scale
    w2 = nt.nodes.new("ShaderNodeTexWave")
    w2.wave_type = "BANDS"; w2.bands_direction = "Z"; w2.wave_profile = "SAW"
    w2.inputs["Scale"].default_value = scale * 0.7
    nt.links.new(v, w1.inputs["Vector"]); nt.links.new(v, w2.inputs["Vector"])
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"
    nt.links.new(w1.outputs["Fac"], mul.inputs[0]); nt.links.new(w2.outputs["Fac"], mul.inputs[1])
    r = _ramp(nt, mul.outputs[0], c2, c1, 0.0, 0.5)
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Sheen Weight"].default_value = 0.6
    b.inputs["Sheen Roughness"].default_value = 0.4
    _bump(nt, b, mul.outputs[0], strength, 0.01)
    m.diffuse_color = (*hexc(c1), 1)
    return m

def fabric(name, c, rough=0.85, sheen=0.7, scale=300.0):
    m, nt, b = _nm(name)
    v = _coords(nt)
    n = nt.nodes.new("ShaderNodeTexNoise")
    n.inputs["Scale"].default_value = scale
    nt.links.new(v, n.inputs["Vector"])
    b.inputs["Base Color"].default_value = (*hexc(c), 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Sheen Weight"].default_value = sheen
    b.inputs["Sheen Roughness"].default_value = 0.35
    _bump(nt, b, n.outputs["Fac"], 0.12, 0.003)
    m.diffuse_color = (*hexc(c), 1)
    return m

def check(name, c1, c2, scale=10.0, rough=0.85):
    """Gingham: two crossing stripe waves."""
    m, nt, b = _nm(name)
    v = _coords(nt)
    w1 = nt.nodes.new("ShaderNodeTexWave"); w1.bands_direction = "X"; w1.wave_profile = "SIN"
    w2 = nt.nodes.new("ShaderNodeTexWave"); w2.bands_direction = "Y"; w2.wave_profile = "SIN"
    for w in (w1, w2):
        w.inputs["Scale"].default_value = scale
        nt.links.new(v, w.inputs["Vector"])
    g1 = nt.nodes.new("ShaderNodeMath"); g1.operation = "GREATER_THAN"; g1.inputs[1].default_value = 0.5
    g2 = nt.nodes.new("ShaderNodeMath"); g2.operation = "GREATER_THAN"; g2.inputs[1].default_value = 0.5
    nt.links.new(w1.outputs["Fac"], g1.inputs[0]); nt.links.new(w2.outputs["Fac"], g2.inputs[0])
    add = nt.nodes.new("ShaderNodeMath"); add.operation = "ADD"
    nt.links.new(g1.outputs[0], add.inputs[0]); nt.links.new(g2.outputs[0], add.inputs[1])
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"; mul.inputs[1].default_value = 0.5
    nt.links.new(add.outputs[0], mul.inputs[0])
    r = _ramp(nt, mul.outputs[0], "#FFFFFF", "#FFFFFF")
    els = r.color_ramp.elements
    els[0].color = (*hexc(c2), 1); els[1].color = (*hexc(c1), 1)
    e = els.new(0.5); e.color = tuple((a + bb) / 2 for a, bb in zip((*hexc(c1), 1), (*hexc(c2), 1)))
    r.color_ramp.interpolation = "CONSTANT"
    els[0].position = 0.0; e.position = 0.25; els[2].position = 0.75
    nt.links.new(r.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Sheen Weight"].default_value = 0.1
    m.diffuse_color = (*hexc(c1), 1)
    return m

def sky(name, top, bottom, strength=3.0, axis="Z"):
    m, nt, b = _nm(name)
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    nt.nodes.remove(b)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    r = _ramp(nt, sep.outputs[axis], bottom, top)
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = strength
    nt.links.new(r.outputs["Color"], em.inputs["Color"])
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    m.diffuse_color = (*hexc(top), 1)
    return m

def glass_mat(name, tint="#FFFFFF", rough=0.02):
    m, nt, b = _nm(name)
    b.inputs["Base Color"].default_value = (*hexc(tint), 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Transmission Weight"].default_value = 1.0
    b.inputs["IOR"].default_value = 1.45
    return m


def _sky_foliage(m, c_dark, c_light, line=0.38, amp=0.12):
    """Adds autumn tree silhouettes to the lower part of a sky() card."""
    nt = m.node_tree
    em = next(n for n in nt.nodes if n.type == "EMISSION")
    ramp = next(n for n in nt.nodes if n.type == "VALTORGB")
    tc = next(n for n in nt.nodes if n.type == "TEX_COORD")
    sep = next(n for n in nt.nodes if n.type == "SEPXYZ")
    n1 = nt.nodes.new("ShaderNodeTexNoise"); n1.inputs["Scale"].default_value = 6.0; n1.inputs["Detail"].default_value = 6
    nt.links.new(tc.outputs["Generated"], n1.inputs["Vector"])
    v = nt.nodes.new("ShaderNodeTexVoronoi"); v.inputs["Scale"].default_value = 18.0
    nt.links.new(tc.outputs["Generated"], v.inputs["Vector"])
    # edge = line + amp*noise ; mask = z < edge
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY_ADD"
    mul.inputs[1].default_value = amp; mul.inputs[2].default_value = line - amp / 2
    nt.links.new(n1.outputs["Fac"], mul.inputs[0])
    lt = nt.nodes.new("ShaderNodeMath"); lt.operation = "LESS_THAN"
    nt.links.new(sep.outputs["Z"], lt.inputs[0]); nt.links.new(mul.outputs[0], lt.inputs[1])
    leaves = _ramp(nt, v.outputs["Distance"], c_light, c_dark, 0.05, 0.6)
    mix = nt.nodes.new("ShaderNodeMix"); mix.data_type = "RGBA"
    nt.links.new(lt.outputs[0], mix.inputs["Factor"])
    nt.links.new(ramp.outputs["Color"], mix.inputs[6]); nt.links.new(leaves.outputs["Color"], mix.inputs[7])
    nt.links.new(mix.outputs[2], em.inputs["Color"])
    # sun glow disc
    d = nt.nodes.new("ShaderNodeVectorMath"); d.operation = "DISTANCE"
    d.inputs[1].default_value = (0.62, 0.5, 0.58)
    nt.links.new(tc.outputs["Generated"], d.inputs[0])
    g = nt.nodes.new("ShaderNodeMapRange"); g.inputs["From Min"].default_value = 0.03; g.inputs["From Max"].default_value = 0.25
    g.inputs["To Min"].default_value = 3.0; g.inputs["To Max"].default_value = 1.0
    nt.links.new(d.outputs["Value"], g.inputs["Value"])
    mm = nt.nodes.new("ShaderNodeMath"); mm.operation = "MULTIPLY"; mm.inputs[1].default_value = em.inputs["Strength"].default_value
    nt.links.new(g.outputs["Result"], mm.inputs[0]); nt.links.new(mm.outputs[0], em.inputs["Strength"])

# ------------------------------------------------------------------ geometry
def _link(name, me, m, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), parent=None):
    o = _obj(name, me, loc, rot, m, parent)
    o.scale = scale
    return o

def rbox(name, size, loc, m, r=0.03, rot=(0, 0, 0), segs=4, parent=None, subd=0):
    o = box(name, size, loc, m, bevel=r, rot=rot, segs=segs, parent=parent)
    o.data.shade_smooth()
    try:
        o.data.set_sharp_from_angle(angle=math.radians(35))
    except Exception:
        pass
    if subd:
        s = o.modifiers.new("Subd", "SUBSURF"); s.levels = subd; s.render_levels = subd
    return o

def puff(name, size, loc, m, rot=(0, 0, 0), parent=None, level=3, crease=0.0):
    """Pillowy cushion: a cube subdivided into a soft blob."""
    o = box(name, size, loc, m, bevel=0.0, rot=rot, parent=parent)
    s = o.modifiers.new("Subd", "SUBSURF"); s.levels = level; s.render_levels = level
    o.data.shade_smooth()
    if crease:
        for e in o.data.edges:
            e.crease = crease  # Blender 4+: attribute
    return o

def revolve(name, profile, loc, m, segs=48, parent=None, rot=(0, 0, 0), smooth=True, scale=(1, 1, 1)):
    """profile = [(r, z), ...] bottom→top; spun around Z."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    rings = []
    for (r, z) in profile:
        ring = []
        for i in range(segs):
            a = 2 * math.pi * i / segs
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), z)))
        rings.append(ring)
    for k in range(len(rings) - 1):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]))
    if profile[0][0] > 0:
        bm.faces.new(list(reversed(rings[0])))
    if profile[-1][0] > 0:
        bm.faces.new(rings[-1])
    bm.normal_update()
    bm.to_mesh(me); bm.free()
    if smooth:
        me.shade_smooth()
    return _link(name, me, m, loc, rot, scale, parent)

def tube(name, pts, r, m, res=12, parent=None, taper=None):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = 4
    cu.resolution_u = res
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for p, c in zip(sp.bezier_points, pts):
        p.co = c
        p.handle_left_type = p.handle_right_type = "AUTO"
    cu.use_fill_caps = True
    o = bpy.data.objects.new(name, cu)
    _CTX["coll"].objects.link(o)
    o.data.materials.append(m)
    if parent is not None:
        o.parent = parent
    return o

class Batch:
    """Many small parts → one mesh per material (fewer draw calls in the app)."""
    def __init__(self, name):
        self.name = name
        self.bms = {}
    def _bm(self, m):
        if m.name not in self.bms:
            self.bms[m.name] = (m, bmesh.new())
        return self.bms[m.name][1]
    @staticmethod
    def _mx(loc, rot, scale):
        return (Matrix.Translation(loc) @ Euler([math.radians(a) for a in rot]).to_matrix().to_4x4()
                @ Matrix.Diagonal((*scale, 1)))
    def cube(self, m, size, loc, rot=(0, 0, 0)):
        bmesh.ops.create_cube(self._bm(m), size=1.0, matrix=self._mx(loc, rot, size))
    def cyl(self, m, r, h, loc, rot=(0, 0, 0), r2=None, segs=12, scale=(1, 1, 1)):
        bmesh.ops.create_cone(self._bm(m), cap_ends=True, segments=segs, radius1=r,
                              radius2=r if r2 is None else r2, depth=h,
                              matrix=self._mx(loc, rot, scale))
    def sphere(self, m, r, loc, scale=(1, 1, 1), rot=(0, 0, 0), segs=12, rings=8):
        bmesh.ops.create_uvsphere(self._bm(m), u_segments=segs, v_segments=rings, radius=r,
                                  matrix=self._mx(loc, rot, scale))
    def build(self, bevel=0.0, smooth=True, parent=None):
        out = []
        for key, (m, bm) in self.bms.items():
            me = bpy.data.meshes.new(self.name + "_" + key)
            bm.to_mesh(me); bm.free()
            if smooth:
                me.shade_smooth()
                try:
                    me.set_sharp_from_angle(angle=math.radians(35))
                except Exception:
                    pass
            o = _link(self.name + "_" + key, me, m, parent=parent)
            if bevel:
                b = o.modifiers.new("Bevel", "BEVEL"); b.width = bevel; b.segments = 2
                b.limit_method = "ANGLE"
            out.append(o)
        self.bms = {}
        return out

def build_all():
    out = [build_living(), build_kitchen3(), build_bedroom3()]
    return out

def render_previews(folder=r"F:\project\PepeHub\design\pets\shots_v3", samples=64, pct=100):
    import os
    os.makedirs(folder, exist_ok=True)
    for n in ("Room_Living", "Room_Kitchen3", "Room_Bedroom3"):
        s = bpy.data.scenes.get(n)
        if s is None:
            continue
        s.eevee.taa_render_samples = samples
        s.render.resolution_percentage = pct
        s.render.filepath = os.path.join(folder, n + ".png")
        bpy.ops.render.render(write_still=True, scene=n)

def render_phone(folder=r"F:\\project\\PepeHub\\design\\pets\\shots_v3\\phone", samples=64, lens=24, res=(780, 1688)):
    """Phone-shaped renders (9:19.5) for the UI concepts; camera lens widened temporarily."""
    import os
    os.makedirs(folder, exist_ok=True)
    for n in ("Room_Living", "Room_Kitchen3", "Room_Bedroom3"):
        s = bpy.data.scenes.get(n)
        if s is None:
            continue
        keep = (s.render.resolution_x, s.render.resolution_y, s.render.resolution_percentage, s.camera.data.lens)
        s.render.resolution_x, s.render.resolution_y = res
        s.render.resolution_percentage = 100
        s.camera.data.lens = lens
        s.eevee.taa_render_samples = samples
        s.render.filepath = os.path.join(folder, n + ".png")
        bpy.ops.render.render(write_still=True, scene=n)
        s.render.resolution_x, s.render.resolution_y, s.render.resolution_percentage, s.camera.data.lens = keep

# ------------------------------------------------------------------ props
def scallop_shade(name, loc, m, r_top=0.09, r_bot=0.2, h=0.17, lobes=7, parent=None, rot=(0, 0, 0)):
    """Tulip / flower lamp shade, open at the bottom."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    segs = lobes * 8
    rows = 10
    grid = []
    for k in range(rows + 1):
        t = k / rows
        z = h * (1 - t)
        rr = r_top + (r_bot - r_top) * (t ** 0.8)
        row = []
        for i in range(segs):
            a = 2 * math.pi * i / segs
            lobe = 0.5 + 0.5 * math.cos(a * lobes)
            rad = rr * (1 + 0.08 * t * lobe)
            zz = z - (0.035 * t ** 3 * (1 - lobe))
            row.append(bm.verts.new((rad * math.cos(a), rad * math.sin(a), zz)))
        grid.append(row)
    for k in range(rows):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((grid[k][i], grid[k][j], grid[k + 1][j], grid[k + 1][i]))
    bm.faces.new(grid[0])
    bm.normal_update()
    bm.to_mesh(me); bm.free()
    me.shade_smooth()
    o = _link(name, me, m, loc, rot, parent=parent)
    sol = o.modifiers.new("Solid", "SOLIDIFY"); sol.thickness = 0.008
    return o

def shelf_books(batch, x0, x1, y, z, depth, palette, rnd, hmin=0.2, hmax=0.3, gold=None, lean=True):
    """Books standing on a shelf along X (spines toward -Y)."""
    x = x0
    while x < x1 - 0.04:
        w = rnd.uniform(0.03, 0.055)
        hgt = rnd.uniform(hmin, hmax)
        m = rnd.choice(palette)
        if lean and rnd.random() < 0.07 and x + 0.12 < x1:
            batch.cube(m, (w, depth, hgt), (x + hgt * 0.35, y, z + hgt * 0.45), rot=(0, 28, 0))
            x += hgt * 0.6
            continue
        batch.cube(m, (w, depth * rnd.uniform(0.85, 1.0), hgt), (x + w / 2, y, z + hgt / 2))
        if gold is not None and rnd.random() < 0.6:
            for gz in (0.25, 0.75):
                batch.cube(gold, (w * 1.02, 0.004, 0.008), (x + w / 2, y - depth / 2 - 0.001, z + hgt * gz))
        x += w + 0.002

def book(name, loc, size, cover_m, page_m, rot=(0, 0, 0), parent=None):
    """Closed hardcover: cover + inset pages."""
    w, d, h = size
    g = empty(name, loc)
    g.rotation_euler = [math.radians(a) for a in rot]
    if parent:
        g.parent = parent
    rbox(name + "_Cover", (w, d, h), (0, 0, 0), cover_m, r=min(h, 0.01) * 0.4, parent=g)
    box(name + "_Pages", (w - 0.012, d - 0.01, h * 0.78), (0.006, 0, 0), page_m, bevel=0.002, parent=g)
    return g

def open_book(name, loc, m_cover, m_page, rot=(0, 0, 0), w=0.3, d=0.22):
    g = empty(name, loc)
    g.rotation_euler = [math.radians(a) for a in rot]
    for s in (-1, 1):
        rbox(name + "_Cover%d" % s, (w / 2 + 0.01, d + 0.01, 0.01), (s * w / 4, 0, 0.005), m_cover, r=0.004, rot=(0, s * -6, 0), parent=g)
        # curved page stack
        me = bpy.data.meshes.new(name + "_Pages%d" % s)
        bm = bmesh.new()
        n = 12
        top, bot = [], []
        for i in range(n + 1):
            t = i / n
            x = s * t * (w / 2 - 0.005)
            zc = 0.012 + 0.03 * math.sin(math.pi * (0.15 + 0.85 * t)) * (1 - t * 0.4)
            top.append((x, zc)); bot.append((x, 0.012))
        vs_t = [[bm.verts.new((x, yy, z)) for (x, z) in top] for yy in (-d / 2, d / 2)]
        vs_b = [[bm.verts.new((x, yy, z)) for (x, z) in bot] for yy in (-d / 2, d / 2)]
        for i in range(n):
            bm.faces.new((vs_t[0][i], vs_t[0][i + 1], vs_t[1][i + 1], vs_t[1][i]))
            bm.faces.new((vs_b[0][i + 1], vs_b[0][i], vs_b[1][i], vs_b[1][i + 1]))
            for k in (0, 1):
                bm.faces.new((vs_b[k][i], vs_b[k][i + 1], vs_t[k][i + 1], vs_t[k][i]))
        bm.faces.new((vs_b[0][n], vs_b[1][n], vs_t[1][n], vs_t[0][n]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(me); bm.free(); me.shade_smooth()
        _link(name + "_Pages%d" % s, me, m_page, parent=g)
    return g

def round_rug(name, loc, R, m_main, m_ring, m_fringe, rings=4, fringe=72, sx=1.0, sy=1.0):
    g = empty(name, loc)
    revolve(name + "_Base", [(0, 0), (R, 0), (R, 0.012), (R * 0.98, 0.016), (0, 0.016)], (0, 0, 0), m_main, segs=96, parent=g, scale=(sx, sy, 1))
    for k in range(1, rings + 1):
        rr = R * k / (rings + 0.6)
        torus(name + "_Ring%d" % k, rr, 0.012, (0, 0, 0.016), m_ring if k % 2 else m_main, parent=g, seg=96, ring=8, scale=(sx, sy, 0.5))
    torus(name + "_Edge", R * 0.985, 0.018, (0, 0, 0.014), m_ring, parent=g, seg=96, ring=8, scale=(sx, sy, 0.6))
    bt = Batch(name + "_Fringe")
    for i in range(fringe):
        a = 2 * math.pi * i / fringe
        x, y = math.cos(a) * (R + 0.04) * sx, math.sin(a) * (R + 0.04) * sy
        bt.cyl(m_fringe, 0.007, 0.06, (x, y, 0.006), rot=(90, 0, math.degrees(a) + 90), segs=6)
    for o in bt.build(parent=g):
        pass
    return g

def ivy(name, start, length, m_leaf, m_stem, rnd, droop=1.0, leaves=26, size=0.045, sway=0.25):
    pts = []
    x, y, z = start
    n = 6
    for i in range(n):
        t = i / (n - 1)
        pts.append((x + math.sin(t * 3 + rnd.random()) * sway * t, y - 0.02 * t, z - length * t * droop))
    tube(name + "_Stem", pts, 0.004, m_stem)
    bt = Batch(name)
    for i in range(leaves):
        t = i / leaves
        k = min(int(t * (n - 1)), n - 2)
        f = t * (n - 1) - k
        p = Vector(pts[k]).lerp(Vector(pts[k + 1]), f)
        side = 1 if i % 2 else -1
        s = size * (0.7 + 0.5 * rnd.random()) * (1.1 - 0.4 * t)
        bt.sphere(m_leaf, s, (p.x + side * s * 0.8, p.y - 0.01, p.z), scale=(1.0, 0.25, 0.75),
                  rot=(rnd.uniform(-20, 20), 0, side * rnd.uniform(10, 40)), segs=8, rings=6)
    bt.build()

def potted(name, loc, m_pot, m_leaf, m_soil, rnd, s=1.0, kind="bush", m_fruit=None):
    x, y, z = loc
    revolve(name + "_Pot", [(0.0, 0), (0.09 * s, 0), (0.12 * s, 0.17 * s), (0.135 * s, 0.19 * s), (0.135 * s, 0.215 * s), (0.12 * s, 0.215 * s)], (x, y, z), m_pot)
    cyl(name + "_Soil", 0.118 * s, 0.01, (x, y, z + 0.2 * s), m_soil)
    bt = Batch(name + "_Leaves")
    if kind == "bush":
        for i in range(60):
            a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0.02, 0.17) * s
            zz = z + (0.25 + rnd.uniform(0, 0.25)) * s
            bt.sphere(m_leaf, 0.055 * s, (x + math.cos(a) * r, y + math.sin(a) * r, zz), scale=(0.55, 0.12, 1.0),
                      rot=(rnd.uniform(-40, 40), rnd.uniform(-40, 40), math.degrees(a)), segs=8, rings=6)
    elif kind == "tree":
        tube(name + "_Trunk", [(x, y, z + 0.2 * s), (x + 0.02 * s, y, z + 0.45 * s), (x - 0.01 * s, y, z + 0.7 * s)], 0.012 * s, soft(name + "_Bark", "#6B4A35", 0.8))
        for i in range(70):
            a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0.0, 0.26) * s
            zz = z + (0.62 + rnd.uniform(-0.15, 0.2)) * s
            bt.sphere(m_leaf, 0.05 * s, (x + math.cos(a) * r, y + math.sin(a) * r * 0.8, zz), scale=(1, 0.35, 0.55),
                      rot=(rnd.uniform(-50, 50), rnd.uniform(-50, 50), math.degrees(a)), segs=8, rings=6)
        if m_fruit:
            for i in range(7):
                a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0.08, 0.22) * s
                bt.sphere(m_fruit, 0.045 * s, (x + math.cos(a) * r, y - 0.12 * s + math.sin(a) * 0.05, z + (0.5 + rnd.uniform(0, 0.25)) * s), scale=(0.9, 0.9, 1.05), segs=12, rings=8)
    bt.build()

def flowers(name, loc, m_vase, m_petal, m_center, m_leaf, rnd, n=7, s=1.0):
    x, y, z = loc
    revolve(name + "_Vase", [(0, 0), (0.045 * s, 0), (0.07 * s, 0.07 * s), (0.04 * s, 0.14 * s), (0.05 * s, 0.17 * s), (0.045 * s, 0.17 * s)], (x, y, z), m_vase)
    bt = Batch(name + "_Bloom")
    for i in range(n):
        a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0.0, 0.09) * s
        cx, cy, cz = x + math.cos(a) * r, y + math.sin(a) * r, z + (0.22 + rnd.uniform(0, 0.08)) * s
        for p in range(6):
            pa = p * math.pi / 3
            bt.sphere(m_petal, 0.022 * s, (cx + math.cos(pa) * 0.022 * s, cy + math.sin(pa) * 0.022 * s, cz), scale=(1, 1, 0.5), segs=8, rings=6)
        bt.sphere(m_center, 0.012 * s, (cx, cy, cz + 0.006 * s), segs=8, rings=6)
    for i in range(5):
        a = rnd.uniform(0, 2 * math.pi)
        bt.sphere(m_leaf, 0.03 * s, (x + math.cos(a) * 0.06 * s, y + math.sin(a) * 0.06 * s, z + 0.19 * s), scale=(1, 0.3, 0.5), rot=(0, 30, math.degrees(a)), segs=8, rings=6)
    bt.build()

def teacup(name, loc, m_cup, m_tea, s=1.0, steam=None):
    x, y, z = loc
    revolve(name + "_Saucer", [(0, 0), (0.06 * s, 0), (0.075 * s, 0.012 * s), (0.07 * s, 0.014 * s), (0, 0.008 * s)], (x, y, z), m_cup)
    revolve(name + "_Cup", [(0, 0.008 * s), (0.028 * s, 0.008 * s), (0.045 * s, 0.05 * s), (0.048 * s, 0.065 * s), (0.044 * s, 0.065 * s), (0.04 * s, 0.05 * s), (0.0, 0.02 * s)], (x, y, z), m_cup)
    cyl(name + "_Tea", 0.041 * s, 0.002, (x, y, z + 0.055 * s), m_tea)
    torus(name + "_Handle", 0.017 * s, 0.005 * s, (x + 0.05 * s, y, z + 0.04 * s), m_cup, rot=(90, 0, 0), seg=16, ring=8)

def pet_spot(prefix, loc):
    e = empty(prefix + "PetSpot", loc)
    e.empty_display_type = "SINGLE_ARROW"
    return e

def stand_in_pet(prefix, loc, scale=1.0, glb=r"F:\project\PepeHub\design\pets\export\cat_baby.glb"):
    """Imports an existing pet model only to judge scale and framing."""
    before = set(bpy.data.objects)
    try:
        bpy.ops.import_scene.gltf(filepath=glb)
    except Exception as e:
        print("pet import failed", e)
        return None
    new = [o for o in bpy.data.objects if o not in before]
    for o in [o for o in new if o.type == "MESH" and o.name.startswith("Icosphere")]:
        new.remove(o); bpy.data.objects.remove(o, do_unlink=True)
    roots = [o for o in new if o.parent is None]
    g = empty(prefix + "PetStandIn", loc)
    for o in new:
        for c in o.users_collection:
            c.objects.unlink(o)
        _CTX["coll"].objects.link(o)
    for o in roots:
        o.parent = g
    g.scale = (scale, scale, scale)
    return g

# ------------------------------------------------------------------ scene setup
def setup_scene(name, res=(1080, 1440)):
    s = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
    try:
        s.render.engine = "BLENDER_EEVEE"
    except TypeError:
        pass
    s.render.resolution_x, s.render.resolution_y = res
    s.render.resolution_percentage = 50
    try:
        s.view_settings.view_transform = "AgX"
        s.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass
    e = s.eevee
    e.use_raytracing = True
    e.ray_tracing_method = "SCREEN"
    e.use_fast_gi = True
    e.use_shadows = True
    e.taa_render_samples = 64
    if s.world is None:
        w = bpy.data.worlds.new(name + "_World"); w.use_nodes = True; s.world = w
    return s


def post_fx(s, bloom=0.6, threshold=0.8, size=0.6):
    """Compositor: bloom around lamps and windows (EEVEE has no built-in bloom)."""
    ng = bpy.data.node_groups.get(s.name + "_Post") or bpy.data.node_groups.new(s.name + "_Post", "CompositorNodeTree")
    ng.nodes.clear()
    for it in list(ng.interface.items_tree):
        ng.interface.remove(it)
    ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    rl = ng.nodes.new("CompositorNodeRLayers"); rl.scene = s
    gl = ng.nodes.new("CompositorNodeGlare")
    gl.inputs["Type"].default_value = "Bloom"
    gl.inputs["Threshold"].default_value = threshold
    gl.inputs["Strength"].default_value = bloom
    gl.inputs["Size"].default_value = size
    out = ng.nodes.new("NodeGroupOutput")
    ng.links.new(rl.outputs["Image"], gl.inputs["Image"])
    ng.links.new(gl.outputs["Image"], out.inputs[0])
    s.compositing_node_group = ng
    s.render.use_compositing = True

def world_color(s, c, strength=0.5):
    bg = next(n for n in s.world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (*hexc(c), 1)
    bg.inputs["Strength"].default_value = strength

def cam(name, loc, target, lens, scene, dof_target=None, fstop=2.8):
    o = camera(name, loc, target, lens=lens, scene=scene)
    if dof_target is not None:
        o.data.dof.use_dof = True
        o.data.dof.focus_object = dof_target
        o.data.dof.aperture_fstop = fstop
    return o

def clear_scene(name):
    s = bpy.data.scenes.get(name)
    if s is None:
        return
    for c in list(s.collection.children):
        for o in list(c.all_objects):
            bpy.data.objects.remove(o, do_unlink=True)
        for cc in list(c.children_recursive):
            bpy.data.collections.remove(cc)
        bpy.data.collections.remove(c)

# ================================================================== LIVING ROOM
# Reading nook: bookcase, sage armchair with knit throw, tulip floor lamp,
# sunset window, round lavender rug. Matches the «Гостиная» concept.
def build_living():
    name = "Room_Living"
    clear_scene(name)
    sc = setup_scene(name)
    world_color(sc, "#4A3424", 0.25)
    post_fx(sc, bloom=0.7, threshold=0.7)
    root = coll("Living", scene=sc)
    use(root)
    rnd = random.Random(21)
    P = "L_"
    # palette
    wall = fabric(P + "WallSage", "#5E7862", rough=0.9, sheen=0.0, scale=80)
    wall_panel = soft(P + "PanelSage", "#69856C", 0.7)
    trim = soft(P + "TrimSage", "#4F6754", 0.55)
    floor = planks(P + "FloorOak", "#B07A4F", "#9A6640")
    wood_d = wood(P + "WoodWalnut", "#6E4A33", "#553624", scale=3.0, rough=0.45, coat=0.2)
    wood_l = wood(P + "WoodHoney", "#B98556", "#9A6A40", scale=3.0, rough=0.45, coat=0.2)
    brass = soft(P + "Brass", "#D8A95B", 0.25, metal=1.0)
    cream = fabric(P + "Cream", "#F1E6D2", 0.8)
    sage_f = fabric(P + "ChairSage", "#87A28E", 0.85, sheen=0.8)
    lav = knit(P + "RugLavender", "#B9A2D6", "#9C83BE", scale=60, strength=0.5)
    lav_d = knit(P + "RugLavDeep", "#9C83BE", "#7F66A3", scale=60, strength=0.5)
    lav_f = fabric(P + "Lavender", "#A891C9", 0.85, sheen=0.9)
    throw = knit(P + "ThrowCream", "#EFE2CC", "#D9C6A6", scale=40, strength=0.8)
    page = soft(P + "Paper", "#F6EEDC", 0.8)
    plum = soft(P + "CoverPlum", "#5B3F66", 0.55, coat=0.3)
    gold = soft(P + "GoldFoil", "#E2B65E", 0.3, metal=1.0)
    leaf = soft(P + "Leaf", "#5E8F4E", 0.55, sss=0.2)
    leaf2 = soft(P + "LeafLight", "#7FAE5E", 0.55, sss=0.2)
    stem = soft(P + "Stem", "#4C6B3A", 0.7)
    pot_w = soft(P + "PotCream", "#EDE4D5", 0.4, coat=0.5)
    soil = soft(P + "Soil", "#3B2A20", 0.95)
    porcelain = soft(P + "Porcelain", "#FBF7F0", 0.2, coat=0.6)
    tea = soft(P + "Tea", "#8A4B22", 0.1)
    shade_m = glow(P + "ShadeGlow", "#FFC98A", 4.0, base="#FFE7C7")
    bulb = glow(P + "Bulb", "#FFE2B0", 25.0)
    book_pal = [soft(P + "Bk%d" % i, c, 0.6, coat=0.15) for i, c in enumerate(
        ["#7A5C8E", "#5E3F5E", "#6F8F72", "#4F7A7A", "#E8DCC4", "#A65A55", "#C9A04A", "#A893C2", "#3F5B70", "#8C6A4F"])]

    W, D, H = 5.6, 4.6, 3.5     # room: x ±2.8, y -2.6..2.0, z 0..3.5 (ceiling stays out of frame)
    yb = 2.0                    # back wall inner face
    # shell ------------------------------------------------------------
    rbox(P + "Floor", (W, D, 0.1), (0, yb - D / 2, -0.05), floor, r=0.0)
    box(P + "WallBack", (W, 0.12, H), (0, yb + 0.06, H / 2), wall, bevel=0)
    for s in (-1, 1):
        box(P + "WallSide%d" % s, (0.12, D, H), (s * (W / 2 + 0.06), yb - D / 2, H / 2), wall, bevel=0)
    box(P + "Ceiling", (W, D, 0.1), (0, yb - D / 2, H + 0.05), wood(P + "CeilWood", "#8A6244", "#70503A", scale=2.0, rough=0.7), bevel=0)
    # wainscot: panel frames up to 1.0
    rbox(P + "Baseboard", (W, 0.04, 0.14), (0, yb - 0.02, 0.07), trim, r=0.008)
    rbox(P + "ChairRail", (W, 0.06, 0.05), (0, yb - 0.03, 1.0), trim, r=0.012)
    bt = Batch(P + "Panels")
    for i in range(7):
        cx = -W / 2 + 0.4 + i * 0.8
        bt.cube(wall_panel, (0.62, 0.02, 0.62), (cx, yb - 0.01, 0.56))
    bt.build(bevel=0.01)
    # crown moulding
    rbox(P + "Crown", (W, 0.08, 0.08), (0, yb - 0.04, H - 0.04), trim, r=0.015)

    # window (right) with sunset ----------------------------------------
    wx, wz, ww, wh = 1.35, 1.95, 1.3, 1.75
    sky_m = sky(P + "Sunset", "#E98B4F", "#FFE2A8", strength=6.0)
    s_pl = box(P + "SkyCard", (4.0, 0.02, 3.0), (wx, yb + 1.6, wz), sky_m, bevel=0)
    _sky_foliage(sky_m, "#B8632F", "#E39A48", line=0.45, amp=0.14)
    # cut the hole: wall pieces around the window instead of a boolean
    wall_obj = bpy.data.objects[P + "WallBack"]
    bpy.data.objects.remove(wall_obj, do_unlink=True)
    xl, xr = wx - ww / 2, wx + ww / 2
    zl, zt = wz - wh / 2, wz + wh / 2
    box(P + "WallL", (xl + W / 2, 0.12, H), ((-W / 2 + xl) / 2, yb + 0.06, H / 2), wall, bevel=0)
    box(P + "WallR", (W / 2 - xr, 0.12, H), ((xr + W / 2) / 2, yb + 0.06, H / 2), wall, bevel=0)
    box(P + "WallBelow", (ww, 0.12, zl), (wx, yb + 0.06, zl / 2), wall, bevel=0)
    box(P + "WallAbove", (ww, 0.12, H - zt), (wx, yb + 0.06, (zt + H) / 2), wall, bevel=0)
    fr = soft(P + "WinFrame", "#F2EADB", 0.45)
    for nme, sz, lc in [("T", (ww + 0.12, 0.16, 0.08), (wx, yb, zt + 0.04)),
                        ("B", (ww + 0.12, 0.16, 0.08), (wx, yb, zl - 0.04)),
                        ("L", (0.08, 0.16, wh), (xl - 0.04, yb, wz)),
                        ("R", (0.08, 0.16, wh), (xr + 0.04, yb, wz)),
                        ("MV", (0.04, 0.06, wh), (wx, yb + 0.02, wz)),
                        ("MH", (ww, 0.06, 0.04), (wx, yb + 0.02, wz + 0.15))]:
        rbox(P + "Win" + nme, sz, lc, fr, r=0.012)
    rbox(P + "WinSill", (ww + 0.4, 0.3, 0.05), (wx, yb - 0.1, zl - 0.1), fr, r=0.015)
    # sheer curtain on the left of the window
    cme = bpy.data.meshes.new(P + "Sheer")
    bm = bmesh.new()
    cols, rows = 40, 20
    cw, chh = 0.55, 2.2
    grid = []
    for r_ in range(rows + 1):
        row = []
        for c_ in range(cols + 1):
            u, v = c_ / cols, r_ / rows
            x = -cw / 2 + u * cw * (0.75 + 0.25 * v)
            y = 0.04 * math.sin(u * math.pi * 7) * (0.6 + 0.4 * v)
            row.append(bm.verts.new((x, y, -chh * (1 - v))))
        grid.append(row)
    for r_ in range(rows):
        for c_ in range(cols):
            bm.faces.new((grid[r_][c_], grid[r_][c_ + 1], grid[r_ + 1][c_ + 1], grid[r_ + 1][c_]))
    bm.to_mesh(cme); bm.free(); cme.shade_smooth()
    sheer_m = fabric(P + "SheerCream", "#EFDCC0", 0.8, sheen=0.5)
    sheer_m.node_tree.nodes["Principled BSDF"].inputs["Subsurface Weight"].default_value = 0.4
    _link(P + "Sheer", cme, sheer_m, (xl - 0.05, yb - 0.18, H - 0.15))
    cyl(P + "CurtainRod", 0.015, ww + 0.9, (wx, yb - 0.18, H - 0.12), brass, rot=(0, 90, 0))

    # bookcase (left) ----------------------------------------------------
    bx0, bx1, bd = -2.75, -1.05, 0.38
    by = yb - bd / 2
    bh = 3.0
    rbox(P + "CaseSideL", (0.05, bd, bh), (bx0 + 0.025, by, bh / 2), wood_d, r=0.01)
    rbox(P + "CaseSideR", (0.05, bd, bh), (bx1 - 0.025, by, bh / 2), wood_d, r=0.01)
    rbox(P + "CaseBack", (bx1 - bx0, 0.02, bh), ((bx0 + bx1) / 2, yb - 0.01, bh / 2), wood_d, r=0)
    rbox(P + "CaseTop", (bx1 - bx0 + 0.06, bd + 0.04, 0.05), ((bx0 + bx1) / 2, by - 0.01, bh), wood_d, r=0.012)
    books_b = Batch(P + "ShelfBooks")
    shelves = [0.08, 0.5, 0.92, 1.34, 1.76, 2.18, 2.6]
    for k, z in enumerate(shelves):
        rbox(P + "Shelf%d" % k, (bx1 - bx0 - 0.1, bd - 0.02, 0.035), ((bx0 + bx1) / 2, by, z), wood_d, r=0.006)
        if z < 2.7:
            gap_l = bx0 + 0.07
            gap_r = bx1 - 0.07 - (0.35 if k == 3 else 0.0)
            shelf_books(books_b, gap_l, gap_r, by - 0.02, z + 0.018, bd * 0.8, book_pal, rnd, 0.24, 0.34, gold=gold)
    books_b.build(bevel=0.003)
    # trinkets: globe-ish brass ball and little plant on shelf 3
    potted(P + "ShelfPlant", (bx1 - 0.25, by, shelves[3] + 0.02), pot_w, leaf2, soil, rnd, s=0.7)
    potted(P + "TopPlant", (bx0 + 0.45, by, bh + 0.025), pot_w, leaf, soil, rnd, s=1.0)
    for i in range(3):
        ivy(P + "Ivy%d" % i, (bx0 + 0.35 + i * 0.22, by - 0.12, bh + 0.15), 0.9 + 0.4 * i, leaf, stem, rnd, leaves=22)

    # armchair (left, angled) -------------------------------------------
    ch = empty(P + "Armchair", (-1.3, 0.6, 0))
    ch.rotation_euler = (0, 0, math.radians(-32))
    for lx, ly in [(-0.34, -0.3), (0.34, -0.3), (-0.34, 0.3), (0.34, 0.3)]:
        cyl(P + "ChairLeg%+.0f%+.0f" % (lx * 10, ly * 10), 0.025, 0.16, (lx, ly, 0.08), wood_d, r2=0.018, parent=ch)
    rbox(P + "ChairBase", (0.95, 0.85, 0.28), (0, 0, 0.3), sage_f, r=0.07, parent=ch, subd=1)
    rbox(P + "ChairSeat", (0.6, 0.74, 0.16), (0, -0.04, 0.5), sage_f, r=0.07, parent=ch, subd=1)
    rbox(P + "ChairBack", (0.95, 0.24, 0.9), (0, 0.34, 0.82), sage_f, r=0.1, parent=ch, subd=1, rot=(-8, 0, 0))
    for s in (-1, 1):
        rbox(P + "ChairArm%d" % s, (0.2, 0.86, 0.48), (s * 0.4, 0.0, 0.58), sage_f, r=0.09, parent=ch, subd=1)
        cyl(P + "ChairArmRoll%d" % s, 0.11, 0.86, (s * 0.4, 0.0, 0.8), sage_f, rot=(90, 0, 0), parent=ch)
    # knit throw over the left arm
    puff(P + "ThrowTop", (0.3, 0.6, 0.05), (-0.42, -0.02, 0.85), throw, parent=ch, level=2)
    puff(P + "ThrowHang", (0.05, 0.58, 0.55), (-0.56, -0.02, 0.6), throw, parent=ch, level=2)
    fb = Batch(P + "ThrowFringe")
    for i in range(12):
        fb.cyl(throw, 0.012, 0.09, (-0.565, -0.29 + i * 0.05, 0.3), segs=6, r2=0.006)
    fb.build(parent=ch)
    # lavender pillow with a gold star
    pil = puff(P + "Pillow", (0.42, 0.16, 0.38), (0.05, 0.2, 0.75), lav_f, parent=ch, level=3, rot=(-12, 0, 6))
    star_me = bpy.data.meshes.new(P + "StarMesh")
    sbm = bmesh.new()
    sv = []
    for i in range(10):
        a = math.pi / 2 + i * math.pi / 5
        r = 0.055 if i % 2 == 0 else 0.024
        sv.append(sbm.verts.new((r * math.cos(a), 0, r * math.sin(a))))
    sbm.faces.new(sv)
    bmesh.ops.solidify(sbm, geom=sbm.faces[:], thickness=0.006)
    sbm.to_mesh(star_me); sbm.free()
    _link(P + "PillowStar", star_me, gold, (0.06, 0.105, 0.77), (-12, 0, 6), parent=ch)

    # floor lamp (arc, tulip shade) --------------------------------------
    lx, ly = 0.95, 1.05
    revolve(P + "LampBase", [(0, 0), (0.16, 0), (0.16, 0.02), (0.12, 0.04), (0.03, 0.05), (0, 0.05)], (lx, ly, 0), brass)
    tube(P + "LampArc", [(lx, ly, 0.04), (lx, ly, 1.2), (lx - 0.05, ly, 1.85), (lx - 0.3, ly - 0.05, 2.05), (lx - 0.5, ly - 0.08, 1.88)], 0.016, brass)
    shade = scallop_shade(P + "LampShade", (lx - 0.5, ly - 0.08, 1.64), shade_m, r_top=0.06, r_bot=0.2, h=0.22)
    ball(P + "LampBulb", 0.045, (lx - 0.5, ly - 0.08, 1.72), bulb)
    tube(P + "LampChain", [(lx - 0.38, ly - 0.08, 1.7), (lx - 0.38, ly - 0.08, 1.55)], 0.003, brass)
    lamp_l = light(P + "LampLight", "POINT", (lx - 0.5, ly - 0.08, 1.66), 220, color=(1.0, 0.78, 0.5), size=0.06)

    # side table with tea & flowers (right) -------------------------------
    tx, ty = 1.55, 0.5
    revolve(P + "TableTop", [(0, 0), (0.34, 0), (0.35, 0.02), (0.34, 0.04), (0, 0.04)], (tx, ty, 0.62), wood_l)
    for i in range(3):
        a = i * 2 * math.pi / 3 + 0.3
        tube(P + "TableLeg%d" % i, [(tx + math.cos(a) * 0.24, ty + math.sin(a) * 0.24, 0.0), (tx + math.cos(a) * 0.17, ty + math.sin(a) * 0.17, 0.62)], 0.018, wood_l)
    teacup(P + "Tea", (tx - 0.12, ty - 0.12, 0.66), porcelain, tea, s=1.2)
    flowers(P + "Flowers", (tx + 0.1, ty + 0.05, 0.66), porcelain, soft(P + "Petal", "#FFFFFF", 0.5, sss=0.3), soft(P + "PetalCore", "#F2D36B", 0.5), leaf, rnd, n=9, s=1.3)
    book(P + "TableBook", (tx + 0.05, ty - 0.18, 0.67), (0.2, 0.15, 0.03), book_pal[0], page, rot=(0, 0, 12))

    # wall pictures + sill plants ----------------------------------------
    art = [("#E7D3A8", "#7FA36B"), ("#C9B5DB", "#6F5A8E"), ("#F0C9A0", "#C77A4A")]
    for i, (px, pz, pw, ph) in enumerate([(-0.55, 2.25, 0.46, 0.58), (0.05, 2.45, 0.34, 0.34), (0.05, 1.95, 0.34, 0.42)]):
        rbox(P + "Frame%d" % i, (pw + 0.07, 0.035, ph + 0.07), (px, yb - 0.02, pz), brass, r=0.01)
        bg_c, fg_c = art[i]
        box(P + "Art%d" % i, (pw, 0.01, ph), (px, yb - 0.04, pz), soft(P + "ArtBg%d" % i, bg_c, 0.8), bevel=0)
        # simple botanical motif: stem + leaves
        tube(P + "ArtStem%d" % i, [(px, yb - 0.047, pz - ph * 0.35), (px + 0.02, yb - 0.047, pz), (px - 0.01, yb - 0.047, pz + ph * 0.3)], 0.004, soft(P + "ArtFg%d" % i, fg_c, 0.8))
        ab = Batch(P + "ArtLeaves%d" % i)
        for k in range(5):
            zz = pz - ph * 0.25 + k * ph * 0.12
            sd = 1 if k % 2 else -1
            ab.sphere(soft(P + "ArtFg%d" % i, fg_c, 0.8), 0.035, (px + sd * 0.035, yb - 0.046, zz), scale=(1.0, 0.1, 0.45), rot=(0, sd * 35, 0), segs=10, rings=6)
        ab.build()
    potted(P + "SillPlantA", (wx - 0.4, yb - 0.12, zl - 0.075), soft(P + "PotTerra", "#C9785A", 0.6), leaf2, soil, rnd, s=0.7)
    flowers(P + "SillFlowers", (wx + 0.4, yb - 0.1, zl - 0.075), pot_w, soft(P + "PetalPink", "#F3C1CF", 0.5, sss=0.3), soft(P + "PetalCore2", "#F2D36B", 0.5), leaf, rnd, n=6, s=1.0)
    for i in range(4):
        ivy(P + "RodIvy%d" % i, (xl - 0.25 + i * 0.12, yb - 0.2, H - 0.12), 0.5 + 0.25 * (i % 3), leaf, stem, rnd, leaves=16, size=0.04)
    # rug, books, pet ------------------------------------------------------
    round_rug(P + "Rug", (0, 0.05, 0.0), 1.15, lav, lav_d, lav, rings=5, fringe=90, sx=1.25, sy=0.95)
    open_book(P + "OpenBook", (0.08, -0.55, 0.018), plum, page, rot=(0, 0, 4))
    book(P + "Stack1", (-0.72, -0.3, 0.035), (0.32, 0.24, 0.05), plum, page, rot=(0, 0, 10))
    book(P + "Stack2", (-0.7, -0.29, 0.09), (0.28, 0.22, 0.05), book_pal[2], page, rot=(0, 0, -6))
    book(P + "Stack3", (-0.72, -0.3, 0.14), (0.26, 0.2, 0.045), book_pal[7], page, rot=(0, 0, 18))
    spot = pet_spot(P, (0, 0.0, 0.02))
    stand_in_pet(P, (0, 0.0, 0.02), scale=1.3)

    # light ----------------------------------------------------------------
    light(P + "WindowSun", "AREA", (wx, yb + 0.4, wz + 0.2), 900, color=(1.0, 0.72, 0.42), size=1.4, rot=(-95, 0, 0))
    light(P + "SunShaft", "SPOT", (wx + 0.3, yb + 1.0, 2.6), 900, color=(1.0, 0.7, 0.4), size=0.3, rot=(-120, 0, 15))
    light(P + "Fill", "AREA", (0, -3.0, 2.4), 160, color=(1.0, 0.82, 0.65), size=3.0, rot=(60, 0, 0))
    light(P + "ShelfWarm", "AREA", (-1.9, 0.6, 2.7), 120, color=(1.0, 0.8, 0.6), size=1.2, rot=(10, 0, 0))
    # yarn basket by the armchair, glowing lantern by the table
    revolve(P + "Basket", [(0, 0), (0.2, 0), (0.24, 0.2), (0.25, 0.22), (0.23, 0.22), (0.2, 0.03), (0, 0.03)], (-0.85, -0.05, 0), knit(P + "Wicker", "#C99A62", "#A77B48", scale=22, strength=1.0))
    for i, (dx, dy, c) in enumerate([(-0.06, 0.02, "#B9A2D6"), (0.07, -0.03, "#E8B4A8"), (0.0, 0.08, "#9DBB9A")]):
        ball(P + "Yarn%d" % i, 0.085, (-0.85 + dx, -0.05 + dy, 0.24), knit(P + "YarnK%d" % i, c, c, scale=45, strength=1.0))
    tube(P + "YarnThread", [(-0.78, -0.1, 0.22), (-0.6, -0.3, 0.05), (-0.45, -0.38, 0.01)], 0.004, knit(P + "YarnK1", "#E8B4A8", "#E8B4A8", scale=45))
    lx2, ly2 = 0.85, -0.5
    rbox(P + "LanternBase", (0.2, 0.2, 0.03), (lx2, ly2, 0.015), brass, r=0.006)
    rbox(P + "LanternTop", (0.22, 0.22, 0.03), (lx2, ly2, 0.34), brass, r=0.006)
    cone(P + "LanternRoof", 0.15, 0.08, (lx2, ly2, 0.39), brass, verts=4, rot=(0, 0, 45))
    torus(P + "LanternRing", 0.03, 0.006, (lx2, ly2, 0.45), brass, rot=(90, 0, 0), seg=16, ring=8)
    for sx_, sy_ in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
        cyl(P + "LanternPost%d%d" % (sx_, sy_), 0.008, 0.3, (lx2 + sx_ * 0.09, ly2 + sy_ * 0.09, 0.18), brass)
    box(P + "LanternGlass", (0.17, 0.17, 0.28), (lx2, ly2, 0.18), soft(P + "LanternGlass", "#FFE9C4", 0.1, coat=1.0), bevel=0)
    revolve(P + "Candle", [(0, 0), (0.04, 0), (0.04, 0.1), (0, 0.1)], (lx2, ly2, 0.03), soft(P + "Wax", "#FFF1DC", 0.5, sss=0.5))
    ball(P + "Flame", 0.015, (lx2, ly2, 0.15), glow(P + "Flame", "#FFB860", 40.0), scale=(1, 1, 1.8))
    light(P + "LanternLight", "POINT", (lx2, ly2, 0.2), 25, color=(1.0, 0.65, 0.35), size=0.04)
    # foreground leaves for depth (out of focus)
    potted(P + "FrontPlant", (-0.95, -1.3, 0.0), pot_w, leaf, soil, rnd, s=2.0)
    cam(P + "Cam", (0.0, -2.75, 1.05), (0.0, 0.8, 0.82), 30, sc, dof_target=spot, fstop=2.8)
    return sc

# ================================================================== KITCHEN
# Blue tiles, sage cabinets, utensil rail, mugs, lemon tree. The pet stands
# behind a wooden table; food is served on the table in front of it.
def build_kitchen3():
    name = "Room_Kitchen3"
    clear_scene(name)
    sc = setup_scene(name)
    world_color(sc, "#3B3A40", 0.15)
    post_fx(sc, bloom=0.4, threshold=0.9)
    root = coll("Kitchen3", scene=sc)
    use(root)
    rnd = random.Random(5)
    P = "K3_"
    tile = tiles(P + "TileBlue", "#8EB1D6", "#9DBCDD", "#EEF2F5", scale=7.0)
    wall_up = fabric(P + "WallCream", "#D9CDB8", 0.9, sheen=0.0, scale=80)
    cab = soft(P + "CabSage", "#8FA88E", 0.5, coat=0.2)
    cab_d = soft(P + "CabSageDark", "#7A9479", 0.5, coat=0.2)
    top = wood(P + "Butcher", "#C99A68", "#A97A4C", scale=3.0, rough=0.4, stretch=(8, 1, 1), coat=0.3)
    table = wood(P + "TableOak", "#C08A58", "#9C6A3F", scale=2.5, rough=0.4, stretch=(1, 6, 1), coat=0.35)
    floor = planks(P + "Floor", "#A9784E", "#94653F")
    brass = soft(P + "Brass", "#D9AA5C", 0.25, metal=1.0)
    copper = soft(P + "Copper", "#C9784A", 0.25, metal=1.0)
    steel = soft(P + "Steel", "#C9CDD2", 0.25, metal=1.0)
    porcelain = soft(P + "Porcelain", "#FBF7F0", 0.2, coat=0.6)
    mug_cols = [soft(P + "Mug%d" % i, c, 0.3, coat=0.5) for i, c in enumerate(["#F3E6D2", "#E7C9C2", "#C8D7E8", "#F2EDE4"])]
    gingham = check(P + "Gingham", "#9D86C6", "#F4EEF8", scale=28.0)
    gingham2 = check(P + "GinghamBig", "#9D86C6", "#F4EEF8", scale=14.0)
    leaf = soft(P + "Leaf", "#5E8F4E", 0.5, sss=0.2)
    lemon = soft(P + "Lemon", "#D9DE6A", 0.45, sss=0.2)
    pot = soft(P + "PotPaint", "#F1EADF", 0.35, coat=0.5)
    soil = soft(P + "Soil", "#3B2A20", 0.95)
    jam = soft(P + "JamGlass", "#B8323F", 0.1, coat=1.0, sss=0.4)
    jam_in = soft(P + "Jam", "#9E2236", 0.15, sss=0.5)
    berry_b = soft(P + "Blueberry", "#3F4A8A", 0.35, coat=0.6)
    berry_s = soft(P + "Strawberry", "#D3363A", 0.25, coat=0.7, sss=0.3)
    berry_r = soft(P + "Raspberry", "#D94468", 0.4, sss=0.4)
    leafc = soft(P + "Calyx", "#4F8A3A", 0.5)

    W, H = 5.0, 3.4
    yb = 1.3
    rbox(P + "Floor", (W, 5.0, 0.1), (0, yb - 2.5, -0.05), floor, r=0)
    box(P + "WallBack", (W, 0.1, H), (0, yb + 0.05, H / 2), wall_up, bevel=0)
    box(P + "TileWall", (W, 0.02, 2.5), (0, yb - 0.01, 0.92 + 1.25), tile, bevel=0)
    for s in (-1, 1):
        box(P + "WallSide%d" % s, (0.1, 5.0, H), (s * (W / 2 + 0.05), yb - 2.5, H / 2), wall_up, bevel=0)

    # counter run ---------------------------------------------------------
    cd = 0.62
    cy = yb - cd / 2
    rbox(P + "CounterBody", (W, cd, 0.86), (0, cy, 0.43), cab, r=0.01)
    rbox(P + "Toe", (W, 0.05, 0.1), (0, yb - cd + 0.03, 0.05), soft(P + "ToeDark", "#5A6B58", 0.6), r=0.0)
    rbox(P + "Countertop", (W, cd + 0.04, 0.06), (0, cy - 0.02, 0.89), top, r=0.012)
    for i in range(6):
        cx = -2.1 + i * 0.84
        rbox(P + "Door%d" % i, (0.78, 0.03, 0.56), (cx, yb - cd - 0.01, 0.42), cab_d, r=0.01)
        rbox(P + "DoorInset%d" % i, (0.62, 0.02, 0.4), (cx, yb - cd - 0.025, 0.42), cab, r=0.01)
        rbox(P + "Drawer%d" % i, (0.78, 0.03, 0.14), (cx, yb - cd - 0.01, 0.79), cab_d, r=0.01)
        tube(P + "Pull%d" % i, [(cx - 0.07, yb - cd - 0.03, 0.79), (cx, yb - cd - 0.045, 0.79), (cx + 0.07, yb - cd - 0.03, 0.79)], 0.007, brass)
    # left tall cabinet with gingham curtain
    rbox(P + "TallCab", (0.9, cd + 0.05, 2.3), (-2.05, cy, 1.15), cab, r=0.015)
    cme = bpy.data.meshes.new(P + "CabCurtain")
    bm = bmesh.new()
    cols, rows = 36, 10
    grid = []
    for r_ in range(rows + 1):
        row = []
        for c_ in range(cols + 1):
            u, v = c_ / cols, r_ / rows
            row.append(bm.verts.new((-0.38 + u * 0.76, 0.02 * math.sin(u * math.pi * 9), 0.7 * v)))
        grid.append(row)
    for r_ in range(rows):
        for c_ in range(cols):
            bm.faces.new((grid[r_][c_], grid[r_][c_ + 1], grid[r_ + 1][c_ + 1], grid[r_ + 1][c_]))
    bm.to_mesh(cme); bm.free(); cme.shade_smooth()
    _link(P + "CabCurtain", cme, gingham2, (-2.05, yb - cd - 0.06, 1.05))
    cyl(P + "CabRod", 0.008, 0.82, (-2.05, yb - cd - 0.06, 1.77), brass, rot=(0, 90, 0))

    # open shelf with mugs + jars ----------------------------------------
    sz = 2.15
    rbox(P + "Shelf", (2.6, 0.26, 0.045), (0.4, yb - 0.13, sz), top, r=0.01)
    for bx in (-0.7, 1.5):
        rbox(P + "Bracket%+.1f" % bx, (0.04, 0.2, 0.18), (bx, yb - 0.1, sz - 0.11), brass, r=0.008)
    # mug hooks under shelf
    for i, x in enumerate([-0.45, -0.2, 0.05, 0.3]):
        g = empty(P + "HangMug%d" % i, (x, yb - 0.14, sz - 0.2))
        g.rotation_euler = (math.radians(180), 0, math.radians(rnd.uniform(-10, 10)))
        revolve(P + "HMug%d" % i, [(0, 0), (0.035, 0), (0.042, 0.02), (0.042, 0.1), (0.039, 0.1), (0.036, 0.02), (0, 0.012)], (0, 0, -0.04), mug_cols[i % 4], parent=g)
        torus(P + "HMugH%d" % i, 0.025, 0.006, (0.045, 0, 0.05 - 0.04), mug_cols[i % 4], rot=(90, 0, 0), parent=g, seg=16, ring=8)
        tube(P + "Hook%d" % i, [(x, yb - 0.14, sz - 0.02), (x, yb - 0.14, sz - 0.1)], 0.003, brass)
    # jars and a teapot on top
    for i, (x, hh, c) in enumerate([(0.75, 0.2, "#E9C46A"), (0.95, 0.16, "#D9A15A"), (1.12, 0.22, "#B9784E")]):
        revolve(P + "Jar%d" % i, [(0, 0), (0.06, 0), (0.065, 0.01), (0.065, hh), (0.05, hh + 0.02), (0, hh + 0.02)], (x, yb - 0.13, sz + 0.023), soft(P + "JarGlass", "#E9EEEC", 0.1, coat=1.0))
        cyl(P + "JarFill%d" % i, 0.058, hh * 0.7, (x, yb - 0.13, sz + 0.023 + hh * 0.35), soft(P + "Grain%d" % i, c, 0.8))
        cyl(P + "JarLid%d" % i, 0.055, 0.03, (x, yb - 0.13, sz + hh + 0.05), top)
    revolve(P + "Teapot", [(0, 0), (0.08, 0), (0.11, 0.06), (0.1, 0.13), (0.05, 0.17), (0.02, 0.19), (0, 0.19)], (1.4, yb - 0.13, sz + 0.023), soft(P + "TeapotMint", "#A9D1C3", 0.3, coat=0.6))
    tube(P + "TeapotSpout", [(1.48, yb - 0.13, sz + 0.08), (1.56, yb - 0.13, sz + 0.13), (1.59, yb - 0.13, sz + 0.17)], 0.015, soft(P + "TeapotMint", "#A9D1C3", 0.3, coat=0.6))
    # utensil rail
    rz = 1.62
    cyl(P + "Rail", 0.01, 1.2, (-0.6, yb - 0.06, rz), brass, rot=(0, 90, 0))
    for i, (x, kind) in enumerate([(-1.05, "ladle"), (-0.8, "whisk"), (-0.55, "spatula"), (-0.3, "ladle")]):
        tube(P + "UHook%d" % i, [(x, yb - 0.06, rz), (x, yb - 0.08, rz - 0.04)], 0.003, brass)
        m = copper if kind == "ladle" else steel
        tube(P + "UHandle%d" % i, [(x, yb - 0.08, rz - 0.04), (x, yb - 0.08, rz - 0.38)], 0.009, m)
        if kind == "ladle":
            ball(P + "UBowl%d" % i, 0.05, (x, yb - 0.1, rz - 0.42), m, scale=(1, 0.6, 0.7))
        elif kind == "whisk":
            for k in range(6):
                a = k * math.pi / 6
                tube(P + "UWire%d_%d" % (i, k), [(x, yb - 0.08, rz - 0.38), (x + 0.04 * math.cos(a), yb - 0.08 + 0.02 * math.sin(a), rz - 0.5), (x, yb - 0.08, rz - 0.6)], 0.002, steel)
        else:
            rbox(P + "USpat%d" % i, (0.07, 0.01, 0.1), (x, yb - 0.08, rz - 0.44), top, r=0.004)
    # counter props: jam jar, cup, napkin, lemon tree, cutting board, bread
    revolve(P + "JamJar", [(0, 0), (0.06, 0), (0.065, 0.01), (0.065, 0.13), (0.055, 0.15), (0, 0.15)], (-1.1, yb - 0.3, 0.92), jam)
    cyl(P + "JamFill", 0.058, 0.11, (-1.1, yb - 0.3, 0.92 + 0.06), jam_in)
    cyl(P + "JamLid", 0.06, 0.03, (-1.1, yb - 0.3, 1.085), check(P + "JamCloth", "#D25A5A", "#FFFFFF", 40.0))
    teacup(P + "Cup", (-0.75, yb - 0.32, 0.92), porcelain, soft(P + "Tea", "#8A4B22", 0.1), s=1.4)
    rbox(P + "Napkin", (0.32, 0.26, 0.01), (-0.95, yb - 0.32, 0.925), gingham, r=0.004, rot=(0, 0, 8))
    rbox(P + "Board", (0.42, 0.03, 0.55), (0.25, yb - 0.04, 1.18), top, r=0.015, rot=(-8, 0, 0))
    potted(P + "Lemon", (1.15, yb - 0.3, 0.92), pot, leaf, soil, rnd, s=1.7, kind="tree", m_fruit=lemon)
    # painted leaf on the pot
    potted(P + "Herbs", (0.62, yb - 0.32, 0.92), soft(P + "PotTerra", "#C9785A", 0.6), soft(P + "Basil", "#6FAF55", 0.5, sss=0.2), soil, rnd, s=0.8)

    # pendant lamp over the table + bread on the counter
    tube(P + "PendCord", [(0.0, -0.3, 3.4), (0.0, -0.3, 2.35)], 0.005, soft(P + "Cord", "#3A302A", 0.6))
    scallop_shade(P + "PendShade", (0.0, -0.3, 2.1), glow(P + "PendGlow", "#FFD49A", 0.6, base="#E9D7BC"), r_top=0.05, r_bot=0.24, h=0.26)
    ball(P + "PendBulb", 0.05, (0.0, -0.3, 2.18), glow(P + "PendBulbM", "#FFE2B0", 6.0))
    light(P + "PendLight", "POINT", (0.0, -0.3, 2.12), 90, color=(1.0, 0.8, 0.55), size=0.05)
    ball(P + "Bread", 0.13, (-0.35, yb - 0.32, 0.98), soft(P + "Crust", "#C98A4A", 0.6), scale=(1.4, 0.8, 0.55))
    for k in range(3):
        cyl(P + "BreadCut%d" % k, 0.008, 0.2, (-0.43 + k * 0.08, yb - 0.32, 1.04), soft(P + "Crumb", "#EBCB94", 0.7), rot=(90, 0, 20))
    # front table + food ----------------------------------------------------
    TZ = 0.5   # low table: the pet's head and paws rise above it
    rbox(P + "TableTop", (2.4, 0.9, 0.07), (0, -0.62, TZ - 0.035), table, r=0.02)
    rbox(P + "Placemat", (0.62, 0.42, 0.006), (0, -0.62, TZ + 0.003), gingham2, r=0.003, rot=(0, 0, -3))
    revolve(P + "Bowl", [(0, 0), (0.07, 0), (0.08, 0.01), (0.15, 0.08), (0.16, 0.1), (0.15, 0.102), (0.07, 0.03), (0, 0.025)], (0, -0.62, TZ + 0.006), porcelain)
    fb = Batch(P + "Berries")
    for i in range(14):
        a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(0.0, 0.1)
        zc = TZ + 0.006 + 0.08 + 0.02 * (1 - r / 0.1)
        kind = i % 3
        if kind == 0:
            fb.sphere(berry_b, 0.025, (math.cos(a) * r, -0.62 + math.sin(a) * r, zc), segs=12, rings=8)
        elif kind == 1:
            fb.sphere(berry_s, 0.035, (math.cos(a) * r, -0.62 + math.sin(a) * r, zc + 0.01), scale=(1, 1, 1.25), rot=(rnd.uniform(-30, 30), rnd.uniform(-30, 30), 0), segs=12, rings=8)
        else:
            fb.sphere(berry_r, 0.028, (math.cos(a) * r, -0.62 + math.sin(a) * r, zc), scale=(1, 1, 1.1), segs=12, rings=8)
    fb.sphere(berry_s, 0.04, (0.34, -0.55, TZ + 0.04), scale=(1, 1, 1.25), rot=(70, 0, 30), segs=12, rings=8)
    fb.sphere(berry_b, 0.026, (0.26, -0.47, TZ + 0.026), segs=12, rings=8)
    fb.sphere(berry_b, 0.026, (0.29, -0.42, TZ + 0.026), segs=12, rings=8)
    fb.build()
    spot = pet_spot(P, (0, 0.05, 0.0))
    stand_in_pet(P, (0, 0.05, 0.0), scale=1.3)

    # light -----------------------------------------------------------------
    light(P + "WindowLeft", "AREA", (-2.4, -0.6, 2.2), 380, color=(1.0, 0.95, 0.88), size=2.0, rot=(0, -70, 0))
    light(P + "UnderShelf", "AREA", (0.4, yb - 0.2, sz - 0.05), 80, color=(1.0, 0.82, 0.6), size=1.8, rot=(0, 0, 0))
    light(P + "Fill", "AREA", (0.5, -3.0, 2.2), 110, color=(1.0, 0.92, 0.85), size=3.0, rot=(65, 0, 8))
    light(P + "Rim", "AREA", (1.6, 0.9, 1.9), 150, color=(1.0, 0.85, 0.7), size=1.0, rot=(-50, 0, 150))
    cam(P + "Cam", (0.0, -2.3, 1.0), (0.0, 0.5, 0.95), 32, sc, dof_target=spot, fstop=3.2)
    return sc

# ================================================================== ATTIC BEDROOM
# Night: sloped wooden ceiling with a skylight (moon, stars), lavender walls,
# round pet bed with a knitted starry blanket, tulip lamp, little-house light.
def _star_mesh(name, r1=0.06, r2=0.026, thick=0.012):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    vs = []
    for i in range(10):
        a = math.pi / 2 + i * math.pi / 5
        r = r1 if i % 2 == 0 else r2
        vs.append(bm.verts.new((r * math.cos(a), 0, r * math.sin(a))))
    f = bm.faces.new(vs)
    bmesh.ops.solidify(bm, geom=[f], thickness=thick)
    bm.to_mesh(me); bm.free()
    return me

def build_bedroom3():
    name = "Room_Bedroom3"
    clear_scene(name)
    sc = setup_scene(name)
    world_color(sc, "#1C1F3A", 0.25)
    post_fx(sc, bloom=0.8, threshold=0.6)
    root = coll("Bedroom3", scene=sc)
    use(root)
    rnd = random.Random(9)
    P = "B3_"
    wall = fabric(P + "WallLilac", "#6F6390", 0.9, sheen=0.0, scale=80)
    panel = wood(P + "PanelPlum", "#5D4C80", "#544576", scale=2.0, rough=0.6, stretch=(8, 1, 1))
    roof = wood(P + "RoofPine", "#C9A27A", "#B08660", scale=2.5, rough=0.55, stretch=(1, 6, 1))
    beam = wood(P + "Beam", "#8A6244", "#70503A", scale=2.5, rough=0.6)
    floor = planks(P + "Floor", "#7D5A43", "#6C4C38")
    brass = soft(P + "Brass", "#D9AA5C", 0.25, metal=1.0)
    knit_p = knit(P + "KnitPlum", "#7A58A6", "#5E4486", scale=16, strength=1.2)
    knit_c = knit(P + "KnitCream", "#E9DCC8", "#CDBDA4", scale=16, strength=1.2)
    lav = fabric(P + "CushionLav", "#9A86C2", 0.8, sheen=0.9)
    gold = glow(P + "StarGold", "#F6C95A", 1.2, base="#E7B44E")
    leaf = soft(P + "Leaf", "#4F7F4A", 0.55, sss=0.2)
    stem = soft(P + "Stem", "#3F5E37", 0.7)
    page = soft(P + "Paper", "#F2E8D5", 0.8)
    pot = soft(P + "Pot", "#DCCFE6", 0.4, coat=0.5)
    soil = soft(P + "Soil", "#3B2A20", 0.95)
    shade_m = glow(P + "ShadeGlow", "#FFC88A", 6.0, base="#FFE7C7")
    bulb = glow(P + "Bulb", "#FFD9A0", 30.0)
    win_glow = glow(P + "HouseWin", "#FFC46B", 12.0)
    night = sky(P + "NightSky", "#0F1638", "#2A3A78", strength=1.2)

    W, H = 5.0, 3.6
    yb = 1.5
    rbox(P + "Floor", (W, 5.0, 0.1), (0, yb - 2.5, -0.05), floor, r=0)
    box(P + "WallBack", (W, 0.1, H), (0, yb + 0.05, H / 2), wall, bevel=0)
    for s in (-1, 1):
        box(P + "WallSide%d" % s, (0.1, 5.0, H), (s * (W / 2 + 0.05), yb - 2.5, H / 2), wall, bevel=0)
    # lower vertical boards
    pb = Batch(P + "Boards")
    for i in range(int(W / 0.16)):
        pb.cube(panel, (0.15, 0.03, 0.95), (-W / 2 + 0.08 + i * 0.16, yb - 0.015, 0.475))
    pb.build(bevel=0.006)
    rbox(P + "BoardCap", (W, 0.07, 0.05), (0, yb - 0.035, 0.97), beam, r=0.01)

    # sloped roof on the right with a skylight --------------------------
    # slope plane: passes through (x=-0.2, z=H) and (x=2.5, z=1.6)
    ang = math.degrees(math.atan2(H - 1.6, 2.7))
    cx, cz = 1.15, (H + 1.6) / 2
    slope_len = math.hypot(2.7, H - 1.6)
    roof_g = empty(P + "Roof", (cx, yb - 1.4, cz))
    roof_g.rotation_euler = (0, math.radians(ang), 0)
    # roof boards with a skylight opening (u along slope, v along y)
    sk_u0, sk_u1 = -0.9, 0.35
    sk_v0, sk_v1 = 0.4, 1.5
    rb = Batch(P + "RoofBoards")
    nb = 22
    for i in range(nb):
        v = -1.3 + i * 0.13
        if sk_v0 < v < sk_v1:
            rb.cube(roof, (sk_u0 + slope_len / 2, 0.12, 0.04), ((-slope_len / 2 + sk_u0) / 2, v, 0))
            rb.cube(roof, (slope_len / 2 - sk_u1, 0.12, 0.04), ((sk_u1 + slope_len / 2) / 2, v, 0))
        else:
            rb.cube(roof, (slope_len, 0.12, 0.04), (0, v, 0))
    rb.build(bevel=0.005, parent=roof_g)
    for k, v in enumerate([-1.3, 0.0, 1.45]):
        rbox(P + "Rafter%d" % k, (slope_len, 0.12, 0.14), (0, v, -0.08), beam, r=0.015, parent=roof_g)
    fr = soft(P + "SkyFrame", "#7A5A44", 0.55)
    for nme, sz, lc in [("A", (sk_u1 - sk_u0 + 0.1, 0.07, 0.1), ((sk_u0 + sk_u1) / 2, sk_v0, -0.02)),
                        ("B", (sk_u1 - sk_u0 + 0.1, 0.07, 0.1), ((sk_u0 + sk_u1) / 2, sk_v1, -0.02)),
                        ("C", (0.07, sk_v1 - sk_v0, 0.1), (sk_u0, (sk_v0 + sk_v1) / 2, -0.02)),
                        ("D", (0.07, sk_v1 - sk_v0, 0.1), (sk_u1, (sk_v0 + sk_v1) / 2, -0.02)),
                        ("M", (0.04, sk_v1 - sk_v0, 0.05), ((sk_u0 + sk_u1) / 2, (sk_v0 + sk_v1) / 2, -0.01)),
                        ("N", (sk_u1 - sk_u0, 0.04, 0.05), ((sk_u0 + sk_u1) / 2, (sk_v0 + sk_v1) / 2, -0.01))]:
        rbox(P + "Sky" + nme, sz, lc, fr, r=0.01, parent=roof_g)
    # night sky card + moon + stars above the skylight
    box(P + "NightCard", (6.0, 6.0, 0.02), (0, 0, 2.2), night, bevel=0, parent=roof_g)
    sb = Batch(P + "Stars")
    star_m = glow(P + "StarDot", "#FFF4D0", 15.0)
    for i in range(60):
        sb.sphere(star_m, rnd.uniform(0.006, 0.015), (rnd.uniform(-1.5, 1.0), rnd.uniform(-0.5, 2.5), 2.15), segs=6, rings=4)
    sb.build(parent=roof_g)
    ball(P + "Moon", 0.16, ((sk_u0 + sk_u1) / 2 + 0.25, (sk_v0 + sk_v1) / 2 + 0.25, 2.1), glow(P + "MoonGlow", "#FFF2CF", 8.0), parent=roof_g, scale=(1, 1, 0.2))
    # side wall under the slope (knee wall) hides the gap
    box(P + "KneeWall", (0.1, 5.0, 1.6), (2.45, yb - 2.5, 0.8), wall, bevel=0)

    # left: framed moon picture + shelf with little house --------------------
    rbox(P + "PicFrame", (0.42, 0.035, 0.52), (-1.25, yb - 0.02, 2.05), brass, r=0.01)
    box(P + "Pic", (0.36, 0.01, 0.46), (-1.25, yb - 0.04, 2.05), soft(P + "PicNavy", "#3A3566", 0.8), bevel=0)
    moon_me = bpy.data.meshes.new(P + "PicMoon")
    bm = bmesh.new()
    vs = []
    for i in range(24):
        a = math.radians(40 + i * 280 / 23)
        vs.append(bm.verts.new((0.09 * math.cos(a), 0, 0.09 * math.sin(a))))
    for i in range(23, -1, -1):
        a = math.radians(40 + i * 280 / 23)
        vs.append(bm.verts.new((0.03 + 0.065 * math.cos(a), 0, 0.065 * math.sin(a))))
    bm.faces.new(vs)
    bm.to_mesh(moon_me); bm.free()
    _link(P + "PicMoonObj", moon_me, gold, (-1.27, yb - 0.046, 2.1), (0, 0, 0))
    for i, (sx, sz) in enumerate([(-1.13, 2.2), (-1.36, 1.92), (-1.12, 1.9)]):
        _link(P + "PicStar%d" % i, _star_mesh(P + "PicStarMe%d" % i, 0.022, 0.01, 0.003), gold, (sx, yb - 0.046, sz))
    rbox(P + "WallShelf", (0.9, 0.22, 0.04), (-0.15, yb - 0.11, 1.65), beam, r=0.01)
    hx = 0.05
    rbox(P + "House", (0.22, 0.16, 0.2), (hx, yb - 0.11, 1.77), soft(P + "HouseWood", "#B98A62", 0.6), r=0.01)
    for s in (-1, 1):
        rbox(P + "HouseRoof%d" % s, (0.16, 0.2, 0.025), (hx + s * 0.06, yb - 0.11, 1.92), beam, r=0.006, rot=(0, -s * 40, 0))
    for i, (dx, dz) in enumerate([(-0.05, 1.79), (0.05, 1.79), (0.0, 1.72)]):
        box(P + "HouseWin%d" % i, (0.045, 0.01, 0.045), (hx + dx, yb - 0.195, dz), win_glow, bevel=0)
    light(P + "HouseLight", "POINT", (hx, yb - 0.3, 1.78), 15, color=(1.0, 0.72, 0.4), size=0.05)
    revolve(P + "Jar", [(0, 0), (0.05, 0), (0.055, 0.02), (0.055, 0.14), (0.035, 0.17), (0, 0.17)], (-0.4, yb - 0.11, 1.67), soft(P + "JarClay", "#C9B6DE", 0.4, coat=0.5))
    book(P + "ShelfBook", (-0.2, yb - 0.11, 1.69), (0.18, 0.13, 0.04), soft(P + "BkPlum", "#4B3266", 0.5), page)
    potted(P + "Ivy", (-0.62, yb - 0.11, 1.67), pot, leaf, soil, rnd, s=0.6)
    for i in range(3):
        ivy(P + "IvyHang%d" % i, (-0.68 + i * 0.06, yb - 0.2, 1.82), 0.6 + 0.2 * i, leaf, stem, rnd, leaves=14, size=0.035)
    # star pendant hanging from the slope
    tube(P + "StarString", [(0.75, yb - 0.6, 3.25), (0.75, yb - 0.6, 2.45)], 0.002, brass)
    _link(P + "StarPendant", _star_mesh(P + "StarPendMe", 0.09, 0.04, 0.025), glow(P + "StarPendGlow", "#FFD77A", 6.0), (0.75, yb - 0.6, 2.38))
    light(P + "StarLight", "POINT", (0.75, yb - 0.7, 2.38), 10, color=(1.0, 0.85, 0.5), size=0.05)

    # nightstand + tulip lamp (left) ----------------------------------------
    nx, ny = -1.15, 0.6
    rbox(P + "Nightstand", (0.55, 0.45, 0.55), (nx, ny, 0.275), beam, r=0.02)
    rbox(P + "NSDrawer", (0.47, 0.02, 0.18), (nx, ny - 0.23, 0.38), soft(P + "NSFront", "#7A5A44", 0.55), r=0.01)
    ball(P + "NSKnob", 0.018, (nx, ny - 0.25, 0.38), brass)
    revolve(P + "LampBase", [(0, 0), (0.09, 0), (0.09, 0.015), (0.03, 0.03), (0, 0.03)], (nx + 0.08, ny + 0.05, 0.55), brass)
    tube(P + "LampNeck", [(nx + 0.08, ny + 0.05, 0.58), (nx + 0.08, ny + 0.05, 0.85), (nx + 0.16, ny + 0.02, 1.0), (nx + 0.3, ny, 0.98)], 0.01, brass)
    scallop_shade(P + "LampShade", (nx + 0.3, ny, 0.78), shade_m, r_top=0.05, r_bot=0.15, h=0.18)
    ball(P + "LampBulb", 0.035, (nx + 0.3, ny, 0.84), bulb)
    light(P + "LampLight", "POINT", (nx + 0.3, ny - 0.05, 0.8), 320, color=(1.0, 0.72, 0.42), size=0.05)
    book(P + "NSBook", (nx - 0.1, ny - 0.05, 0.57), (0.2, 0.15, 0.035), soft(P + "BkTeal", "#3F6A78", 0.5), page, rot=(0, 0, -14))

    # round pet bed with starry knitted blanket ------------------------------
    bx, by = 0.15, 0.1
    bed = empty(P + "PetBed", (bx, by, 0))
    revolve(P + "BedBase", [(0, 0), (0.62, 0), (0.66, 0.05), (0.66, 0.1), (0, 0.1)], (0, 0, 0), knit_c, parent=bed)
    torus(P + "BedRim", 0.56, 0.17, (0, 0, 0.2), knit_c, parent=bed, seg=64, ring=24, scale=(1, 0.9, 1))
    revolve(P + "BedCushion", [(0, 0.08), (0.42, 0.08), (0.46, 0.14), (0.42, 0.2), (0, 0.2)], (0, 0, 0), lav, parent=bed, scale=(1, 0.9, 1))
    # blanket: draped over the front of the rim
    me = bpy.data.meshes.new(P + "Blanket")
    bm = bmesh.new()
    # profile (y, z) of the blanket: inside the bed → over the front rim → down to the floor
    prof = [(0.2, 0.24), (-0.05, 0.27), (-0.3, 0.33), (-0.48, 0.41), (-0.62, 0.38), (-0.74, 0.27), (-0.8, 0.13), (-0.82, 0.04)]
    seg_len = [math.dist(prof[i], prof[i + 1]) for i in range(len(prof) - 1)]
    total = sum(seg_len)
    def along(s):
        for i, L in enumerate(seg_len):
            if s <= L or i == len(seg_len) - 1:
                f = min(s / L, 1.0)
                return (prof[i][0] + (prof[i + 1][0] - prof[i][0]) * f, prof[i][1] + (prof[i + 1][1] - prof[i][1]) * f)
            s -= L
    cols, rows = 40, 30
    grid = []
    for r_ in range(rows + 1):
        row = []
        v = r_ / rows
        yy, zz = along(v * total)
        for c_ in range(cols + 1):
            u = c_ / cols - 0.5
            x = u * (0.95 + 0.2 * v)
            # follow the round rim: the sides curl back
            yv = yy + 0.35 * (u * 2) ** 2 * (0.5 if v > 0.35 else 0.2)
            zv = zz - 0.06 * (u * 2) ** 2
            yv += 0.025 * math.sin(u * 14 + v * 3) * v
            row.append(bm.verts.new((x, yv, zv)))
        grid.append(row)
    for r_ in range(rows):
        for c_ in range(cols):
            bm.faces.new((grid[r_][c_], grid[r_][c_ + 1], grid[r_ + 1][c_ + 1], grid[r_ + 1][c_]))
    bm.to_mesh(me); bm.free(); me.shade_smooth()
    bl = _link(P + "Blanket", me, knit_p, (0, 0, 0), parent=bed)
    so = bl.modifiers.new("Solid", "SOLIDIFY"); so.thickness = 0.035
    sd = bl.modifiers.new("Subd", "SUBSURF"); sd.levels = 2; sd.render_levels = 2
    tx_ = bpy.data.textures.get(P + "Folds") or bpy.data.textures.new(P + "Folds", "CLOUDS")
    tx_.noise_scale = 0.18
    dp = bl.modifiers.new("Folds", "DISPLACE"); dp.texture = tx_; dp.strength = 0.035; dp.mid_level = 0.5
    # stars on the blanket + tassels on its hem
    for i in range(6):
        u = -0.5 + i * 0.2 + rnd.uniform(-0.03, 0.03)
        st = _link(P + "BlanketStar%d" % i, _star_mesh(P + "BStarMe%d" % i, 0.04, 0.018, 0.004), gold, (u * 1.1, -0.78 - 0.01 * (i % 2), 0.2 + 0.07 * (i % 2)), (12, 0, rnd.uniform(-20, 20)), parent=bed)
    tb = Batch(P + "Tassels")
    for i in range(14):
        x = -0.62 + i * 0.095
        tb.sphere(knit_p, 0.02, (x, -0.84, 0.035), segs=8, rings=6)
        tb.cyl(knit_p, 0.012, 0.05, (x, -0.86, 0.01), r2=0.022, segs=8, rot=(90, 0, 0))
    tb.build(parent=bed)
    spot = pet_spot(P, (bx, by + 0.05, 0.2))
    stand_in_pet(P, (bx, by + 0.05, 0.2), scale=1.1)

    # fairy lights along the front rafter, mushroom lamp on the floor
    fl = Batch(P + "Fairy")
    bulbs = [glow(P + "FairyW", "#FFD27A", 18.0), glow(P + "FairyP", "#FFB3C8", 14.0)]
    for i in range(18):
        u = i / 17
        x = -2.3 + 4.4 * u
        z = 2.8 - 0.18 * math.sin(math.pi * (u * 3 % 1))
        fl.sphere(bulbs[i % 2], 0.022, (x, yb - 0.12, z), segs=8, rings=6)
    fl.build()
    tube(P + "FairyWire", [(-2.3, yb - 0.11, 2.8), (-1.6, yb - 0.11, 2.63), (-0.85, yb - 0.11, 2.8), (-0.1, yb - 0.11, 2.63), (0.6, yb - 0.11, 2.8), (1.35, yb - 0.11, 2.63), (2.1, yb - 0.11, 2.8)], 0.003, soft(P + "Wire", "#3A3A3A", 0.5))
    light(P + "FairyGlow", "AREA", (0, yb - 0.3, 3.05), 40, color=(1.0, 0.8, 0.55), size=4.0, rot=(0, 0, 0))
    mx, my = -0.78, -0.62
    revolve(P + "MushStem", [(0, 0), (0.07, 0), (0.05, 0.05), (0.045, 0.2), (0, 0.2)], (mx, my, 0), soft(P + "MushStemM", "#F3E6D2", 0.5, sss=0.4))
    revolve(P + "MushCap", [(0.0, 0.0), (0.2, 0.0), (0.21, 0.02), (0.17, 0.11), (0.09, 0.17), (0, 0.19)], (mx, my, 0.18), glow(P + "MushCapGlow", "#FF9C8A", 2.5, base="#F08A7C"))
    sp_ = Batch(P + "MushDots")
    for i in range(9):
        a = i * 2 * math.pi / 9 + 0.3
        rr = 0.12 if i % 2 else 0.07
        sp_.sphere(soft(P + "MushDot", "#FFF6EA", 0.5), 0.022, (mx + math.cos(a) * rr, my + math.sin(a) * rr, 0.18 + 0.16 - rr * 0.55), scale=(1, 1, 0.4), segs=8, rings=6)
    sp_.build()
    light(P + "MushLight", "POINT", (mx, my, 0.15), 40, color=(1.0, 0.6, 0.45), size=0.05)
    # floor props: pouf, books, rug ----------------------------------------
    revolve(P + "Pouf", [(0, 0), (0.3, 0), (0.34, 0.08), (0.34, 0.22), (0.3, 0.3), (0, 0.31)], (1.45, -0.35, 0), knit_p)
    book(P + "FloorBook1", (-0.95, -0.55, 0.03), (0.3, 0.22, 0.05), soft(P + "BkLav", "#8C74B8", 0.5), page, rot=(0, 0, 18))
    book(P + "FloorBook2", (-0.93, -0.55, 0.08), (0.26, 0.2, 0.045), soft(P + "BkPlum2", "#4B3266", 0.5), page, rot=(0, 0, 4))
    round_rug(P + "Rug", (0.15, -0.1, 0.0), 1.25, knit(P + "RugLav", "#8F7BB6", "#7C68A3", scale=60, strength=0.5), knit(P + "RugLavD", "#7A66A2", "#6A5791", scale=60, strength=0.5), knit_c, rings=4, fringe=90, sx=1.2, sy=0.95)

    # light ---------------------------------------------------------------------
    light(P + "Moonlight", "AREA", (1.3, yb - 0.6, 3.3), 220, color=(0.6, 0.7, 1.0), size=1.0, rot=(-25, 30, 0))
    light(P + "Fill", "AREA", (0, -3.0, 2.2), 35, color=(0.75, 0.7, 1.0), size=3.0, rot=(65, 0, 0))
    light(P + "WarmBounce", "AREA", (-1.0, -0.6, 0.4), 70, color=(1.0, 0.7, 0.45), size=1.0, rot=(-80, 0, 0))
    cam(P + "Cam", (0.0, -2.5, 1.15), (0.1, 0.6, 0.85), 30, sc, dof_target=spot, fstop=3.2)
    return sc
