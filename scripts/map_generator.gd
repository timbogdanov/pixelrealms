extends Node2D

## Procedural map generator for the Pixel Realms battle arena.
## Generates an 800x600 pixel terrain map with noise-based coastlines,
## elevation-driven terrain, paths between key locations, and mob spawn zones.

var terrain: PackedByteArray
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

# Hill visual color (golden/yellow stone)
const HILL_COLOR := Color(0.72, 0.65, 0.28)

# Country shape polygons (normalized 0.0-1.0)
const USA_POLY: Array[Vector2] = [
	Vector2(0.05, 0.15), Vector2(0.12, 0.12), Vector2(0.20, 0.10),
	Vector2(0.30, 0.08), Vector2(0.40, 0.12), Vector2(0.48, 0.10),
	Vector2(0.55, 0.12), Vector2(0.65, 0.10), Vector2(0.75, 0.12),
	Vector2(0.82, 0.16), Vector2(0.90, 0.22), Vector2(0.95, 0.32),
	Vector2(0.93, 0.42), Vector2(0.88, 0.52), Vector2(0.80, 0.58),
	Vector2(0.72, 0.65), Vector2(0.62, 0.72), Vector2(0.52, 0.78),
	Vector2(0.42, 0.82), Vector2(0.32, 0.88), Vector2(0.22, 0.85),
	Vector2(0.14, 0.78), Vector2(0.08, 0.68), Vector2(0.05, 0.55),
	Vector2(0.04, 0.42), Vector2(0.03, 0.28),
]
const CANADA_POLY: Array[Vector2] = [
	Vector2(0.05, 0.38), Vector2(0.08, 0.28), Vector2(0.14, 0.18),
	Vector2(0.22, 0.12), Vector2(0.32, 0.08), Vector2(0.42, 0.05),
	Vector2(0.52, 0.04), Vector2(0.62, 0.05), Vector2(0.72, 0.08),
	Vector2(0.80, 0.14), Vector2(0.88, 0.22), Vector2(0.94, 0.32),
	Vector2(0.95, 0.42), Vector2(0.92, 0.55), Vector2(0.86, 0.65),
	Vector2(0.78, 0.74), Vector2(0.68, 0.80), Vector2(0.55, 0.85),
	Vector2(0.42, 0.88), Vector2(0.30, 0.85), Vector2(0.20, 0.78),
	Vector2(0.12, 0.68), Vector2(0.07, 0.55),
]
const EUROPE_POLY: Array[Vector2] = [
	Vector2(0.28, 0.08), Vector2(0.38, 0.05), Vector2(0.50, 0.06),
	Vector2(0.62, 0.08), Vector2(0.72, 0.14), Vector2(0.80, 0.22),
	Vector2(0.86, 0.32), Vector2(0.90, 0.44), Vector2(0.88, 0.56),
	Vector2(0.84, 0.66), Vector2(0.76, 0.75), Vector2(0.66, 0.82),
	Vector2(0.54, 0.88), Vector2(0.42, 0.92), Vector2(0.32, 0.88),
	Vector2(0.22, 0.80), Vector2(0.16, 0.70), Vector2(0.12, 0.58),
	Vector2(0.10, 0.44), Vector2(0.12, 0.32), Vector2(0.18, 0.20),
	Vector2(0.24, 0.12),
]
const MAP_POLYS: Array[Array] = [USA_POLY, CANADA_POLY, EUROPE_POLY]

func _ready() -> void:
	_width = Config.MAP_WIDTH
	_height = Config.MAP_HEIGHT
	var total: int = _width * _height
	terrain.resize(total)
	terrain.fill(0)

	_terrain_image = Image.create(_width, _height, false, Image.FORMAT_RGB8)
	_display_texture = ImageTexture.create_from_image(_terrain_image)

	_sprite = $MapSprite
	_sprite.texture = _display_texture
	_sprite.centered = false


func _point_in_polygon(point: Vector2, polygon: Array) -> bool:
	var inside: bool = false
	var j: int = polygon.size() - 1
	for i in polygon.size():
		var pi: Vector2 = polygon[i]
		var pj: Vector2 = polygon[j]
		if (pi.y > point.y) != (pj.y > point.y):
			var x_intersect: float = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
			if point.x < x_intersect:
				inside = not inside
		j = i
	return inside


