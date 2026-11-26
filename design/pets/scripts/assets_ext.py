# Сцены Питомника из готовых CC0-ассетов (Poly Pizza: Quaternius, Kenney, CreativeTrio,
# Kay/Isa Lousberg). Модели лежат в design/pets/assets_ext/polypizza/<категория>/<имя>.glb,
# список и авторы — manifest.tsv и CREDITS.md рядом.
#
# Запуск в Blender (MCP или Text Editor):
#   exec(open(r"F:/project/PepeHub/design/pets/scripts/assets_ext.py", encoding="utf-8").read())
#   build_all(); render_all()
import bpy, math, os
from mathutils import Vector, Matrix

ROOT = r"F:/project/PepeHub/design/pets"
ASSETS = ROOT + "/assets_ext/polypizza"
SHOTS = ROOT + "/shots_ext"

_CACHE = {}  # имя ассета -> коллекция-шаблон (импорт один раз на файл)


def asset_path(name):
    for cat in os.listdir(ASSETS):
        p = os.path.join(ASSETS, cat, name + ".glb")
        if os.path.exists(p):
            return p
    raise FileNotFoundError(name)


def _lib_collection():
    lib = bpy.data.collections.get("ExtLibrary")
    if lib is None:
        lib = bpy.data.collections.new("ExtLibrary")
        bpy.context.scene.collection.children.link(lib)
    return lib


def template(name):
    """Импортирует glb один раз в скрытую коллекцию ExtLibrary/<name>."""
    coll = bpy.data.collections.get("ext_" + name)
    if coll is not None:
        return coll
    lib = _lib_collection()
    coll = bpy.data.collections.new("ext_" + name)
    lib.children.link(coll)
    before = set(bpy.data.objects)
    acts_before = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=asset_path(name))
    new = [o for o in bpy.data.objects if o not in before]
    acts = [a for a in bpy.data.actions if a not in acts_before]
    for a in acts:
        a.use_fake_user = True
        a["asset"] = name
    coll["actions"] = [a.name for a in acts]
    # Стёкла окон непрозрачные серые — делаем их светящимся «небом».
    for o in new:
        if o.type != "MESH":
            continue
        for m in o.data.materials:
            if m and m.name.lower().startswith("glass") and m.node_tree:
                b = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
                if b:
                    sky = hexc("#BFE3F5")
                    b.inputs["Base Color"].default_value = (*sky, 1)
                    b.inputs["Emission Color"].default_value = (*sky, 1)
                    b.inputs["Emission Strength"].default_value = 1.4
                    o.visible_shadow = False
    # У Quaternius в glb лежит служебная сфера-форма кости (Icosphere) — убираем.
    for o in list(new):
        if o.type == "MESH" and o.name.startswith("Icosphere") and not o.modifiers \
                and o.parent_type != "BONE":
            new.remove(o)
            bpy.data.objects.remove(o)
    # В glb Kenney каждый меш лежит дважды (копия с переставленными материалами) точно
    # поверх оригинала — в Cycles такое наложение рендерится чёрным. Оставляем первую копию.
    seen = set()
    for o in sorted([o for o in new if o.type == "MESH"], key=lambda o: o.name):
        bb = tuple(round(v, 4) for c in o.bound_box for v in (o.matrix_world @ Vector(c)))
        sig = (len(o.data.vertices), len(o.data.polygons), bb)
        if sig in seen:
            new.remove(o)
            bpy.data.objects.remove(o)
        else:
            seen.add(sig)
    for o in new:
        for c in list(o.users_collection):
            c.objects.unlink(o)
        coll.objects.link(o)
    # Нормализация: корень в ноль, низ на z=0, центр по XY в ноль.
    roots = [o for o in new if o.parent is None]
    bpy.context.view_layer.update()
    lo, hi = _bounds(new)
    off = Vector((-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))
    for r in roots:
        r.location += off
    bpy.context.view_layer.update()
    coll["size"] = list(hi - lo)
    lib.hide_viewport = False
    for lc in _layer_colls(bpy.context.view_layer.layer_collection, "ExtLibrary"):
        lc.exclude = True
    return coll


def _layer_colls(lc, name):
    if lc.collection.name == name:
        yield lc
    for ch in lc.children:
        yield from _layer_colls(ch, name)


def _bounds(objs):
    lo = Vector((1e9, 1e9, 1e9)); hi = -lo
    for o in objs:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    return lo, hi


def place(name, loc=(0, 0, 0), rot=0.0, height=None, size=None, coll=None, label=None,
          scale=None):
    """Ставит экземпляр ассета. height — высота в метрах, size — наибольший габарит."""
    t = template(name)
    sx, sy, sz = t["size"]
    if scale is None:
        if height:
            scale = height / sz
        elif size:
            scale = size / max(sx, sy, sz)
        else:
            scale = 1.0
    inst = bpy.data.objects.new(label or name, None)
    inst.instance_type = "COLLECTION"
    inst.instance_collection = t
    inst.location = loc
    inst.rotation_euler = (0, 0, math.radians(rot))
    inst.scale = (scale,) * 3
    (coll or bpy.context.scene.collection).objects.link(inst)
    return inst


