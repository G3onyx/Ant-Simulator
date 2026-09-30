class_name Tester extends Node


var sim: Simulator

var map_width: int
var map_height: int
var map_offset: Vector2


static func frange(start: float, end: float, samples: int) -> Array[float]:
	if end < start or samples < 2: return []
	# 0.0, 1.0, 5 -> [0.0, 0.25, 0.5, 0.75, 1.0]
	var values: Array[float] = [start]
	var step = (end - start) / (samples - 1)
	for i in range(1, samples - 1):
		values.append(start + i * step)
	values.append(end)
	return values


class StatAccumulator:
	var sum := 0.0
	var sum_sq := 0.0
	var count := 0

	func add(v: float) -> void:
		sum += v
		sum_sq += v * v
		count += 1

	func mean() -> float:
		return 0.0 if count == 0 else sum / count

	func stddev() -> float:
		if count < 2:
			return 0.0
		var variance := (sum_sq - (sum * sum) / count) / (count - 1)
		return sqrt(max(variance, 0.0))


func _make_vary_data(config: Dictionary, key: String, count: int) -> Dictionary:
	var v = config.get(key, [])
	return {} if v.is_empty() else {
		"var": v[0],
		"values": frange(v[1], v[2], count)
	}


func _make_scalar_stats(keys: Array) -> Dictionary:
	var out := {}
	for key in keys:
		out[key] = StatAccumulator.new()
	return out


func _make_frame_stats(keys: Array, frames: int) -> Dictionary:
	var out := {}
	for key in keys:
		var arr: Array = []
		arr.resize(frames)
		for i in range(frames):
			arr[i] = StatAccumulator.new()
		out[key] = arr
	return out
	
	

"""
--- TEST 1: Exploitation vs Exploration ---
Massive world, single food source far away
X axis: Vary curiosity 0.01 to 0.5
Y axis: ticks_to_first_food and total_food_collected
Low curiosity: Harder to locate, easier to retreive
High curiosity: Easier to locate, harder to retreive
"""
"""
--- TEST 2: Shortest path ---
2 paths to 1 food sources, one is shorter
Vary pheromone_decay_rate
X axis: time
Y axis: proportion of ants on each path
Multiple lines for different pheromone decay rates  
Ants should settle on short path
"""
"""
--- TEST 3: Noise resilience ---
Standard world with food
X axis: Sweep odometric error (cognitive drift) from 0.0 to 0.3
Y axis: total_food_collected
2 lines: Run once with pheromones on and once with pheromones off (pheromone_drop_rate = 0)
See how pheromones make up for blindness
"""
"""
--- TEST 4: Dynamic environment adaptation ---
World with 2 food sources, near and far
Delete near food halfway through test (vertical line)
X axis: time
Y axis: active_foraging_ants
Multiple lines for different pheromone decay rates
See how long active_foraging_ants takes to recover after deletion
"""

var default := {
	"ant_count": 100,
	"spawn_rate": 10.0,
	"colony_radius": 4.0,
	
	"tpf": 5 * Simulator.TARGET_TPS, # Pull metrics every 5ss
	"run_time": 60.0, # 60ss total
	
	"versions": 1,
	"sweeps": 10,
	"batches": 1,
}

@onready var tests_config := [
	{
		"name": "Exploitation vs Exploration",
		"layer": %Test1,
		"sweeps": 40,
		"batches": 40,
		"run_time": 8.5 * 60.0, # total 8m30s
		"vary per sweep": ["ant_curiosity", 0.0, 1.0],
		"record per sweep": ["ticks_to_first_food", "total_food_collected"],
	},
	{
		"name": "Shortest path",
		"layer": %Test2,
		"sweeps": 30,
		"batches": 50,
		"run_time": 8.5 * 60.0, # total 8m30s
		"vary per sweep": ["pheromone_decay_rate", 0.01, 0.8],
		"record per frame": ["short_path_traffic", "long_path_traffic"],
	},
	{
		"name": "Noise resilience",
		"layer": %Test3,
		"sweeps": 40,
		"batches": 40,
		"run_time": 3.5 * 60.0, # total 3m30s
		"versions": 2,
		"vary per version": ["pheromone_drop_rate", 0, 100],
		"vary per sweep": ["ant_odometric_error", 0.0, 0.8],
		"record per sweep": ["total_food_collected"],
	},
	{
		"name": "Recover from change",
		"layer": %Test4,
		"sweeps": 20,
		"batches": 100,
		"run_time": 12.0 * 60.0, # total 12m0s
		"vary per sweep": ["pheromone_decay_rate", 0.01, 0.8],
		"on frame": func(frame: int, state: Dictionary):
			if state.triggered: return
			if frame >= state.trigger_frame:
				state.triggered = true
				# Delete food at (60, 30) with radius 5 brush
				state.sim.apply_paint(PackedFloat32Array([60.0, 30.0, 5.0, -2.0])),
		"record per frame": ["active_foraging_ants"],
	}
]

