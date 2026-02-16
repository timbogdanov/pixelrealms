extends Node2D

## Procedural map generator for the Pixel Realms battle arena.
## Generates a large noise-based terrain map with 4 biomes (Plains, Forest, Desert, Snow),
## irregular ocean border, rivers, roads connecting shops, and mob spawn zones.

enum Biome { PLAINS, FOREST_BIOME, DESERT, SNOW_BIOME }

var terrain: PackedByteArray
var headless: bool = false
var _width: int
var _height: int
var _terrain_image: Image
var _display_texture: ImageTexture
var _sprite: Sprite2D

var _elevation_noise: FastNoiseLite

var hill_position: Vector2
var shop_positions: Array[Vector2] = []
var spawn_positions: Array[Vector2] = []
var mob_spawn_zones: Array = []

# Water animation
var _water_pixels: PackedInt32Array = PackedInt32Array()
var _water_base_colors: PackedColorArray = PackedColorArray()
var _water_image: Image
var _water_texture: ImageTexture
var _water_sprite: Sprite2D
var _water_shore_dist: PackedFloat32Array = PackedFloat32Array()
var _water_time: float = 0.0

# Hill visual color (golden/yellow stone)
const HILL_COLOR := Color(0.72, 0.65, 0.28)


func _ready() -> void:
	_width = Config.MAP_WIDTH
	_height = Config.MAP_HEIGHT
	var total: int = _width * _height
	terrain.resize(total)
	terrain.fill(0)

	if headless:
		return

	_terrain_image = Image.create(_width, _height, false, Image.FORMAT_RGB8)
	_display_texture = ImageTexture.create_from_image(_terrain_image)

	_sprite = $MapSprite
	_sprite.texture = _display_texture
	_sprite.centered = false

	_water_image = Image.create(_width, _height, false, Image.FORMAT_RGBA8)
	_water_image.fill(Color(0, 0, 0, 0))
	_water_texture = ImageTexture.create_from_image(_water_image)
	_water_sprite = Sprite2D.new()
	_water_sprite.texture = _water_texture
	_water_sprite.centered = false
	_water_sprite.z_index = 0
	add_child(_water_sprite)


# ---------------------------------------------------------------------------
# Main generation
# ---------------------------------------------------------------------------

