extends Node3D

## The README studio, shared by every content pack (dot-bootstrap tools/readme/). A pack's tools/readme_shot.sh copies
## this file and readme_studio.tscn into <pack>/tools/readme_studio/ (git-ignored) and runs it on a GPU box.
##
## What it draws comes from the pack: tools/readme.cfg names an adapter script ([shot] adapter, default
## res://tools/readme_adapter.gd), a RefCounted with
##     func ids() -> PackedStringArray                   every item, in README order
##     func model(id: String) -> Node3D                  a fresh model; the studio adds it to the tree
##     func pose(node: Node3D, id: String, pose: String, opts: Dictionary) -> void
##                                                       optional: put the model in a pose after it entered the tree
##     func profile(id: String) -> Dictionary            optional: {name, summary: {col: text}, rows: [[label, text]]}
##
## The look: a soft radial grey backdrop, a key/fill/rim rig with soft shadows, a ground that fades into the backdrop
## and only shows the model's shadow and a contact blob, a 3/4 hero angle. The model is framed by its rendered
## silhouette (a transparent pass, alpha bounds), so skinned poses frame as they look, not as their rest mesh.
## Everything is rendered at `supersample` times the size with MSAA and scaled down with Lanczos.
##
##   godot --path . res://tools/readme_studio/readme_studio.tscn -- --out /abs/dir [--ids a,b] [--width 1280] [--height 720]
##   godot --headless --path . res://tools/readme_studio/readme_studio.tscn -- --data     prints READMEDATA <json>
## Not headless for shots (a headless frame is black): tools/readme_shot.sh runs it under Xvfb on the GPU.
##
## Output: <id>.png for the first pose, <id>_<pose>.png for every other pose in [pose] <id>.poses (or [shot] poses).

const CFG := "res://tools/readme.cfg"

var _cfg := ConfigFile.new()
var _adapter: Object
var _vp: SubViewport
var _env: Environment
var _back: TextureRect
var _holder: Node3D
var _ground: Array[Node3D] = []
var _cam: Camera3D
var _key: DirectionalLight3D


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out := ""
	var ids := PackedStringArray()
	var width := 1280
	var height := 720
	var data := false
	for i in args.size():
		var nxt := args[i + 1] if i + 1 < args.size() else ""
		match args[i]:
			"--out": out = nxt
			"--ids": ids = nxt.split(",", false)
			"--width": width = int(nxt)
			"--height": height = int(nxt)
			"--data": data = true
	if _cfg.load(CFG) != OK:
		_fail("cannot read %s" % CFG)
		return
	var adapter_path := String(_cfg.get_value("shot", "adapter", "res://tools/readme_adapter.gd"))
	var script := load(adapter_path) as Script
	if script == null:
		_fail("cannot load the adapter %s" % adapter_path)
		return
	_adapter = script.new()
	if ids.is_empty():
		ids = PackedStringArray(_adapter.call("ids"))
	if data:
		_dump(ids)
		return
	if out == "":
		_fail("--out <dir> (or --data) is required")
		return
	DirAccess.make_dir_recursive_absolute(out)

	var ss := int(_cfg.get_value("shot", "supersample", 2))
	_build_stage(Vector2i(width * ss, height * ss))
	var failed := 0
	for id in ids:
		var poses := _poses(id)
		for pi in poses.size():
			var pose := poses[pi]
			var model := _adapter.call("model", id) as Node3D
			if model == null:
				push_error("readme_studio: no model for %s" % id)
				failed += 1
				break
			if not await _shoot(model, id, pose, out.path_join(("%s.png" % id) if pi == 0 else ("%s_%s.png" % [id, pose])), width, height):
				failed += 1
	get_tree().quit(1 if failed > 0 else 0)


func _fail(why: String) -> void:
	push_error("readme_studio: " + why)
	get_tree().quit(2)


## READMEDATA {"ids": [...], "items": {id: profile + {"poses": [...]}}}, one line, for gen_readme.py.
func _dump(ids: PackedStringArray) -> void:
	var items := {}
	for id in ids:
		var p: Dictionary = _adapter.call("profile", id) if _adapter.has_method("profile") else {"name": id}
		p["poses"] = Array(_poses(id))
		items[id] = p
	print("READMEDATA " + JSON.stringify({"ids": Array(ids), "items": items}))
	get_tree().quit(0)


func _poses(id: String) -> PackedStringArray:
	return String(_opt(id, "poses", "idle")).replace(" ", "").split(",", false)


## [pose] "<id>.<key>", else [shot] "<key>".
func _opt(id: String, key: String, fallback: Variant) -> Variant:
	return _cfg.get_value("pose", "%s.%s" % [id, key], _cfg.get_value("shot", key, fallback))


