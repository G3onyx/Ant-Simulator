class_name Simulator extends RefCounted

var max_food_per_cell := 1000
var max_pheromone_per_cell := 1000
var pheromone_decay_rate := 0.1 ## How quickly pheromones disappear
var pheromone_diffusion_rate := 0.02 ## How quickly pheromones spread out
var recruitment_multiplier := 2.0 ## Intensity multiplier for to-food pheromone

var pheromone_drop_rate := 100 ## Pheromones dropped per second
var ant_odometric_error := 0.05 ## Cumulative percentage error per second in navigation
var ant_max_carry := 50 ## Maximum food an ant can carry
var ant_gather_time := 1.0 ## Seconds to pick up or drop off food
var ant_speed := 2.0
var ant_curiosity := 0.1 ## Likelihood of ants ignoring pheromone trails

const SPATIAL_GRID_CELL_SIZE := 2.0

# GPU state
var using_local_rd := false
var rd: RenderingDevice
var rids: Array[RID] = []
var shader_rids: Array[RID] = []
var buffers := {}
var textures := {}
var shaders := {}
var pipelines := {}
var uniform_sets := {}

var params := PackedByteArray()
var push_process := PackedByteArray()
var push_build := PackedByteArray()
var push_clear := PackedByteArray()
var push_evap := PackedByteArray()
var push_render := PackedByteArray()
var push_paint := PackedByteArray()


var ant_count: int
var spawn_rate: float
var map_width: int
var map_height: int
var colony_pos: Vector2
var colony_rad: float

var frame_count := 0
var map_ticks := 0
var batch_ticks := 0
var evp_count := 0
var active_ants := 0.0
var ping_pong := false
var grid_heads_size := 0
var rng := RandomNumberGenerator.new()

# Timing state
const TARGET_TPS := 60
const TESTING_TPS := 2000
const TICK_TIME_SEC := 1.0 / TARGET_TPS


func setup(
	ant_count_: int, spawn_rate_: float,
	map_width_: int, map_height_: int,
	colony_pos_: Vector2, colony_rad_: float, 
	terrain_data: Dictionary = {},
	headless: bool = false
) -> void:
	ant_count = ant_count_; spawn_rate = spawn_rate_;
	map_width = map_width_; map_height = map_height_
	colony_pos = colony_pos_; colony_rad = colony_rad_
	
	# Setup push arrays
	push_evap.resize(16)
	params.resize(80)
	push_process.resize(32)
	push_build.resize(16)
	push_clear.resize(16)
	push_render.resize(16)
	push_paint.resize(16)
	
	# Setup rendering device
	if headless:
		using_local_rd = true
		rd = RenderingServer.create_local_rendering_device()
	else:
		rd = RenderingServer.get_rendering_device()
	
	if rd == null:
		printerr("CRITICAL ERROR: Failed to create a RenderingDevice")
		return
	
	reset(terrain_data)


func reset(terrain_data: Dictionary) -> void:
	frame_count = 0
	map_ticks = 0
	evp_count = 0
	active_ants = 0.0
	ping_pong = false
	batch_ticks = 0
	
	if not rids.is_empty(): cleanup()
	_setup_gpu(terrain_data)
	
	# Encode static constants
	push_build.encode_u32(12, 0)
	
	push_clear.encode_u32(0, 0) # pass_mode = 0
	push_clear.encode_u32(4, grid_heads_size)
	push_clear.encode_float(8, 0.0) 
	push_clear.encode_u32(12, 0)
	
	push_render.encode_u32(0, 2)
	
	push_paint.encode_u32(4, 0)
	push_paint.encode_u32(8, 0)
	push_paint.encode_u32(12, 0)
	

func cleanup() -> void:
	rids.reverse()
	for rid in rids:
		if rid.is_valid(): 
			rd.free_rid(rid)
	
	rids.clear()
	buffers.clear()
	textures.clear()
	uniform_sets.clear()

func full_cleanup() -> void:
	cleanup()
	
	shader_rids.reverse()
	for rid in shader_rids:
		if rid.is_valid():
			rd.free_rid(rid)
			
	shader_rids.clear()
	pipelines.clear()
	shaders.clear()
	
	if using_local_rd:
		using_local_rd = false
		rd.free()
		rd = null

func get_metrics() -> Dictionary:
	var data := rd.buffer_get_data(buffers["metrics"])
	return {
		"frame_count": frame_count,
		"ticks_to_first_food": data.decode_u32(0),
		"total_food_collected": data.decode_u32(4),
		"active_foraging_ants": data.decode_u32(8),
		"short_path_traffic": data.decode_u32(12),
		"long_path_traffic": data.decode_u32(16)
	}
	

