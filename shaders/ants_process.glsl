#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct Ant {
    vec2 pos;
    float ang;
    uint state;
	
    vec2 home_disp;
    uint food;
    float timer;
};

struct Cell {
    uint wall; // 0=empty, 1=wall
    uint food;
    uint pheromone_food;
    uint pheromone_home;
};

layout(set = 0, binding = 0, std430) buffer AntBuffer { Ant ants[]; };
layout(set = 0, binding = 1, std430) buffer WorldGrid { Cell map[]; };
layout(set = 0, binding = 2, std430) buffer GridHeads { int heads[]; };
layout(set = 0, binding = 3, std430) buffer AntNext { int next_indices[]; };
layout(set = 0, binding = 4, rgba32f) writeonly uniform image2D render_tex;
layout(set = 0, binding = 5, rgba32f) uniform image2D world_tex;

layout(push_constant) uniform Push {
	uint ant_count;
    uint frame_count;
    uint update_render_tex;
	uint take_snapshot; 
    uint snapshot_index;
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
    float time_per_unit; // seconds it takes to gather/drop 1 unit of food
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
	uint ticks_to_first_food; // Time until food is discovered
    uint total_food_collected;
	uint active_foraging_ants; // Number of ants currently holding food
    uint short_path_traffic;
    uint long_path_traffic;
    uint _pad1, _pad2, _pad3;
	uint history_active_ants[512]; 
    uint history_short_path[512];
    uint history_long_path[512];
} metrics;


// States
const uint SEARCHING = 0u;
const uint RETURNING = 1u;
const uint GATHERING = 2u;
const uint DROPPING = 3u;

// Maths
const float PI = 3.14159265359;
const float TAU = 2.0 * PI;
const float EPS = 0.001;
const float INF = 1e30;
const float EPS2 = EPS * EPS;
const float COS45 = 0.70710678; 

// Ant collision
const float ANT_RADIUS = 0.3; 
const float ANT_DIAMETER = ANT_RADIUS * 2.0;
const float ANT_DIAMETER_SQ = ANT_DIAMETER * ANT_DIAMETER;

// Ant sensing
const float SENSE_RANGE = 4.0; // Sense cone length in tiles
const float TURN_SPEED = 2.0;

// Ant jitteriness
const float SEARCH_JITTER = 0.1;
const float FOLLOW_JITTER = 0.05;