def place_real(name, loc=(0, 0, 0), rot=0.0, height=None, size=None, coll=None, label=None,
               action=None, frame=None):
    """Как place, но полная копия объектов (нужно для анимированных питомцев)."""
    t = template(name)
    sx, sy, sz = t["size"]
    scale = height / sz if height else (size / max(sx, sy, sz) if size else 1.0)
    root = bpy.data.objects.new(label or name, None)
    root.empty_display_size = 0.2
    (coll or bpy.context.scene.collection).objects.link(root)
    mapping = {}
    for o in t.objects:
        c = o.copy()
        if o.data is not None and o.type == "ARMATURE":
            c.data = o.data.copy()
        mapping[o] = c
        (coll or bpy.context.scene.collection).objects.link(c)
    for o, c in mapping.items():
        if o.parent in mapping:
            c.parent = mapping[o.parent]
        else:
            c.parent = root
        for m in c.modifiers:
            if m.type == "ARMATURE" and m.object in mapping:
                m.object = mapping[m.object]
    root.location = loc
    root.rotation_euler = (0, 0, math.radians(rot))
    root.scale = (scale,) * 3
    root["asset"] = name
    if action:
        set_action(root, action, frame)
    return root


def actions_of(name):
    return [n.split("|")[-1] for n in template(name)["actions"]]


def set_action(root, key, frame=None):
    """Включает клип ассета: key — имя клипа (Idle, Eating, Sitting_Idle...)."""
    arm = next((o for o in root.children_recursive if o.type == "ARMATURE"), None)
    if arm is None:
        return None
    names = list(template(root["asset"])["actions"])
    k = key.lower()
    pick = next((n for n in names if n.split("|")[-1].lower() == k), None) or \
        next((n for n in names if k in n.split("|")[-1].lower()), None)
    act = bpy.data.actions.get(pick) if pick else None
    if act is None:
        return None
    arm.animation_data_create()
    arm.animation_data.action = act
    try:
        slots = act.slots
        if len(slots):
            arm.animation_data.action_slot = slots[0]
    except AttributeError:
        pass
    return act.name


# ---------------------------------------------------------------- материалы и комната

def mat(name, color, rough=0.8, emit=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*color, 1)
        b.inputs["Emission Strength"].default_value = emit
    return m


