extends Node


const tile_size := 16.0
const tile_dims := Vector2.ONE * tile_size
const MAX_STROKES := 128
const MAX_TICKS_PER_FRAME := 200
const COLONY_POS := Vector2.ZERO
const DELETION_TIME := 5.0 * 60.0 # 5m0s

func to_grid(global_pos: Vector2, offset: Vector2) -> Vector2:
	return (global_pos / tile_size) - offset
func to_world(grid_pos: Vector2, offset: Vector2) -> Vector2:
	return (grid_pos + offset) * tile_size
	
func colony_pos(offset: Vector2) -> Vector2:
	return to_grid(COLONY_POS, offset)

func get_tilemap_data(layer: TileMapLayer, offset: Vector2, width: int) -> Dictionary:
	var walls: Array[int] = []
	var food: Array[int] = []
	for cell in layer.get_used_cells():
		var local = cell - Vector2i(offset)
		var idx = local.y * width + local.x
		var tile_data = layer.get_cell_tile_data(cell)
		if tile_data.get_custom_data("is_wall"):
			walls.append(idx)
		elif tile_data.get_custom_data("is_food"):
			food.append(idx)
	return {"walls": walls, "food": food}
