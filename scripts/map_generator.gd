extends Node2D

## Procedural map generator for the Pixel Realms battle arena.
## Generates an 800x600 pixel terrain map with noise-based coastlines,
## elevation-driven terrain, paths between key locations, and mob spawn zones.
## Country shapes loaded from CountryData (real geographic boundaries).

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

# Water animation
var _water_pixels: PackedInt32Array = PackedInt32Array()
var _water_base_colors: PackedColorArray = PackedColorArray()
var _water_image: Image
var _water_texture: ImageTexture
var _water_sprite: Sprite2D
var _water_time: float = 0.0

# Hill visual color (golden/yellow stone)
const HILL_COLOR := Color(0.72, 0.65, 0.28)

# Multi-polygon country data (set per generate() call)
var _active_polygons: Array = []
var _polygon_aabbs: Array = []  # Rect2 per ring for fast rejection
var _center: Vector2 = Vector2.ZERO  # country centroid in pixel coords


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

	_water_image = Image.create(_width, _height, false, Image.FORMAT_RGBA8)
	_water_image.fill(Color(0, 0, 0, 0))
	_water_texture = ImageTexture.create_from_image(_water_image)
	_water_sprite = Sprite2D.new()
	_water_sprite.texture = _water_texture
	_water_sprite.centered = false
	_water_sprite.z_index = 0  # same level as terrain
	add_child(_water_sprite)


# ---------------------------------------------------------------------------
# Multi-polygon support
# ---------------------------------------------------------------------------

func _precompute_aabbs() -> void:
	_polygon_aabbs.clear()
	for polygon: Array in _active_polygons:
		var min_x: float = 1.0
		var max_x: float = 0.0
		var min_y: float = 1.0
		var max_y: float = 0.0
		for v: Vector2 in polygon:
			min_x = minf(min_x, v.x)
			max_x = maxf(max_x, v.x)
			min_y = minf(min_y, v.y)
			max_y = maxf(max_y, v.y)
		_polygon_aabbs.append(Rect2(min_x, min_y, max_x - min_x, max_y - min_y))


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


func _point_in_country(norm_pos: Vector2) -> bool:
	for i in _active_polygons.size():
		var aabb: Rect2 = _polygon_aabbs[i]
		if not aabb.has_point(norm_pos):
			continue
		if _point_in_polygon(norm_pos, _active_polygons[i]):
			return true
	return false


func _find_land_radius(center: Vector2, angle: float) -> float:
	## Ray-march from center outward at the given angle.
	## Returns the distance (in pixels) to the last land pixel found.
	var max_dist: float = 0.0
	for step in 500:
		var pos: Vector2 = center + Vector2(cos(angle), sin(angle)) * float(step)
		var px: int = int(pos.x)
		var py: int = int(pos.y)
		if px < 0 or px >= _width or py < 0 or py >= _height:
			break
		var norm: Vector2 = Vector2(float(px) / float(_width), float(py) / float(_height))
		if _point_in_country(norm):
			max_dist = float(step)
		elif max_dist > 0.0:
			break  # We left the land
	return max_dist


# ---------------------------------------------------------------------------
# Main generation
# ---------------------------------------------------------------------------