uint pcg_hash(inout uint seed) {
    seed = seed * 747796405u + 2891336453u;
    uint word = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand(inout uint seed) {
    return float(pcg_hash(seed) & 0x00FFFFFFu) * (1.0 / float(0x01000000));
}

vec2 randir(inout uint seed) {
	return vec2((rand(seed) - 0.5) * 2.0, (rand(seed) - 0.5) * 2.0);
}


vec2 rand_gaussian(inout uint seed) {
    float u1 = max(EPS, rand(seed)); // prevent log(0)
    float u2 = rand(seed);
    float r = sqrt(-2.0 * log(u1));
    float theta = TAU * u2;
    return vec2(r * cos(theta), r * sin(theta));
}


bool is_blocked(vec2 pos) {
	if (pos.x < 0.0 || pos.y < 0.0 || pos.x >= float(U.map_w) || pos.y >= float(U.map_h))
        return true;
    uint idx = uint(pos.y) * U.map_w + uint(pos.x);
    return map[idx].wall > 0u;
}


uint sense(vec2 pos, vec2 sense_dir, bool sense_food) {
	vec2 sense_pos = pos + sense_dir * SENSE_RANGE;
	
	if (sense_pos.x < 0.0 || sense_pos.y < 0.0 || sense_pos.x >= float(U.map_w) || sense_pos.y >= float(U.map_h))
		return 0u;
	
	uint idx = uint(sense_pos.y) * U.map_w + uint(sense_pos.x);
    
    if (map[idx].wall > 0u) return 0u;
    if (sense_food && map[idx].food > 0u) return 0xFFFFFFFFu;
	
	return sense_food ? map[idx].pheromone_food : map[idx].pheromone_home;
}


vec2 nearest_free_cell_center(vec2 pos) {
    ivec2 size = ivec2(int(U.map_w), int(U.map_h));
    ivec2 base = ivec2(floor(pos));

    vec2 best_pos = pos;
    float best_d2 = INF;

    const int MAX_SEARCH = 12;

    for (int r = 0; r <= MAX_SEARCH; r++) {
        for (int y = -r; y <= r; y++) {
            for (int x = -r; x <= r; x++) {
                if (abs(x) != r && abs(y) != r) continue; // ring only

                ivec2 cell = base + ivec2(x, y);
                if (cell.x < 0 || cell.y < 0 || cell.x >= size.x || cell.y >= size.y) continue;
                
                vec2 cell_center = vec2(cell) + vec2(0.5);
				if (is_blocked(cell_center)) continue;
				
                float d2 = dot(cell_center - pos, cell_center - pos);

                if (d2 < best_d2) {
                    best_d2 = d2;
                    best_pos = cell_center;
                }
            }
        }

        if (best_d2 < INF) break;
    }

    return best_pos;
}


const vec2 RING_8[8] = vec2[8](
    vec2(1.0, 0.0), vec2(COS45, COS45), vec2(0.0, 1.0), vec2(-COS45, COS45),
    vec2(-1.0, 0.0), vec2(-COS45, -COS45), vec2(0.0, -1.0), vec2(COS45, -COS45)
);
vec2 resolve_wall_penetration(vec2 pos) {
    if (!is_blocked(pos)) return pos;
    vec2 p = nearest_free_cell_center(pos);

    if (is_blocked(p)) {
        for (int i = 0; i < 8; i++) {
            vec2 test = p + (RING_8[i] * ANT_RADIUS);
            if (!is_blocked(test))
                return test;
        }
    }
	return p;
}


vec2 ant_ant_collision(
	vec2 pos,
	uint index,
	inout uint seed
) {
	int cols = int(ceil(float(U.map_w) / U.cell_size));
	int rows = int(ceil(float(U.map_h) / U.cell_size));
    int grid_total_cells = heads.length();
	
	ivec2 center_cell = ivec2(floor(pos / U.cell_size));
	vec2 separation = vec2(0.0);
	float crowd_count = 0.0;
	
	for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
			ivec2 check_cell = center_cell + ivec2(x, y);
			
			if (check_cell.x < 0 || check_cell.x >= cols || check_cell.y < 0 || check_cell.y >= rows) continue;
			
            int neighbor_index = check_cell.y * cols + check_cell.x;
            if (neighbor_index < 0 || neighbor_index >= grid_total_cells) continue;
	
			// Traverse the linked list for this cell
            int other_val = heads[neighbor_index];
            while (other_val > 0) {
				int other_index = other_val - 1;
				
				other_val = next_indices[other_index];
				
				if (other_index == int(index)) continue;
				
				// Ant-Ant collision check
				vec2 other_pos = ants[other_index].pos;
				vec2 diff = pos - other_pos;
				float d2 = dot(diff, diff);
				
				if (d2 < ANT_DIAMETER_SQ) {
					crowd_count += 1.0;
                    if (crowd_count >= 8.0) break; // surrounded abort
					
					if (d2 > EPS2) {
						float inv_d = inversesqrt(d2);
						separation += diff * (ANT_DIAMETER * inv_d - 1.0) * 0.5;
					} else {
						separation += 0.1 * randir(seed);
					}
				}
            }
		}
	}
	
	return separation;
}


vec2 move_and_slide(
	vec2 pos,
	vec2 separation,
	inout vec2 dir,
	inout Ant ant,
	inout uint seed
) {
	vec2 total_move = vec2(0.0);
	vec2 vel = vec2(0.0);
	if (ant.state != GATHERING) {
		vel = dir * U.speed * U.tick_delta;
		total_move = separation + vel;
	}
	
    float intended_move_sq = dot(total_move, total_move);
	
	// Sliding collision
    if (is_blocked(pos + vec2(total_move.x, 0.0) + vec2(sign(total_move.x) * ANT_RADIUS, 0.0)))
        total_move.x = 0.0;
    if (is_blocked(pos + vec2(0.0, total_move.y) + vec2(0.0, sign(total_move.y) * ANT_RADIUS)))
        total_move.y = 0.0;
   
    float actual_move_sq = dot(total_move, total_move);
	
    // Stuck detection: ant is stuck if the wall blocks it for too long
	if (ant.state != GATHERING && ant.state != DROPPING) {
		if (intended_move_sq > EPS2 && actual_move_sq < intended_move_sq * 0.01)
			ant.timer += U.tick_delta;
		else
			ant.timer = 0.0;
	}
	
	return total_move;
}


