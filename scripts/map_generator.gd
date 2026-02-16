extends Node2D

## Chunk-based procedural map generator for the Pixel Realms battle arena.
## Terrain generates lazily per-chunk on first access.
## Server only generates chunks entities occupy. Client only generates visuals near camera.

enum Biome { PLAINS, FOREST_BIOME, DESERT, SNOW_BIOME }

const CHUNK_SIZE := 128

var headless: bool = false

var _width: int
var _height: int
var _grid_w: int
var _grid_h: int

# Chunks: terrain data (lazy, generated on first access)
var _chunks: Dictionary = {}  # Vector2i(cx,cy) -> PackedByteArray

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
var _visual_chunks: Dictionary = {}  # Vector2i -> {sprite: Sprite2D, mat: ShaderMaterial}
var _chunk_parent: Node2D
var _water_shader: Shader
var _water_time: float = 0.0

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

	# Hard water border (30px)
	var dist_to_edge: int = mini(mini(x, _width - 1 - x), mini(y, _height - 1 - y))
	if dist_to_edge < 30:
		return Config.Terrain.WATER

	# Island shape
	var dx: float = (fx - _center_x) / _max_radius
	var dy: float = (fy - _center_y) / _max_radius
	var dist_sq: float = dx * dx + dy * dy
	var continent_val: float = _continent_noise.get_noise_2d(fx, fy)
	var land_value: float = 0.6 - dist_sq * 0.45 + continent_val * 0.35

	if land_value <= 0.0:
		return Config.Terrain.WATER
	if land_value <= 0.04:
		return Config.Terrain.SHALLOW_WATER

	# Elevation + biome
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
# Lazy chunk generation
# ---------------------------------------------------------------------------

func _get_or_generate_chunk(cx: int, cy: int) -> PackedByteArray:
	var key := Vector2i(cx, cy)
	if _chunks.has(key):
		return _chunks[key]

	var chunk := PackedByteArray()
	chunk.resize(CHUNK_SIZE * CHUNK_SIZE)

	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	for ly in CHUNK_SIZE:
		var world_y: int = base_y + ly
		if world_y >= _height:
			for lx in CHUNK_SIZE:
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.WATER
			continue
		for lx in CHUNK_SIZE:
			var world_x: int = base_x + lx
			if world_x >= _width:
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.WATER
				continue

			var pixel_key := Vector2i(world_x, world_y)

			# Check river/road overlays first (these override base terrain)
			if _river_pixels.has(pixel_key):
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.SHALLOW_WATER
				continue
			if _road_pixels.has(pixel_key):
				chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.PATH
				continue

			# Check mountain override
			var dist_to_hill: float = Vector2(world_x, world_y).distance_to(_mountain_center)
			if dist_to_hill <= _mountain_total_r:
				var base_t: int = _compute_terrain_type_at(world_x, world_y)
				if base_t != Config.Terrain.WATER and base_t != Config.Terrain.SHALLOW_WATER:
					if dist_to_hill <= _mountain_stone_r:
						chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.STONE
					else:
						chunk[ly * CHUNK_SIZE + lx] = Config.Terrain.HILL
					continue

			chunk[ly * CHUNK_SIZE + lx] = _compute_terrain_type_at(world_x, world_y)

	_chunks[key] = chunk
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

		# Skip if starting in water
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

			# Carve river strip perpendicular to walk direction
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
				# Don't carve through mountain zone
				if Vector2(fx, fy).distance_to(hill_position) <= _mountain_total_r + 5.0:
					continue
				_river_pixels[Vector2i(fx, fy)] = true

			# Advance with wobble
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
	# Connect all shops to hill
	for shop_pos in shop_positions:
		_compute_path_pixels(shop_pos, hill_position)

	# Connect each shop to nearest neighbor
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
				# Only mark road on land that would be walkable
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

		# Connect spawn to nearest shop
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

	# Compute visible chunk range with 2-chunk margin
	var margin: float = float(CHUNK_SIZE) * 2.0
	var min_x: int = maxi(0, int((camera_pos.x - view_half.x - margin) / float(CHUNK_SIZE)))
	var max_x: int = mini(_grid_w - 1, int((camera_pos.x + view_half.x + margin) / float(CHUNK_SIZE)))
	var min_y: int = maxi(0, int((camera_pos.y - view_half.y - margin) / float(CHUNK_SIZE)))
	var max_y: int = mini(_grid_h - 1, int((camera_pos.y + view_half.y + margin) / float(CHUNK_SIZE)))

	# Load needed chunks (limit 4 new per frame)
	var loaded_this_frame: int = 0
	for cy in range(min_y, max_y + 1):
		for cx in range(min_x, max_x + 1):
			var key := Vector2i(cx, cy)
			if not _visual_chunks.has(key):
				if loaded_this_frame >= 4:
					continue
				_generate_chunk_visuals(cx, cy)
				loaded_this_frame += 1
			else:
				# Update water time uniform
				var entry: Dictionary = _visual_chunks[key]
				var mat: ShaderMaterial = entry["mat"]
				if mat != null:
					mat.set_shader_parameter("time", _water_time)

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
		var entry: Dictionary = _visual_chunks[key]
		var sprite: Sprite2D = entry["sprite"]
		sprite.queue_free()
		_visual_chunks.erase(key)