func _make_buf(bytes: PackedByteArray) -> RID:
	var rid = rd.storage_buffer_create(bytes.size(), bytes)
	rids.append(rid)
	return rid

func _make_tex(fmt: RDTextureFormat, data: Array[PackedByteArray]) -> RID:
	var rid = rd.texture_create(fmt, RDTextureView.new(), data)
	rids.append(rid)
	return rid

func _update_params_buffer() -> void:
	var time_per_unit = ant_gather_time / float(ant_max_carry)
	var drop_amt = int(pheromone_drop_rate * TICK_TIME_SEC)
	
	params.encode_float(0, colony_pos.x)
	params.encode_float(4, colony_pos.y)
	params.encode_u32(8, map_width)
	params.encode_u32(12, map_height)
	
	params.encode_float(16, ant_curiosity)
	params.encode_float(20, ant_odometric_error)
	params.encode_float(24, recruitment_multiplier)
	params.encode_float(28, colony_rad * colony_rad)
	
	params.encode_float(32, ant_speed)
	params.encode_u32(36, ant_max_carry)
	params.encode_float(40, time_per_unit)
	params.encode_u32(44, drop_amt)
	
	params.encode_float(48, pheromone_decay_rate)
	params.encode_float(52, pheromone_diffusion_rate)
	params.encode_u32(56, max_food_per_cell)
	params.encode_u32(60, max_pheromone_per_cell)
	
	params.encode_float(64, SPATIAL_GRID_CELL_SIZE)
	params.encode_float(68, TICK_TIME_SEC)
	params.encode_u32(72, frame_count)
	params.encode_u32(76, 0)
	
	if "params" in buffers:
		rd.buffer_update(buffers["params"], 0, 80, params)
	else:
		var ubo_rid = rd.uniform_buffer_create(params.size(), params)
		rids.append(ubo_rid)
		buffers["params"] = ubo_rid
			