func generate(seed_val: int = 42, map_index: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# --- Load country polygon data ---
	var country_id: String = CountryData.MAP_IDS[clampi(map_index, 0, CountryData.MAP_IDS.size() - 1)]
	var country_info: Dictionary = CountryData.COUNTRIES[country_id]
	_active_polygons = country_info["polygons"]
	_precompute_aabbs()
	var centroid: Vector2 = country_info["centroid"]
	var center_x: float = centroid.x * float(_width)
	var center_y: float = centroid.y * float(_height)
	_center = Vector2(center_x, center_y)

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
			var is_land: bool = _point_in_country(norm_pos)

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

			# Mountain zone: STONE peak + HILL slopes around center
			var dist_to_center: float = Vector2(x, y).distance_to(_center)
			if dist_to_center <= Config.MOUNTAIN_TOTAL_RADIUS:
				if dist_to_center <= Config.MOUNTAIN_STONE_RADIUS:
					terrain[idx] = Config.Terrain.STONE
					var center_blend: float = 1.0 - (dist_to_center / Config.MOUNTAIN_STONE_RADIUS)
					var color: Color = Config.TERRAIN_COLORS[Config.Terrain.STONE]
					color = color.lightened(center_blend * 0.12 + variation)
					# Terrain detail based on hash
					var mshash: int = (x * 97 + y * 61) % 100
					if mshash < 10:
						color = color.lightened(0.08)  # speckle
					elif mshash < 18:
						color = color.darkened(0.06)  # crack
					_terrain_image.set_pixel(x, y, color)
				else:
					terrain[idx] = Config.Terrain.HILL
					var slope_frac: float = (dist_to_center - Config.MOUNTAIN_STONE_RADIUS) / (Config.MOUNTAIN_TOTAL_RADIUS - Config.MOUNTAIN_STONE_RADIUS)
					var color: Color = HILL_COLOR.lightened((1.0 - slope_frac) * 0.15 + variation)
					# Terrain detail based on hash
					var mhhash: int = (x * 97 + y * 61) % 100
					if mhhash < 10:
						color = color.lightened(0.06)
					elif mhhash < 18:
						color = color.darkened(0.05)
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
			# Terrain detail based on hash
			var hash_val: int = (x * 73 + y * 37) % 100
			match t:
				Config.Terrain.GRASS:
					if hash_val < 8:
						color = color.lightened(0.06)  # lighter blade
					elif hash_val < 12:
						color = color.darkened(0.05)  # shadow
				Config.Terrain.FOREST:
					var fhash: int = (x * 51 + y * 89) % 100
					if fhash < 15:
						color = color.darkened(0.12)  # dark canopy
					elif fhash < 25:
						color = color.lightened(0.04)  # lighter patch
				Config.Terrain.STONE:
					var shash: int = (x * 97 + y * 61) % 100
					if shash < 10:
						color = color.lightened(0.08)  # speckle
					elif shash < 18:
						color = color.darkened(0.06)  # crack
				Config.Terrain.HILL:
					var hhash: int = (x * 97 + y * 61) % 100
					if hhash < 10:
						color = color.lightened(0.06)
					elif hhash < 18:
						color = color.darkened(0.05)
				Config.Terrain.PATH:
					var phash: int = (x * 41 + y * 83) % 100
					if phash < 5:
						color = color.lightened(0.05)  # worn center
					elif phash < 10:
						color = color.darkened(0.04)  # dirt variation
			_terrain_image.set_pixel(x, y, color)

	# --- Generate rivers ---
	_generate_rivers(rng)

	# --- Place key locations ---
	hill_position = _center
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

	# --- Post-processing passes ---
	_apply_coastline_detail()
	_apply_biome_transitions()
	_apply_mountain_glow()
	_collect_water_pixels()

	# --- Finalize texture ---
	_display_texture.update(_terrain_image)


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


# ---------------------------------------------------------------------------
#  Shop placement: 3 shops at 120-degree intervals, using land-aware radius
# ---------------------------------------------------------------------------
func _place_shops(rng: RandomNumberGenerator) -> void:
	shop_positions.clear()
	var base_angle: float = rng.randf_range(0.0, TAU / 3.0)

	for i in 3:
		var angle: float = base_angle + (TAU / 3.0) * float(i)
		var land_dist: float = _find_land_radius(_center, angle)
		var target_dist: float = maxf(land_dist * 0.6, Config.SHOP_MIN_DIST_FROM_HILL)
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * target_dist
		var snapped: Vector2 = _find_grass_or_path_near(target, 80)

		# Validate minimum distance from other shops
		var attempts: int = 0
		while attempts < 5:
			var too_close: bool = false
			for existing in shop_positions:
				if snapped.distance_to(existing) < Config.SHOP_MIN_DIST_APART:
					too_close = true
					break
			if not too_close:
				break
			attempts += 1
			target_dist += 30.0
			target = _center + Vector2(cos(angle), sin(angle)) * target_dist
			snapped = _find_grass_or_path_near(target, 80)

		shop_positions.append(snapped)


# ---------------------------------------------------------------------------
#  Spawn placement: NUM_PLAYERS spawns spread evenly around perimeter
# ---------------------------------------------------------------------------
func _place_spawns(rng: RandomNumberGenerator) -> void:
	spawn_positions.clear()
	var base_angle: float = rng.randf_range(0.0, TAU / float(Config.NUM_PLAYERS))

	for i in Config.NUM_PLAYERS:
		var angle: float = base_angle + (TAU / float(Config.NUM_PLAYERS)) * float(i)
		angle += rng.randf_range(-0.05, 0.05)
		var land_dist: float = _find_land_radius(_center, angle)
		var target_dist: float = maxf(land_dist * 0.75, 30.0)
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * target_dist
		var snapped: Vector2 = _find_grass_or_path_near(target, 80)

		# Validate minimum distance from safe zones
		var attempts: int = 0
		while attempts < 5:
			var too_close: bool = false
			for shop_pos in shop_positions:
				if snapped.distance_to(shop_pos) < Config.PLAYER_SPAWN_MIN_DIST_FROM_SHOP:
					too_close = true
					break
			if not too_close:
				break
			attempts += 1
			target_dist += 10.0
			target = _center + Vector2(cos(angle), sin(angle)) * target_dist
			snapped = _find_grass_or_path_near(target, 80)

		spawn_positions.append(snapped)


# ---------------------------------------------------------------------------
#  Mob spawn zone placement using land-aware radius
# ---------------------------------------------------------------------------
func _place_mob_spawn_zones(rng: RandomNumberGenerator) -> void:
	mob_spawn_zones.clear()

	# 8 slime zones in outer ring (80-95% from center)
	for i in 8:
		var angle: float = (TAU / 8.0) * float(i) + rng.randf_range(-0.2, 0.2)
		var land_dist: float = _find_land_radius(_center, angle)
		var dist_frac: float = rng.randf_range(0.80, 0.95)
		var target_dist: float = maxf(land_dist * dist_frac, 30.0)
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * target_dist
		var pos: Vector2 = _find_walkable_near(target, 60)
		pos = _nudge_mob_from_shops(pos, angle, target_dist, 60)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.SLIME,
			"count": rng.randi_range(3, 5),
		})

	# 4 skeleton zones in middle ring (45-65% from center)
	for i in 4:
		var angle: float = (TAU / 4.0) * float(i) + rng.randf_range(-0.3, 0.3)
		var land_dist: float = _find_land_radius(_center, angle)
		var dist_frac: float = rng.randf_range(0.45, 0.65)
		var target_dist: float = maxf(land_dist * dist_frac, 30.0)
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * target_dist
		var pos: Vector2 = _find_walkable_near(target, 60)
		pos = _nudge_mob_from_shops(pos, angle, target_dist, 60)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.SKELETON,
			"count": rng.randi_range(3, 5),
		})

	# 3 bandit zones in mid-outer ring (40-55% from center)
	for i in 3:
		var angle: float = (TAU / 3.0) * float(i) + rng.randf_range(-0.3, 0.3)
		var land_dist: float = _find_land_radius(_center, angle)
		var dist_frac: float = rng.randf_range(0.40, 0.55)
		var target_dist: float = maxf(land_dist * dist_frac, 30.0)
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * target_dist
		var pos: Vector2 = _find_walkable_near(target, 60)
		pos = _nudge_mob_from_shops(pos, angle, target_dist, 60)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.BANDIT,
			"count": rng.randi_range(3, 4),
		})

	# 2 knight zones near center (20-35% from center, but not on mountain)
	for i in 2:
		var angle: float = (TAU / 2.0) * float(i) + rng.randf_range(-0.4, 0.4)
		var land_dist: float = _find_land_radius(_center, angle)
		var dist_frac: float = rng.randf_range(0.20, 0.35)
		var target_dist: float = maxf(land_dist * dist_frac, 30.0)
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * target_dist
		# Ensure not overlapping with mountain
		if target.distance_to(_center) < Config.MOUNTAIN_TOTAL_RADIUS + 10.0:
			target = _center + Vector2(cos(angle), sin(angle)) * (Config.MOUNTAIN_TOTAL_RADIUS + 15.0)
		var pos: Vector2 = _find_walkable_near(target, 60)
		pos = _nudge_mob_from_shops(pos, angle, target_dist, 60)
		mob_spawn_zones.append({
			"pos": pos,
			"type": Config.MobType.KNIGHT,
			"count": rng.randi_range(3, 4),
		})