# ---------------------------------------------------------------------------
# Generate visual sprites for a single chunk
# ---------------------------------------------------------------------------

func _generate_chunk_visuals(cx: int, cy: int) -> void:
	var chunk: PackedByteArray = _get_or_generate_chunk(cx, cy)
	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	# Create terrain color image
	var terrain_img := Image.create(CHUNK_SIZE, CHUNK_SIZE, false, Image.FORMAT_RGB8)

	# Create terrain data image (RG8: R=terrain_type/10, G=shore_dist/20)
	var data_img := Image.create(CHUNK_SIZE, CHUNK_SIZE, false, Image.FORMAT_RG8)

	# Compute shore distances for this chunk
	var shore_dist: PackedByteArray = _compute_chunk_shore_distance(cx, cy, chunk)

	for ly in CHUNK_SIZE:
		var world_y: int = base_y + ly
		for lx in CHUNK_SIZE:
			var world_x: int = base_x + lx
			var idx: int = ly * CHUNK_SIZE + lx
			var t: int = chunk[idx]
			var sd: int = shore_dist[idx]

			# Data texture: terrain type and shore distance
			data_img.set_pixel(lx, ly, Color(float(t) / 10.0, float(sd) / 20.0, 0.0))

			# Color
			var fx: float = float(world_x)
			var fy: float = float(world_y)
			var color: Color = Config.TERRAIN_COLORS[t]

			if t == Config.Terrain.WATER:
				# Depth variation for ocean
				if world_x >= 0 and world_x < _width and world_y >= 0 and world_y < _height:
					var depth: float = _continent_noise.get_noise_2d(fx * 0.5, fy * 0.5) * 0.15
					color = color.darkened(clampf(depth, 0.0, 0.3))
					# Hard border darkening
					var dist_to_edge: int = mini(mini(world_x, _width - 1 - world_x), mini(world_y, _height - 1 - world_y))
					if dist_to_edge < 30:
						var border_depth: float = float(30 - dist_to_edge) / 30.0 * 0.3
						color = color.darkened(border_depth)
			elif t == Config.Terrain.SHALLOW_WATER:
				var river_var: float = sin(fx * 0.3) * 0.03
				color = color.lightened(river_var)
			elif t != Config.Terrain.PATH:
				# Land pixel: elevation shading + detail
				var elev_val: float = _elevation_noise.get_noise_2d(fx, fy)
				var elevation: float = (elev_val + 1.0) * 0.5
				var variation: float = _color_noise.get_noise_2d(fx * 3.0, fy * 3.0) * 0.04
				var shade: float = 0.85 + elevation * 0.3
				color = Color(
					clampf(color.r * shade, 0.0, 1.0),
					clampf(color.g * shade, 0.0, 1.0),
					clampf(color.b * shade, 0.0, 1.0))
				color = color.lightened(variation)

				# Mountain special coloring
				var dist_to_hill: float = Vector2(world_x, world_y).distance_to(_mountain_center)
				if t == Config.Terrain.STONE and dist_to_hill <= _mountain_stone_r:
					var stone_color: Color = Config.TERRAIN_COLORS[Config.Terrain.STONE]
					var center_blend: float = 1.0 - (dist_to_hill / _mountain_stone_r)
					color = stone_color.lightened(center_blend * 0.12 + variation)
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
				var px_variation: float = sin(fx * 0.5) * 0.03
				color = color.lightened(px_variation)

			terrain_img.set_pixel(lx, ly, color)

	# Apply coastline sand strip
	_apply_chunk_coastline(cx, cy, chunk, terrain_img)

	# Apply dithered transitions
	_apply_chunk_dither(cx, cy, chunk, terrain_img)

	# Apply mountain glow
	_apply_chunk_mountain_glow(cx, cy, terrain_img)

	# Create textures
	var terrain_tex := ImageTexture.create_from_image(terrain_img)
	var data_tex := ImageTexture.create_from_image(data_img)

	# Create sprite with water shader
	var sprite := Sprite2D.new()
	sprite.texture = terrain_tex
	sprite.centered = false
	sprite.position = Vector2(base_x, base_y)

	var mat := ShaderMaterial.new()
	mat.shader = _water_shader
	mat.set_shader_parameter("terrain_data", data_tex)
	mat.set_shader_parameter("time", _water_time)
	sprite.material = mat

	_chunk_parent.add_child(sprite)
	_visual_chunks[Vector2i(cx, cy)] = {"sprite": sprite, "mat": mat}