func _setup_gpu(terrain_data: Dictionary) -> void:
	# World grid and texture
	var total_cells = map_width * map_height
	
	var grid_data = PackedInt32Array()
	grid_data.resize(total_cells * 4)
	grid_data.fill(0)
	
	var tex_data = PackedFloat32Array()
	tex_data.resize(total_cells * 4)
	tex_data.fill(0.0)
	
	if not terrain_data.is_empty():
		for idx in terrain_data["walls"]:
			grid_data[idx * 4] = 1
			tex_data[idx * 4] = 1.0
		for idx in terrain_data["food"]:
			grid_data[idx * 4 + 1] = max_food_per_cell 
			tex_data[idx * 4 + 1] = 1.0
			
	var fmt = RDTextureFormat.new()
	fmt.width = map_width
	fmt.height = map_height
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	
	textures["world"] = _make_tex(fmt, [tex_data.to_byte_array()])
	
	var grid_bytes = grid_data.to_byte_array()
	buffers["grid_a"] = _make_buf(grid_bytes)
	buffers["grid_b"] = _make_buf(grid_bytes)
	
	# Ants buffer	
	var ant_bytes := PackedByteArray()
	ant_bytes.resize(ant_count * 32) 
	for i in range(ant_count):
		var theta = rng.randf() * TAU
		var offset_pos = colony_pos + (Vector2(cos(theta), sin(theta)) * colony_rad * sqrt(rng.randf()))
		var off := i * 32
		var to_home = colony_pos - offset_pos
		
		ant_bytes.encode_float(off + 0, offset_pos.x)
		ant_bytes.encode_float(off + 4, offset_pos.y)
		ant_bytes.encode_float(off + 8, rng.randf() * TAU)
		ant_bytes.encode_u32(off + 12, 0) # state
		ant_bytes.encode_float(off + 16, to_home.x)
		ant_bytes.encode_float(off + 20, to_home.y)
		ant_bytes.encode_u32(off + 24, 0) # food
		ant_bytes.encode_float(off + 28, 0.0) # timer
	buffers["ants"] = _make_buf(ant_bytes)
	
	# Spatial grid and strokes
	var gx = max(1, int(ceil(float(map_width) / SPATIAL_GRID_CELL_SIZE)))
	var gy = max(1, int(ceil(float(map_height) / SPATIAL_GRID_CELL_SIZE)))
	grid_heads_size = gx * gy
	
	var heads_bytes := PackedByteArray()
	heads_bytes.resize(grid_heads_size * 4)
	buffers["heads"] = _make_buf(heads_bytes)
	
	var zero_next := PackedByteArray()
	zero_next.resize(ant_count * 4)
	buffers["next"] = _make_buf(zero_next)
	
	var stroke_bytes := PackedFloat32Array()
	stroke_bytes.resize(G.MAX_STROKES * 4)
	buffers["strokes"] = _make_buf(stroke_bytes.to_byte_array())
	
	# Render texture
	var rfmt = RDTextureFormat.new()
	rfmt.width = max(1, int(ceil(sqrt(ant_count))))
	rfmt.height = rfmt.width
	rfmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	rfmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	textures["render"] = _make_tex(rfmt, [])
	
	# Metrics
	var metrics_bytes := PackedByteArray()
	metrics_bytes.resize(32 + (512 * 4 * 3)) # 6176 bytes
	metrics_bytes.fill(0)
	metrics_bytes.encode_u32(0, 0xFFFFFFFF)
	buffers["metrics"] = _make_buf(metrics_bytes)
	
	# Pipelines
	if pipelines.is_empty():
		var make_pipe = func(path: String, key: String) -> void:
			var sh = rd.shader_create_from_spirv(load(path).get_spirv())
			var pipe = rd.compute_pipeline_create(sh)
			shader_rids.append_array([sh, pipe])
			shaders[key] = sh
			pipelines[key] = pipe

		make_pipe.call("res://shaders//ants_build.glsl", "build")
		make_pipe.call("res://shaders//ants_process.glsl", "process")
		make_pipe.call("res://shaders//map_process.glsl", "map")
		make_pipe.call("res://shaders//paint.glsl", "paint")
	
	# Uniform sets
	var mk_u = func(b: int, id: RID, type: RenderingDevice.UniformType) -> RDUniform:
		var u = RDUniform.new();
		u.binding = b;
		u.uniform_type = type;
		u.add_id(id);
		return u
		
	_update_params_buffer()
	
	var make_main_u = func(grid_buf: RID) -> Array:
		return [
			mk_u.call(0, buffers["ants"], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(1, grid_buf, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(2, buffers["heads"], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(3, buffers["next"], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(4, textures["render"], RenderingDevice.UNIFORM_TYPE_IMAGE),
			mk_u.call(5, textures["world"], RenderingDevice.UNIFORM_TYPE_IMAGE),
			mk_u.call(6, buffers["params"], RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER),
			mk_u.call(7, buffers["metrics"], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
		]
	
	var make_map_u = func(grid_in: RID, grid_out: RID) -> Array:
		return [
			mk_u.call(0, grid_in, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(1, grid_out, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(2, buffers["heads"], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(3, textures["world"], RenderingDevice.UNIFORM_TYPE_IMAGE),
			mk_u.call(6, buffers["params"], RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)
		]

	var make_paint_u = func(grid_buf: RID) -> Array:
		return [
			mk_u.call(0, grid_buf, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(1, textures["world"], RenderingDevice.UNIFORM_TYPE_IMAGE),
			mk_u.call(2, buffers["strokes"], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			mk_u.call(6, buffers["params"], RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)
		]
	
	var mk_set = func(u_arr: Array, shader_key: String) -> RID:
		var s = rd.uniform_set_create(u_arr, shaders[shader_key], 0)
		rids.append(s)
		return s
	
	uniform_sets["main_a"] = mk_set.call(make_main_u.call(buffers["grid_a"]), "build")
	uniform_sets["main_b"] = mk_set.call(make_main_u.call(buffers["grid_b"]), "build")
	
	uniform_sets["map_a"] = mk_set.call(make_map_u.call(buffers["grid_a"], buffers["grid_b"]), "map") # Reads A, writes B
	uniform_sets["map_b"] = mk_set.call(make_map_u.call(buffers["grid_b"], buffers["grid_a"]), "map") # Reads B, writes A
	
	uniform_sets["paint_a"] = mk_set.call(make_paint_u.call(buffers["grid_a"]), "paint")
	uniform_sets["paint_b"] = mk_set.call(make_paint_u.call(buffers["grid_b"]), "paint")


func update(ticks: int, should_render_frame: bool = false, snapshot_interval: int = 0) -> void:
	if ticks <= 0 and not should_render_frame: return
	
	_update_params_buffer()
	
	var list = rd.compute_list_begin()
	
	var map_set = "map_b" if ping_pong else "map_a"
	var main_set = "main_b" if ping_pong else "main_a"
	
	for i in range(ticks):
		batch_ticks += 1
		var is_final_tick = i == ticks - 1
		var render_this_tick = 1 if (should_render_frame and is_final_tick) else 0
		
		var snap_this_tick = 0
		var snapshot_idx = 0
		
		if snapshot_interval > 0 and (batch_ticks % snapshot_interval) == 0:
			snap_this_tick = 1
			snapshot_idx = int(batch_ticks / float(snapshot_interval)) - 1
		
		_step_sim(list, map_set, main_set, render_this_tick, snap_this_tick, snapshot_idx)
		map_ticks += 1
		
		if map_ticks >= 4:
			_dispatch_evaporation(list, map_ticks, map_set)
			ping_pong = not ping_pong
			map_set = "map_b" if ping_pong else "map_a"
			main_set = "main_b" if ping_pong else "main_a"
			map_ticks = 0
	
	if map_ticks > 0:
		_dispatch_evaporation(list, map_ticks, map_set)
		ping_pong = not ping_pong
		map_ticks = 0
		
	if should_render_frame:
		_dispatch_render_map(list, map_set)
			
	rd.compute_list_end()


func _step_sim(list: int, map_set: String, main_set: String, render_this_tick: int, snap_this_tick: int, snapshot_idx: int) -> void:
	if active_ants < ant_count:
		active_ants = min(active_ants + (spawn_rate * TICK_TIME_SEC), ant_count)
	
	var groups = int(ceil(active_ants / 64.0))
	if groups == 0: return

	_dispatch_clear(list, map_set) # Clear heads
	_dispatch_build_and_process(list, groups, main_set, render_this_tick, snap_this_tick, snapshot_idx) # Build and process
	
	frame_count += 1

func _run_compute(list: int, pipe: String, u_set: String, push: PackedByteArray, x_groups: int, y_groups: int = 1):
	rd.compute_list_bind_compute_pipeline(list, pipelines[pipe])
	rd.compute_list_bind_uniform_set(list, uniform_sets[u_set], 0)
	
	if push.size() > 0:
		rd.compute_list_set_push_constant(list, push, push.size())
	
	rd.compute_list_dispatch(list, x_groups, y_groups, 1)
	rd.compute_list_add_barrier(list)

func _dispatch_clear(list: int, map_set: String) -> void:
	var x_groups = int(ceil(map_width / 16.0))
	var y_groups = int(ceil(map_height / 16.0))
	_run_compute(list, "map", map_set, push_clear, x_groups, y_groups)

func _dispatch_evaporation(list: int, tick_num: int, map_set: String) -> void:
	evp_count += 1
	
	push_evap.encode_u32(0, 1) # pass_mode = 1
	push_evap.encode_u32(4, evp_count)
	var decay_factor = exp(-pheromone_decay_rate * tick_num * TICK_TIME_SEC)
	push_evap.encode_float(8, decay_factor)
	push_evap.encode_u32(12, tick_num)
	
	var x_groups = int(ceil(map_width / 16.0))
	var y_groups = int(ceil(map_height / 16.0))
	_run_compute(list, "map", map_set, push_evap, x_groups, y_groups)

func _dispatch_render_map(list: int, map_set: String) -> void:
	var x_groups = int(ceil(map_width / 16.0))
	var y_groups = int(ceil(map_height / 16.0))
	_run_compute(list, "map", map_set, push_render, x_groups, y_groups)
	
func _dispatch_build_and_process(list: int, groups: int, main_set: String, render_this_tick: int, snap_this_tick: int, snapshot_idx: int) -> void:
	push_build.encode_u32(0, int(active_ants)) # Read by both shaders
	push_build.encode_u32(4, frame_count) # Read only by ants_process
	push_build.encode_u32(8, render_this_tick)
	_run_compute(list, "build", main_set, push_build, groups)
	
	push_process.encode_u32(0, int(active_ants))
	push_process.encode_u32(4, frame_count)
	push_process.encode_u32(8, render_this_tick)
	push_process.encode_u32(12, snap_this_tick)
	push_process.encode_u32(16, snapshot_idx)
	_run_compute(list, "process", main_set, push_process, groups)

func apply_paint(strokes: PackedFloat32Array) -> void:
	var stroke_count = floori(strokes.size() / 4.0)
	var upload = strokes.duplicate()
	upload.resize(G.MAX_STROKES * 4)
	rd.buffer_update(buffers["strokes"], 0, upload.size() * 4, upload.to_byte_array())
	
	push_paint.encode_u32(0, stroke_count)
	
	var paint_set = "paint_b" if ping_pong else "paint_a"
	
	var list = rd.compute_list_begin()
	_run_compute(list, "paint", paint_set, push_paint, int(ceil(stroke_count / 32.0)))
	rd.compute_list_end()

func get_snapshots(frames: int) -> Dictionary:
	var data := rd.buffer_get_data(buffers["metrics"])
	var result := {
		"active_foraging_ants": [],
		"short_path_traffic": [],
		"long_path_traffic": []
	}
	# Calculate byte offsets (32 byte header + 2048 bytes per array)
	for i in range(frames):
		result["active_foraging_ants"].append(data.decode_u32(32 + (i * 4)))
		result["short_path_traffic"].append(data.decode_u32(2080 + (i * 4)))
		result["long_path_traffic"].append(data.decode_u32(4128 + (i * 4)))
	return result