func generate(seed_val: int = 42, _map_index: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# --- Noise layers ---
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
	_elevation_noise = elevation_noise

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

	var detail_noise := FastNoiseLite.new()
	detail_noise.seed = rng.randi()
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.frequency = 0.03
	detail_noise.fractal_octaves = 2

	var color_noise := FastNoiseLite.new()
	color_noise.seed = rng.randi()
	color_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	color_noise.frequency = 0.08
	color_noise.fractal_octaves = 1

	var center_x: float = float(_width) / 2.0
	var center_y: float = float(_height) / 2.0
	var max_radius: float = minf(center_x, center_y)

	var best_elev: float = -999.0
	var best_elev_pos := Vector2(center_x, center_y)

	# --- Pass 1 & 2: Land/ocean mask + terrain assignment ---
	for y in _height:
		for x in _width:
			var idx: int = y * _width + x
			var fx: float = float(x)
			var fy: float = float(y)

			# Hard water border (30px)
			var dist_to_edge: int = mini(mini(x, _width - 1 - x), mini(y, _height - 1 - y))
			if dist_to_edge < 30:
				terrain[idx] = Config.Terrain.WATER
				if not headless:
					var depth: float = float(30 - dist_to_edge) / 30.0 * 0.3
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.WATER]
					color = color.darkened(depth)
					_terrain_image.set_pixel(x, y, color)
				continue

			# Island shape: continent noise + squared distance falloff
			var dx: float = (fx - center_x) / max_radius
			var dy: float = (fy - center_y) / max_radius
			var dist_sq: float = dx * dx + dy * dy
			var continent_val: float = continent_noise.get_noise_2d(fx, fy)
			var land_value: float = 0.6 - dist_sq * 0.45 + continent_val * 0.35

			if land_value <= 0.0:
				# Ocean
				terrain[idx] = Config.Terrain.WATER
				if not headless:
					var depth: float = continent_noise.get_noise_2d(fx * 0.5, fy * 0.5) * 0.15
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.WATER]
					color = color.darkened(clampf(depth, 0.0, 0.3))
					_terrain_image.set_pixel(x, y, color)
				continue

			if land_value <= 0.04:
				# Shallow water near coastline
				terrain[idx] = Config.Terrain.SHALLOW_WATER
				if not headless:
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.SHALLOW_WATER]
					_terrain_image.set_pixel(x, y, color)
				continue

			# --- Land pixel: compute elevation and biome ---
			var elev_val: float = elevation_noise.get_noise_2d(fx, fy)
			var elevation: float = (elev_val + 1.0) * 0.5  # remap to [0, 1]

			if elevation > best_elev:
				best_elev = elevation
				best_elev_pos = Vector2(fx, fy)

			# Biome from temperature + moisture
			var temp: float = temperature_noise.get_noise_2d(fx, fy)
			var moist: float = moisture_noise.get_noise_2d(fx, fy)
			var detail: float = detail_noise.get_noise_2d(fx, fy)

			var biome: int
			if temp < -0.15:
				biome = Biome.SNOW_BIOME
			elif temp > 0.25 and moist < -0.1:
				biome = Biome.DESERT
			elif moist > 0.15:
				biome = Biome.FOREST_BIOME
			else:
				biome = Biome.PLAINS

			# Terrain type from elevation + biome
			var t: int
			if elevation > 0.85:
				t = Config.Terrain.STONE
			elif elevation > 0.70:
				t = Config.Terrain.HILL
			else:
				match biome:
					Biome.PLAINS:
						if detail > 0.2:
							t = Config.Terrain.FOREST
						else:
							t = Config.Terrain.GRASS
					Biome.FOREST_BIOME:
						if detail < -0.1:
							t = Config.Terrain.GRASS  # clearings
						else:
							t = Config.Terrain.FOREST
					Biome.DESERT:
						t = Config.Terrain.SAND
					Biome.SNOW_BIOME:
						if detail > 0.2:
							t = Config.Terrain.SNOW_FOREST
						else:
							t = Config.Terrain.SNOW
					_:
						t = Config.Terrain.GRASS

			terrain[idx] = t

			if headless:
				continue

			var color: Color = Config.TERRAIN_COLORS[t]
			var variation: float = color_noise.get_noise_2d(fx * 3.0, fy * 3.0) * 0.04

			# Elevation shading: higher = lighter
			var shade: float = 0.85 + elevation * 0.3
			color = Color(
				clampf(color.r * shade, 0.0, 1.0),
				clampf(color.g * shade, 0.0, 1.0),
				clampf(color.b * shade, 0.0, 1.0))

			# Per-pixel color variation
			color = color.lightened(variation)

			# Per-terrain pixel detail (hash-based noise)
			var hash_val: int = (x * 73 + y * 37) % 100
			match t:
				Config.Terrain.GRASS:
					if hash_val < 8:
						color = color.lightened(0.06)
					elif hash_val < 12:
						color = color.darkened(0.05)
				Config.Terrain.FOREST:
					var fhash: int = (x * 51 + y * 89) % 100
					if fhash < 15:
						color = color.darkened(0.12)
					elif fhash < 25:
						color = color.lightened(0.04)
				Config.Terrain.STONE:
					var shash: int = (x * 97 + y * 61) % 100
					if shash < 10:
						color = color.lightened(0.08)
					elif shash < 18:
						color = color.darkened(0.06)
				Config.Terrain.HILL:
					var hhash: int = (x * 97 + y * 61) % 100
					if hhash < 10:
						color = color.lightened(0.06)
					elif hhash < 18:
						color = color.darkened(0.05)
				Config.Terrain.SAND:
					var sahash: int = (x * 83 + y * 47) % 100
					if sahash < 10:
						color = color.lightened(0.05)
					elif sahash < 18:
						color = color.darkened(0.04)
				Config.Terrain.SNOW:
					var snhash: int = (x * 59 + y * 71) % 100
					if snhash < 12:
						color = color.lightened(0.04)
					elif snhash < 20:
						color = color.darkened(0.03)
				Config.Terrain.SNOW_FOREST:
					var sfhash: int = (x * 51 + y * 89) % 100
					if sfhash < 15:
						color = color.darkened(0.10)
					elif sfhash < 25:
						color = color.lightened(0.05)

			_terrain_image.set_pixel(x, y, color)

	# --- Pass 3: Place hill at highest elevation ---
	hill_position = best_elev_pos
	_carve_mountain(color_noise)

	# --- Pass 4: Generate rivers ---
	_generate_rivers(rng)

	# --- Pass 5: Place shops ---
	_place_shops(rng)

	# --- Pass 6: Generate roads ---
	_generate_roads()

	# --- Pass 7: Place spawns ---
	_place_spawns(rng)

	# --- Pass 8: Place mob zones ---
	_place_mob_spawn_zones(rng)

	if not headless:
		# --- Pass 9: Post-processing ---
		_apply_coastline_detail()
		_apply_dithered_transitions()
		_apply_mountain_glow()

		# --- Pass 10: Collect water pixels for animation ---
		_collect_water_pixels()

		# --- Finalize texture ---
		_display_texture.update(_terrain_image)


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
	var center_x: float = float(Config.MAP_WIDTH) / 2.0
	var center_y: float = float(Config.MAP_HEIGHT) / 2.0
	var max_radius: float = minf(center_x, center_y)

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
			var dx: float = (fx - center_x) / max_radius
			var dy: float = (fy - center_y) / max_radius
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
			var shade: float = 0.85 + elevation * 0.3
			color = Color(
				clampf(color.r * shade, 0.0, 1.0),
				clampf(color.g * shade, 0.0, 1.0),
				clampf(color.b * shade, 0.0, 1.0))
			img.set_pixel(x, y, color)

	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# Public terrain query functions
# ---------------------------------------------------------------------------

func is_walkable(pos: Vector2i) -> bool:
	var t: int = get_terrain_at(pos)
	return t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER


func get_terrain(pos: Vector2) -> int:
	return get_terrain_at(Vector2i(int(pos.x), int(pos.y)))


func get_terrain_at(pos: Vector2i) -> int:
	if pos.x < 0 or pos.x >= _width or pos.y < 0 or pos.y >= _height:
		return Config.Terrain.WATER
	return terrain[pos.y * _width + pos.x]


func get_speed_mult(pos: Vector2i) -> float:
	var t: int = get_terrain_at(pos)
	var speed: float = Config.TERRAIN_SPEED[t]
	return speed


func find_walkable_near(target: Vector2, search_radius: int) -> Vector2:
	return _find_walkable_near(target, search_radius)


func find_grass_or_path_near(target: Vector2, search_radius: int) -> Vector2:
	return _find_grass_or_path_near(target, search_radius)


# ---------------------------------------------------------------------------
# Mountain carving: STONE peak + HILL slopes at hill_position
# ---------------------------------------------------------------------------

func _carve_mountain(color_noise: FastNoiseLite) -> void:
	var cx: float = hill_position.x
	var cy: float = hill_position.y
	var stone_r: float = Config.MOUNTAIN_STONE_RADIUS
	var total_r: float = Config.MOUNTAIN_TOTAL_RADIUS
	var min_x: int = maxi(0, int(cx - total_r) - 1)
	var max_x: int = mini(_width - 1, int(cx + total_r) + 1)
	var min_y: int = maxi(0, int(cy - total_r) - 1)
	var max_y: int = mini(_height - 1, int(cy + total_r) + 1)

	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var dist: float = Vector2(x, y).distance_to(hill_position)
			if dist > total_r:
				continue
			var idx: int = y * _width + x
			# Skip water
			if terrain[idx] == Config.Terrain.WATER or terrain[idx] == Config.Terrain.SHALLOW_WATER:
				continue

			if dist <= stone_r:
				terrain[idx] = Config.Terrain.STONE
				if not headless:
					var variation: float = color_noise.get_noise_2d(float(x) * 3.0, float(y) * 3.0) * 0.04
					var center_blend: float = 1.0 - (dist / stone_r)
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.STONE]
					color = color.lightened(center_blend * 0.12 + variation)
					var mshash: int = (x * 97 + y * 61) % 100
					if mshash < 10:
						color = color.lightened(0.08)
					elif mshash < 18:
						color = color.darkened(0.06)
					_terrain_image.set_pixel(x, y, color)
			else:
				terrain[idx] = Config.Terrain.HILL
				if not headless:
					var variation: float = color_noise.get_noise_2d(float(x) * 3.0, float(y) * 3.0) * 0.04
					var slope_frac: float = (dist - stone_r) / (total_r - stone_r)
					var color: Color = HILL_COLOR.lightened((1.0 - slope_frac) * 0.15 + variation)
					var mhhash: int = (x * 97 + y * 61) % 100
					if mhhash < 10:
						color = color.lightened(0.06)
					elif mhhash < 18:
						color = color.darkened(0.05)
					_terrain_image.set_pixel(x, y, color)


# ---------------------------------------------------------------------------
# River generation: 5-6 rivers flowing outward from hill toward coast
# ---------------------------------------------------------------------------

func _generate_rivers(rng: RandomNumberGenerator) -> void:
	var num_rivers: int = rng.randi_range(5, 6)
	var base_angle: float = rng.randf_range(0.0, TAU)

	for i in num_rivers:
		var angle: float = base_angle + (TAU / float(num_rivers)) * float(i) + rng.randf_range(-0.2, 0.2)

		# Start partway from hill toward the edge
		var start_dist: float = rng.randf_range(180.0, 500.0)
		var start_x: float = hill_position.x + cos(angle) * start_dist
		var start_y: float = hill_position.y + sin(angle) * start_dist
		start_x = clampf(start_x, 40.0, float(_width - 40))
		start_y = clampf(start_y, 40.0, float(_height - 40))

		# Skip if starting in water
		var start_px: int = int(start_x)
		var start_py: int = int(start_y)
		if start_px < 0 or start_px >= _width or start_py < 0 or start_py >= _height:
			continue
		if terrain[start_py * _width + start_px] == Config.Terrain.WATER:
			continue

		var cur_x: float = start_x
		var cur_y: float = start_y
		var walk_angle: float = angle  # Walk outward from hill
		var river_width: int = rng.randi_range(3, 4)

		for _step in 5000:
			var px: int = int(cur_x)
			var py: int = int(cur_y)

			if px < 1 or px >= _width - 1 or py < 1 or py >= _height - 1:
				break

			if terrain[py * _width + px] == Config.Terrain.WATER:
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
				var fidx: int = fy * _width + fx
				var t: int = terrain[fidx]
				# Only overwrite land terrain, not water/stone/path
				if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.STONE or t == Config.Terrain.PATH:
					continue
				# Don't carve through mountain zone
				if Vector2(fx, fy).distance_to(hill_position) <= Config.MOUNTAIN_TOTAL_RADIUS + 5.0:
					continue
				terrain[fidx] = Config.Terrain.SHALLOW_WATER
				if not headless:
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.SHALLOW_WATER]
					var river_var: float = sin(float(fx) * 0.3) * 0.03
					color = color.lightened(river_var)
					_terrain_image.set_pixel(fx, fy, color)

			# Advance with wobble
			walk_angle += rng.randf_range(-0.25, 0.25)

			# Gentle bias to keep flowing away from hill
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
# Shop placement: Poisson disk sampling across land
# ---------------------------------------------------------------------------

func _place_shops(rng: RandomNumberGenerator) -> void:
	shop_positions.clear()
	var attempts: int = 0

	while shop_positions.size() < Config.NUM_SHOPS and attempts < 2000:
		attempts += 1
		var x: float = rng.randf_range(100.0, float(_width - 100))
		var y: float = rng.randf_range(100.0, float(_height - 100))
		var pos := Vector2(x, y)

		# Must be on open terrain
		var t: int = get_terrain(pos)
		if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.STONE or t == Config.Terrain.HILL:
			continue

		# Must be far from hill
		if pos.distance_to(hill_position) < Config.SHOP_MIN_DIST_FROM_HILL:
			continue

		# Must be far from other shops
		var too_close: bool = false
		for existing in shop_positions:
			if pos.distance_to(existing) < Config.SHOP_MIN_DIST_APART:
				too_close = true
				break
		if too_close:
			continue

		shop_positions.append(pos)


# ---------------------------------------------------------------------------
# Road generation: connect shops to hill and shops to nearest neighbor
# ---------------------------------------------------------------------------

func _generate_roads() -> void:
	# Connect all shops to hill (spoke roads)
	for shop_pos in shop_positions:
		_generate_path(shop_pos, hill_position)

	# Connect each shop to nearest neighbor (creates mesh)
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
			_generate_path(shop_positions[i], shop_positions[nearest_idx])


