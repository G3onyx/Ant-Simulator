#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

struct Cell {
    uint wall; // 0=empty, 1=wall
    uint food;
    uint pheromone_food;
    uint pheromone_home;
};

layout(set = 0, binding = 0, std430) readonly buffer WorldGridIn { Cell map_in[]; };
layout(set = 0, binding = 1, std430) buffer WorldGridOut { Cell map_out[]; };
layout(set = 0, binding = 2, std430) buffer GridHeads { uint heads[]; };
layout(set = 0, binding = 3, rgba32f) uniform image2D world_tex;

layout(push_constant) uniform Push {
    uint pass_mode; // 0=clear, 1=evaporate, 2=render
	uint multiuse; // grid_size (0) or evp_count (1)
	float decay_factor;
    uint diff_mult;
} push;

layout(set = 0, binding = 6, std140) uniform Params {
    vec2 colony_pos;
    uint map_w;
    uint map_h;
	
    float curiosity;
    float odometric_error;
    float recruitment_mult;
    float colony_radius_sq;
	
    float speed;
    uint max_carry;
    float time_per_unit;
    uint drop_amount;

    float decay_rate;
    float diffusion_rate;
    uint max_food_per_cell;
    uint max_pheromone_per_cell;
	
	float cell_size;
    float tick_delta;
    uint frame_count;
	uint _pad2;
} U;


uint pcg_hash(inout uint seed) {
    seed = seed * 747796405u + 2891336453u;
    uint word = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand(inout uint seed) {
    return float(pcg_hash(seed) & 0x00FFFFFFu) * (1.0 / float(0x01000000));
}


void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= U.map_w || p.y >= U.map_h) return;
	
    uint id = p.y * U.map_w + p.x;

    // Buffer clear (runs every tick)
    if (push.pass_mode == 0u) {
        if (id < push.multiuse) heads[id] = 0u;
		return;
    }

    // Evaporation and Diffusion
    if (push.pass_mode == 1u) {
		// Copy static state to new buffer
        map_out[id].wall = map_in[id].wall;
        map_out[id].food = map_in[id].food;
		
		// No diffusion within walls
		if (map_in[id].wall > 0u) {
            map_out[id].pheromone_food = 0u;
            map_out[id].pheromone_home = 0u;
            return;
        }
		
		vec2 center = vec2(float(map_in[id].pheromone_food), float(map_in[id].pheromone_home));
        vec2 lap = -center;
		
		int w = int(U.map_w);
        int n_row = max(0, p.y - 1) * w;
        int s_row = min(int(U.map_h) - 1, p.y + 1) * w;
        int c_row = p.y * w;
        int w_col = max(0, p.x - 1);
        int e_col = min(w - 1, p.x + 1);

        uint N = n_row + p.x;
        uint S = s_row + p.x;
        uint E = c_row + e_col;
        uint W = c_row + w_col;
        uint NW = n_row + w_col;
        uint NE = n_row + e_col;
        uint SW = s_row + w_col;
        uint SE = s_row + e_col;
		
		// Orthogonal (0.20)
        lap += vec2(float(map_in[N].pheromone_food), float(map_in[N].pheromone_home)) * 0.20;
        lap += vec2(float(map_in[S].pheromone_food), float(map_in[S].pheromone_home)) * 0.20;
        lap += vec2(float(map_in[E].pheromone_food), float(map_in[E].pheromone_home)) * 0.20;
        lap += vec2(float(map_in[W].pheromone_food), float(map_in[W].pheromone_home)) * 0.20;

        lap += vec2(float(map_in[NW].pheromone_food), float(map_in[NW].pheromone_home)) * 0.05;
        lap += vec2(float(map_in[NE].pheromone_food), float(map_in[NE].pheromone_home)) * 0.05;
        lap += vec2(float(map_in[SW].pheromone_food), float(map_in[SW].pheromone_home)) * 0.05;
        lap += vec2(float(map_in[SE].pheromone_food), float(map_in[SE].pheromone_home)) * 0.05;
		
		// Apply PDE and exponential decay
		float batched_D = min(U.diffusion_rate * float(push.diff_mult), 0.25);
        vec2 diff = center + (batched_D * lap);
        diff *= push.decay_factor;
		
        if (diff.x < 0.1) diff.x = 0.0;
        if (diff.y < 0.1) diff.y = 0.0;

		// Stochastic rounding
		uint seed = id + push.multiuse * 78213u;
        uint hash = pcg_hash(seed);
        float r = float(hash & 0x00FFFFFFu) * (1.0 / float(0x01000000));

        map_out[id].pheromone_food = min(uint(max(0.0, diff.x) + r), U.max_pheromone_per_cell);
        map_out[id].pheromone_home = min(uint(max(0.0, diff.y) + r), U.max_pheromone_per_cell);
    }
	
	// Render only
	else if (push.pass_mode == 2u) {
        vec4 pixel = vec4(
            map_in[id].wall > 0u ? 1.0 : 0.0,
            float(map_in[id].food) / float(U.max_food_per_cell),
            float(map_in[id].pheromone_food) / float(U.max_pheromone_per_cell),
            float(map_in[id].pheromone_home) / float(U.max_pheromone_per_cell)
        );
        imageStore(world_tex, p, pixel);
    }
}