def hexc(h):
    h = h.lstrip("#")
    srgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def box(name, dims, loc, material, coll, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = dims
    bpy.ops.object.transform_apply(scale=True)
    if bevel:
        mod = o.modifiers.new("bevel", "BEVEL"); mod.width = bevel; mod.segments = 3
    o.data.materials.append(material)
    for c in list(o.users_collection):
        c.objects.unlink(o)
    coll.objects.link(o)
    return o


def activate(sc):
    win = bpy.context.window or bpy.context.window_manager.windows[0]
    win.scene = sc


def drop_scene(sc):
    """Удаляет сцену вместе с её объектами и коллекциями (кроме общей ExtLibrary)."""
    for c in list(sc.collection.children):
        if c.name == "ExtLibrary":
            continue
        for o in list(c.all_objects):
            bpy.data.objects.remove(o)
        for ch in list(c.children_recursive):
            bpy.data.collections.remove(ch)
        bpy.data.collections.remove(c)
    for o in list(sc.collection.objects):
        bpy.data.objects.remove(o)
    bpy.data.scenes.remove(sc)


def new_scene(name, wall="#E9DDF2", wall2="#DCEBDD", floor="#D9B48F", trim="#FFF8EE",
              W=5.0, D=4.0, H=3.0):
    """Сцена-«коробка»: пол, две стены, плинтус, камера спереди, свет."""
    old = bpy.data.scenes.get(name)
    if old is not None:
        old.name = name + "_old"
    sc = bpy.data.scenes.new(name)
    activate(sc)  # активную сцену удалять нельзя — Blender падает
    if old is not None:
        drop_scene(old)
    room = bpy.data.collections.new(name + "_Room")
    sc.collection.children.link(room)
    props = bpy.data.collections.new(name + "_Props")
    sc.collection.children.link(props)
    lib = _lib_collection()
    if lib.name not in sc.collection.children:
        sc.collection.children.link(lib)
    for lc in _layer_colls(bpy.context.view_layer.layer_collection, "ExtLibrary"):
        lc.exclude = True

    mw = mat(name + "_wall", hexc(wall), 0.9)
    mw2 = mat(name + "_wall2", hexc(wall2), 0.9)
    mf = mat(name + "_floor", hexc(floor), 0.6)
    mt = mat(name + "_trim", hexc(trim), 0.5)
    box("Floor", (W, D, 0.1), (0, 0, -0.05), mf, room)
    box("WallBack", (W, 0.12, H), (0, D / 2 + 0.06, H / 2), mw, room)
    box("WallLeft", (0.12, D, H), (-W / 2 - 0.06, 0, H / 2), mw2, room)
    box("WainBack", (W, 0.03, 0.9), (0, D / 2 - 0.015, 0.45), mw2, room)
    box("TrimBack", (W, 0.06, 0.06), (0, D / 2 - 0.03, 0.92), mt, room)
    box("BaseBack", (W, 0.04, 0.1), (0, D / 2 - 0.035, 0.05), mt, room)
    box("BaseLeft", (0.04, D, 0.1), (-W / 2 + 0.02, 0, 0.05), mt, room)

    cam_data = bpy.data.cameras.new(name + "_cam")
    cam_data.lens = 30
    cam = bpy.data.objects.new(name + "_cam", cam_data)
    room.objects.link(cam)
    cam.location = (0.55, -4.75, 2.05)
    cam.rotation_euler = (math.radians(75), 0, math.radians(8))
    sc.camera = cam

    sun = bpy.data.lights.new(name + "_sun", "SUN"); sun.energy = 2.5; sun.angle = 0.3
    sun.color = (1.0, 0.95, 0.88)
    so = bpy.data.objects.new(name + "_sun", sun); room.objects.link(so)
    so.rotation_euler = (math.radians(50), math.radians(10), math.radians(-35))
    fill = bpy.data.lights.new(name + "_fill", "AREA"); fill.energy = 300; fill.size = 4
    fill.color = (0.95, 0.92, 1.0)
    fo = bpy.data.objects.new(name + "_fill", fill); room.objects.link(fo)
    fo.location = (1.5, -3.5, 3.2)
    fo.rotation_euler = (math.radians(50), 0, math.radians(20))

    world = bpy.data.worlds.new(name + "_world")
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (*hexc("#F4ECE0"), 1)
    bg.inputs["Strength"].default_value = 0.6
    sc.world = world

    sc.render.resolution_x = 1080
    sc.render.resolution_y = 1350
    try:
        sc.view_settings.view_transform = "AgX"
    except TypeError:
        pass
    return sc, room, props


def lamp_glow(loc, color="#FFD9A0", energy=40, radius=0.15, coll=None):
    l = bpy.data.lights.new("glow", "POINT"); l.energy = energy; l.shadow_soft_size = radius
    l.color = hexc(color)
    o = bpy.data.objects.new("glow", l); o.location = loc
    (coll or bpy.context.scene.collection).objects.link(o)
    return o





# ---------------------------------------------------------------- сцены

PETS_ALL = [("pet_cat_b", "Idle"), ("pet_birb", "Idle"), ("pet_pink_slime", "Idle"),
            ("pet_chick", "Idle"), ("pet_ducky", None), ("pet_red_dino", None),
            ("pet_pug", "Idle"), ("pet_shiba", "Idle"), ("pet_fox", "Idle"),
            ("pet_cat_a", "Idle"), ("pet_panda", "Idle"), ("pet_bunny", "Idle"),
            ("pet_dragon_b", "Flying_Idle"), ("pet_dragon", "Flying"), ("pet_hywirl", "Flying_Idle"),
            ("pet_goleling", "Flying_Idle"), ("pet_frog", "Idle"), ("pet_raccoon", "Idle")]


def build_lineup():
    sc, room, props = new_scene("Ext_Pets", W=12.5, D=4, wall="#EFE6F5", wall2="#DCEBDD")
    n = len(PETS_ALL)
    cols = 9
    for i, (p, a) in enumerate(PETS_ALL):
        row, col = divmod(i, cols)
        x = (col - (cols - 1) / 2) * (1.3 if row == 0 else 1.1)
        y = -0.2 + row * -1.6
        place_real(p, loc=(x, y + 1.4, 0), height=0.75, coll=props, label=p, action=a)
    sc.camera.location = (0, -7.6, 3.5)
    sc.camera.rotation_euler = (math.radians(70), 0, 0)
    sc.camera.data.lens = 27
    sc.render.resolution_x = 1920
    sc.render.resolution_y = 860
    sc.frame_current = 12
    return sc


# ---------------------------------------------------------------- комнаты под кадр игры
# Камера, точка питомца и свет — как в приложении (assets/pets/rooms/rooms.json):
# портрет 780×1688, объектив 24 мм (вертикальный угол 73.7° = fov из rooms.json), вид спереди.
# Видимая ширина: у питомца ±0.95 м, у задней стены ±1.65 м; боковые стены в кадр не попадают,
# сверху виден потолок. Точки покупного декора приложения (rooms.json → decor) оставлены свободными.

APP_PETS = r"F:/project/PepeHub/apps/pepehub/assets/pets"
GAME_RES = (780, 1688)
YB = 2.0          # внутренняя грань задней стены
ROOM_H = 3.5

# Источник rooms.json приложения (export_app_rooms пишет его отсюда). Камеры — прежние,
# fov = 2·atan(18/24): квадратный рендер с объективом 24 мм. spot — где стоит питомец.
GAME_ROOMS = {
    "living": dict(
        title="Гостиная",
        camera=dict(position=(0.0, -2.75, 1.05), forward=(0.0, 0.997907817363739, -0.06465316563844681),
                    up=(0.0, 0.06465316563844681, 0.997907817363739)),
        spot=(0.0, 0.0, 0.016), yaw=0.0,
        light=dict(dir=(-0.45, 0.35, -1.0), color=(1.0, 0.9, 0.78), intensity=2.4, ambient=(1.0, 0.86, 0.72))),
    "kitchen": dict(
        title="Кухня",
        camera=dict(position=(0.0, -2.3, 1.0), forward=(0.0, 0.9998405993454447, -0.017854296416882957),
                    up=(0.0, 0.017854296416882957, 0.9998405993454447)),
        spot=(0.0, 0.55, 0.0), yaw=0.0,          # еда на полу; питомец подальше — над панелью еды
        light=dict(dir=(0.6, 0.4, -1.0), color=(1.0, 0.97, 0.92), intensity=2.6, ambient=(0.92, 0.95, 1.0))),
    "bedroom": dict(
        title="Спальня",
        camera=dict(position=(0.0, -2.5, 1.15), forward=(0.032091527190284, 0.994837342898804, -0.09627458157085197),
                    up=(0.0031040170902078014, 0.09622452979644186, 0.9953548135933022)),
        spot=(0.15, 0.15, 0.12), yaw=0.0,         # на подушке лежанки
        light=dict(dir=(0.5, 0.3, -1.0), color=(0.78, 0.8, 1.0), intensity=1.6, ambient=(0.62, 0.58, 0.95))),
}

# Покупной декор приложения: место в комнате (масштаб — для моделей assets/pets/decor/*.glb).
GAME_DECOR = {
    "decor_book_stack": dict(room="living", pos=(-0.62, -0.36, 0.0), rot=14, scale=1.35),
    "decor_lantern": dict(room="living", pos=(0.62, -0.42, 0.0), rot=-20, scale=1.35),
    "decor_globe": dict(room="living", pos=(-1.2, 1.62, 2.25), rot=-30, scale=1.3),   # на шкафу
    "decor_aquarium": dict(room="living", pos=(1.3, 1.7, 0.72), rot=0, scale=1.5),     # на тумбе
    "decor_mushroom_lamp": dict(room="bedroom", pos=(-0.52, -0.42, 0.0), rot=10, scale=1.3),
    "decor_moon_lamp": dict(room="bedroom", pos=(-0.35, 1.9, 1.15), rot=-10, scale=1.3),  # на подоконнике
}


def _cp():
    """Модуль кубических питомцев (design/pets/scripts/cube_pets.py)."""
    import sys, importlib
    here = ROOT.replace("/", "\\") + r"\scripts"
    if here not in sys.path:
        sys.path.insert(0, here)
    import cube_pets
    importlib.reload(cube_pets)
    return cube_pets


def _room_cfg(key):
    return GAME_ROOMS[key]


def game_camera(sc, coll, key):
    """Камера из rooms.json: position/forward/up, объектив 24 мм на 36 мм кадре (fit по высоте)."""
    cam_cfg = _room_cfg(key)["camera"]
    fwd = Vector(cam_cfg["forward"]).normalized()
    up = Vector(cam_cfg["up"]).normalized()
    z = -fwd
    x = up.cross(z).normalized()
    y = z.cross(x)
    m = Matrix((x, y, z)).transposed().to_4x4()
    m.translation = Vector(cam_cfg["position"])
    data = bpy.data.cameras.new(sc.name + "_cam")
    data.lens = 24
    data.sensor_width = 36
    data.sensor_fit = "AUTO"
    cam = bpy.data.objects.new(sc.name + "_cam", data)
    coll.objects.link(cam)
    cam.matrix_world = m
    sc.camera = cam
    sc.render.resolution_x, sc.render.resolution_y = GAME_RES
    return cam


def game_room(name, key, wall, wain, floor, trim="#FFF8EE", ceiling="#F6EFE6", world="#F4ECE0",
              sun_energy=2.2):
    """Комната-коробка под кадр игры: пол, задняя стена с панелями, потолок, свет."""
    old = bpy.data.scenes.get(name)
    if old is not None:
        old.name = name + "_old"
    sc = bpy.data.scenes.new(name)
    activate(sc)
    if old is not None:
        drop_scene(old)
    room = bpy.data.collections.new(name + "_Room"); sc.collection.children.link(room)
    props = bpy.data.collections.new(name + "_Props"); sc.collection.children.link(props)
    lib = _lib_collection()
    if lib.name not in sc.collection.children:
        sc.collection.children.link(lib)
    for lc in _layer_colls(bpy.context.view_layer.layer_collection, "ExtLibrary"):
        lc.exclude = True
    W, y0 = 5.6, -2.8
    D = YB - y0
    yc = (y0 + YB) / 2
    mw, mwa = mat(name + "_wall", hexc(wall), 0.9), mat(name + "_wain", hexc(wain), 0.8)
    mf, mt = mat(name + "_floor", hexc(floor), 0.55), mat(name + "_trim", hexc(trim), 0.5)
    ms = mat(name + "_seam", tuple(c * 0.75 for c in hexc(floor)), 0.6)
    mc = mat(name + "_ceil", hexc(ceiling), 0.9)
    box("Floor", (W, D, 0.1), (0, yc, -0.05), mf, room)
    for i in range(-6, 7):            # стыки досок
        box("Seam", (0.012, D, 0.004), (i * 0.42, yc, 0.001), ms, room)
    box("WallBack", (W, 0.12, ROOM_H), (0, YB + 0.06, ROOM_H / 2), mw, room)
    box("WallL", (0.12, D, ROOM_H), (-W / 2 - 0.06, yc, ROOM_H / 2), mw, room)
    box("WallR", (0.12, D, ROOM_H), (W / 2 + 0.06, yc, ROOM_H / 2), mw, room)
    box("Ceiling", (W, D, 0.1), (0, yc, ROOM_H + 0.05), mc, room)
    box("Wainscot", (W, 0.04, 0.95), (0, YB - 0.02, 0.475), mwa, room)
    for i in range(-3, 4):            # панели на нижней части стены
        box("Panel", (0.62, 0.02, 0.62), (i * 0.8, YB - 0.045, 0.5), mwa, room, bevel=0.01)
    box("Rail", (W, 0.07, 0.06), (0, YB - 0.035, 0.97), mt, room)
    box("Skirting", (W, 0.05, 0.12), (0, YB - 0.045, 0.06), mt, room)
    box("Cornice", (W, 0.1, 0.1), (0, YB - 0.05, ROOM_H - 0.05), mt, room)

    game_camera(sc, room, key)
    cfg = _room_cfg(key)["light"]
    sun = bpy.data.lights.new(name + "_sun", "SUN"); sun.energy = sun_energy; sun.angle = 0.35
    sun.color = cfg["color"]
    so = bpy.data.objects.new(name + "_sun", sun); room.objects.link(so)
    so.rotation_euler = Vector(cfg["dir"]).to_track_quat("-Z", "Y").to_euler()
    fill = bpy.data.lights.new(name + "_fill", "AREA"); fill.energy = 260; fill.size = 3
    fill.color = (1.0, 0.95, 0.9)
    fo = bpy.data.objects.new(name + "_fill", fill); room.objects.link(fo)
    fo.location = (0.4, -2.2, 2.6)
    fo.rotation_euler = (math.radians(55), 0, 0)
    w = bpy.data.worlds.new(name + "_world"); w.use_nodes = True
    bg = next(n for n in w.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (*hexc(world), 1)
    bg.inputs["Strength"].default_value = 0.5
    sc.world = w
    try:
        sc.view_settings.view_transform = "AgX"
    except TypeError:
        pass
    return sc, room, props


def put_cube_pet(species, stage, coll, key, clip="Idle", frame=1, rot=0.0, offset=(0, 0, 0)):
    """Кубический питомец в точке spot из rooms.json (как его ставит приложение)."""
    cp = _cp()
    fn = getattr(cp, species)
    arm, ob = cp.build_pet(fn(stage), coll)
    cp.add_clips(arm)
    arm.location = Vector(_room_cfg(key)["spot"]) + Vector(offset)
    arm.rotation_euler.z = math.radians(rot)
    act = bpy.data.actions.get(arm.name.replace("_Rig", "") + "_" + clip)
    arm.animation_data.action = act
    if act is not None and len(act.slots):
        arm.animation_data.action_slot = act.slots[0]
    arm.hide_viewport = True          # кости не мешают в окне; позу задаёт действие
    arm["cube_pet"] = ob["cube_pet"] = 1   # в фон приложения питомец не рендерится
    bpy.context.scene.frame_current = frame
    return arm


def pet_bed(loc, coll, w=0.95, d=0.8, color="#A893D6", cushion="#E9DEF7", name="PetBed"):
    """Лежанка в блочном стиле: подушка и мягкий бортик (своя геометрия — готовой CC0 нет)."""
    m1, m2 = mat("petbed_rim", hexc(color), 0.85), mat("petbed_pad", hexc(cushion), 0.9)
    x, y, z = loc
    box(name + "_Pad", (w - 0.12, d - 0.12, 0.12), (x, y, z + 0.06), m2, coll, bevel=0.04)
    rim_h, t = 0.26, 0.13
    box(name + "_Back", (w, t, rim_h), (x, y + d / 2 - t / 2, z + rim_h / 2), m1, coll, bevel=0.05)
    box(name + "_Front", (w, t, rim_h * 0.62), (x, y - d / 2 + t / 2, z + rim_h * 0.31), m1, coll, bevel=0.05)
    for sx in (-1, 1):
        box(name + "_Side", (t, d, rim_h * 0.85), (x + sx * (w / 2 - t / 2), y, z + rim_h * 0.425), m1, coll,
            bevel=0.05)


def pet_bowl(loc, coll, color="#E98FA9", fill="#9A6A45", name="Bowl", emit=0.0, w=0.3):
    """Миска в блочном стиле: скруглённый короб и содержимое сверху (корм или вода)."""
    x, y, z = loc
    box(name + "_Body", (w, w, 0.1), (x, y, z + 0.05), mat(name + "_m", hexc(color), 0.5), coll, bevel=0.035)
    box(name + "_Fill", (w * 0.72, w * 0.72, 0.02), (x, y, z + 0.095),
        mat(name + "_fill", hexc(fill), 0.35, emit=emit), coll, bevel=0.008)


def _flip(label):
    """Потолочные светильники лежат «на полу» — переворачиваем к потолку."""
    o = bpy.data.objects[label]
    o.rotation_euler.x = math.radians(180)


def build_living():
    sc, room, P = game_room("Ext_Living", "living", wall="#DCD3EE", wain="#C9DCC8", floor="#C99A6E")
    # задняя стена: шкаф с книгами слева, окно, торшер справа; диван — фон за питомцем
    place("bookcase_books", (-1.45, 1.66, 0), height=2.25, coll=P)
    place("pothos_plant", (-1.72, 1.7, 2.25), height=0.45, coll=P)
    place("window_large", (0.3, YB - 0.03, 1.15), height=1.55, coll=P)
    place("sofa", (-0.05, 1.42, 0), size=1.7, coll=P)
    place("lamp_round_floor", (0.88, 1.62, 0), height=1.75, coll=P)
    place("nightstand_q", (1.3, 1.7, 0), height=0.72, coll=P, label="living_cabinet")   # под аквариум
    place("light_ceiling_q", (0.0, 0.7, ROOM_H), height=0.6, coll=P, label="living_ceiling_lamp")
    _flip("living_ceiling_lamp")
    # пол: ковёр под питомцем, диванчик слева на переднем плане
    place("rug_round_k", (0.0, 0.05, 0.0), size=1.9, coll=P)
    place("couch_small", (-1.2, -0.55, 0), rot=35, size=1.15, coll=P)
    lamp_glow((0.88, 1.62, 1.62), energy=70, coll=room)
    lamp_glow((0.0, 0.7, ROOM_H - 0.55), energy=60, color="#FFE7C2", coll=room)
    put_cube_pet("fox", "teen", P, "living")
    return sc


def build_kitchen():
    sc, room, P = game_room("Ext_Kitchen", "kitchen", wall="#DDEBF2", wain="#F2E6D6", floor="#D7B48C",
                            world="#F3EEE8")
    # кухонный ряд вдоль задней стены (видно x ±1.4)
    yc = 1.66
    place("fridge_large_k", (-1.38, yc, 0), height=1.95, coll=P)
    place("counter_drawers_q", (-0.72, yc, 0), height=0.92, coll=P)
    place("stove_k", (-0.12, yc, 0), height=0.92, coll=P)
    place("sink_k", (0.5, yc, 0), height=0.92, coll=P)
    place("counter_doors_q", (1.15, yc, 0), height=0.92, coll=P)
    place("cooking_pot", (-0.12, yc, 0.92), size=0.36, coll=P)
    place("muffin", (-0.75, yc - 0.05, 0.92), height=0.13, coll=P)
    place("houseplant", (1.25, yc, 0.92), height=0.5, coll=P)
    place("window_small", (0.5, YB - 0.03, 1.35), height=1.15, coll=P)
    place("ceiling_light_q", (0.0, 0.4, ROOM_H), height=0.5, coll=P, label="kitchen_ceiling_lamp")
    _flip("kitchen_ceiling_lamp")
    shelf = mat("kitchen_shelf", hexc("#C99A6E"), 0.5)          # полка с чашками над столешницей
    box("Shelf", (1.0, 0.22, 0.04), (-0.55, YB - 0.11, 1.72), shelf, room, bevel=0.01)
    place("mug_k", (-0.85, YB - 0.12, 1.74), rot=-20, height=0.11, coll=P)
    place("cup_tea_k", (-0.55, YB - 0.12, 1.74), height=0.07, coll=P)
    place("mug_k", (-0.25, YB - 0.12, 1.74), rot=25, height=0.11, coll=P)
    lamp_glow((0.0, 0.4, ROOM_H - 0.6), energy=80, color="#FFE7C2", coll=room)
    # Еда на полу: коврик-подложка и миски перед питомцем, питомец стоит рядом (spot z=0).
    sx, sy = _room_cfg("kitchen")["spot"][:2]
    place("mat_il", (sx, sy - 0.5, 0), size=1.15, coll=P)
    pet_bowl((sx - 0.3, sy - 0.48, 0.0), P, color="#E98FA9", fill="#9A6A45", name="BowlFood")
    pet_bowl((sx + 0.3, sy - 0.48, 0.0), P, color="#8FB8E9", fill="#BFE3F5", name="BowlWater", emit=0.3)
    place("bone_kl", (sx - 0.12, sy - 0.88, 0.0), rot=20, size=0.22, coll=P)
    put_cube_pet("puppy", "teen", P, "kitchen")
    return sc




def build_bedroom():
    sc, room, P = game_room("Ext_Bedroom", "bedroom", wall="#CFC8EC", wain="#B9AEDF", floor="#B98D6A",
                            world="#E9E2F4", sun_energy=1.4)
    place("closet_q", (-1.45, 1.55, 0), height=2.1, coll=P)
    place("window_round", (-0.35, YB - 0.03, 1.15), height=1.45, coll=P)
    place("bed_double_q", (1.85, 1.12, 0), rot=90, height=0.95, coll=P)
    place("nightstand_q", (0.62, 1.72, 0), height=0.5, coll=P)
    place("light_desk", (0.55, 1.74, 0.5), height=0.42, coll=P)
    place("alarm_clock_ct", (0.74, 1.64, 0.5), height=0.15, coll=P)
    place("light_ceiling_q", (0.0, 0.5, ROOM_H), height=0.6, coll=P, label="bedroom_ceiling_lamp")
    _flip("bedroom_ceiling_lamp")
    shelf = mat("bedroom_shelf", hexc("#8E6A4C"), 0.5)          # полка над кроватью
    box("Shelf", (1.0, 0.22, 0.04), (1.2, YB - 0.11, 1.6), shelf, room, bevel=0.01)
    place("books_ct", (0.95, YB - 0.12, 1.62), height=0.2, coll=P)
    place("potted_plant", (1.45, YB - 0.12, 1.62), height=0.28, coll=P)
    place("pothos_plant", (-1.45, 1.6, 2.1), height=0.4, coll=P)
    lamp_glow((0.55, 1.7, 0.85), energy=55, coll=room)
    spot = Vector(_room_cfg("bedroom")["spot"])
    place("mat_il", (spot.x, spot.y - 0.1, 0), size=1.9, coll=P)
    pet_bed((spot.x, spot.y, 0.0), P)
    place("rubber_duck_ct", (spot.x + 0.58, spot.y - 0.62, 0), rot=-25, size=0.22, coll=P)
    place("open_book", (spot.x - 1.1, spot.y + 0.45, 0), rot=15, size=0.34, coll=P)
    sill = mat("bedroom_sill", hexc("#FFF8EE"), 0.5)            # подоконник под ночник-луну
    box("Sill", (0.95, 0.18, 0.04), (-0.35, YB - 0.09, 1.13), sill, room, bevel=0.01)
    # spot z=0.12 — питомец сидит на подушке лежанки
    put_cube_pet("bunny", "cub", P, "bedroom")
    return sc


def build_all():
    """Пересобирает сцены Ext_* (старые с тем же именем заменяются)."""
    scenes = [build_lineup(), build_living(), build_kitchen(), build_bedroom()]
    activate(scenes[1])
    empty = bpy.data.scenes.get("Scene")
    if empty is not None and not empty.objects:
        bpy.data.scenes.remove(empty)
    return scenes


def render_all(only=None, samples=64):
    os.makedirs(SHOTS, exist_ok=True)
    for s in bpy.data.scenes:
        if not s.name.startswith("Ext_") or (only and s.name not in only):
            continue
        activate(s)
        s.frame_set(s.frame_current)
        try:
            s.render.engine = "CYCLES"
            s.cycles.samples = samples
            s.cycles.use_denoising = True
        except (TypeError, AttributeError):
            pass
        s.render.filepath = f"{SHOTS}/{s.name[4:].lower()}.png"
        bpy.ops.render.render(write_still=True, scene=s.name)


# ---------------------------------------------------------------- выгрузка в приложение

ROOM_RES = 2048                      # квадрат: приложение обрезает его под экран
GAME_FG = {"bedroom": ("PetBed_Front", "PetBed_Side")}   # что стоит перед питомцем


def preview_decor(on=True):
    """Ставит модели покупного декора приложения на их места — только для проверки в окне."""
    for key in GAME_ROOMS:
        sc = bpy.data.scenes.get("Ext_" + key.capitalize())
        if sc is None:
            continue
        name = sc.name + "_DecorPreview"
        old = bpy.data.collections.get(name)
        if old is not None:
            for o in list(old.all_objects):
                bpy.data.objects.remove(o)
            bpy.data.collections.remove(old)
        if not on:
            continue
        coll = bpy.data.collections.new(name)
        sc.collection.children.link(coll)
        activate(sc)
        for item, d in GAME_DECOR.items():
            if d["room"] != key:
                continue
            before = set(bpy.data.objects)
            bpy.ops.import_scene.gltf(filepath=f"{APP_PETS}/decor/{item}.glb")
            new = [o for o in bpy.data.objects if o not in before]
            holder = bpy.data.objects.new("decor:" + item, None)
            coll.objects.link(holder)
            for o in new:
                for c in list(o.users_collection):
                    c.objects.unlink(o)
                coll.objects.link(o)
                if o.parent is None:
                    o.parent = holder
            holder.location = d["pos"]
            holder.rotation_euler.z = math.radians(d["rot"])
            holder.scale = (d["scale"],) * 3
            for o in [holder] + new:
                o.hide_render = True   # в фон не попадает


def _square_render(sc, path, transparent, samples):
    keep = (sc.render.resolution_x, sc.render.resolution_y, sc.render.film_transparent,
            sc.render.image_settings.file_format, sc.render.image_settings.color_mode)
    sc.render.resolution_x = sc.render.resolution_y = ROOM_RES
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = transparent
    try:
        sc.render.engine = "CYCLES"
        sc.cycles.samples = samples
        sc.cycles.use_denoising = True
    except (TypeError, AttributeError):
        pass
    if transparent:
        sc.render.image_settings.file_format = "PNG"
        sc.render.image_settings.color_mode = "RGBA"
    else:
        sc.render.image_settings.file_format = "JPEG"
        sc.render.image_settings.color_mode = "RGB"
        sc.render.image_settings.quality = 88
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True, scene=sc.name)
    (sc.render.resolution_x, sc.render.resolution_y, sc.render.film_transparent,
     sc.render.image_settings.file_format, sc.render.image_settings.color_mode) = keep


def export_app_rooms(only=None, samples=128):
    """Фоны (и передний план) комнат и rooms.json в apps/pepehub/assets/pets/rooms/."""
    import json
    out = APP_PETS + "/rooms"
    os.makedirs(out, exist_ok=True)
    meta = {}
    for key, cfg in GAME_ROOMS.items():
        sc = bpy.data.scenes["Ext_" + key.capitalize()]
        activate(sc)
        fg = GAME_FG.get(key, ())
        if not only or key in only:
            pets = [o for o in sc.objects if o.get("cube_pet")]
            for o in pets:
                o.hide_render = True
            _square_render(sc, f"{out}/{key}_bg.jpg", False, samples)
            if fg:
                hold = {}
                for o in sc.objects:
                    if o.type == "MESH" and not o.hide_render and not any(o.name.startswith(p) for p in fg):
                        hold[o] = o.is_holdout
                        o.is_holdout = True
                for o in sc.objects:          # ассеты-экземпляры коллекций тоже закрываем
                    if o.instance_type == "COLLECTION" and not o.hide_render:
                        hold[o] = o.is_holdout
                        o.is_holdout = True
                _square_render(sc, f"{out}/{key}_fg.png", True, samples)
                for o, v in hold.items():
                    o.is_holdout = v
            for o in pets:
                o.hide_render = False
        cam = dict(cfg["camera"])
        meta[key] = dict(
            title=cfg["title"],
            camera=dict(position=list(cam["position"]), forward=list(cam["forward"]), up=list(cam["up"]),
                        fov=2 * math.atan(18.0 / 24.0)),
            spot=list(cfg["spot"]), yaw=cfg["yaw"], light=cfg["light"],
            background=f"assets/pets/rooms/{key}_bg.jpg",
            foreground=f"assets/pets/rooms/{key}_fg.png" if fg else None,
            decor=[dict(id=k, pos=list(v["pos"]), rot=v["rot"], scale=v["scale"])
                   for k, v in GAME_DECOR.items() if v["room"] == key],
        )
    with open(f"{out}/rooms.json", "w", encoding="utf-8") as f:
        json.dump(dict(version=2, order=list(GAME_ROOMS), rooms=meta), f, ensure_ascii=False, indent=1)
    return list(meta)