# ---------------------------------------------------------------------------
# Path generation: direct walk from A to B, carving PATH terrain
# ---------------------------------------------------------------------------

func _generate_path(from_pos: Vector2, to_pos: Vector2) -> void:
	var dist: float = from_pos.distance_to(to_pos)
	var steps: int = int(dist) + 1
	if steps <= 0:
		return

	var direction: Vector2 = (to_pos - from_pos).normalized()
	var step_size: float = dist / float(steps)
	var path_half_width: int = 1  # 3px wide path

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
				var fidx: int = fy * _width + fx
				var current_terrain: int = terrain[fidx]
				# Only overwrite walkable land terrain, never water or stone
				if current_terrain == Config.Terrain.GRASS or current_terrain == Config.Terrain.FOREST \
					or current_terrain == Config.Terrain.SAND or current_terrain == Config.Terrain.SNOW \
					or current_terrain == Config.Terrain.SNOW_FOREST or current_terrain == Config.Terrain.SHALLOW_WATER:
					terrain[fidx] = Config.Terrain.PATH
					if not headless:
						var color: Color = Config.TERRAIN_COLORS[Config.Terrain.PATH]
						var px_variation: float = sin(float(fx) * 0.5) * 0.03
						color = color.lightened(px_variation)
						_terrain_image.set_pixel(fx, fy, color)


# ---------------------------------------------------------------------------
# Spawn placement: random positions on open ground
# ---------------------------------------------------------------------------

func _place_spawns(rng: RandomNumberGenerator) -> void:
	spawn_positions.clear()
	var attempts: int = 0

	while spawn_positions.size() < Config.NUM_PLAYERS and attempts < 3000:
		attempts += 1
		var x: float = rng.randf_range(100.0, float(_width - 100))
		var y: float = rng.randf_range(100.0, float(_height - 100))
		var pos := Vector2(x, y)

		# Must be on open ground
		var t: int = get_terrain(pos)
		if t != Config.Terrain.GRASS and t != Config.Terrain.SAND and t != Config.Terrain.SNOW and t != Config.Terrain.PATH:
			continue

		# Must be far from hill
		if pos.distance_to(hill_position) < 200.0:
			continue

		# Must be far from shops
		var too_close: bool = false
		for shop_pos in shop_positions:
			if pos.distance_to(shop_pos) < Config.PLAYER_SPAWN_MIN_DIST_FROM_SHOP:
				too_close = true
				break
		if too_close:
			continue

		# Connect spawn to nearest shop with a path
		var nearest_shop: Vector2 = _find_nearest(pos, shop_positions)
		_generate_path(pos, nearest_shop)

		spawn_positions.append(pos)


# ---------------------------------------------------------------------------
# Mob spawn zone placement
# ---------------------------------------------------------------------------

func _place_mob_spawn_zones(rng: RandomNumberGenerator) -> void:
	mob_spawn_zones.clear()

	# Knights near hill (outside mountain)
	for _i in 4:
		var pos: Vector2 = _find_mob_position(rng, Config.MOUNTAIN_TOTAL_RADIUS + 30.0, 600.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.KNIGHT, "count": rng.randi_range(3, 4)})

	# Bandits mid-inner range
	for _i in 6:
		var pos: Vector2 = _find_mob_position(rng, 200.0, 1200.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.BANDIT, "count": rng.randi_range(3, 4)})

	# Skeletons wider range
	for _i in 8:
		var pos: Vector2 = _find_mob_position(rng, 300.0, 1800.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.SKELETON, "count": rng.randi_range(3, 5)})

	# Slimes everywhere
	for _i in 15:
		var pos: Vector2 = _find_mob_position(rng, 0.0, 99999.0)
		mob_spawn_zones.append({"pos": pos, "type": Config.MobType.SLIME, "count": rng.randi_range(3, 5)})


func _find_mob_position(rng: RandomNumberGenerator, min_hill_dist: float, max_hill_dist: float) -> Vector2:
	for _attempt in 300:
		var x: float = rng.randf_range(60.0, float(_width - 60))
		var y: float = rng.randf_range(60.0, float(_height - 60))
		var pos := Vector2(x, y)

		var t: int = get_terrain(pos)
		if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.STONE:
			continue

		var dist_to_hill: float = pos.distance_to(hill_position)
		if dist_to_hill < min_hill_dist or dist_to_hill > max_hill_dist:
			continue

		# Min distance from shops
		var too_close: bool = false
		for shop_pos in shop_positions:
			if pos.distance_to(shop_pos) < Config.MOB_MIN_DIST_FROM_SHOP:
				too_close = true
				break
		if too_close:
			continue

		return pos

	# Fallback
	return _find_walkable_near(Vector2(float(_width) / 2.0, float(_height) / 2.0), 500)


