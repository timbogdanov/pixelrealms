extends Node2D

## Chunk-based procedural map generator for the Pixel Realms battle arena.
## Terrain generates lazily per-chunk on first access.
## Visual generation is split across multiple frames with time budgeting.

enum Biome { PLAINS, FOREST_BIOME, DESERT, SNOW_BIOME }

const CHUNK_SIZE := 128
const CHUNK_BUDGET_USEC := 4000  # 4ms per frame budget for chunk work

var headless: bool = false

var _width: int
var _height: int
var _grid_w: int
var _grid_h: int

# Chunks: terrain data (lazy, generated on first access)
var _chunks: Dictionary = {}  # Vector2i(cx,cy) -> PackedByteArray
var _chunk_water_count: Dictionary = {}  # Vector2i -> int (water pixel count per chunk)

# Pre-computed global data (rivers/roads as pixel positions)
var _river_pixels: Dictionary = {}  # Vector2i(x,y) -> true
var _road_pixels: Dictionary = {}   # Vector2i(x,y) -> true
var _mountain_center: Vector2 = Vector2.ZERO
var _mountain_stone_r: float = 0.0
var _mountain_total_r: float = 0.0

# Noise layers (stored for lazy chunk generation)
var _continent_noise: FastNoiseLite
var _elevation_noise: FastNoiseLite
var _temperature_noise: FastNoiseLite
var _moisture_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _color_noise: FastNoiseLite
var _center_x: float
var _center_y: float
var _max_radius: float

# Public results
var hill_position: Vector2
var shop_positions: Array[Vector2] = []
var spawn_positions: Array[Vector2] = []
var mob_spawn_zones: Array = []

# Visual chunks (client only)
var _visual_chunks: Dictionary = {}  # Vector2i -> Sprite2D
var _chunk_parent: Node2D
var _water_shader: Shader
var _water_time: float = 0.0

# Multi-frame work queue
var _chunk_work_queue: Array = []  # [{cx, cy, phase, key, chunk, shore_dist, terrain_img, data_img}]
var _chunk_queued: Dictionary = {}  # Vector2i -> true (fast lookup for queued chunks)

# Hill visual color
const HILL_COLOR := Color(0.72, 0.65, 0.28)


func _ready() -> void:
	_width = Config.MAP_WIDTH
	_height = Config.MAP_HEIGHT
	_grid_w = ceili(float(_width) / float(CHUNK_SIZE))
	_grid_h = ceili(float(_height) / float(CHUNK_SIZE))

	if headless:
		return

	# Create chunk container for visual sprites
	_chunk_parent = Node2D.new()
	_chunk_parent.z_index = -1
	add_child(_chunk_parent)

	# Load water shader
	_water_shader = load("res://shaders/water.gdshader")


# ---------------------------------------------------------------------------
# Main generation — global layout only (fast, no per-pixel loops)
# ---------------------------------------------------------------------------

func generate(seed_val: int = 42, _map_index: int = 0) -> void:
	_chunks.clear()
	_chunk_water_count.clear()
	_river_pixels.clear()
	_road_pixels.clear()

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# --- Phase 1: Setup noise layers ---
	_continent_noise = FastNoiseLite.new()
	_continent_noise.seed = rng.randi()
	_continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_continent_noise.frequency = 0.002
	_continent_noise.fractal_octaves = 4

	_elevation_noise = FastNoiseLite.new()
	_elevation_noise.seed = rng.randi()
	_elevation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_elevation_noise.frequency = 0.005
	_elevation_noise.fractal_octaves = 4

	_temperature_noise = FastNoiseLite.new()
	_temperature_noise.seed = rng.randi()
	_temperature_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_temperature_noise.frequency = 0.0015
	_temperature_noise.fractal_octaves = 3

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.seed = rng.randi()
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_moisture_noise.frequency = 0.002
	_moisture_noise.fractal_octaves = 3

	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = rng.randi()
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.frequency = 0.03
	_detail_noise.fractal_octaves = 2

	_color_noise = FastNoiseLite.new()
	_color_noise.seed = rng.randi()
	_color_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_color_noise.frequency = 0.08
	_color_noise.fractal_octaves = 1

	_center_x = float(_width) / 2.0
	_center_y = float(_height) / 2.0
	_max_radius = minf(_center_x, _center_y)

	# --- Phase 2: Find hill via sparse sampling (every 10px) ---
	var best_elev: float = -999.0
	var best_elev_pos := Vector2(_center_x, _center_y)
	var step: int = 10
	for sy in range(0, _height, step):
		for sx in range(0, _width, step):
			var fx: float = float(sx)
			var fy: float = float(sy)
			var dx: float = (fx - _center_x) / _max_radius
			var dy: float = (fy - _center_y) / _max_radius
			var dist_sq: float = dx * dx + dy * dy
			var continent_val: float = _continent_noise.get_noise_2d(fx, fy)
			var land_value: float = 0.6 - dist_sq * 0.45 + continent_val * 0.35
			if land_value <= 0.04:
				continue
			var elev_val: float = _elevation_noise.get_noise_2d(fx, fy)
			var elevation: float = (elev_val + 1.0) * 0.5
			if elevation > best_elev:
				best_elev = elevation
				best_elev_pos = Vector2(fx, fy)

	hill_position = best_elev_pos
	_mountain_center = hill_position
	_mountain_stone_r = Config.MOUNTAIN_STONE_RADIUS
	_mountain_total_r = Config.MOUNTAIN_TOTAL_RADIUS

	# --- Phase 3: Compute river paths ---
	_compute_rivers(rng)

	# --- Phase 4: Place shops ---
	_place_shops(rng)

	# --- Phase 5: Compute roads ---
	_compute_roads()

	# --- Phase 6: Place spawns ---
	_place_spawns(rng)

	# --- Phase 7: Place mob zones ---
	_place_mob_spawn_zones(rng)


# ---------------------------------------------------------------------------
# Terrain type from noise (no chunk needed)
# ---------------------------------------------------------------------------

func _compute_terrain_type_at(x: int, y: int) -> int:
	var fx: float = float(x)
	var fy: float = float(y)

	var dist_to_edge: int = mini(mini(x, _width - 1 - x), mini(y, _height - 1 - y))
	if dist_to_edge < 30:
		return Config.Terrain.WATER

	var dx: float = (fx - _center_x) / _max_radius
	var dy: float = (fy - _center_y) / _max_radius
	var dist_sq: float = dx * dx + dy * dy
	var continent_val: float = _continent_noise.get_noise_2d(fx, fy)
	var land_value: float = 0.6 - dist_sq * 0.45 + continent_val * 0.35

	if land_value <= 0.0:
		return Config.Terrain.WATER
	if land_value <= 0.04:
		return Config.Terrain.SHALLOW_WATER

	var elev_val: float = _elevation_noise.get_noise_2d(fx, fy)
	var elevation: float = (elev_val + 1.0) * 0.5
	var temp: float = _temperature_noise.get_noise_2d(fx, fy)
	var moist: float = _moisture_noise.get_noise_2d(fx, fy)
	var detail: float = _detail_noise.get_noise_2d(fx, fy)

	if elevation > 0.85:
		return Config.Terrain.STONE
	if elevation > 0.70:
		return Config.Terrain.HILL

	var biome: int
	if temp < -0.15:
		biome = Biome.SNOW_BIOME
	elif temp > 0.25 and moist < -0.1:
		biome = Biome.DESERT
	elif moist > 0.15:
		biome = Biome.FOREST_BIOME
	else:
		biome = Biome.PLAINS

	match biome:
		Biome.PLAINS:
			if detail > 0.2:
				return Config.Terrain.FOREST
			return Config.Terrain.GRASS
		Biome.FOREST_BIOME:
			if detail < -0.1:
				return Config.Terrain.GRASS
			return Config.Terrain.FOREST
		Biome.DESERT:
			return Config.Terrain.SAND
		Biome.SNOW_BIOME:
			if detail > 0.2:
				return Config.Terrain.SNOW_FOREST
			return Config.Terrain.SNOW

	return Config.Terrain.GRASS


# ---------------------------------------------------------------------------
# Lazy chunk generation (terrain data only)
# ---------------------------------------------------------------------------

func _get_or_generate_chunk(cx: int, cy: int) -> PackedByteArray:
	var key := Vector2i(cx, cy)
	if _chunks.has(key):
		return _chunks[key]

	var chunk := PackedByteArray()
	chunk.resize(CHUNK_SIZE * CHUNK_SIZE)

	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	# Pre-check if chunk overlaps mountain
	var chunk_center := Vector2(float(base_x + CHUNK_SIZE / 2), float(base_y + CHUNK_SIZE / 2))
	var chunk_diagonal: float = float(CHUNK_SIZE) * 0.7071
	var chunk_near_mountain: bool = chunk_center.distance_to(_mountain_center) < _mountain_total_r + chunk_diagonal

	var water_count: int = 0

	for ly in CHUNK_SIZE:
		var world_y: int = base_y + ly
		if world_y >= _height:
			for lx in CHUNK_SIZE:
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.WATER
			water_count += CHUNK_SIZE
			continue
		for lx in CHUNK_SIZE:
			var world_x: int = base_x + lx
			if world_x >= _width:
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.WATER
				water_count += 1
				continue

			var pixel_key := Vector2i(world_x, world_y)

			# Check river/road overlays first
			if _river_pixels.has(pixel_key):
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.SHALLOW_WATER
				water_count += 1
				continue
			if _road_pixels.has(pixel_key):
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.PATH
				continue

			# Check mountain override (only if chunk is near mountain)
			if chunk_near_mountain:
				var dist_to_hill: float = Vector2(world_x, world_y).distance_to(_mountain_center)
				if dist_to_hill <= _mountain_total_r:
					var base_t: int = _compute_terrain_type_at(world_x, world_y)
					if base_t != Config.Terrain.WATER and base_t != Config.Terrain.SHALLOW_WATER:
						if dist_to_hill <= _mountain_stone_r:
							chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.STONE
						else:
							chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.HILL
						continue

			var t: int = _compute_terrain_type_at(world_x, world_y)
			chunk[ly * CHUNK_SIZE + lx] = t
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				water_count += 1

	_chunks[key] = chunk
	_chunk_water_count[key] = water_count
	return chunk


# ---------------------------------------------------------------------------
# Public terrain query functions
# ---------------------------------------------------------------------------

func get_terrain_at(pos: Vector2i) -> int:
	if pos.x < 0 or pos.x >= _width or pos.y < 0 or pos.y >= _height:
		return Config.Terrain.WATER
	var cx: int = pos.x / CHUNK_SIZE
	var cy: int = pos.y / CHUNK_SIZE
	var chunk: PackedByteArray = _get_or_generate_chunk(cx, cy)
	var lx: int = pos.x % CHUNK_SIZE
	var ly: int = pos.y % CHUNK_SIZE
	return chunk[ly * CHUNK_SIZE + lx]


func get_terrain(pos: Vector2) -> int:
	return get_terrain_at(Vector2i(int(pos.x), int(pos.y)))


func is_walkable(pos: Vector2i) -> bool:
	var t: int = get_terrain_at(pos)
	return t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER


func get_speed_mult(pos: Vector2i) -> float:
	var t: int = get_terrain_at(pos)
	var speed: float = Config.TERRAIN_SPEED[t]
	return speed


func find_walkable_near(target: Vector2, search_radius: int) -> Vector2:
	return _find_walkable_near(target, search_radius)