func generate(seed_val: int = 42, map_index: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# --- Noise layers ---

	# Continent noise: broad island shape
	var continent_noise := FastNoiseLite.new()
	continent_noise.seed = rng.randi()
	continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	continent_noise.frequency = 0.005
	continent_noise.fractal_octaves = 4

	# Elevation noise: terrain height variation within the island
	var elevation_noise := FastNoiseLite.new()
	elevation_noise.seed = rng.randi()
	elevation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	elevation_noise.frequency = 0.012
	elevation_noise.fractal_octaves = 3
	_elevation_noise = elevation_noise

	# Forest noise: separate layer for forest cluster placement
	var forest_noise := FastNoiseLite.new()
	forest_noise.seed = rng.randi()
	forest_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	forest_noise.frequency = 0.025
	forest_noise.fractal_octaves = 2

	# Color variation noise: subtle per-pixel color offsets
	var color_noise := FastNoiseLite.new()
	color_noise.seed = rng.randi()
	color_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	color_noise.frequency = 0.08
	color_noise.fractal_octaves = 1

	# Lake noise: additional water bodies inside the continent
	var lake_noise := FastNoiseLite.new()
	lake_noise.seed = rng.randi()
	lake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	lake_noise.frequency = 0.015
	lake_noise.fractal_octaves = 2

	var center_x: float = _width * 0.5
	var center_y: float = _height * 0.5
	var hill_radius: float = Config.HILL_RADIUS

	# Select country polygon
	var active_poly: Array = MAP_POLYS[clampi(map_index, 0, MAP_POLYS.size() - 1)]

	# --- Pass 1: Generate base terrain using country shape ---
	for y in _height:
		for x in _width:
			var idx: int = y * _width + x

			# Hard water border within 5px of edges
			var dist_to_edge: int = mini(mini(x, _width - 1 - x), mini(y, _height - 1 - y))
			if dist_to_edge < 5:
				terrain[idx] = Config.Terrain.WATER
				var color: Color = Config.TERRAIN_COLORS[Config.Terrain.WATER]
				color = color.darkened(clampf(float(5 - dist_to_edge) / 5.0 * 0.3, 0.0, 0.3))
				_terrain_image.set_pixel(x, y, color)
				continue

			# Country shape check with noise wobble for organic coastline
			var wobble: float = continent_noise.get_noise_2d(x, y) * 0.02
			var norm_pos := Vector2(float(x) / float(_width) + wobble, float(y) / float(_height) + wobble)
			var is_land: bool = _point_in_polygon(norm_pos, active_poly)

			if not is_land:
				terrain[idx] = Config.Terrain.WATER
				var depth: float = continent_noise.get_noise_2d(x * 0.5, y * 0.5) * 0.15
				var color: Color = Config.TERRAIN_COLORS[Config.Terrain.WATER]
				color = color.darkened(clampf(depth, 0.0, 0.3))
				_terrain_image.set_pixel(x, y, color)
				continue

			# Land: compute elevation
			var elev_val: float = elevation_noise.get_noise_2d(x, y)
			var base_height: float = 0.3 + continent_noise.get_noise_2d(x, y) * 0.2
			var elevation: float = base_height + elev_val * 0.25

			# Check for inland lakes
			var lake_val: float = lake_noise.get_noise_2d(x, y)
			if lake_val > 0.42 and elevation < 0.35:
				terrain[idx] = Config.Terrain.WATER
				var color: Color = Config.TERRAIN_COLORS[Config.Terrain.WATER]
				color = color.lightened(0.05)
				_terrain_image.set_pixel(x, y, color)
				continue

			var forest_val: float = forest_noise.get_noise_2d(x, y)
			var variation: float = color_noise.get_noise_2d(x * 3.0, y * 3.0) * 0.04

			# Hill zone: forced HILL terrain near center
			var dist_to_center: float = Vector2(x, y).distance_to(Vector2(center_x, center_y))
			if dist_to_center <= hill_radius:
				terrain[idx] = Config.Terrain.HILL
				var center_blend: float = 1.0 - (dist_to_center / hill_radius)
				var color: Color = HILL_COLOR.lightened(center_blend * 0.15 + variation)
				_terrain_image.set_pixel(x, y, color)
				continue

			# Elevation-based terrain assignment
			var t: int
			if elevation > 0.65:
				t = Config.Terrain.STONE
			elif elevation > 0.45:
				t = Config.Terrain.HILL
			elif forest_val > 0.15 and elevation < 0.25:
				t = Config.Terrain.FOREST
			else:
				t = Config.Terrain.GRASS

			terrain[idx] = t
			var color: Color = Config.TERRAIN_COLORS[t]
			color = color.lightened(variation)
			_terrain_image.set_pixel(x, y, color)

	# --- Generate rivers ---
	_generate_rivers(rng)

	# --- Place key locations ---
	hill_position = Vector2(center_x, center_y)
	_place_shops(rng)
	_place_spawns(rng)

	# --- Generate paths connecting shops to Hill ---
	for shop_pos in shop_positions:
		_generate_path(shop_pos, hill_position)

	# --- Generate paths connecting spawns to nearest shop ---
	for spawn_pos in spawn_positions:
		var nearest_shop: Vector2 = _find_nearest(spawn_pos, shop_positions)
		_generate_path(spawn_pos, nearest_shop)

	# --- Place mob spawn zones ---
	_place_mob_spawn_zones(rng)

	# --- Finalize texture ---
	_display_texture.update(_terrain_image)


func is_walkable(pos: Vector2i) -> bool:
	var t: int = get_terrain_at(pos)
	return t != Config.Terrain.STONE


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


# ---------------------------------------------------------------------------
#  Shop placement: 3 shops at 120-degree intervals, ~60% from center to edge
# ---------------------------------------------------------------------------
func _place_shops(rng: RandomNumberGenerator) -> void:
	shop_positions.clear()
	var center: Vector2 = Vector2(_width * 0.5, _height * 0.5)
	var base_angle: float = rng.randf_range(0.0, TAU / 3.0)

	for i in 3:
		var angle: float = base_angle + (TAU / 3.0) * float(i)
		var target_dist: float = minf(_width, _height) * 0.5 * 0.6
		var target: Vector2 = center + Vector2(cos(angle), sin(angle)) * target_dist
		var snapped: Vector2 = _find_walkable_near(target, 40)
		shop_positions.append(snapped)


# ---------------------------------------------------------------------------
#  Spawn placement: NUM_PLAYERS spawns spread evenly around perimeter
# ---------------------------------------------------------------------------
func _place_spawns(rng: RandomNumberGenerator) -> void:
	spawn_positions.clear()
	var center: Vector2 = Vector2(_width * 0.5, _height * 0.5)
	var base_angle: float = rng.randf_range(0.0, TAU / float(Config.NUM_PLAYERS))

	for i in Config.NUM_PLAYERS:
		var angle: float = base_angle + (TAU / float(Config.NUM_PLAYERS)) * float(i)
		angle += rng.randf_range(-0.05, 0.05)
		var target_dist: float = minf(_width, _height) * 0.5 * 0.75
		var target: Vector2 = center + Vector2(cos(angle), sin(angle)) * target_dist
		var snapped: Vector2 = _find_walkable_near(target, 50)
		spawn_positions.append(snapped)


# ---------------------------------------------------------------------------
#  Mob spawn zone placement
# ---------------------------------------------------------------------------
func _place_mob_spawn_zones(rng: RandomNumberGenerator) -> void:
	mob_spawn_zones.clear()
	var center: Vector2 = Vector2(_width * 0.5, _height * 0.5)
	var max_dist: float = minf(_width, _height) * 0.5

	# 8 slime zones in outer ring (80-95% from center)
	for i in 8:
		var angle: float = (TAU / 8.0) * float(i) + rng.randf_range(-0.2, 0.2)
		var dist_frac: float = rng.randf_range(0.80, 0.95)
		var target: Vector2 = center + Vector2(cos(angle), sin(angle)) * max_dist * dist_frac
		var pos: Vector2 = _find_walkable_near(target, 30)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.SLIME,
			"count": rng.randi_range(3, 5),
		})

	# 4 skeleton zones in middle ring (45-65% from center)
	for i in 4:
		var angle: float = (TAU / 4.0) * float(i) + rng.randf_range(-0.3, 0.3)
		var dist_frac: float = rng.randf_range(0.45, 0.65)
		var target: Vector2 = center + Vector2(cos(angle), sin(angle)) * max_dist * dist_frac
		var pos: Vector2 = _find_walkable_near(target, 30)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.SKELETON,
			"count": rng.randi_range(3, 5),
		})

	# 2 knight zones near center (20-35% from center, but not on Hill)
	for i in 2:
		var angle: float = (TAU / 2.0) * float(i) + rng.randf_range(-0.4, 0.4)
		var dist_frac: float = rng.randf_range(0.20, 0.35)
		var target: Vector2 = center + Vector2(cos(angle), sin(angle)) * max_dist * dist_frac
		# Ensure not overlapping with Hill
		if target.distance_to(center) < Config.HILL_RADIUS + 10.0:
			target = center + Vector2(cos(angle), sin(angle)) * (Config.HILL_RADIUS + 15.0)
		var pos: Vector2 = _find_walkable_near(target, 30)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.KNIGHT,
			"count": rng.randi_range(3, 4),
		})