void take_food(uint amount_wanted, uint cell_index, inout Ant ant) {
	uint current_food = map[cell_index].food;
	
	for (int i = 0; i < 5; i++) {
		if (current_food == 0u) break;
		
		uint take = min(amount_wanted, current_food);
		uint expected = current_food;
		uint new_food = current_food - take;
		
		uint prev = atomicCompSwap(map[cell_index].food, expected, new_food);
	
		if (prev == expected) {			
			ant.food += take;
			return;
		}
		
		current_food = prev;
	}
}


bool look_for_nearby_food(vec2 pos, inout float ang) {
    ivec2 base = ivec2(pos);
    float best_dist = 100.0;
    vec2 best_food = vec2(0.0);
    bool found = false;

    // Check a 3x3 area
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int cx = base.x + x;
            int cy = base.y + y;
            
            if (cx < 0 || cy < 0 || cx >= int(U.map_w) || cy >= int(U.map_h)) continue;

            uint idx = uint(cy) * U.map_w + uint(cx);
            if (map[idx].food > 0u) {
                vec2 food_pos = vec2(base.x + x, base.y + y) + vec2(0.5);
                float d2 = dot(food_pos - pos, food_pos - pos);
                if (d2 < best_dist) {
                    best_dist = d2;
                    best_food = food_pos;
                    found = true;
                }
            }
        }
    }

    if (found) {
        float target_ang = atan(best_food.y - pos.y, best_food.x - pos.x);
        float diff = target_ang - ang;
        while (diff < -PI) diff += TAU;
        while (diff > PI) diff -= TAU;
        
        // Rapid snap to physical food nearby
        ang += clamp(diff, -TURN_SPEED * U.tick_delta * 4.0, TURN_SPEED * U.tick_delta * 4.0);
    }
    return found;
}


bool try_steer_by_pheromones(vec2 pos, vec2 forward_dir, bool sense_food, inout uint seed, inout float ang) {
    vec2 left_dir =  vec2(forward_dir.x + forward_dir.y, forward_dir.y - forward_dir.x) * COS45;
    vec2 right_dir = vec2(forward_dir.x - forward_dir.y, forward_dir.x + forward_dir.y) * COS45;
	
	uint s_fwd = sense(pos, forward_dir, sense_food);
    uint s_left = sense(pos, left_dir, sense_food);
    uint s_right = sense(pos, right_dir, sense_food);
    
    float f = float(s_fwd);
    float l = float(s_left);
    float r = float(s_right);
    float total = f + l + r;
    
    if (total <= 0.0 || rand(seed) < U.curiosity) return false;

    float weight = (r - l) / (r + l + 1.0); 
    
    float forward_dampening = clamp(1.0 - (f / max(max(l, r), 1.0)), 0.0, 1.0);
    
    float k = TURN_SPEED * U.tick_delta * 2.0;
    ang += weight * forward_dampening * k;
	
	return true;
}