func find_grass_or_path_near(target: Vector2, search_radius: int) -> Vector2:
	return _find_grass_or_path_near(target, search_radius)


# ---------------------------------------------------------------------------
# River computation: store pixel positions (no terrain writes)
# ---------------------------------------------------------------------------

func _compute_rivers(rng: RandomNumberGenerator) -> void:
	var num_rivers: int = rng.randi_range(5, 6)
	var base_angle: float = rng.randf_range(0.0, TAU)

	for i in num_rivers:
		var angle: float = base_angle + (TAU / float(num_rivers)) * float(i) + rng.randf_range(-0.2, 0.2)

		var start_dist: float = rng.randf_range(180.0, 500.0)
		var start_x: float = hill_position.x + cos(angle) * start_dist
		var start_y: float = hill_position.y + sin(angle) * start_dist
		start_x = clampf(start_x, 40.0, float(_width - 40))
		start_y = clampf(start_y, 40.0, float(_height - 40))

		var start_t: int = _compute_terrain_type_at(int(start_x), int(start_y))
		if start_t == Config.Terrain.WATER:
			continue

		var cur_x: float = start_x
		var cur_y: float = start_y
		var walk_angle: float = angle
		var river_width: int = rng.randi_range(3, 4)

		for _step in 5000:
			var px: int = int(cur_x)
			var py: int = int(cur_y)
			if px < 1 or px >= _width - 1 or py < 1 or py >= _height - 1:
				break
			var base_t: int = _compute_terrain_type_at(px, py)
			if base_t == Config.Terrain.WATER:
				break

			var perp_angle: float = walk_angle + PI * 0.5
			var perp_dx: float = cos(perp_angle)
			var perp_dy: float = sin(perp_angle)
			var half_w: int = river_width / 2

			for w in range(-half_w, half_w + 1):
				var fx: int = px + int(round(perp_dx * float(w)))
				var fy: int = py + int(round(perp_dy * float(w)))
				if fx < 0 or fx >= _width or fy < 0 or fy >= _height:
					continue
				var t: int = _compute_terrain_type_at(fx, fy)
				if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.STONE:
					continue
				if Vector2(fx, fy).distance_to(hill_position) <= _mountain_total_r + 5.0:
					continue
				_river_pixels[Vector2i(fx, fy)] = true

			walk_angle += rng.randf_range(-0.25, 0.25)
			var to_hill: Vector2 = hill_position - Vector2(cur_x, cur_y)
			var away_angle: float = to_hill.angle() + PI
			var angle_diff: float = away_angle - walk_angle
			while angle_diff > PI:
				angle_diff -= TAU
			while angle_diff < -PI:
				angle_diff += TAU
			walk_angle += angle_diff * 0.05

			cur_x += cos(walk_angle)
			cur_y += sin(walk_angle)


# ---------------------------------------------------------------------------
# Shop placement
# ---------------------------------------------------------------------------

func _place_shops(rng: RandomNumberGenerator) -> void:
	shop_positions.clear()
	var attempts: int = 0

	while shop_positions.size() < Config.NUM_SHOPS and attempts < 2000:
		attempts += 1
		var x: float = rng.randf_range(100.0, float(_width - 100))
		var y: float = rng.randf_range(100.0, float(_height - 100))
		var pos := Vector2(x, y)

		var t: int = _compute_terrain_type_at(int(x), int(y))
		if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.STONE or t == Config.Terrain.HILL:
			continue
		if pos.distance_to(hill_position) < Config.SHOP_MIN_DIST_FROM_HILL:
			continue

		var too_close: bool = false
		for existing in shop_positions:
			if pos.distance_to(existing) < Config.SHOP_MIN_DIST_APART:
				too_close = true
				break
		if too_close:
			continue

		shop_positions.append(pos)


# ---------------------------------------------------------------------------
# Road computation: store pixel positions (no terrain writes)
# ---------------------------------------------------------------------------

func _compute_roads() -> void:
	for shop_pos in shop_positions:
		_compute_path_pixels(shop_pos, hill_position)

	for i in shop_positions.size():
		var nearest_dist: float = 999999.0
		var nearest_idx: int = -1
		for j in shop_positions.size():
			if i == j:
				continue
			var d: float = shop_positions[i].distance_to(shop_positions[j])
			if d < nearest_dist:
				nearest_dist = d
				nearest_idx = j
		if nearest_idx >= 0:
			_compute_path_pixels(shop_positions[i], shop_positions[nearest_idx])


func _compute_path_pixels(from_pos: Vector2, to_pos: Vector2) -> void:
	var dist: float = from_pos.distance_to(to_pos)
	var steps: int = int(dist) + 1
	if steps <= 0:
		return
	var direction: Vector2 = (to_pos - from_pos).normalized()
	var step_size: float = dist / float(steps)
	var path_half_width: int = 1

	for i in steps + 1:
		var pos: Vector2 = from_pos + direction * step_size * float(i)
		var px: int = int(pos.x)
		var py: int = int(pos.y)
		for dy in range(-path_half_width, path_half_width + 1):
			for dx in range(-path_half_width, path_half_width + 1):
				var fx: int = px + dx
				var fy: int = py + dy
				if fx < 0 or fx >= _width or fy < 0 or fy >= _height:
					continue
				var t: int = _compute_terrain_type_at(fx, fy)
				if t == Config.Terrain.GRASS or t == Config.Terrain.FOREST \
					or t == Config.Terrain.SAND or t == Config.Terrain.SNOW \
					or t == Config.Terrain.SNOW_FOREST or t == Config.Terrain.SHALLOW_WATER:
					_road_pixels[Vector2i(fx, fy)] = true


# ---------------------------------------------------------------------------
# Spawn placement
# ---------------------------------------------------------------------------