# ---------------------------------------------------------------------------
#  River generation: 3 rivers flowing from inland hills toward the coast
# ---------------------------------------------------------------------------
func _generate_rivers(rng: RandomNumberGenerator) -> void:
	var center_x: float = _width * 0.5
	var center_y: float = _height * 0.5
	var map_radius: float = minf(_width, _height) * 0.5
	var hill_radius: float = Config.HILL_RADIUS
	var base_angle: float = rng.randf_range(0.0, TAU / 3.0)

	for i in 3:
		# Pick a starting angle ~120 degrees apart with some randomness
		var angle: float = base_angle + (TAU / 3.0) * float(i) + rng.randf_range(-0.3, 0.3)

		# Start point: center offset by ~35% of map radius (inland hills area)
		var start_dist: float = map_radius * 0.35
		var start_x: float = center_x + cos(angle) * start_dist
		var start_y: float = center_y + sin(angle) * start_dist

		# Walk direction: roughly toward nearest edge (same angle as offset)
		var walk_angle: float = angle
		var cur_x: float = start_x
		var cur_y: float = start_y
		var river_width: int = rng.randi_range(2, 3)

		# Walk until we hit water or the map edge
		for _step in 2000:  # safety limit
			var px: int = int(cur_x)
			var py: int = int(cur_y)

			# Stop if outside map bounds
			if px < 1 or px >= _width - 1 or py < 1 or py >= _height - 1:
				break

			# Stop if we hit existing water (we've reached the coast)
			var center_idx: int = py * _width + px
			var center_terrain: int = terrain[center_idx]
			if center_terrain == Config.Terrain.WATER:
				break

			# Carve a strip perpendicular to the walk direction
			var perp_angle: float = walk_angle + PI * 0.5
			var perp_dx: float = cos(perp_angle)
			var perp_dy: float = sin(perp_angle)
			var half_w: int = river_width / 2

			for w in range(-half_w, half_w + 1):
				var fx: int = px + int(round(perp_dx * float(w)))
				var fy: int = py + int(round(perp_dy * float(w)))

				if fx < 0 or fx >= _width or fy < 0 or fy >= _height:
					continue

				var idx: int = fy * _width + fx
				var t: int = terrain[idx]

				# Only overwrite GRASS, FOREST, HILL — never WATER, STONE, PATH
				if t != Config.Terrain.GRASS and t != Config.Terrain.FOREST and t != Config.Terrain.HILL:
					continue

				# Don't carve through the central hill zone
				var dist_to_center: float = Vector2(fx, fy).distance_to(Vector2(center_x, center_y))
				if dist_to_center <= hill_radius + 5.0:
					continue

				terrain[idx] = Config.Terrain.SHALLOW_WATER
				var color: Color = Config.TERRAIN_COLORS[Config.Terrain.SHALLOW_WATER]
				var variation: float = sin(float(fx) * 0.3) * 0.03
				color = color.lightened(variation)
				_terrain_image.set_pixel(fx, fy, color)

			# Advance one pixel in walk direction with wobble
			walk_angle += rng.randf_range(-0.3, 0.3)
			cur_x += cos(walk_angle)
			cur_y += sin(walk_angle)