## Options for one pose, handed to the adapter: [pose] "<pose>.<k>" overridden by "<id>.<pose>.<k>".
func _pose_opts(id: String, pose: String) -> Dictionary:
	var o := {}
	if not _cfg.has_section("pose"):
		return o
	for k in _cfg.get_section_keys("pose"):
		if k.begins_with(pose + "."):
			o[k.substr(pose.length() + 1)] = _cfg.get_value("pose", k)
	for k in _cfg.get_section_keys("pose"):
		if k.begins_with("%s.%s." % [id, pose]):
			o[k.substr(id.length() + pose.length() + 2)] = _cfg.get_value("pose", k)
	return o


func _shoot(model: Node3D, id: String, pose: String, path: String, width: int, height: int) -> bool:
	_holder.rotation = Vector3.ZERO
	_holder.add_child(model)
	model.rotation_degrees = _cfg.get_value("pose", id + ".base", Vector3.ZERO)
	if _adapter.has_method("pose"):
		_adapter.call("pose", model, id, pose, _pose_opts(id, pose))
	_holder.rotation_degrees = Vector3(float(_opt(id, "tilt", 0.0)), float(_opt(id, "yaw", 145.0)), float(_opt(id, "roll", 0.0)))
	for f in 2:
		await get_tree().process_frame

	# A first guess from the rest bounds, then the camera is fitted to the rendered silhouette.
	var box := _aabb(_holder)
	var elev := deg_to_rad(float(_opt(id, "elevation", 10.0)))
	var dir := Vector3(0, sin(elev), cos(elev))
	var basis := Basis.looking_at(-dir, Vector3.UP)
	var tan_v := tan(deg_to_rad(_cam.fov) * 0.5)
	var aspect := float(_vp.size.x) / float(_vp.size.y)
	var target := box.get_center()
	var d := maxf(box.size.length() * 0.5, 0.05) / tan_v / 0.8
	var fill_x := float(_opt(id, "fill", 0.84))
	var fill_y := float(_opt(id, "fill_y", 0.80))
	# The ground follows the model: its lowest rendered point, unless the pack pins it ([shot] ground_y).
	var floor_y := float(_opt(id, "ground_y", box.position.y))
	_place_ground(box, floor_y, id)

	_measure_mode(true)
	for pass_i in int(_opt(id, "fit_passes", 4)):
		_cam.global_transform = Transform3D(basis, target + dir * d)
		_shadow_range(d, box)
		var img := await _grab()
		var used := img.get_used_rect()
		if used.size.x <= 0 or used.size.y <= 0:
			push_error("readme_studio: %s %s rendered nothing" % [id, pose])
			_measure_mode(false)
			_clear()
			return false
		var w := float(img.get_width())
		var h := float(img.get_height())
		var c := Vector2(used.position) + Vector2(used.size) * 0.5
		# Pixels to world at the target's depth, then slide the camera so the silhouette is centred.
		var per_px := 2.0 * d * tan_v / h
		var off := Vector2(c.x - w * 0.5, c.y - h * 0.5) * per_px
		target += basis.x * off.x - basis.y * off.y
		var s := maxf(float(used.size.x) / w / fill_x, float(used.size.y) / h / fill_y)
		d *= s
	_measure_mode(false)
	_cam.global_transform = Transform3D(basis, target + dir * d)
	_shadow_range(d, box)
	var img2 := await _grab()
	img2.resize(width, height, Image.INTERPOLATE_LANCZOS)
	var ok := img2.save_png(path) == OK
	print("READMESHOT %s %s %s" % [id, pose, path])
	_clear()
	return ok


func _grab() -> Image:
	for f in int(_cfg.get_value("shot", "settle_frames", 6)):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return _vp.get_texture().get_image()


func _clear() -> void:
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	for g in _ground:
		g.queue_free()
	_ground.clear()


## Transparent background, backdrop and ground hidden: the alpha of the frame is the model's silhouette.
func _measure_mode(on: bool) -> void:
	_vp.transparent_bg = on
	_env.background_mode = Environment.BG_CLEAR_COLOR if on else Environment.BG_CANVAS
	_env.glow_enabled = false if on else bool(_cfg.get_value("look", "glow", false))
	_back.visible = not on
	for g in _ground:
		g.visible = not on


func _shadow_range(d: float, box: AABB) -> void:
	_key.directional_shadow_max_distance = d + box.size.length() * 1.5