void update_brain(inout Ant ant, inout vec2 ant_dir, uint cell_index, inout uint seed) {
	
	// Getting unstuck
	if (ant.timer > 0.5) {
        ant.ang += PI;
        ant.timer = 0.0;
    }
	
	// Searching or Returning
	if (ant.state == SEARCHING || ant.state == RETURNING) {
		bool is_searching = ant.state == SEARCHING;
		bool carrying = ant.food > 0u;
		
		vec2 true_to_colony = U.colony_pos - ant.pos;
        float true_dist_sq = dot(true_to_colony, true_to_colony);
		
		vec2 to_colony = ant.home_disp;
		float dist_sq = dot(to_colony, to_colony);
				
		// Start gathering food
		if (!carrying && map[cell_index].food > 0u && ant.food < U.max_carry) {
			ant.state = GATHERING;
			return;
		}
		
		// Start dropping food
		if (carrying && true_dist_sq < U.colony_radius_sq) {
			ant.state = DROPPING;
			return;
		}
		
		// Start searching for the colony
		if (carrying && dist_sq < U.colony_radius_sq) {
			ant.state = SEARCHING;
			is_searching = true;
		}
		
		// Steering logic
		vec2 whisker_pos = ant.pos + ant_dir * SENSE_RANGE;
		if (is_blocked(whisker_pos)) {
			vec2 left_dir =  vec2(ant_dir.x + ant_dir.y, ant_dir.y - ant_dir.x) * COS45;
			vec2 right_dir = vec2(ant_dir.x - ant_dir.y, ant_dir.x + ant_dir.y) * COS45;
			
			vec2 left_w = ant.pos + left_dir * SENSE_RANGE;
			vec2 right_w = ant.pos + right_dir * SENSE_RANGE;

			if (!is_blocked(left_w))
				ant.ang -= TURN_SPEED * U.tick_delta; // Steer left away from wall
			else if (!is_blocked(right_w))
				ant.ang += TURN_SPEED * U.tick_delta; // Steer right away from wall
			else
				ant.ang += PI; // Dead end, flip around
			
			return;
		}
		
		bool following_food_trail = !carrying;
		bool steered = false;
		
		if (following_food_trail && look_for_nearby_food(ant.pos, ant.ang))
			steered = true;
		else
			steered = try_steer_by_pheromones(ant.pos, ant_dir, following_food_trail, seed, ant.ang);
		
		float home_ang = atan(to_colony.y, to_colony.x);
		float diff = home_ang - ant.ang;
		while (diff < -PI) diff += TAU;
		while (diff > PI) diff -= TAU;
		
		bool towards_colony = abs(diff) < (PI * 0.5);
		float jitter = (steered ? FOLLOW_JITTER : SEARCH_JITTER) * (U.tick_delta * 60.0);
		float max_turn = TURN_SPEED * U.tick_delta;
		
		// Memory failed, searching for home
		if (carrying && is_searching) {
			ant.ang += (rand(seed) - 0.5) * jitter;
		}
		// Searching for food
		else if (is_searching) {
			bool far_from_colony = true_dist_sq > U.colony_radius_sq * 4.0;
			bool misled = steered && towards_colony;
			if (misled && far_from_colony)
				ant.ang -= sign(diff) * max_turn;
			else
				ant.ang += (rand(seed) - 0.5) * jitter; // follow trails better
		}
		// Returning home with food
		else {
			bool misled = steered && !towards_colony;
			if (misled)
				ant.ang += sign(diff) * max_turn;
			
			float compass_weight = steered ? 0.05 : 0.01;
			float compass_pull = clamp(diff * compass_weight, -max_turn, max_turn);
			ant.ang += compass_pull;
			
			ant.ang += (rand(seed) - 0.5) * jitter;
		}
	}
	
	// Gathering food
	else if (ant.state == GATHERING) {
		ant.timer += U.tick_delta;

		if (ant.timer >= U.time_per_unit) {
			take_food(1u, cell_index, ant);
			ant.timer -= U.time_per_unit;
			
			if (metrics.ticks_to_first_food == 0xFFFFFFFFu)
				atomicMin(metrics.ticks_to_first_food, push.frame_count);
		}
		
		if (ant.food >= U.max_carry) {
			ant.state = RETURNING;
			ant.timer = 0.0;
			atomicAdd(metrics.active_foraging_ants, 1u);
		} else if (map[cell_index].food == 0u) {
			ant.state = ant.food > 0u ? RETURNING : SEARCHING;
			ant.timer = 0.0;
			if (ant.food > 0u) atomicAdd(metrics.active_foraging_ants, 1u);
		}
	}
	
	// Dropping off food
	else if (ant.state == DROPPING) {
		ant.home_disp = U.colony_pos - ant.pos; // re-calibrate pedometer
		
		ant.timer += U.tick_delta;
		if (ant.timer >= U.time_per_unit) {
			uint amount = min(ant.food, 1u);
			ant.food -= amount;
			atomicAdd(metrics.total_food_collected, amount);
			ant.timer -= U.time_per_unit;
		}
		
		if (ant.food == 0u) {
			ant.state = SEARCHING;
			ant.ang += PI;
			ant.timer = 0.0;
			atomicAdd(metrics.active_foraging_ants, 0xFFFFFFFFu);
		}
	}
}


