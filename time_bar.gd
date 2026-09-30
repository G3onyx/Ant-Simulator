extends HBoxContainer

const OPTIONS := [
	{ text = "", speed = 0.0 },
	{ text = "5%", speed = 0.05 },
	{ text = "20%", speed = 0.2 },
	{ text = "1x", speed = 1.0 },
	{ text = "5x", speed = 5.0 },
	{ text = "20x", speed = 20.0 },
	{ text = "50x", speed = 50.0 },
	{ text = "MAX", speed = 200.0 },
]

@onready var buttons: Array[Button] = [%Pause]
var button_group := ButtonGroup.new()

signal time_scaled(time_scale: float)

const BUTTON_SIZE := 40.0 * Vector2.ONE

func _ready() -> void:
	var button: Button = %Pause
	
	for i in range(OPTIONS.size()):
		if i > 0:
			button = Button.new()
			add_child(button)
			buttons.append(button)
			
		var option = OPTIONS[i]
		button.text = option.text
		button.custom_minimum_size = BUTTON_SIZE
		button.toggle_mode = true
		button.button_group = button_group
		
		button.pressed.connect(func():
			time_scaled.emit(option.speed)
		)
		
	set_time_scale(1.0)


func set_time_scale(time_scale: float) -> void:
	for i in range(OPTIONS.size()):
		if OPTIONS[i].speed == time_scale:
			buttons[i].button_pressed = true
			buttons[i].pressed.emit()
			return
