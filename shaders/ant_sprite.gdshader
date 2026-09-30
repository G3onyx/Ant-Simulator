shader_type canvas_item;

uniform int col_num = 4;
uniform int row_num = 1;
uniform float animation_speed = 10.0;
uniform float sim_time;

uniform sampler2D ant_data_texture: filter_nearest;
uniform float tile_size;
uniform vec2 map_offset;

varying float v_food;

void vertex() {
	ivec2 tex_size = textureSize(ant_data_texture, 0);
	int x = INSTANCE_ID % tex_size.x;
	int y = INSTANCE_ID / tex_size.x;
	
	vec4 data = texelFetch(ant_data_texture, ivec2(x, y), 0);
	vec2 ant_pos = data.xy;
	float ant_angle = data.z + PI;
	
	v_food = data.w;
	
	// Create rotation matrix
	float c = cos(ant_angle);
	float s = sin(ant_angle);
	mat2 rot = mat2(vec2(c, s), vec2(-s, c));
	
	// Apply rotation to the local vertex coordinates
	VERTEX = rot * VERTEX;
	
	// Move the ant to its world position
	vec2 final_pos = (ant_pos + map_offset) * tile_size;
	VERTEX += final_pos;

	// Sprite animation
	float random_offset = INSTANCE_CUSTOM.x;
	int total_frames = col_num * row_num;
	int current_frame = int(sim_time * animation_speed + random_offset) % total_frames;
	
	int frame_x = current_frame % col_num;
	int frame_y = current_frame / col_num;
	
	vec2 frame_size = vec2(1.0 / float(col_num), 1.0 / float(row_num));
	UV = UV * frame_size;
	UV += vec2(float(frame_x), float(frame_y)) * frame_size;
}

void fragment() {
	vec4 tex_colour = texture(TEXTURE, UV);
	vec4 target_colour = vec4(1.0, 1.0, 0.0, tex_colour.a);
	
	float has_food = step(0.001, v_food);
	float is_full = step(0.99, v_food); 
	
	float carry_amount = has_food * mix(0.1, 0.75, v_food);
	float final_yellow_amount = mix(carry_amount, 1.0, is_full);
	
	COLOR = mix(tex_colour, target_colour, final_yellow_amount);
}