func _nudge_mob_from_shops(pos: Vector2, angle: float, base_dist: float, search_radius: int) -> Vector2:
	var current_pos: Vector2 = pos
	var current_dist: float = base_dist
	for _attempt in 5:
		var too_close: bool = false
		for shop_pos in shop_positions:
			if current_pos.distance_to(shop_pos) < Config.MOB_MIN_DIST_FROM_SHOP:
				too_close = true
				break
		if not too_close:
			return current_pos
		current_dist += 15.0
		var target: Vector2 = _center + Vector2(cos(angle), sin(angle)) * current_dist
		current_pos = _find_walkable_near(target, search_radius)
	return current_pos


# ---------------------------------------------------------------------------
#  River generation: 3 rivers flowing from inland hills toward the coast
# ---------------------------------------------------------------------------
func _generate_rivers(rng: RandomNumberGenerator) -> void:
	var mountain_radius: float = Config.MOUNTAIN_TOTAL_RADIUS
	var base_angle: float = rng.randf_range(0.0, TAU / 3.0)

	for i in 3:
		# Pick a starting angle ~120 degrees apart with some randomness
		var angle: float = base_angle + (TAU / 3.0) * float(i) + rng.randf_range(-0.3, 0.3)

		# Use land-aware radius for river start point
		var land_dist: float = _find_land_radius(_center, angle)
		var start_dist: float = land_dist * 0.35
		var start_x: float = _center.x + cos(angle) * start_dist
		var start_y: float = _center.y + sin(angle) * start_dist

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
				var dist_to_center: float = Vector2(fx, fy).distance_to(_center)
				if dist_to_center <= mountain_radius + 5.0:
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
	return t != Config.Terrain.WATER and t != Config.Terrain.SHALLOW_WATER