func _place_spawns(rng: RandomNumberGenerator) -> void:
	spawn_positions.clear()
	var attempts: int = 0

	while spawn_positions.size() < Config.NUM_PLAYERS and attempts < 3000:
		attempts += 1
		var x: float = rng.randf_range(100.0, float(_width - 100))
		var y: float = rng.randf_range(100.0, float(_height - 100))
		var pos := Vector2(x, y)

		var t: int = _compute_terrain_type_at(int(x), int(y))
		if t != Config.Terrain.GRASS and t != Config.Terrain.SAND and t != Config.Terrain.SNOW and t != Config.Terrain.PATH:
			continue
		if pos.distance_to(hill_position) < 200.0:
			continue

		var too_close: bool = false
		for shop_pos in shop_positions:
			if pos.distance_to(shop_pos) < Config.PLAYER_SPAWN_MIN_DIST_FROM_SHOP:
				too_close = true
				break
		if too_close:
			continue

		var nearest_shop: Vector2 = _find_nearest(pos, shop_positions)
		_compute_path_pixels(pos, nearest_shop)

		spawn_positions.append(pos)


# ---------------------------------------------------------------------------
# Mob spawn zone placement
# ---------------------------------------------------------------------------

func _place_mob_spawn_zones(rng: RandomNumberGenerator) -> void:
	mob_spawn_zones.clear()

	for _i in 4:
		var pos: Vector2 = _find_mob_position(rng, _mountain_total_r + 30.0, 600.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.KNIGHT, "count": rng.randi_range(3, 4)})

	for _i in 6:
		var pos: Vector2 = _find_mob_position(rng, 200.0, 1200.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.BANDIT, "count": rng.randi_range(3, 4)})

	for _i in 8:
		var pos: Vector2 = _find_mob_position(rng, 300.0, 1800.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.SKELETON, "count": rng.randi_range(3, 5)})

	for _i in 15:
		var pos: Vector2 = _find_mob_position(rng, 0.0, 99999.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.SLIME, "count": rng.randi_range(3, 5)})


func _find_mob_position(rng: RandomNumberGenerator, min_hill_dist: float, max_hill_dist: float) -> Vector2:
	for _attempt in 300:
		var x: float = rng.randf_range(60.0, float(_width - 60))
		var y: float = rng.randf_range(60.0, float(_height - 60))
		var pos := Vector2(x, y)

		var t: int = _compute_terrain_type_at(int(x), int(y))
		if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.STONE:
			continue

		var dist_to_hill: float = pos.distance_to(hill_position)
		if dist_to_hill < min_hill_dist or dist_to_hill > max_hill_dist:
			continue

		var too_close: bool = false
		for shop_pos in shop_positions:
			if pos.distance_to(shop_pos) < Config.MOB_MIN_DIST_FROM_SHOP:
				too_close = true
				break
		if too_close:
			continue

		return pos

	return _find_walkable_near(Vector2(float(_width) / 2.0, float(_height) / 2.0), 500)


# ---------------------------------------------------------------------------
# Chunk visual management (client only, called each frame from main.gd)
# ---------------------------------------------------------------------------

func update_visible_chunks(camera_pos: Vector2, view_half: Vector2) -> void:
	if headless:
		return

	_water_time += get_process_delta_time()

	# Update global water time (single call instead of per-chunk)
	RenderingServer.global_shader_parameter_set("water_time", _water_time)

	# Compute visible chunk range with 2-chunk margin
	var margin: float = float(CHUNK_SIZE) * 2.0
	var min_x: int = maxi(0, int((camera_pos.x - view_half.x - margin) / float(CHUNK_SIZE)))
	var max_x: int = mini(_grid_w - 1, int((camera_pos.x + view_half.x + margin) / float(CHUNK_SIZE)))
	var min_y: int = maxi(0, int((camera_pos.y - view_half.y - margin) / float(CHUNK_SIZE)))
	var max_y: int = mini(_grid_h - 1, int((camera_pos.y + view_half.y + margin) / float(CHUNK_SIZE)))

	# Enqueue new chunks that need generation
	var new_chunks_added: bool = false
	for cy in range(min_y, max_y + 1):
		for cx in range(min_x, max_x + 1):
			var key := Vector2i(cx, cy)
			if not _visual_chunks.has(key) and not _chunk_queued.has(key):
				_chunk_work_queue.append({
					"cx": cx, "cy": cy, "phase": 0, "key": key,
					"chunk": PackedByteArray(),
					"shore_dist": PackedByteArray(),
					"terrain_img": null,
					"data_img": null,
				})
				_chunk_queued[key] = true
				new_chunks_added = true

	# Sort by distance to camera (nearest first) when new chunks added
	if new_chunks_added:
		_chunk_work_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_center := Vector2(float(a["cx"] * CHUNK_SIZE + CHUNK_SIZE / 2),
									float(a["cy"] * CHUNK_SIZE + CHUNK_SIZE / 2))
			var b_center := Vector2(float(b["cx"] * CHUNK_SIZE + CHUNK_SIZE / 2),
									float(b["cy"] * CHUNK_SIZE + CHUNK_SIZE / 2))
			return a_center.distance_squared_to(camera_pos) < b_center.distance_squared_to(camera_pos)
		)

	# Process queued work with time budget
	var start: int = Time.get_ticks_usec()
	var idx: int = 0
	while idx < _chunk_work_queue.size():
		if Time.get_ticks_usec() - start > CHUNK_BUDGET_USEC:
			break
		var work: Dictionary = _chunk_work_queue[idx]
		_process_chunk_phase(work)
		if work["phase"] >= 3:
			_chunk_queued.erase(work["key"])
			_chunk_work_queue.remove_at(idx)
		else:
			idx += 1

	# Unload far chunks (4-chunk margin beyond visible)
	var unload_margin: float = float(CHUNK_SIZE) * 4.0
	var unload_keys: Array = []
	for key: Vector2i in _visual_chunks:
		var world_x: float = float(key.x * CHUNK_SIZE) + float(CHUNK_SIZE) * 0.5
		var world_y: float = float(key.y * CHUNK_SIZE) + float(CHUNK_SIZE) * 0.5
		if absf(world_x - camera_pos.x) > view_half.x + unload_margin \
			or absf(world_y - camera_pos.y) > view_half.y + unload_margin:
			unload_keys.append(key)

	for key: Vector2i in unload_keys:
		var sprite: Sprite2D = _visual_chunks[key]
		sprite.queue_free()
		_visual_chunks.erase(key)


# ---------------------------------------------------------------------------
# Multi-frame phase dispatcher
# ---------------------------------------------------------------------------

func _process_chunk_phase(work: Dictionary) -> void:
	var phase: int = work["phase"]
	match phase:
		0:
			_chunk_phase_0(work)
		1:
			_chunk_phase_1(work)
		2:
			_chunk_phase_2(work)


# Phase 0: terrain data + shore distance + data image
func _chunk_phase_0(work: Dictionary) -> void:
	var cx: int = work["cx"]
	var cy: int = work["cy"]

	var chunk: PackedByteArray = _get_or_generate_chunk(cx, cy)
	work["chunk"] = chunk

	var shore_dist: PackedByteArray = _compute_chunk_shore_distance(cx, cy, chunk)
	work["shore_dist"] = shore_dist

	# Create data image (RG8: R=terrain_type/10, G=shore_dist/20)
	var data_img := Image.create(CHUNK_SIZE, CHUNK_SIZE, false, Image.FORMAT_RG8)
	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var idx: int = ly * CHUNK_SIZE + lx
			data_img.set_pixel(lx, ly, Color(float(chunk[idx]) / 10.0, float(shore_dist[idx]) / 20.0, 0.0))
	work["data_img"] = data_img
	work["phase"] = 1


# Phase 1: color image generation (the expensive per-pixel loop)
func _chunk_phase_1(work: Dictionary) -> void:
	var cx: int = work["cx"]
	var cy: int = work["cy"]
	var chunk: PackedByteArray = work["chunk"]
	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	# Pre-check mountain proximity
	var chunk_center := Vector2(float(base_x + CHUNK_SIZE / 2), float(base_y + CHUNK_SIZE / 2))
	var chunk_diagonal: float = float(CHUNK_SIZE) * 0.7071
	var chunk_near_mountain: bool = chunk_center.distance_to(_mountain_center) < _mountain_total_r + chunk_diagonal

	var terrain_img := Image.create(CHUNK_SIZE, CHUNK_SIZE, false, Image.FORMAT_RGB8)

	for ly in CHUNK_SIZE:
		var world_y: int = base_y + ly
		for lx in CHUNK_SIZE:
			var world_x: int = base_x + lx
			var t: int = chunk[ly * CHUNK_SIZE + lx]
			var fx: float = float(world_x)
			var fy: float = float(world_y)
			var color: Color = Config.TERRAIN_COLORS[t]

			if t == Config.Terrain.WATER:
				if world_x >= 0 and world_x < _width and world_y >= 0 and world_y < _height:
					var depth: float = _continent_noise.get_noise_2d(fx * 0.5, fy * 0.5) * 0.15
					color = color.darkened(clampf(depth, 0.0, 0.3))
					var dist_to_edge: int = mini(mini(world_x, _width - 1 - world_x), mini(world_y, _height - 1 - world_y))
					if dist_to_edge < 30:
						color = color.darkened(float(30 - dist_to_edge) / 30.0 * 0.3)
			elif t == Config.Terrain.SHALLOW_WATER:
				color = color.lightened(sin(fx * 0.3) * 0.03)
			elif t != Config.Terrain.PATH:
				var elev_val: float = _elevation_noise.get_noise_2d(fx, fy)
				var elevation: float = (elev_val + 1.0) * 0.5
				var variation: float = _color_noise.get_noise_2d(fx * 3.0, fy * 3.0) * 0.04
				var shade: float = 0.85 + elevation * 0.3
				color = Color(
					clampf(color.r * shade, 0.0, 1.0),
					clampf(color.g * shade, 0.0, 1.0),
					clampf(color.b * shade, 0.0, 1.0))
				color = color.lightened(variation)

				# Mountain coloring (only if chunk is near mountain)
				if chunk_near_mountain:
					var dist_to_hill: float = Vector2(world_x, world_y).distance_to(_mountain_center)
					if t == Config.Terrain.STONE and dist_to_hill <= _mountain_stone_r:
						var center_blend: float = 1.0 - (dist_to_hill / _mountain_stone_r)
						color = Config.TERRAIN_COLORS[Config.Terrain.STONE].lightened(center_blend * 0.12 + variation)
					elif t == Config.Terrain.HILL and dist_to_hill <= _mountain_total_r:
						var slope_frac: float = (dist_to_hill - _mountain_stone_r) / (_mountain_total_r - _mountain_stone_r)
						color = HILL_COLOR.lightened((1.0 - slope_frac) * 0.15 + variation)

				# Per-terrain pixel detail (hash-based)
				var hash_val: int = (world_x * 73 + world_y * 37) % 100
				match t:
					Config.Terrain.GRASS:
						if hash_val < 8:
							color = color.lightened(0.06)
						elif hash_val < 12:
							color = color.darkened(0.05)
					Config.Terrain.FOREST:
						var fhash: int = (world_x * 51 + world_y * 89) % 100
						if fhash < 15:
							color = color.darkened(0.12)
						elif fhash < 25:
							color = color.lightened(0.04)
					Config.Terrain.STONE:
						var shash: int = (world_x * 97 + world_y * 61) % 100
						if shash < 10:
							color = color.lightened(0.08)
						elif shash < 18:
							color = color.darkened(0.06)
					Config.Terrain.HILL:
						var hhash: int = (world_x * 97 + world_y * 61) % 100
						if hhash < 10:
							color = color.lightened(0.06)
						elif hhash < 18:
							color = color.darkened(0.05)
					Config.Terrain.SAND:
						var sahash: int = (world_x * 83 + world_y * 47) % 100
						if sahash < 10:
							color = color.lightened(0.05)
						elif sahash < 18:
							color = color.darkened(0.04)
					Config.Terrain.SNOW:
						var snhash: int = (world_x * 59 + world_y * 71) % 100
						if snhash < 12:
							color = color.lightened(0.04)
						elif snhash < 20:
							color = color.darkened(0.03)
					Config.Terrain.SNOW_FOREST:
						var sfhash: int = (world_x * 51 + world_y * 89) % 100
						if sfhash < 15:
							color = color.darkened(0.10)
						elif sfhash < 25:
							color = color.lightened(0.05)
			else:
				# PATH
				color = color.lightened(sin(fx * 0.5) * 0.03)

			terrain_img.set_pixel(lx, ly, color)

	work["terrain_img"] = terrain_img
	work["phase"] = 2


