shader_type canvas_item;

uniform float max_pheromone = 1.0;

const vec4 floor_colour = vec4(0.2, 0.2, 0.2, 0.5);
const vec4 wall_colour = vec4(0.4, 0.23, 0.2, 1.0);
const vec4 food_colour = vec4(0.8, 0.9, 0.1, 1.0);
const vec4 p_food_colour = vec4(0.0, 1.0, 1.0, 1.0);
const vec4 p_home_colour = vec4(1.0, 0.0, 1.0, 1.0);
	
void fragment() {
	vec4 data = texture(TEXTURE, UV);
	
	float wall = data.r;
	float food = data.g;
	float p_food = data.b;
	float p_home = data.a;
	
	float intensity = max_pheromone;
	p_food = log(1.0 + p_food * intensity) / log(1.0 + intensity);
	p_home = log(1.0 + p_home * intensity) / log(1.0 + intensity);
	
	float visible_food = food > 0.001 ? mix(0.2, 1.0, food) : 0.0;
	float wall_mask = step(0.5, wall);
	
	vec4 final_colour = floor_colour;
	
	final_colour.rgb += p_home_colour.rgb * p_home * 0.8;
    final_colour.rgb += p_food_colour.rgb * p_food * 0.8;
	
	final_colour = mix(final_colour, food_colour, visible_food);
	final_colour = mix(final_colour, wall_colour, wall_mask);
    
    COLOR = final_colour;
}