# ---------------------------------------------------------------------------
# Shore distance computation for a chunk (directional scan, max 20px)
# ---------------------------------------------------------------------------

func _compute_chunk_shore_distance(cx: int, cy: int, chunk: PackedByteArray) -> PackedByteArray:
	var dist := PackedByteArray()
	dist.resize(CHUNK_SIZE * CHUNK_SIZE)
	dist.fill(20)  # default: far from shore

	var base_x: int = cx * CHUNK_SIZE
	var base_y: int = cy * CHUNK_SIZE

	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var t: int = chunk[ly * CHUNK_SIZE + lx]
			if t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER:
				continue

			# Check 4 cardinal directions for land within 20px
			var min_d: int = 20
			for dir_idx in 4:
				var ddx: int = [1, -1, 0, 0][dir_idx]
				var ddy: int = [0, 0, 1, -1][dir_idx]
				for step in range(1, 21):
					var wx: int = base_x + lx + ddx * step
					var wy: int = base_y + ly + ddy * step
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
						# Need to check adjacent chunk
						var adj_chunk: PackedByteArray = _get_or_generate_chunk(check_cx, check_cy)
						check_t = adj_chunk[check_ly * CHUNK_SIZE + check_lx]
					if check_t != Config.Terrain.WATER and check_t != Config.Terrain.SHALLOW_WATER:
						min_d = mini(min_d, step)
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

			# Check cardinal neighbors for water
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
				# Check distance-2 neighbors
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
					# Get neighbor color from neighbor chunk's image or compute it
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

	# Quick check: is this chunk anywhere near the hill glow?
	var chunk_center := Vector2(float(base_x + CHUNK_SIZE / 2), float(base_y + CHUNK_SIZE / 2))
	if chunk_center.distance_to(hill_position) > glow_outer + float(CHUNK_SIZE):
		return

	for ly in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var world_x: int = base_x + lx
			var world_y: int = base_y + ly
			var dist: float = Vector2(world_x, world_y).distance_to(hill_position)
			if dist >= glow_inner and dist <= glow_outer:
				var t: float = 1.0 - absf(dist - hill_r) / 8.0
				t = clampf(t, 0.0, 1.0) * 0.2
				var current: Color = img.get_pixel(lx, ly)
				var glowed := Color(
					lerpf(current.r, gold.r, t),
					lerpf(current.g, gold.g, t),
					lerpf(current.b, gold.b, t))
				img.set_pixel(lx, ly, glowed)


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
	var adj_chunk: PackedByteArray = _get_or_generate_chunk(tcx, tcy)
	return adj_chunk[tly * CHUNK_SIZE + tlx]


# ---------------------------------------------------------------------------
# Helper: compute terrain color for a specific world pixel
# ---------------------------------------------------------------------------

func _compute_terrain_color(wx: int, wy: int, t: int) -> Color:
	var fx: float = float(wx)
	var fy: float = float(wy)
	var color: Color = Config.TERRAIN_COLORS[t]

	if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.PATH:
		return color

	var elev_val: float = _elevation_noise.get_noise_2d(fx, fy)
	var elevation: float = (elev_val + 1.0) * 0.5
	var variation: float = _color_noise.get_noise_2d(fx * 3.0, fy * 3.0) * 0.04
	var shade: float = 0.85 + elevation * 0.3
	color = Color(
		clampf(color.r * shade, 0.0, 1.0),
		clampf(color.g * shade, 0.0, 1.0),
		clampf(color.b * shade, 0.0, 1.0))
	color = color.lightened(variation)
	return color


# ---------------------------------------------------------------------------
# Clear all visual chunks (for game cleanup)
# ---------------------------------------------------------------------------

func clear_visuals() -> void:
	for key: Vector2i in _visual_chunks:
		var entry: Dictionary = _visual_chunks[key]
		var sprite: Sprite2D = entry["sprite"]
		sprite.queue_free()
	_visual_chunks.clear()


# ---------------------------------------------------------------------------
# Fast preview generation (200x200 thumbnail for lobby)
# ---------------------------------------------------------------------------

func generate_preview(seed_val: int, pw: int = 200, ph: int = 200) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# Same noise layers as generate() — must consume rng.randi() in same order
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

	# Consume remaining noise seeds to keep rng sequence aligned
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

			# Hard water border
			var dist_to_edge: float = minf(minf(fx, float(Config.MAP_WIDTH) - fx),
				minf(fy, float(Config.MAP_HEIGHT) - fy))
			if dist_to_edge < 30.0:
				img.set_pixel(x, y, Config.TERRAIN_COLORS[Config.Terrain.WATER])
				continue

			# Island shape
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

			# Biome
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