# ---------------------------------------------------------------------------
#  Path generation: direct walk from A to B, carving PATH terrain
# ---------------------------------------------------------------------------
func _generate_path(from_pos: Vector2, to_pos: Vector2) -> void:
	# Bresenham-style walk with slight width (3px) for visible paths
	var dist: float = from_pos.distance_to(to_pos)
	var steps: int = int(dist) + 1
	if steps <= 0:
		return

	var direction: Vector2 = (to_pos - from_pos).normalized()
	var step_size: float = dist / float(steps)
	var path_half_width: int = 1  # 3px wide path (center +/- 1)

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
				var idx: int = fy * _width + fx
				var current_terrain: int = terrain[idx]
				# Only overwrite grass, forest, or shallow water with path; never overwrite water, stone, or hill
				if current_terrain == Config.Terrain.GRASS or current_terrain == Config.Terrain.FOREST or current_terrain == Config.Terrain.SHALLOW_WATER:
					terrain[idx] = Config.Terrain.PATH
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.PATH]
					# Slight variation for visual interest
					var px_variation: float = sin(float(fx) * 0.5) * 0.03
					color = color.lightened(px_variation)
					_terrain_image.set_pixel(fx, fy, color)


# ---------------------------------------------------------------------------
#  Utility: find nearest position in a list
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
#  Utility: find walkable land position near a target via expanding search
# ---------------------------------------------------------------------------
func _find_walkable_near(target: Vector2, search_radius: int) -> Vector2:
	var tx: int = clampi(int(target.x), 0, _width - 1)
	var ty: int = clampi(int(target.y), 0, _height - 1)

	# Check the target pixel first
	if _is_walkable_idx(tx, ty):
		return Vector2(tx, ty)

	# Expanding ring search (try up to double radius as fallback)
	var max_radius: int = search_radius * 2
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var px: int = tx + dx
				var py: int = ty + dy
				if _is_walkable_idx(px, py):
					return Vector2(px, py)

	# Fallback: return target even if not ideal
	return Vector2(tx, ty)


func _is_walkable_idx(x: int, y: int) -> bool:
	if x < 0 or x >= _width or y < 0 or y >= _height:
		return false
	var t: int = terrain[y * _width + x]
	return t != Config.Terrain.STONE and t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER
