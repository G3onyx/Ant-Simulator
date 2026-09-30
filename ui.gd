class_name UI extends CanvasLayer

const wall_sprite: Texture2D = preload("res://assets/draw_wall.png")
const food_sprite: Texture2D = preload("res://assets/draw_food.png")
var walls_or_food := true


func swap_draw_mode() -> void:
	walls_or_food = not walls_or_food
	%DrawMode.icon = wall_sprite if walls_or_food else food_sprite


func _unhandled_input(event):
	if event.is_action_pressed("swap_draw_mode"):
		swap_draw_mode()

func _on_draw_pressed() -> void:
	swap_draw_mode()
	