# Phase 2: post-processing + texture creation + sprite
func _chunk_phase_2(work: Dictionary) -> void:
	var cx: int = work["cx"]
	var cy: int = work["cy"]
	var chunk: PackedByteArray = work["chunk"]
	var terrain_img: Image = work["terrain_img"]
	var data_img: Image = work["data_img"]
	var key: Vector2i = work["key"]

	# Skip costly post-processing for all-water chunks
	var wc: int = _chunk_water_count.get(key, 0)
	var total_pixels: int = CHUNK_SIZE * CHUNK_SIZE
	if wc < total_pixels:
		_apply_chunk_coastline(cx, cy, chunk, terrain_img)
		_apply_chunk_dither(cx, cy, chunk, terrain_img)
		_apply_chunk_mountain_glow(cx, cy, terrain_img)

	# Create textures
	var terrain_tex := ImageTexture.create_from_image(terrain_img)
	var data_tex := ImageTexture.create_from_image(data_img)

	# Create sprite with water shader
	var sprite := Sprite2D.new()
	sprite.texture = terrain_tex
	sprite.centered = false
	sprite.position = Vector2(cx * CHUNK_SIZE, cy * CHUNK_SIZE)

	var mat := ShaderMaterial.new()
	mat.shader = _water_shader
	mat.set_shader_parameter("terrain_data", data_tex)
	sprite.material = mat

	_chunk_parent.add_child(sprite)
	_visual_chunks[key] = sprite

	# Free intermediate data
	work["chunk"] = PackedByteArray()
	work["shore_dist"] = PackedByteArray()
	work["terrain_img"] = null
	work["data_img"] = null
	work["phase"] = 3


# ---------------------------------------------------------------------------
# Shore distance computation (NO cascade — only reads already-generated chunks)
# ---------------------------------------------------------------------------

func _compute_chunk_shore_distance(cx: int, cy: int, chunk: PackedByteArray) -> PackedByteArray:
	var dist := PackedByteArray()
	dist.resize(CHUNK_SIZE * CHUNK_SIZE)
	dist.fill(20)

	var key := Vector2i(cx, cy)
	var wc: int = _chunk_water_count.get(key, 0)

	# Early exit: all land — no water pixels to process
	if wc == 0:
		return dist

	# Early exit: all water — check if deep ocean (all neighbors also all-water)
	var total_pixels: int = CHUNK_SIZE * CHUNK_SIZE
	if wc == total_pixels:
		var any_land_neighbor: bool = false
		for nkey in [Vector2i(cx - 1, cy), Vector2i(cx + 1, cy), Vector2i(cx, cy - 1), Vector2i(cx, cy + 1)]:
			var nc: int = _chunk_water_count.get(nkey, total_pixels)
			if nc < total_pixels:
				any_land_neighbor = true
				break
		if not any_land_neighbor:
			return dist  # Deep ocean, no shore effects

	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var t: int = chunk[ly * CHUNK_SIZE + lx]
			if t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER:
				continue

			var min_d: int = 20
			for dir_idx in 4:
				var ddx: int = [1, -1, 0, 0][dir_idx]
				var ddy: int = [0, 0, 1, -1][dir_idx]
				for scan_step in range(1, 21):
					var wx: int = base_x + lx + ddx * scan_step
					var wy: int = base_y + ly + ddy * scan_step
					if wx < 0 or wx >= _width or wy < 0 or wy >= _height:
						break
					var check_cx: int = wx / CHUNK_SIZE
					var check_cy: int = wy / CHUNK_SIZE
					var check_lx: int = wx % CHUNK_SIZE
					var check_ly: int = wy % CHUNK_SIZE
					var check_t: int
					if check_cx == cx and check_cy == cy:
						check_t = chunk[check_ly * CHUNK_SIZE + check_lx]
					else:
						# Only read already-generated chunks (NO cascade)
						var adj_key := Vector2i(check_cx, check_cy)
						if not _chunks.has(adj_key):
							break
						var adj_chunk: PackedByteArray = _chunks[adj_key]
						check_t = adj_chunk[check_ly * CHUNK_SIZE + check_lx]
					if check_t != Config.Terrain.WATER and check_t != Config.Terrain.SHALLOW_WATER:
						min_d = mini(min_d, scan_step)
						break

			dist[ly * CHUNK_SIZE + lx] = min_d

	return dist


# ---------------------------------------------------------------------------
# Per-chunk coastline sand strip
# ---------------------------------------------------------------------------

