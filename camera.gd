extends Camera2D

@export var max_zoom_in: float = 8.0
@export var max_zoom_out: float = 1.0 / 16.0
@export var zoom_factor_step: float = 1.4

@export var zoom_smoothness: float = 6.0 
@export var pan_smoothness: float = 6.0

var _zoom: float
var _target_zoom: float
var _zoom_pos: Vector2
var _pan_vel: Vector2 = Vector2.ZERO
var _last_pos: Vector2
var _last_time_usec: int

func _ready() -> void:		
	_zoom = log(zoom.x)
	_target_zoom = _zoom
	_last_pos = global_position
	_last_time_usec = Time.get_ticks_usec()

func _handle_pan(movement: Vector2):
	global_position -= movement / zoom.x
	
func _handle_zoom(dir: int):
	_zoom_pos = get_viewport().get_mouse_position()
	_target_zoom += dir * log(zoom_factor_step)
	
	var target_linear = clamp(exp(_target_zoom), max_zoom_out, max_zoom_in)
	_target_zoom = log(target_linear)


func _process(_delta: float) -> void:
	var current_time = Time.get_ticks_usec()
	var real_delta = (current_time - _last_time_usec) / 1000000.0
	_last_time_usec = current_time
	real_delta = min(real_delta, 0.1) # safety cap for lag
	
	# Zooming
	var zoom_weight = 1.0 - exp(-zoom_smoothness * real_delta)
	_zoom = lerp(_zoom, _target_zoom, zoom_weight)

	var new_zoom_raw = exp(_zoom)
	
	if abs(_zoom - _target_zoom) < 0.0001:
		_zoom = _target_zoom
		new_zoom_raw = exp(_zoom)

	# Zoom to mouse
	if not is_equal_approx(new_zoom_raw, zoom.x):
		var mouse_before = get_canvas_transform().affine_inverse() * _zoom_pos
		zoom = Vector2(new_zoom_raw, new_zoom_raw)
		force_update_scroll()
		var mouse_after = get_canvas_transform().affine_inverse() * _zoom_pos
		global_position += mouse_before - mouse_after

	# Panning
	if Input.get_mouse_button_mask() != 0:
		# Calculate velocity while dragging/pushing
		var current_speed = (global_position - _last_pos) / real_delta
		_pan_vel = _pan_vel.lerp(current_speed, 1.0 - exp(-20.0 * real_delta))
	else:
		# Apply drift after inputs are released
		global_position += _pan_vel * real_delta
		_pan_vel *= exp(-pan_smoothness * real_delta)
		
		if _pan_vel.length() < 0.01:
			_pan_vel = Vector2.ZERO

	_last_pos = global_position
