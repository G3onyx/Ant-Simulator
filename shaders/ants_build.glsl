#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct Ant {
    vec2 pos;
    float ang;
    uint state;
	
    vec2 home_dir;
    uint food;
    float timer;
};

struct _Cell {
    uint _wall; // 0=empty, 1=wall
    uint _food;
    uint _pheromone_food;
    uint _pheromone_home;
};

layout(set = 0, binding = 0, std430) buffer AntBuffer { Ant ants[]; };
layout(set = 0, binding = 2, std430) buffer GridHeads { int heads[]; };
layout(set = 0, binding = 3, std430) buffer AntNext { int next_indices[]; };

layout(set = 0, binding = 1, std430) buffer WorldGrid { _Cell _map[]; };
layout(set = 0, binding = 4, rgba32f) writeonly uniform image2D _render_tex;
layout(set = 0, binding = 5, rgba32f) uniform image2D _world_tex;

layout(push_constant) uniform Push {
    uint ant_count;
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

layout(set = 0, binding = 7, std430) buffer MetricsBuffer {
	uint ticks_to_first_food;
    uint total_food_collected;
	uint active_foraging_ants;
    uint short_path_traffic;
    uint long_path_traffic;
    uint _pad1, _pad2, _pad3;
} metrics;


void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= push.ant_count) return;

	vec2 safe_pos = clamp(ants[index].pos, vec2(0.0), vec2(float(U.map_w) - 1.0, float(U.map_h) - 1.0));
    ivec2 grid_pos = ivec2(safe_pos / U.cell_size);

    int cols = int(ceil(float(U.map_w) / U.cell_size));
    int grid_total_cells = heads.length();

    int cell_index = clamp(grid_pos.y * cols + grid_pos.x, 0, grid_total_cells - 1);
    next_indices[index] = atomicExchange(heads[cell_index], int(index + 1));
}