func _build_stage(size: Vector2i) -> void:
	_vp = SubViewport.new()
	_vp.size = size
	_vp.msaa_3d = Viewport.MSAA_8X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	_vp.positional_shadow_atlas_size = 4096
	add_child(_vp)

	var grad := Gradient.new()
	grad.set_color(0, Color(String(_cfg.get_value("look", "backdrop_center", "#6b7077"))))
	grad.set_color(1, Color(String(_cfg.get_value("look", "backdrop_edge", "#26282c"))))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.42)
	tex.fill_to = Vector2(1.15, 1.1)
	tex.width = 512
	tex.height = 288
	_back = TextureRect.new()
	_back.texture = tex
	_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_back.stretch_mode = TextureRect.STRETCH_SCALE
	_back.size = Vector2(size)
	_vp.add_child(_back)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.78, 0.80, 0.84)
	sky_mat.sky_horizon_color = Color(0.62, 0.63, 0.66)
	sky_mat.ground_horizon_color = Color(0.40, 0.40, 0.42)
	sky_mat.ground_bottom_color = Color(0.12, 0.12, 0.13)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	_env = Environment.new()
	_env.background_mode = Environment.BG_CANVAS
	_env.background_canvas_max_layer = 0
	_env.background_color = Color(0, 0, 0, 0)
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_energy = float(_cfg.get_value("look", "ambient", 0.55))
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_env.tonemap_mode = Environment.TONE_MAPPER_AGX
	_env.tonemap_exposure = float(_cfg.get_value("look", "exposure", 1.0))
	_env.ssao_enabled = true
	_env.ssao_radius = float(_cfg.get_value("look", "ssao_radius", 0.25))
	_env.ssao_intensity = 1.2
	var we := WorldEnvironment.new()
	we.environment = _env
	_vp.add_child(we)

	# Key (upper front left, soft shadows), fill (right, low), rim (behind, picks the silhouette off the backdrop).
	_key = _light(_cfg.get_value("look", "key_rot", Vector3(-38, -32, 0)), float(_cfg.get_value("look", "key", 2.2)), Color(1.0, 0.97, 0.92), true)
	var _f := _light(_cfg.get_value("look", "fill_rot", Vector3(-12, 62, 0)), float(_cfg.get_value("look", "fill", 0.7)), Color(0.88, 0.92, 1.0), false)
	var _r := _light(_cfg.get_value("look", "rim_rot", Vector3(-28, 168, 0)), float(_cfg.get_value("look", "rim", 1.8)), Color(1.0, 1.0, 1.0), false)

	_holder = Node3D.new()
	_vp.add_child(_holder)
	_cam = Camera3D.new()
	_cam.fov = float(_cfg.get_value("shot", "fov", 24.0))
	_cam.near = 0.02
	_cam.far = 4000.0
	_vp.add_child(_cam)
	_cam.current = true


func _light(rot_deg: Vector3, energy: float, color: Color, shadow: bool) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.rotation_degrees = rot_deg
	l.light_energy = energy
	l.light_color = color
	l.shadow_enabled = shadow
	l.shadow_blur = 1.5
	# Small primitive bodies acne at the default bias; [look] shadow_bias / shadow_normal_bias tune it.
	l.shadow_bias = float(_cfg.get_value("look", "shadow_bias", 0.08))
	l.shadow_normal_bias = float(_cfg.get_value("look", "shadow_normal_bias", 2.5))
	l.light_angular_distance = 2.0
	l.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_vp.add_child(l)
	return l


## A shadow catcher (only the cast shadow shows, fading out) and a soft contact blob under the footprint.
## Off with [shot] ground = false (a hovering or laid-down item).
func _place_ground(box: AABB, y: float, id: String) -> void:
	if not bool(_opt(id, "ground", true)):
		return
	var span := maxf(box.size.x, box.size.z)
	var catcher := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(span * 4.0, span * 4.0)
	catcher.mesh = plane
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode shadow_to_opacity, depth_draw_never, cull_disabled;
uniform float strength = 0.6;
void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = vec3(0.0);
	ALPHA = strength * (1.0 - smoothstep(0.35, 1.0, r));
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("strength", float(_cfg.get_value("look", "ground_shadow", 0.6)))
	catcher.material_override = m
	catcher.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	catcher.position = Vector3(box.get_center().x, y, box.get_center().z)
	_vp.add_child(catcher)
	_ground.append(catcher)

	var blob := MeshInstance3D.new()
	var bp := PlaneMesh.new()
	bp.size = Vector2(maxf(box.size.x, 0.01) * 1.15, maxf(box.size.z, 0.01) * 1.15)
	blob.mesh = bp
	var bs := Shader.new()
	bs.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
uniform float strength = 0.35;
void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = vec3(0.0);
	ALPHA = strength * pow(clamp(1.0 - r, 0.0, 1.0), 1.8);
}
"""
	var bm := ShaderMaterial.new()
	bm.shader = bs
	bm.set_shader_parameter("strength", float(_cfg.get_value("look", "contact", 0.35)))
	blob.material_override = bm
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blob.position = Vector3(box.get_center().x, y + 0.002 * span, box.get_center().z)
	_vp.add_child(blob)
	_ground.append(blob)


## World bounds of every visible mesh under [param root] (rest pose for skinned meshes).
func _aabb(root: Node) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		if not vi.is_visible_in_tree() or not (vi is GeometryInstance3D):
			continue
		var b := vi.get_aabb()
		if b.size == Vector3.ZERO:
			continue
		var xf := vi.global_transform
		for c in 8:
			var p: Vector3 = xf * b.get_endpoint(c)
			if first:
				out = AABB(p, Vector3.ZERO)
				first = false
			else:
				out = out.expand(p)
	return out