func run_tests() -> void:
	var start_time = Time.get_ticks_msec()
	print("[Starting automated test suite]")
	print("Output directory: %s\n" % [ProjectSettings.globalize_path("user://")])
	
	var tests = range(tests_config.size())
	
	var total_simulated_seconds = 0.0
	for i in tests:
		var config = tests_config[i]
		print("\n--- Running test %d: %s ---" % [i + 1, config.name])
		total_simulated_seconds += await _run_test(config)
	
	var sim_hours = total_simulated_seconds / 3600.0
	print("\n[All tests completed in %d ms]" % [Time.get_ticks_msec() - start_time])
	print("[Total simulated agent time: %.2f hours]" % sim_hours)
	
	if sim: sim.full_cleanup()
	get_tree().quit()


func _run_test(config: Dictionary) -> float:
	if sim: sim.full_cleanup()
	sim = Simulator.new()
	
	# Test variables
	var ant_count: int = config.get("ant_count", default.ant_count)
	var spawn_rate: float = config.get("spawn_rate", default.spawn_rate)
	var colony_radius: float = config.get("colony_radius", default.colony_radius)
	
	var run_time: float = config.get("run_time", default.run_time)
	var tpf: int = config.get("tpf", default.tpf)
	var total_ticks := int(run_time * Simulator.TARGET_TPS)
	var frames := ceili(float(total_ticks) / tpf)
	
	var versions: int = config.get("versions", default.versions)
	var batches: int = config.get("batches", default.batches)
	var sweeps: int = config.get("sweeps", default.sweeps)

	var vdata = _make_vary_data(config, "vary per version", versions)
	var sdata = _make_vary_data(config, "vary per sweep", sweeps)
	
	var to_record_per_frame: Array = config.get("record per frame", [])
	var to_record_per_sweep: Array = config.get("record per sweep", [])
	var action: Callable = config.get("on frame", Callable())
	
	# Tilemap variables
	var layer: TileMapLayer = config.layer
	var rect = layer.get_used_rect()
	map_offset = rect.position
	map_width = max(rect.size.x, 1)
	map_height = max(rect.size.y, 1)
	
	var map_data: Dictionary = G.get_tilemap_data(layer, map_offset, map_width)

	# Simulator setup
	sim.setup(
		ant_count, spawn_rate,
		map_width, map_height,
		G.colony_pos(map_offset), colony_radius,
		map_data,
		true,
	)
	
	var total_sweeps: int = versions * sweeps
	var current_sweep: int = 0
	var test_start_time = Time.get_ticks_msec()
	
	# VERSIONS
	for version in range(versions):
		if not vdata.is_empty():
			sim.set(vdata.var, vdata.values[version])
		
		var all_sweeps_data := []
		
		# SWEEPS (parameter sweep)
		for sweep in range(sweeps):
			current_sweep += 1
			
			var current_param_val := 0.0
			if not sdata.is_empty():
				current_param_val = sdata.values[sweep]
				sim.set(sdata.var, current_param_val)
			
			var sweep_stats := _make_scalar_stats(to_record_per_sweep)
			var frame_stats := _make_frame_stats(to_record_per_frame, frames)
			
			# BATCHES (repeat)
			for batch in range(batches):
				sim.reset(map_data) 
				
				var action_state := {
					"trigger_frame": int(G.DELETION_TIME * sim.TARGET_TPS),
					"triggered": false,
					"sim": sim,
				}
				
				await _run_single_sim(
					frames, tpf,
					to_record_per_frame, to_record_per_sweep,
					action, action_state,
					frame_stats, sweep_stats
				)
				
				print("  - Batch %d/%d complete" % [batch + 1, batches])
			
			all_sweeps_data.append({
				"param_val": current_param_val,
				"sweep_stats": sweep_stats,
				"frame_stats": frame_stats
			})
			
			# ETA calculations
			var elapsed_msec = Time.get_ticks_msec() - test_start_time
			var avg_time_per_sweep = float(elapsed_msec) / current_sweep
			var remaining_sweeps = total_sweeps - current_sweep
			var eta_sec = int((avg_time_per_sweep * remaining_sweeps) / 1000.0)
			
			var param_name = sdata.get("var", "Baseline")
			print("  - Completed sweep %d/%d (%s: %f) | ETA: %02d:%02d" % [
				current_sweep, total_sweeps, param_name, current_param_val, 
				int(eta_sec / 60.0), eta_sec % 60
			])
			
		_save_results(config.name, version, all_sweeps_data, sdata, frames)
	
	return sweeps * batches * versions * run_time