func _apply_chunk_coastline(cx: int, cy: int, chunk: PackedByteArray, img: Image) -> void:
	var sand_inner := Color(0.76, 0.70, 0.50)
	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var t: int = chunk[ly * CHUNK_SIZE + lx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				continue

			var world_x: int = base_x + lx
			var world_y: int = base_y + ly

			var adjacent_water: bool = false
			var near_water: bool = false
			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = world_x + offset.x
				var ny: int = world_y + offset.y
				if nx < 0 or nx >= _width or ny < 0 or ny >= _height:
					continue
				var nt: int = _get_terrain_world(nx, ny, cx, cy, chunk)
				if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER:
					adjacent_water = true
					break

			if adjacent_water:
				var hash_val: int = (world_x * 73 + world_y * 37) % 100
				var sand: Color = sand_inner
				if hash_val < 10:
					sand = sand.darkened(0.06)
				img.set_pixel(lx, ly, sand)
			else:
				for offset in [Vector2i(-2, 0), Vector2i(2, 0), Vector2i(0, -2), Vector2i(0, 2),
							   Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
					var nx: int = world_x + offset.x
					var ny: int = world_y + offset.y
					if nx < 0 or nx >= _width or ny < 0 or ny >= _height:
						continue
					var nt: int = _get_terrain_world(nx, ny, cx, cy, chunk)
					if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER:
						near_water = true
						break
				if near_water:
					var original: Color = img.get_pixel(lx, ly)
					img.set_pixel(lx, ly, original.lerp(sand_inner, 0.5))


# ---------------------------------------------------------------------------
# Per-chunk dithered transitions
# ---------------------------------------------------------------------------

func _apply_chunk_dither(cx: int, cy: int, chunk: PackedByteArray, img: Image) -> void:
	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var world_x: int = base_x + lx
			var world_y: int = base_y + ly

			if (world_x + world_y) % 2 != 0:
				continue

			var t: int = chunk[ly * CHUNK_SIZE + lx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.PATH:
				continue

			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = world_x + offset.x
				var ny: int = world_y + offset.y
				if nx < 0 or nx >= _width or ny < 0 or ny >= _height:
					continue
				var nt: int = _get_terrain_world(nx, ny, cx, cy, chunk)
				if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER or nt == Config.Terrain.PATH:
					continue
				if nt != t:
					var neighbor_color: Color = _compute_terrain_color(nx, ny, nt)
					img.set_pixel(lx, ly, neighbor_color)
					break


# ---------------------------------------------------------------------------
# Per-chunk mountain glow
# ---------------------------------------------------------------------------

func _apply_chunk_mountain_glow(cx: int, cy: int, img: Image) -> void:
	var hill_r: float = Config.HILL_RADIUS
	var glow_inner: float = hill_r - 5.0
	var glow_outer: float = hill_r + 8.0
	var gold := Color(1.0, 0.85, 0.3)
	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	var chunk_center := Vector2(float(base_x + CHUNK_SIZE / 2), float(base_y + CHUNK_SIZE / 2))
	if chunk_center.distance_to(hill_position) > glow_outer + float(CHUNK_SIZE):
		return

	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var dist: float = Vector2(base_x + lx, base_y + ly).distance_to(hill_position)
			if dist >= glow_inner and dist <= glow_outer:
				var t: float = 1.0 - absf(dist - hill_r) / 8.0
				t = clampf(t, 0.0, 1.0) * 0.2
				var current: Color = img.get_pixel(lx, ly)
				img.set_pixel(lx, ly, Color(
					lerpf(current.r, gold.r, t),
					lerpf(current.g, gold.g, t),
					lerpf(current.b, gold.b, t)))


# ---------------------------------------------------------------------------
# Helper: get terrain at world position, using current chunk if possible
# ---------------------------------------------------------------------------

func _get_terrain_world(wx: int, wy: int, cur_cx: int, cur_cy: int, cur_chunk: PackedByteArray) -> int:
	if wx < 0 or wx >= _width or wy < 0 or wy >= _height:
		return Config.Terrain.WATER
	var tcx: int = wx / CHUNK_SIZE
	var tcy: int = wy / CHUNK_SIZE
	var tlx: int = wx % CHUNK_SIZE
	var tly: int = wy % CHUNK_SIZE
	if tcx == cur_cx and tcy == cur_cy:
		return cur_chunk[tly * CHUNK_SIZE + tlx]
	# Only read already-generated chunks (no cascade)
	var adj_key := Vector2i(tcx, tcy)
	if not _chunks.has(adj_key):
		return Config.Terrain.WATER  # Treat unchunked as water for visual purposes
	var adj_chunk: PackedByteArray = _chunks[adj_key]
	return adj_chunk[tly * CHUNK_SIZE + tlx]


# ---------------------------------------------------------------------------
# Helper: compute terrain color for a specific world pixel
# ---------------------------------------------------------------------------

func _compute_terrain_color(wx: int, wy: int, t: int) -> Color:
	var color: Color = Config.TERRAIN_COLORS[t]
	if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.PATH:
		return color
	var fx: float = float(wx)
	var fy: float = float(wy)
	var elev_val: float = _elevation_noise.get_noise_2d(fx, fy)
	var elevation: float = (elev_val + 1.0) * 0.5
	var variation: float = _color_noise.get_noise_2d(fx * 3.0, fy * 3.0) * 0.04
	var shade: float = 0.85 + elevation * 0.3
	color = Color(
		clampf(color.r * shade, 0.0, 1.0),
		clampf(color.g * shade, 0.0, 1.0),
		clampf(color.b * shade, 0.0, 1.0))
	return color.lightened(variation)


# ---------------------------------------------------------------------------
# Clear all visual chunks (for game cleanup)
# ---------------------------------------------------------------------------

func clear_visuals() -> void:
	for key: Vector2i in _visual_chunks:
		var sprite: Sprite2D = _visual_chunks[key]
		sprite.queue_free()
	_visual_chunks.clear()
	_chunk_work_queue.clear()
	_chunk_queued.clear()


# ---------------------------------------------------------------------------
# Fast preview generation (200x200 thumbnail for lobby)
# ---------------------------------------------------------------------------

func generate_preview(seed_val: int, pw: int = 200, ph: int = 200) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var continent_noise := FastNoiseLite.new()
	continent_noise.seed = rng.randi()
	continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	continent_noise.frequency = 0.002
	continent_noise.fractal_octaves = 4

	var elevation_noise := FastNoiseLite.new()
	elevation_noise.seed = rng.randi()
	elevation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	elevation_noise.frequency = 0.005
	elevation_noise.fractal_octaves = 4

	var temperature_noise := FastNoiseLite.new()
	temperature_noise.seed = rng.randi()
	temperature_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	temperature_noise.frequency = 0.0015
	temperature_noise.fractal_octaves = 3

	var moisture_noise := FastNoiseLite.new()
	moisture_noise.seed = rng.randi()
	moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moisture_noise.frequency = 0.002
	moisture_noise.fractal_octaves = 3

	rng.randi()  # detail_noise
	rng.randi()  # color_noise

	var scale_x: float = float(Config.MAP_WIDTH) / float(pw)
	var scale_y: float = float(Config.MAP_HEIGHT) / float(ph)
	var pcenter_x: float = float(Config.MAP_WIDTH) / 2.0
	var pcenter_y: float = float(Config.MAP_HEIGHT) / 2.0
	var pmax_radius: float = minf(pcenter_x, pcenter_y)

	var img := Image.create(pw, ph, false, Image.FORMAT_RGB8)

	for y in ph:
		for x in pw:
			var fx: float = float(x) * scale_x
			var fy: float = float(y) * scale_y

			var dist_to_edge: float = minf(minf(fx, float(Config.MAP_WIDTH) - fx),
				minf(fy, float(Config.MAP_HEIGHT) - fy))
			if dist_to_edge < 30.0:
				img.set_pixel(x, y, Config.TERRAIN_COLORS[Config.Terrain.WATER])
				continue

			var dx: float = (fx - pcenter_x) / pmax_radius
			var dy: float = (fy - pcenter_y) / pmax_radius
			var dist_sq: float = dx * dx + dy * dy
			var continent_val: float = continent_noise.get_noise_2d(fx, fy)
			var land_value: float = 0.6 - dist_sq * 0.45 + continent_val * 0.35

			if land_value <= 0.0:
				img.set_pixel(x, y, Config.TERRAIN_COLORS[Config.Terrain.WATER])
				continue
			if land_value <= 0.04:
				img.set_pixel(x, y, Config.TERRAIN_COLORS[Config.Terrain.SHALLOW_WATER])
				continue

			var elev_val: float = elevation_noise.get_noise_2d(fx, fy)
			var elevation: float = (elev_val + 1.0) * 0.5
			var temp: float = temperature_noise.get_noise_2d(fx, fy)
			var moist: float = moisture_noise.get_noise_2d(fx, fy)

			var t: int
			if elevation > 0.85:
				t = Config.Terrain.STONE
			elif elevation > 0.70:
				t = Config.Terrain.HILL
			else:
				if temp < -0.15:
					t = Config.Terrain.SNOW
				elif temp > 0.25 and moist < -0.1:
					t = Config.Terrain.SAND
				elif moist > 0.15:
					t = Config.Terrain.FOREST
				else:
					t = Config.Terrain.GRASS

			var color: Color = Config.TERRAIN_COLORS[t]
			var pshade: float = 0.85 + elevation * 0.3
			color = Color(
				clampf(color.r * pshade, 0.0, 1.0),
				clampf(color.g * pshade, 0.0, 1.0),
				clampf(color.b * pshade, 0.0, 1.0))
			img.set_pixel(x, y, color)

	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

func _find_nearest(from_pos: Vector2, candidates: Array[Vector2]) -> Vector2:
	var best: Vector2 = candidates[0]
	var best_dist: float = from_pos.distance_squared_to(candidates[0])
	for i in range(1, candidates.size()):
		var d: float = from_pos.distance_squared_to(candidates[i])
		if d < best_dist:
			best_dist = d
			best = candidates[i]
	return best


func _find_walkable_near(target: Vector2, search_radius: int) -> Vector2:
	var tx: int = clampi(int(target.x), 0, _width - 1)
	var ty: int = clampi(int(target.y), 0, _height - 1)

	if _is_walkable_idx(tx, ty):
		return Vector2(tx, ty)

	var max_r: int = search_radius * 2
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var px: int = tx + dx
				var py: int = ty + dy
				if _is_walkable_idx(px, py):
					return Vector2(px, py)

	return Vector2(tx, ty)


func _is_walkable_idx(x: int, y: int) -> bool:
	if x < 0 or x >= _width or y < 0 or y >= _height:
		return false
	var t: int = get_terrain_at(Vector2i(x, y))
	return t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER


func _is_open_ground(x: int, y: int) -> bool:
	if x < 0 or x >= _width or y < 0 or y >= _height:
		return false
	var t: int = get_terrain_at(Vector2i(x, y))
	return t == Config.Terrain.GRASS or t == Config.Terrain.PATH \
		or t == Config.Terrain.SAND or t == Config.Terrain.SNOW


func _find_grass_or_path_near(target: Vector2, search_radius: int) -> Vector2:
	var tx: int = clampi(int(target.x), 0, _width - 1)
	var ty: int = clampi(int(target.y), 0, _height - 1)

	if _is_open_ground(tx, ty):
		return Vector2(tx, ty)

	var max_r: int = search_radius * 2
	for r in range(1, max_r + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var px: int = tx + dx
				var py: int = ty + dy
				if _is_open_ground(px, py):
					return Vector2(px, py)

	return Vector2(tx, ty)
