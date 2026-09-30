#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

struct Cell {
    uint wall; // 0=empty, 1=wall
    uint food;
    uint _pheromone_food;
    uint _pheromone_home;
};

struct Stroke {
	vec2 pos;
	float radius;
	float data; // 1/-1: add/delete wall, 2/-2: add/delete food
};

layout(set = 0, binding = 0, std430) buffer WorldGrid { Cell map[]; };
layout(set = 0, binding = 1, rgba32f) uniform image2D world_tex;
layout(set = 0, binding = 2, std430) readonly buffer Strokes { Stroke strokes[]; };

layout(push_constant) uniform Push {
    uint stroke_count;
	uint _pad1, _pad2, _pad3;
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
    uint _pad1, _pad2;
} U;


void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= push.stroke_count) return;

    Stroke s = strokes[id];
    
    // Decode data
    int channel = int(abs(s.data)) - 1; // 0 = wall, 1 = food
    bool is_adding = s.data > 0;

    ivec2 base = ivec2(floor(s.pos));
    vec2 brush_center = vec2(base) + vec2(0.5);
    float rad_sq = s.radius * s.radius;
    int bound = int(ceil(s.radius));

    for (int y = -bound; y <= bound; y++) {
        for (int x = -bound; x <= bound; x++) {
            ivec2 cell = base + ivec2(x, y);
            if (cell.x < 0 || cell.y < 0 || cell.x >= U.map_w || cell.y >= U.map_h) continue;

            vec2 tile_center = vec2(cell) + vec2(0.5);
            vec2 diff = tile_center - brush_center;
            
            if (dot(diff, diff) <= rad_sq) {
                uint index = uint(cell.y) * U.map_w + uint(cell.x);

                if (channel == 0) // Wall
					atomicExchange(map[index].wall, is_adding ? 1u : 0u);
                else if (channel == 1) // Food
                    atomicExchange(map[index].food, is_adding ? U.max_food_per_cell : 0u);
            }
        }
    }
}