func _run_single_sim(
	frames: int, snapshot_interval: int,
	to_record_per_frame: Array, to_record_per_sweep: Array,
	action: Callable, action_state: Dictionary,
	frame_stats: Dictionary, sweep_stats: Dictionary
) -> void:
	var record_frames = not to_record_per_frame.is_empty()
		
	var total_ticks_to_sim = frames * snapshot_interval if record_frames else frames * snapshot_interval
	total_ticks_to_sim = frames * snapshot_interval if snapshot_interval > 0 else int(frames * snapshot_interval)
	
	var ticks_processed = 0
	var chunk_size := sim.TESTING_TPS
	
	while ticks_processed < total_ticks_to_sim:
		if action.is_valid():
			action.call(sim.frame_count, action_state)

		var chunk = min(chunk_size, total_ticks_to_sim - ticks_processed)
		ticks_processed += chunk

		sim.update(chunk, false, snapshot_interval if record_frames else 0)
		sim.rd.submit()
		sim.rd.sync()
	
	await get_tree().process_frame
	
	if record_frames:
		var all_snapshots := sim.get_snapshots(frames)
		for key in to_record_per_frame:
			for frame_idx in range(frames):
				frame_stats[key][frame_idx].add(float(all_snapshots[key][frame_idx]))

	if not to_record_per_sweep.is_empty():
		var sweep_metrics := sim.get_metrics()
		for key in to_record_per_sweep:
			sweep_stats[key].add(float(sweep_metrics[key]))
			

func _save_results(test_name: String, version: int, all_sweeps_data: Array, sdata: Dictionary, frames: int) -> void:
	var base_name = test_name.replace(" ", "_").to_lower() + "_v%d" % version
	var has_sweep = not sdata.is_empty()
	var sweep_name = sdata.get("var", "sweep_idx")
	
	# Summary data
	if not all_sweeps_data[0].sweep_stats.is_empty():
		var f = FileAccess.open("user://%s_summary.csv" % base_name, FileAccess.WRITE)
		
		# Build header
		var header = sweep_name
		for metric in all_sweeps_data[0].sweep_stats.keys():
			header += ",%s_mean,%s_std" % [metric, metric]
		f.store_line(header)
		
		# Write rows
		for i in range(all_sweeps_data.size()):
			var data = all_sweeps_data[i]
			var row = str(data.param_val) if has_sweep else str(i)
			
			for metric in data.sweep_stats.keys():
				var stat: StatAccumulator = data.sweep_stats[metric]
				row += ",%f,%f" % [stat.mean(), stat.stddev()]
				
			f.store_line(row)
	
	# Time-series data
	if not all_sweeps_data[0].frame_stats.is_empty():
		var f = FileAccess.open("user://%s_timeseries.csv" % base_name, FileAccess.WRITE)
		
		var header = "frame"
		for i in range(all_sweeps_data.size()):
			var sweep_data = all_sweeps_data[i]
			var prefix = "%s_%s_" % [sweep_name, str(sweep_data.param_val)] if has_sweep else "S%d_" % i
			
			for metric in sweep_data.frame_stats.keys():
				header += ",%s%s_mean,%s%s_std" % [prefix, metric, prefix, metric]
		f.store_line(header)
		
		for frame_idx in range(frames):
			var row = str(frame_idx)
			
			for i in range(all_sweeps_data.size()):
				var sweep_data = all_sweeps_data[i]
				
				for metric in sweep_data.frame_stats.keys():
					var stat: StatAccumulator = sweep_data.frame_stats[metric][frame_idx]
					row += ",%f,%f" % [stat.mean(), stat.stddev()]
					
			f.store_line(row)

	print("  - Saved: %s_summary.csv" % base_name)
	if not all_sweeps_data[0].frame_stats.is_empty():
		print("  - Saved: %s_timeseries.csv" % base_name)
