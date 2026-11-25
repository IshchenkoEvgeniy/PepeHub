# Assets of the «Питомник» screen for the app (2026-11-25).
# Exec inside Blender after lib.py, rooms_v3.py, icons_v4.py (pets_rooms_v3.blend open):
#   export_app_assets()
# Writes apps/pepehub/assets/pets/rooms/:
#   <room>_bg.jpg   the room without the pet and without buyable decor (square)
#   <room>_fg.png   only what stands in front of the pet (alpha), if any
#   rooms.json      camera, pet spot, light and decor spots per room, in Blender
#                   coordinates (Z up, front of the pet = -Y)
# and apps/pepehub/assets/pets/decor/<item>.glb (buyable decor from scene Icons4).
import bpy, os, json, math
from mathutils import Vector, Matrix

APP = r"F:\project\PepeHub\apps\pepehub\assets\pets"
ROOM_RES = 2048
ROOM_LENS = 24.0          # square render: the same vertical FOV as the phone renders

ROOMS = {
    "living": dict(
        scene="Room_Living", cam="L_Cam", spot=(0.0, 0.0, 0.016), yaw=0.0,
        hide=("L_PetStandIn", "L_PetSpot", "L_Lantern", "L_Candle", "L_Flame", "L_Stack1", "L_Stack2", "L_Stack3"),
        fg=(), light=dict(dir=(-0.45, 0.35, -1.0), color=(1.0, 0.9, 0.78), intensity=2.4, ambient=(1.0, 0.86, 0.72)),
        title="Гостиная"),
    "kitchen": dict(
        scene="Room_Kitchen3", cam="K3_Cam", spot=(0.0, 0.05, 0.0), yaw=0.0,
        hide=("K3_PetStandIn", "K3_PetSpot"),
        fg=("K3_TableTop", "K3_Placemat", "K3_Bowl", "K3_Berries"),
        light=dict(dir=(0.6, 0.4, -1.0), color=(1.0, 0.97, 0.92), intensity=2.6, ambient=(0.92, 0.95, 1.0)),
        title="Кухня"),
    "bedroom": dict(
        scene="Room_Bedroom3", cam="B3_Cam", spot=(0.15, 0.15, 0.2), yaw=0.0,
        hide=("B3_PetStandIn", "B3_PetSpot", "B3_Mush"),
        fg=("B3_PetBed",), fg_from=0.66,
        light=dict(dir=(0.5, 0.3, -1.0), color=(0.78, 0.8, 1.0), intensity=1.6, ambient=(0.62, 0.58, 0.95)),
        title="Спальня"),
}

# Buyable decor: one home spot each (Blender coordinates of its room).
DECOR = {
    "decor_book_stack": dict(room="living", pos=(-0.72, -0.32, 0.0), rot=14, scale=1.7),
    "decor_lantern": dict(room="living", pos=(0.88, -0.52, 0.0), rot=-20, scale=1.8),
    "decor_globe": dict(room="living", pos=(1.5, 0.5, 0.66), rot=-30, scale=1.3),
    "decor_aquarium": dict(room="living", pos=(1.35, 1.88, 1.03), rot=0, scale=1.6),
    "decor_mushroom_lamp": dict(room="bedroom", pos=(-0.78, -0.62, 0.0), rot=10, scale=1.7),
    "decor_moon_lamp": dict(room="bedroom", pos=(0.35, 1.39, 1.67), rot=-10, scale=1.3),
}

def _tree(name):
    o = bpy.data.objects.get(name)
    return [o] + list(o.children_recursive) if o else []

def _match(scene, prefixes):
    out = set()
    for o in scene.objects:
        for p in prefixes:
            if o.name == p or o.name.startswith(p):
                out.update(_tree(o.name))
    return out

def _camera_data(sc, cam):
    # matrix_world of an object in a scene that is not active is stale (it
    # gave the kitchen and bedroom a camera at the origin): activate and
    # evaluate the scene first.
    bpy.context.window.scene = sc
    bpy.context.view_layer.update()
    m = cam.matrix_world
    pos = m.translation
    forward = -(m.to_3x3() @ Vector((0, 0, 1)))
    up = m.to_3x3() @ Vector((0, 1, 0))
    fov = 2 * math.atan(18.0 / ROOM_LENS)     # square sensor fit
    return dict(position=list(pos), forward=list(forward.normalized()), up=list(up.normalized()), fov=fov)

def _render(sc, path, transparent):
    keep = dict(res=(sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage),
                film=sc.render.film_transparent, fmt=sc.render.image_settings.file_format,
                mode=sc.render.image_settings.color_mode, lens=sc.camera.data.lens)
    sc.render.resolution_x = sc.render.resolution_y = ROOM_RES
    sc.render.resolution_percentage = 100
    sc.camera.data.lens = ROOM_LENS
    sc.render.film_transparent = transparent
    if transparent:
        sc.render.image_settings.file_format = "PNG"; sc.render.image_settings.color_mode = "RGBA"
    else:
        sc.render.image_settings.file_format = "JPEG"; sc.render.image_settings.color_mode = "RGB"
        sc.render.image_settings.quality = 88
    sc.eevee.taa_render_samples = 96
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True, scene=sc.name)
    sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage = keep["res"]
    sc.render.film_transparent = keep["film"]
    sc.render.image_settings.file_format = keep["fmt"]; sc.render.image_settings.color_mode = keep["mode"]
    sc.camera.data.lens = keep["lens"]