void main() {
    uint index = gl_GlobalInvocationID.x;
	if (index >= push.ant_count) return;

	uint seed = index + (push.frame_count * 78213u);
    Ant ant = ants[index];
	
	vec2 pos = ant.pos;
	vec2 old_pos = pos;
	vec2 dir = vec2(cos(ant.ang), sin(ant.ang));
	 
	// Collision and movement
	vec2 separation = ant_ant_collision(pos, index, seed);
	
	float backward_push = dot(separation, dir);
	if (backward_push < 0.0) separation -= dir * backward_push; 

	vec2 total_move = move_and_slide(pos, separation, dir, ant, seed);
	bool moved = dot(total_move, total_move) > EPS2;
	
    pos = resolve_wall_penetration(pos + total_move); // Push out of walls
	pos.x = clamp(pos.x, ANT_RADIUS, float(U.map_w) - ANT_RADIUS);
	pos.y = clamp(pos.y, ANT_RADIUS, float(U.map_h) - ANT_RADIUS);
	
	uint cell_index = uint(pos.y) * U.map_w + uint(pos.x);
	ant.pos = pos; // move
	
	// Behaviour
    update_brain(ant, dir, cell_index, seed);
	
	if (moved) {
		vec2 actual_move = pos - old_pos;
		float step_dist = length(actual_move);
		
		// Stochastic path integration (polar odometry)
		if (step_dist > 0.0) {
			vec2 noise = rand_gaussian(seed);
            
			float perceived_dist_mult = 1.0 + (noise.x * U.odometric_error);
			vec2 perceived_move = actual_move * perceived_dist_mult;
			
			float err_ang = noise.y * U.odometric_error * U.tick_delta;
			float cos_e = cos(err_ang);
			float sin_e = sin(err_ang);
			
			perceived_move = vec2(
				perceived_move.x * cos_e - perceived_move.y * sin_e,
				perceived_move.x * sin_e + perceived_move.y * cos_e
			);
			
			ant.home_disp -= perceived_move;
		}
		
		// Add pheromones
        if (ant.food == 0u)
            atomicAdd(map[cell_index].pheromone_home, U.drop_amount);
        else if (ant.state == RETURNING)
            atomicAdd(map[cell_index].pheromone_food, uint(float(U.drop_amount) * U.recruitment_mult));
	}
	
	// Sync to ant buffer
    ant.pos = pos;
    ants[index] = ant;
	
	// Path traffic snapshotting
	if (push.take_snapshot == 1u) {
		// Ignore ants in the colony
		vec2 to_col = U.colony_pos - ant.pos;
		if (dot(to_col, to_col) > U.colony_radius_sq) { 
			
			// Left/right check
			if (ant.pos.x > U.colony_pos.x)
				atomicAdd(metrics.history_short_path[push.snapshot_index], 1u);
			else
				atomicAdd(metrics.history_long_path[push.snapshot_index], 1u);
		}
	}
	
	// Output to render texture
	if (push.update_render_tex == 1u) {
		int tex_w = imageSize(render_tex).x;
		ivec2 tex_pos = ivec2(int(index) % tex_w, int(index) / tex_w);
		imageStore(render_tex, tex_pos, vec4(ant.pos.x, ant.pos.y, ant.ang, float(ant.food) / float(U.max_carry)));
	}
	
	// Thread 0 stores metrics to the buffers
	if (index == 0u && push.take_snapshot == 1u)
		metrics.history_active_ants[push.snapshot_index] = metrics.active_foraging_ants;
}