func _is_grass_or_path(x: int, y: int) -> bool:
	if x < 0 or x >= _width or y < 0 or y >= _height:
		return false
	var t: int = terrain[y * _width + x]
	return t == Config.Terrain.GRASS or t == Config.Terrain.PATH


func _find_grass_or_path_near(target: Vector2, search_radius: int) -> Vector2:
	var tx: int = clampi(int(target.x), 0, _width - 1)
	var ty: int = clampi(int(target.y), 0, _height - 1)

	if _is_grass_or_path(tx, ty):
		return Vector2(tx, ty)

	var max_radius: int = search_radius * 2
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var px: int = tx + dx
				var py: int = ty + dy
				if _is_grass_or_path(px, py):
					return Vector2(px, py)

	return Vector2(tx, ty)


func find_walkable_near(target: Vector2, search_radius: int) -> Vector2:
	return _find_walkable_near(target, search_radius)


func find_grass_or_path_near(target: Vector2, search_radius: int) -> Vector2:
	return _find_grass_or_path_near(target, search_radius)


# ---------------------------------------------------------------------------
#  Post-processing: coastline detail
# ---------------------------------------------------------------------------
func _apply_coastline_detail() -> void:
	var sand := Color(0.75, 0.68, 0.45)
	for y in range(1, _height - 1):
		for x in range(1, _width - 1):
			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				continue
			# Check 4 neighbors for water
			var has_water: bool = false
			if terrain[idx - 1] == Config.Terrain.WATER or terrain[idx - 1] == Config.Terrain.SHALLOW_WATER:
				has_water = true
			elif terrain[idx + 1] == Config.Terrain.WATER or terrain[idx + 1] == Config.Terrain.SHALLOW_WATER:
				has_water = true
			elif terrain[idx - _width] == Config.Terrain.WATER or terrain[idx - _width] == Config.Terrain.SHALLOW_WATER:
				has_water = true
			elif terrain[idx + _width] == Config.Terrain.WATER or terrain[idx + _width] == Config.Terrain.SHALLOW_WATER:
				has_water = true
			if has_water:
				var variation: float = float((x * 53 + y * 71) % 100) / 100.0 * 0.06
				_terrain_image.set_pixel(x, y, sand.lightened(variation))


