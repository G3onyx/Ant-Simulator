@tool
class_name Runner extends Node2D

enum Mode {Normal, Test1, Test2, Test3, Test4}
@export var mode := Mode.Normal
@export var ant_count := 100
@export var spawn_rate := 10.0 ## Ants per second
@export var colony_radius := 3.0: ## In tiles
	set(new_radius):
		colony_radius = new_radius
		queue_redraw()

var sim: Simulator
var testing := false
var terrain: TileMapLayer

var test_action: Callable
var test_state: Dictionary

var map_width: int
var map_height: int
var map_offset: Vector2

var time_scale := 1.0
var visual_timer := 0.0
var accumulator := 0.0
var active_tps := 0.0

# Drawing state
var pen_diameter := 1
var pending_strokes := PackedFloat32Array()

const PAN_SPEED := 300.0


func get_terrain() -> TileMapLayer:
	match mode:
		Mode.Test1: return %Test1
		Mode.Test2: return %Test2
		Mode.Test3: return %Test3
		Mode.Test4: return %Test4
	return %Terrain


func run(layer: TileMapLayer) -> void:
	if sim: sim.full_cleanup()
	sim = Simulator.new()
	
	%WorldSprite.material.set_shader_parameter("max_pheromone", float(sim.max_pheromone_per_cell))
	
	var terrain_rect = layer.get_used_rect()
	map_offset = terrain_rect.position
	map_width = max(terrain_rect.size.x, 1)
	map_height = max(terrain_rect.size.y, 1)
	
	var active_ant_count = ant_count
	var active_spawn_rate = spawn_rate
	var active_colony_radius = colony_radius
	if mode != Mode.Normal:
		var config = %Tests.tests_config[mode - 1]
		
		active_ant_count = config.get("ant_count", active_ant_count)
		active_spawn_rate = config.get("spawn_rate", active_spawn_rate)
		active_colony_radius = config.get("colony_radius", active_colony_radius)
		
		# Setup the mid-test event
		test_action = config.get("on frame", Callable())
		if test_action.is_valid():
			test_state = {
				"trigger_frame": int(G.DELETION_TIME * sim.TARGET_TPS),
				"triggered": false,
				"sim": sim
			}
	else:
		test_action = Callable()
		
	# Simulator setup
	sim.setup(
		ant_count, spawn_rate,
		map_width, map_height,
		G.colony_pos(map_offset), colony_radius,
		G.get_tilemap_data(layer, map_offset, map_width)
	)
	
	# Setup multi-mesh instance
	%Ants.multimesh.instance_count = ant_count
	%Ants.multimesh.mesh.size = G.tile_dims
	for i in range(ant_count): # Random animation offset so ant animations aren't synced
		%Ants.multimesh.set_instance_transform_2d(i, Transform2D())
		%Ants.multimesh.set_instance_custom_data(i, Color(sim.rng.randf() * 100.0, 0, 0, 0))
	
	# Setup world texture
	var tex = Texture2DRD.new()
	tex.texture_rd_rid = sim.textures["world"]
	%WorldSprite.texture = tex
	%WorldSprite.scale = G.tile_dims
	%WorldSprite.global_position = map_offset * G.tile_size
	
	# Setup render texture
	var rtex = Texture2DRD.new()
	rtex.texture_rd_rid = sim.textures["render"]
	%Ants.material.set_shader_parameter("ant_data_texture", rtex)
	%Ants.material.set_shader_parameter("tile_size", G.tile_size)
	%Ants.material.set_shader_parameter("map_offset", map_offset)


func _ready() -> void:
	if Engine.is_editor_hint(): return
	
	testing = testing or "testing" in OS.get_cmdline_user_args()
	
	if testing:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		
		for node in [%UI, %Camera, %Terrain, %Ants, %WorldSprite]:
			node.queue_free()
		
		%Tests.run_tests()
		return
	
	%Terrain.hide()
	%Tests.hide()
	%Ants.show()
	%WorldSprite.show()
	%TimeControl.time_scaled.connect(func(ts): time_scale = ts)
	run(get_terrain())


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or testing: return
	
	if pending_strokes.size() > 0:
		sim.apply_paint(pending_strokes)
		pending_strokes.clear()
	
	var dt = clamp(delta, 0.0001, 0.1)
	var pan_dir = Input.get_vector("left", "right", "up", "down")
	if pan_dir != Vector2.ZERO: %Camera._handle_pan(-pan_dir * PAN_SPEED * dt)
	
	var ticks = 0
	if time_scale > 0.0:
		accumulator += dt * time_scale
		while accumulator >= Simulator.TICK_TIME_SEC:
			ticks += 1
			accumulator -= Simulator.TICK_TIME_SEC
			
	active_tps = lerpf(active_tps, ticks / dt, 0.1)
	
	visual_timer += dt
	var should_render_frame = visual_timer >= 1.0 / 30.0
	if should_render_frame:
		visual_timer = 0.0
	
	sim.update(ticks, should_render_frame)
	
	if test_action.is_valid():
		test_action.call(sim.frame_count, test_state)
	
	if should_render_frame:
		%Ants.multimesh.visible_instance_count = int(sim.active_ants)
		%Ants.material.set_shader_parameter("sim_time", sim.frame_count * Simulator.TICK_TIME_SEC)
		queue_redraw()