# ---------------------------------------------------------------------------
# Post-processing: coastline detail (sand strip along water edges)
# ---------------------------------------------------------------------------

func _apply_coastline_detail() -> void:
	var sand_inner := Color(0.76, 0.70, 0.50)
	var inner_pixels: Array = []
	var outer_pixels: Array = []

	for y in range(1, _height - 1):
		for x in range(1, _width - 1):
			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				continue

			# Check if any cardinal neighbor is water
			var adjacent_water: bool = false
			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var ni: int = (y + offset.y) * _width + (x + offset.x)
				var nt: int = terrain[ni]
				if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER:
					adjacent_water = true
					break

			if adjacent_water:
				inner_pixels.append(idx)
			else:
				# Check distance-2 neighbors
				var near_water: bool = false
				for offset in [Vector2i(-2, 0), Vector2i(2, 0), Vector2i(0, -2), Vector2i(0, 2),
							   Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
					var nx: int = x + offset.x
					var ny: int = y + offset.y
					if nx >= 0 and nx < _width and ny >= 0 and ny < _height:
						var ni: int = ny * _width + nx
						var nt: int = terrain[ni]
						if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER:
							near_water = true
							break
				if near_water:
					outer_pixels.append([idx, _terrain_image.get_pixel(x, y)])

	# Apply inner sand
	for idx: int in inner_pixels:
		var x: int = idx % _width
		var y: int = idx / _width
		var hash_val: int = (x * 73 + y * 37) % 100
		var sand: Color = sand_inner
		if hash_val < 10:
			sand = sand.darkened(0.06)
		_terrain_image.set_pixel(x, y, sand)

	# Apply outer sand (blend 50% with original)
	for entry: Array in outer_pixels:
		var idx: int = entry[0]
		var original: Color = entry[1]
		var x: int = idx % _width
		var y: int = idx / _width
		var blended: Color = original.lerp(sand_inner, 0.5)
		_terrain_image.set_pixel(x, y, blended)


# ---------------------------------------------------------------------------
# Post-processing: dithered biome transitions (retro checkerboard)
# ---------------------------------------------------------------------------

func _apply_dithered_transitions() -> void:
	for y in range(1, _height - 1):
		for x in range(1, _width - 1):
			# Only dither on checkerboard pattern
			if (x + y) % 2 != 0:
				continue

			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER or t == Config.Terrain.PATH:
				continue

			# Check if at a terrain border
			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = x + offset.x
				var ny: int = y + offset.y
				var nt: int = terrain[ny * _width + nx]
				if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER or nt == Config.Terrain.PATH:
					continue
				if nt != t:
					# Swap to neighbor color for dithered edge
					var neighbor_color: Color = _terrain_image.get_pixel(nx, ny)
					_terrain_image.set_pixel(x, y, neighbor_color)
					break


# ---------------------------------------------------------------------------
# Post-processing: mountain glow aura
# ---------------------------------------------------------------------------

func _apply_mountain_glow() -> void:
	var hill_r: float = Config.HILL_RADIUS
	var glow_inner: float = hill_r - 5.0
	var glow_outer: float = hill_r + 8.0
	var gold := Color(1.0, 0.85, 0.3)
	var cx: float = hill_position.x
	var cy: float = hill_position.y
	var min_x: int = maxi(0, int(cx - glow_outer) - 1)
	var max_x: int = mini(_width - 1, int(cx + glow_outer) + 1)
	var min_y: int = maxi(0, int(cy - glow_outer) - 1)
	var max_y: int = mini(_height - 1, int(cy + glow_outer) + 1)

	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var dist: float = Vector2(x, y).distance_to(hill_position)
			if dist >= glow_inner and dist <= glow_outer:
				var t: float = 1.0 - absf(dist - hill_r) / 8.0
				t = clampf(t, 0.0, 1.0) * 0.2
				var current: Color = _terrain_image.get_pixel(x, y)
				var glowed := Color(
					lerpf(current.r, gold.r, t),
					lerpf(current.g, gold.g, t),
					lerpf(current.b, gold.b, t))
				_terrain_image.set_pixel(x, y, glowed)


# ---------------------------------------------------------------------------
# Water animation: collect water pixel indices and base colors
# ---------------------------------------------------------------------------

func _collect_water_pixels() -> void:
	_water_pixels.clear()
	_water_base_colors.clear()
	_water_shore_dist.clear()

	# Build lookup: pixel index -> array index
	var water_indices: Dictionary = {}
	for y in _height:
		for x in _width:
			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				water_indices[idx] = _water_pixels.size()
				_water_pixels.append(idx)
				_water_base_colors.append(_terrain_image.get_pixel(x, y))
				_water_shore_dist.append(20.0)  # default far

	# BFS from land pixels adjacent to water to compute shore distance
	var queue: Array = []
	for y in _height:
		for x in _width:
			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER:
				for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx: int = x + offset.x
					var ny: int = y + offset.y
					if nx >= 0 and nx < _width and ny >= 0 and ny < _height:
						var nidx: int = ny * _width + nx
						if water_indices.has(nidx) and _water_shore_dist[water_indices[nidx]] > 0.5:
							_water_shore_dist[water_indices[nidx]] = 1.0
							queue.append([nx, ny, 1.0])

	# BFS expand
	var head: int = 0
	while head < queue.size():
		var entry: Array = queue[head]
		head += 1
		var cx: int = entry[0]
		var cy: int = entry[1]
		var cd: float = entry[2]
		if cd >= 20.0:
			continue
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var nx: int = cx + offset.x
			var ny: int = cy + offset.y
			if nx >= 0 and nx < _width and ny >= 0 and ny < _height:
				var nidx: int = ny * _width + nx
				if water_indices.has(nidx):
					var arr_idx: int = water_indices[nidx]
					if cd + 1.0 < _water_shore_dist[arr_idx]:
						_water_shore_dist[arr_idx] = cd + 1.0
						queue.append([nx, ny, cd + 1.0])


# ---------------------------------------------------------------------------
# Water animation: per-frame update (called from main.gd)
# ---------------------------------------------------------------------------

func update_water(delta: float, camera_pos: Vector2, view_half: Vector2) -> void:
	if headless:
		return
	_water_time += delta
	var cam_min_x: int = int(maxf(camera_pos.x - view_half.x - 2.0, 0.0))
	var cam_max_x: int = int(minf(camera_pos.x + view_half.x + 2.0, float(_width - 1)))
	var cam_min_y: int = int(maxf(camera_pos.y - view_half.y - 2.0, 0.0))
	var cam_max_y: int = int(minf(camera_pos.y + view_half.y + 2.0, float(_height - 1)))

	for i in _water_pixels.size():
		var idx: int = _water_pixels[i]
		var x: int = idx % _width
		var y: int = idx / _width
		if x < cam_min_x or x > cam_max_x or y < cam_min_y or y > cam_max_y:
			continue

		var base: Color = _water_base_colors[i]
		var shore_dist: float = _water_shore_dist[i]

		# Shore-directed wave
		var strength: float = clampf(1.0 - shore_dist / 15.0, 0.0, 1.0)
		var phase: float = _water_time * 1.5 + shore_dist * 0.4
		var wave: float = sin(phase) * 0.04 * strength

		var c := Color(base.r + wave, base.g + wave * 0.5, base.b + wave * 1.5, 1.0)

		# Foam near shore
		if shore_dist < 3.0 and sin(phase * 2.0) > 0.7:
			var foam_blend: float = (3.0 - shore_dist) / 3.0 * 0.3
			c = c.lerp(Color.WHITE, foam_blend)

		_water_image.set_pixel(x, y, c)

	_water_texture.update(_water_image)


# ---------------------------------------------------------------------------
# Utility: find nearest position in a list
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


# ---------------------------------------------------------------------------
# Utility: find walkable land position near a target
# ---------------------------------------------------------------------------

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
	var t: int = terrain[y * _width + x]
	return t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER


func _is_open_ground(x: int, y: int) -> bool:
	if x < 0 or x >= _width or y < 0 or y >= _height:
		return false
	var t: int = terrain[y * _width + x]
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