# ---------------------------------------------------------------------------
#  Post-processing: biome transitions
# ---------------------------------------------------------------------------
func _apply_biome_transitions() -> void:
	for y in range(1, _height - 1):
		for x in range(1, _width - 1):
			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				continue
			var my_color: Color = _terrain_image.get_pixel(x, y)
			var blend_count: int = 0
			var blend_r: float = 0.0
			var blend_g: float = 0.0
			var blend_b: float = 0.0
			for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var nx: int = x + offset.x
				var ny: int = y + offset.y
				var nt: int = terrain[ny * _width + nx]
				if nt == Config.Terrain.WATER or nt == Config.Terrain.SHALLOW_WATER:
					continue
				if nt != t:
					var nc: Color = _terrain_image.get_pixel(nx, ny)
					blend_r += nc.r
					blend_g += nc.g
					blend_b += nc.b
					blend_count += 1
			if blend_count > 0:
				var avg_r: float = blend_r / float(blend_count)
				var avg_g: float = blend_g / float(blend_count)
				var avg_b: float = blend_b / float(blend_count)
				var blended := Color(
					lerpf(my_color.r, avg_r, 0.3),
					lerpf(my_color.g, avg_g, 0.3),
					lerpf(my_color.b, avg_b, 0.3))
				_terrain_image.set_pixel(x, y, blended)


# ---------------------------------------------------------------------------
#  Post-processing: mountain glow aura
# ---------------------------------------------------------------------------
func _apply_mountain_glow() -> void:
	var hill_r: float = Config.HILL_RADIUS
	var glow_inner: float = hill_r - 5.0
	var glow_outer: float = hill_r + 8.0
	var gold := Color(1.0, 0.85, 0.3)
	var cx: float = _center.x
	var cy: float = _center.y
	var min_x: int = maxi(0, int(cx - glow_outer) - 1)
	var max_x: int = mini(_width - 1, int(cx + glow_outer) + 1)
	var min_y: int = maxi(0, int(cy - glow_outer) - 1)
	var max_y: int = mini(_height - 1, int(cy + glow_outer) + 1)
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var dist: float = Vector2(x, y).distance_to(_center)
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
#  Water animation: collect water pixel indices and base colors
# ---------------------------------------------------------------------------
func _collect_water_pixels() -> void:
	_water_pixels.clear()
	_water_base_colors.clear()
	for y in _height:
		for x in _width:
			var idx: int = y * _width + x
			var t: int = terrain[idx]
			if t == Config.Terrain.WATER or t == Config.Terrain.SHALLOW_WATER:
				_water_pixels.append(idx)
				_water_base_colors.append(_terrain_image.get_pixel(x, y))


# ---------------------------------------------------------------------------
#  Water animation: per-frame update (called from main.gd)
# ---------------------------------------------------------------------------
func update_water(delta: float, camera_pos: Vector2, view_half: Vector2) -> void:
	_water_time += delta
	var cam_min_x: int = maxi(0, int(camera_pos.x - view_half.x) - 2)
	var cam_max_x: int = mini(_width - 1, int(camera_pos.x + view_half.x) + 2)
	var cam_min_y: int = maxi(0, int(camera_pos.y - view_half.y) - 2)
	var cam_max_y: int = mini(_height - 1, int(camera_pos.y + view_half.y) + 2)

	for i in _water_pixels.size():
		var idx: int = _water_pixels[i]
		var x: int = idx % _width
		var y: int = idx / _width
		if x < cam_min_x or x > cam_max_x or y < cam_min_y or y > cam_max_y:
			continue
		var base: Color = _water_base_colors[i]
		# Sin-wave ripple
		var ripple: float = sin(_water_time * 2.0 + float(x) * 0.3 + float(y) * 0.2) * 0.06
		var color := Color(base.r + ripple, base.g + ripple, base.b + ripple * 1.5)
		# Sparkle
		var sparkle_hash: int = (x * 131 + y * 97 + int(_water_time * 3.0)) % 1000
		if sparkle_hash < 3:
			color = Color(0.9, 0.95, 1.0, 0.8)
		_terrain_image.set_pixel(x, y, color)

	_display_texture.update(_terrain_image)