func paint(value: float):
	if pending_strokes.size() >= G.MAX_STROKES * 4: return
	var center = G.to_grid(get_local_mouse_position(), map_offset)
	var channel = 0 if %UI.walls_or_food else 1
	var data = (channel + 1.0) * (1.0 if value > 0.5 else -1.0)
	pending_strokes.append_array([center.x, center.y, pen_diameter * 0.5, data])

func _unhandled_input(event: InputEvent) -> void:
	if testing: return
	
	var drawing = Input.is_action_pressed("drawing")
	if event is InputEventMouseMotion:
		if event.button_mask == 0: return
		if drawing:
			paint(1.0 if event.button_mask & MOUSE_BUTTON_MASK_LEFT else 0.0)
		else:
			%Camera._handle_pan(event.relative)
			
	if event is InputEventMouseButton and event.is_pressed():
		match event.button_index:
			MOUSE_BUTTON_LEFT: if drawing: paint(1.0)
			MOUSE_BUTTON_RIGHT: if drawing: paint(0.0)
			MOUSE_BUTTON_WHEEL_UP: 
				if drawing: pen_diameter = min(19, pen_diameter + 1)
				else: %Camera._handle_zoom(1)
			MOUSE_BUTTON_WHEEL_DOWN: 
				if drawing: pen_diameter = max(1, pen_diameter - 1)
				else: %Camera._handle_zoom(-1)

func get_brush_cells() -> Array[Vector2i]:
	var base := G.to_grid(get_local_mouse_position(), map_offset).floor()
	var center := base + Vector2(0.5, 0.5)
	var radius := pen_diameter * 0.5
	var radius_sq := radius * radius
	var bound := int(ceil(radius))
	
	var start_x := clampi(int(base.x) - bound, 0, map_width - 1)
	var end_x   := clampi(int(base.x) + bound, 0, map_width - 1)
	var start_y := clampi(int(base.y) - bound, 0, map_height - 1)
	var end_y   := clampi(int(base.y) + bound, 0, map_height - 1)

	var cells: Array[Vector2i] = []
	for y in range(start_y, end_y + 1):
		for x in range(start_x, end_x + 1):
			var tile_center := Vector2(x + 0.5, y + 0.5)
			var dx := tile_center.x - center.x
			var dy := tile_center.y - center.y
			if dx * dx + dy * dy <= radius_sq:
				cells.append(Vector2i(x, y))
	return cells

func _draw() -> void:
	if testing: return
	
	const colony_colour := Color(0.0, 1.0, 0.0, 1.0)
	const wall_colour := Color(0.4, 0.23, 0.2, 2.0) / 2.0
	const food_colour := Color(0.8, 0.9, 0.1, 2.0) / 2.0

	draw_circle(to_local(G.COLONY_POS), colony_radius * G.tile_size, colony_colour)
	
	if not Engine.is_editor_hint() and Input.is_action_pressed("drawing"):
		var col = wall_colour if %UI.walls_or_food else food_colour
		var size := G.tile_dims
		
		for cell in get_brush_cells():
			var world_pos = G.to_world(Vector2(cell), map_offset)
			draw_rect(Rect2(to_local(world_pos), size), col, true)

func update_stats() -> void:
	if testing: return
	
	var fps = Engine.get_frames_per_second()
	
	var speed_text := ""
	if time_scale == 0.0:
		speed_text = "[b][color=gray]PAUSED[/color][/b]\n"
	else:
		var ts = snapped(time_scale, 0.001)
		var display_speed = "%d" % ts if ts == floor(ts) else str(ts)
		speed_text = "[b][color=green]Speed: %sx[/color][/b]\n" % display_speed
		
	var live_stats := ""
	if time_scale > 0: # if not paused
		var real_tps := active_tps * Simulator.TICK_TIME_SEC
		var t = snapped(real_tps, 0.001)
		var display_tps = "%d" % t if t == floor(t) else str(t)
		
		if abs(real_tps - time_scale) > 0.1:
			live_stats += "True Speed: [color=gold]%sx[/color]\n" % display_tps
		
		if fps < 30:
			live_stats += "FPS: [color=crimson]%d[/color]\n" % fps
		else:
			live_stats += "FPS: %d\n" % fps
	
	var total_sim_seconds = int(sim.frame_count * Simulator.TICK_TIME_SEC)
	var hours = float(total_sim_seconds) / 3600
	var minutes = float(total_sim_seconds % 3600) / 60
	var seconds = total_sim_seconds % 60
	var time_str = "Sim Time: [color=cyan]%02d:%02d:%02d[/color]\n" % [hours, minutes, seconds]
	
	var mouse_str := ""
	var cell_pos := G.to_grid(get_local_mouse_position(), map_offset).floor()
	cell_pos.x = clamp(cell_pos.x, 0, map_width - 1)
	cell_pos.y = clamp(cell_pos.y, 0, map_height - 1)
	mouse_str = "Mouse Pos: [color=orange](%d, %d)[/color]\n" % [cell_pos.x, cell_pos.y]
	
	%Stats.text = \
		speed_text + \
		live_stats + \
		time_str + \
		mouse_str + \
		"Ants: %d / %d" % [int(sim.active_ants), ant_count]


func _on_reset_pressed() -> void:
	if testing: return
	%TimeControl.set_time_scale(1.0)
	accumulator = 0.0
	visual_timer = 0.0
	active_tps = 0.0
	pending_strokes.clear()
	run(get_terrain())


func _on_layers_item_selected(index: int) -> void:
	mode = index as Mode