def cut_foreground(path, start, feather=0.015):
    """Keeps only the part of a foreground render below `start` (a fraction
    of the height from the top), fading in over `feather`. The app draws the
    foreground as a flat layer over the pet, so for a pet that sits *in*
    something (the bed) only its front edge may stay."""
    import numpy as np
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    rows_from_top = (h - 1 - np.arange(h)) / h          # Blender rows go bottom-up
    keep = np.clip((rows_from_top - start) / feather, 0.0, 1.0)
    px[:, :, 3] *= keep[:, None]
    img.pixels.foreach_set(px.ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)

def export_rooms(only=None):
    out = os.path.join(APP, "rooms")
    os.makedirs(out, exist_ok=True)
    meta = {}
    for key, r in ROOMS.items():
        sc = bpy.data.scenes[r["scene"]]
        cam = bpy.data.objects[r["cam"]]
        sc.camera = cam
        hidden = _match(sc, r["hide"])
        state = {o: o.hide_render for o in hidden}
        for o in hidden:
            o.hide_render = True
        if not only or key in only:
            _render(sc, os.path.join(out, key + "_bg.jpg"), False)
            if r["fg"]:
                front = _match(sc, r["fg"])
                hold = {}
                for o in sc.objects:
                    if o.type in ("MESH", "CURVE") and o not in front and not o.hide_render:
                        hold[o] = o.is_holdout
                        o.is_holdout = True
                _render(sc, os.path.join(out, key + "_fg.png"), True)
                if r.get("fg_from"):
                    cut_foreground(os.path.join(out, key + "_fg.png"), r["fg_from"])
                for o, v in hold.items():
                    o.is_holdout = v
        for o, v in state.items():
            o.hide_render = v
        lens = cam.data.lens
        cam.data.lens = ROOM_LENS
        bpy.context.view_layer.update()
        meta[key] = dict(title=r["title"], camera=_camera_data(sc, cam), spot=list(r["spot"]), yaw=r["yaw"],
                         light=r["light"], background="assets/pets/rooms/%s_bg.jpg" % key,
                         foreground=("assets/pets/rooms/%s_fg.png" % key) if r["fg"] else None,
                         decor=[dict(id=k, pos=list(v["pos"]), rot=v["rot"], scale=v["scale"]) for k, v in DECOR.items() if v["room"] == key])
        cam.data.lens = lens
    with open(os.path.join(out, "rooms.json"), "w", encoding="utf-8") as f:
        json.dump(dict(version=1, order=["living", "kitchen", "bedroom"], rooms=meta), f, ensure_ascii=False, indent=1)
    return list(meta)

def export_decor():
    """Bakes buyable decor from the Icons4 shelf into small glb models."""
    out = os.path.join(APP, "decor")
    os.makedirs(out, exist_ok=True)
    src = bpy.data.scenes["Icons4"]
    bpy.context.window.scene = src
    dg = bpy.context.evaluated_depsgraph_get()
    rows = len(ITEMS4)
    cells = {}
    for r, (title, items) in enumerate(ITEMS4):
        for k, (item_id, _) in enumerate(items):
            cells[item_id] = Vector((k * STEP4, (rows - 1 - r) * STEP4 * 1.2, 0))
    done = []
    for item_id in DECOR:
        coll = bpy.data.collections.get("I4_" + item_id)
        if coll is None:
            continue
        name = "Export_decor_" + item_id
        sc = bpy.data.scenes.get(name) or bpy.data.scenes.new(name)
        for o in list(sc.collection.objects):
            bpy.data.objects.remove(o, do_unlink=True)
        inv = Matrix.Translation(-cells[item_id])
        for o in coll.all_objects:
            if o.type not in ("MESH", "CURVE") or "Spark" in o.name or "Glint" in o.name:
                continue
            me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
            me.transform(inv @ o.matrix_world)
            # transmission is not drawn in the app: glass becomes a light, see-through surface
            for i, m in enumerate(me.materials):
                if m is None:
                    continue
                b = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None) if m.use_nodes else None
                if b and b.inputs["Transmission Weight"].default_value > 0.5:
                    g = bpy.data.materials.get("Decor_glass") or bpy.data.materials.new("Decor_glass")
                    g.use_nodes = True
                    gb = next(n for n in g.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
                    gb.inputs["Base Color"].default_value = (0.9, 0.96, 1.0, 1)
                    gb.inputs["Roughness"].default_value = 0.05
                    gb.inputs["Alpha"].default_value = 0.22
                    try:
                        g.surface_render_method = "BLENDED"
                    except Exception:
                        pass
                    me.materials[i] = g
            no = bpy.data.objects.new(o.name, me)
            sc.collection.objects.link(no)
        with bpy.context.temp_override(scene=sc, view_layer=sc.view_layers[0]):
            bpy.ops.export_scene.gltf(filepath=os.path.join(out, item_id + ".glb"), export_format="GLB",
                                      use_active_scene=True, export_yup=True, export_apply=False)
        done.append(item_id)
        bpy.data.scenes.remove(sc)
    return done

def export_app_assets():
    return export_rooms(), export_decor()
