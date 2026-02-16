extends Node

## Pre-generated ImageTexture sprites for all game entities.
## Generated once at startup, cached for efficient draw_texture_rect() rendering.

# --- Cached textures ---
var player_tex: Dictionary = {}  # "p{color}_{frame}" -> ImageTexture
var mob_tex: Dictionary = {}     # "m{type}_{frame}" -> ImageTexture
var shop_tex: ImageTexture
var gold_tex: ImageTexture
var potion_tex: ImageTexture
var arrow_tex: ImageTexture
var skull_tex: ImageTexture
var crown_tex: ImageTexture
var flag_tex: Dictionary = {}  # color_idx -> ImageTexture (or "neutral" key for gold)

# --- Equipment visual constants (used by main.gd at render time) ---
const WEAPON_COLORS: Dictionary = {
	1: Color(0.6, 0.45, 0.2),    # tier 1: wooden
	2: Color(0.7, 0.7, 0.75),    # tier 2: iron
	3: Color(0.92, 0.92, 0.96),  # tier 3: steel
}

const SKIN_COLOR := Color(0.87, 0.72, 0.53)

# Mob sprite dimensions
const MOB_SIZES: Dictionary = {
	0: Vector2(6, 6),   # SLIME
	1: Vector2(8, 6),   # SKELETON
	2: Vector2(8, 8),   # KNIGHT
	3: Vector2(7, 7),   # BANDIT
}


func _ready() -> void:
	_gen_players()
	_gen_mobs()
	_gen_shop()
	_gen_pickups()
	_gen_arrow()
	_gen_skull()
	_gen_crown()
	_gen_flags()


# --- Public API ---

func get_player(color_idx: int, frame: int) -> ImageTexture:
	var key: String = "p%d_%d" % [color_idx, frame]
	return player_tex.get(key)


func get_mob(mob_type: int, frame: int) -> ImageTexture:
	var key: String = "m%d_%d" % [mob_type, frame]
	return mob_tex.get(key)


func get_mob_size(mob_type: int) -> Vector2:
	var size: Vector2 = MOB_SIZES.get(mob_type, Vector2(8, 8))
	return size


# --- Internal helper ---

func _make_tex(w: int, h: int, data: Array, palette: Array) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var row: Array = data[y]
		for x in w:
			var t: int = row[x]
			if t > 0:
				img.set_pixel(x, y, palette[t])
	return ImageTexture.create_from_image(img)


# ==========================================================
# Player sprites (8x8 humanoid, 4 frames x 20 colors = 80)
# ==========================================================
# Pixel types: 0=clear 1=hair 2=skin 3=body 4=arm 5=leg

func _gen_players() -> void:
	var frames: Array = [
		# 0: idle
		[[0,0,1,1,1,1,0,0],[0,1,2,2,2,2,1,0],[0,4,3,3,3,3,4,0],[0,4,3,3,3,3,4,0],[0,4,3,3,3,3,4,0],[0,0,3,3,3,3,0,0],[0,0,5,0,0,5,0,0],[0,0,5,0,0,5,0,0]],
		# 1: walk_0 (legs apart)
		[[0,0,1,1,1,1,0,0],[0,1,2,2,2,2,1,0],[0,4,3,3,3,3,4,0],[0,4,3,3,3,3,4,0],[0,4,3,3,3,3,4,0],[0,0,3,3,3,3,0,0],[0,5,0,0,0,0,5,0],[0,5,0,0,0,0,5,0]],
		# 2: walk_1 (legs close)
		[[0,0,1,1,1,1,0,0],[0,1,2,2,2,2,1,0],[0,4,3,3,3,3,4,0],[0,4,3,3,3,3,4,0],[0,4,3,3,3,3,4,0],[0,0,3,3,3,3,0,0],[0,0,0,5,5,0,0,0],[0,0,0,5,5,0,0,0]],
		# 3: attack (arms extended outward)
		[[0,0,1,1,1,1,0,0],[0,1,2,2,2,2,1,0],[4,0,3,3,3,3,0,4],[4,0,3,3,3,3,0,4],[0,0,3,3,3,3,0,0],[0,0,3,3,3,3,0,0],[0,0,5,0,0,5,0,0],[0,0,5,0,0,5,0,0]],
	]
	for ci in Config.PLAYER_COLORS.size():
		var pc: Color = Config.PLAYER_COLORS[ci]
		var palette: Array = [
			Color(0, 0, 0, 0),    # 0: transparent
			pc.darkened(0.3),      # 1: hair
			SKIN_COLOR,            # 2: skin
			pc,                    # 3: body
			pc.lightened(0.12),    # 4: arm
			pc.darkened(0.25),     # 5: leg
		]
		for fi in frames.size():
			player_tex["p%d_%d" % [ci, fi]] = _make_tex(8, 8, frames[fi], palette)


# ==========================================================
# Mob sprites (2 frames each for idle bob)
# ==========================================================

func _gen_mobs() -> void:
	# --- Slime (6x6): green blob ---
	# 0=clear 1=dark_outline 2=body 3=highlight
	var sp: Array = [Color(0,0,0,0), Color(0.15,0.45,0.15), Color(0.3,0.75,0.3), Color(0.5,0.9,0.4)]
	mob_tex["m0_0"] = _make_tex(6, 6, [
		[0,0,1,1,0,0],[0,1,2,2,1,0],[1,2,3,3,2,1],
		[1,2,2,2,2,1],[0,1,2,2,1,0],[0,0,1,1,0,0]], sp)
	mob_tex["m0_1"] = _make_tex(6, 6, [
		[0,0,0,0,0,0],[0,1,1,1,1,0],[1,2,3,3,2,1],
		[1,2,2,2,2,1],[1,2,2,2,2,1],[0,1,1,1,1,0]], sp)

	# --- Skeleton (8x6): bone white with eye sockets ---
	# 0=clear 1=bone 2=eyes 3=shadow
	var kp: Array = [Color(0,0,0,0), Color(0.9,0.88,0.82), Color(0.15,0.1,0.1), Color(0.7,0.68,0.6)]
	mob_tex["m1_0"] = _make_tex(8, 6, [
		[0,0,1,1,1,1,0,0],[0,1,2,1,1,2,1,0],[0,0,1,3,3,1,0,0],
		[0,0,3,0,0,3,0,0],[0,0,0,1,1,0,0,0],[0,0,3,0,0,3,0,0]], kp)
	mob_tex["m1_1"] = _make_tex(8, 6, [
		[0,0,1,1,1,1,0,0],[0,1,2,1,1,2,1,0],[0,0,1,3,3,1,0,0],
		[0,0,0,3,3,0,0,0],[0,0,3,0,0,3,0,0],[0,0,3,0,0,3,0,0]], kp)

	# --- Knight (8x8): armored with shield and sword ---
	# 0=clear 1=helmet 2=visor 3=armor 4=shield 5=sword
	var np: Array = [Color(0,0,0,0), Color(0.55,0.55,0.55), Color(0.15,0.15,0.2),
		Color(0.5,0.5,0.52), Color(0.3,0.35,0.65), Color(0.8,0.8,0.85)]
	mob_tex["m2_0"] = _make_tex(8, 8, [
		[0,0,1,1,1,1,0,0],[0,1,1,2,2,1,1,0],[0,4,1,3,3,1,5,0],[0,4,1,3,3,1,5,0],
		[0,0,3,3,3,3,0,0],[0,0,3,3,3,3,0,0],[0,0,3,0,0,3,0,0],[0,0,3,0,0,3,0,0]], np)
	mob_tex["m2_1"] = _make_tex(8, 8, [
		[0,0,1,1,1,1,0,0],[0,1,1,2,2,1,1,0],[0,4,1,3,3,1,5,0],[0,4,1,3,3,1,5,0],
		[0,0,3,3,3,3,0,0],[0,0,3,3,3,3,0,0],[0,0,0,3,3,0,0,0],[0,0,3,0,0,3,0,0]], np)

	# --- Bandit (7x7): hooded with dagger ---
	# 0=clear 1=hood 2=skin 3=eyes 4=tunic 5=dagger 6=pants
	var bp: Array = [Color(0,0,0,0), Color(0.45,0.3,0.15), Color(0.87,0.72,0.53),
		Color(0.15,0.1,0.1), Color(0.55,0.4,0.2), Color(0.7,0.7,0.65), Color(0.3,0.25,0.2)]
	mob_tex["m3_0"] = _make_tex(7, 7, [
		[0,0,1,1,1,0,0],[0,1,1,1,1,1,0],[0,1,2,3,3,2,0],[0,0,4,4,4,0,0],
		[5,0,4,4,4,0,0],[0,0,6,0,6,0,0],[0,0,6,0,6,0,0]], bp)
	mob_tex["m3_1"] = _make_tex(7, 7, [
		[0,0,1,1,1,0,0],[0,1,1,1,1,1,0],[0,1,2,3,3,2,0],[0,0,4,4,4,0,0],
		[5,0,4,4,4,0,0],[0,6,0,0,0,6,0],[0,6,0,0,0,6,0]], bp)


# ==========================================================
# Shop sprite (16x16): building with roof, windows, door
# ==========================================================

func _gen_shop() -> void:
	# 0=clear 1=roof 2=roof_edge 3=wall 4=wall_border 5=window_glass
	# 6=door 7=handle(gold) 8=stone 9=stone_dark 10=chimney
	# 11=wall_light 12=window_frame 13=smoke 14=sign 15=door_arch
	var p: Array = [
		Color(0, 0, 0, 0),          # 0: transparent
		Color(0.62, 0.16, 0.10),    # 1: roof tile
		Color(0.42, 0.10, 0.06),    # 2: roof edge / ridge
		Color(0.76, 0.60, 0.34),    # 3: wall
		Color(0.50, 0.40, 0.24),    # 4: wall border / timber
		Color(0.28, 0.42, 0.72),    # 5: window glass
		Color(0.42, 0.28, 0.14),    # 6: door wood
		Color(0.90, 0.75, 0.25),    # 7: door handle gold
		Color(0.52, 0.50, 0.46),    # 8: stone
		Color(0.36, 0.34, 0.30),    # 9: stone dark / mortar
		Color(0.40, 0.32, 0.24),    # 10: chimney brick
		Color(0.82, 0.68, 0.42),    # 11: wall light grain
		Color(0.88, 0.86, 0.82),    # 12: window frame white
		Color(0.72, 0.72, 0.74, 0.6), # 13: smoke wisp
		Color(0.55, 0.40, 0.18),    # 14: hanging sign
		Color(0.36, 0.22, 0.10),    # 15: door arch dark
	]
	shop_tex = _make_tex(16, 16, [
		[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,10,13, 0, 0],
		[0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0,10, 0, 0, 0],
		[0, 0, 0, 0, 0, 0, 2, 1, 2, 0, 0, 0,10, 0, 0, 0],
		[0, 0, 0, 0, 0, 2, 1, 1, 1, 2, 0, 0,10, 0, 0, 0],
		[0, 0, 0, 0, 2, 1, 1, 2, 1, 1, 2, 2, 2, 2, 0, 0],
		[0, 0, 0, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 0],
		[0, 0, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2],
		[0, 4, 3,11, 3,11, 3, 3,11, 3,11, 3, 3,11, 4,14],
		[0, 4,12, 5, 5,12, 3,11, 3,11,12, 5, 5,12, 4,14],
		[0, 4,12, 5, 5,12, 3, 3,11, 3,12, 5, 5,12, 4, 0],
		[0, 4, 3,11, 3, 3,15, 6, 6,15, 3,11, 3, 3, 4, 0],
		[0, 4,11, 3,11, 3, 6, 6, 7, 6, 3, 3,11, 3, 4, 0],
		[0, 4, 3,11, 3,11, 6, 6, 6, 6,11, 3, 3,11, 4, 0],
		[0, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 9, 9, 0],
		[0, 9, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 9, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]], p)


# ==========================================================
# Pickup sprites
# ==========================================================

func _gen_pickups() -> void:
	# Gold coin (5x5): 0=clear 1=dark_gold 2=gold 3=highlight
	gold_tex = _make_tex(5, 5, [
		[0,1,2,1,0],[1,2,2,2,1],[2,2,3,2,2],[1,2,2,2,1],[0,1,2,1,0]],
		[Color(0,0,0,0), Color(0.7,0.55,0.15), Color(1.0,0.85,0.3), Color(1.0,0.95,0.65)])

	# Health potion (5x6): 0=clear 1=cork 2=glass 3=outline 4=body 5=highlight
	potion_tex = _make_tex(5, 6, [
		[0,0,1,0,0],[0,0,2,0,0],[0,3,4,3,0],[3,4,5,4,3],[3,4,4,4,3],[0,3,3,3,0]],
		[Color(0,0,0,0), Color(0.6,0.45,0.25), Color(0.7,0.7,0.75),
		 Color(0.85,0.2,0.2), Color(0.75,0.15,0.15), Color(0.95,0.4,0.4)])


# ==========================================================
# Arrow sprite (5x3)
# ==========================================================

func _gen_arrow() -> void:
	# 0=clear 1=steel_tip 2=wood_shaft 3=feather
	arrow_tex = _make_tex(5, 3, [
		[0,0,2,2,3],[1,1,2,2,0],[0,0,2,2,3]],
		[Color(0,0,0,0), Color(0.7,0.7,0.78), Color(0.6,0.45,0.25), Color(0.85,0.85,0.8)])


# ==========================================================
# Skull sprite (5x5)
# ==========================================================

func _gen_skull() -> void:
	# 0=clear 1=bone_white 2=eye_socket 3=teeth_gray
	var p: Array = [
		Color(0, 0, 0, 0),
		Color(0.92, 0.90, 0.85),
		Color(0.15, 0.1, 0.1),
		Color(0.78, 0.76, 0.72),
	]
	skull_tex = _make_tex(5, 5, [
		[0,1,1,1,0],
		[1,1,1,1,1],
		[1,2,1,2,1],
		[0,1,1,1,0],
		[0,3,3,3,0]], p)


# ==========================================================
# Crown sprite (5x3): golden crown for bounty players
# ==========================================================

func _gen_crown() -> void:
	# 0=clear 1=gold 2=bright_gold 3=gem_red
	var p: Array = [
		Color(0, 0, 0, 0),
		Color(0.85, 0.7, 0.15),
		Color(1.0, 0.9, 0.3),
		Color(0.9, 0.15, 0.15),
	]
	crown_tex = _make_tex(5, 3, [
		[2,0,2,0,2],
		[1,1,1,1,1],
		[1,3,1,3,1]], p)


# ==========================================================
# Flag sprites (7x10): one per player color + neutral gold
# ==========================================================

func _gen_flags() -> void:
	var pole_color := Color(0.35, 0.25, 0.12)
	# Generate for each player color
	for ci in Config.PLAYER_COLORS.size():
		flag_tex[ci] = _make_flag(Config.PLAYER_COLORS[ci], pole_color)
	# Neutral gold flag
	flag_tex["neutral"] = _make_flag(Color(1.0, 0.85, 0.3), pole_color)


func _make_flag(flag_color: Color, pole_color: Color) -> ImageTexture:
	var img := Image.create(7, 10, false, Image.FORMAT_RGBA8)
	var dark := flag_color.darkened(0.25)
	# Pole (column 0, all rows)
	for y in 10:
		img.set_pixel(0, y, pole_color)
	# Flag body (rows 0-5, columns 1-6)
	for y in 6:
		for x in range(1, 7):
			# Pennant cutout: rows 2-3, column 6 = transparent
			if x == 6 and (y == 2 or y == 3):
				continue  # transparent
			# Border edges
			if y == 0 or y == 5 or x == 1:
				img.set_pixel(x, y, dark)
			else:
				img.set_pixel(x, y, flag_color)
	return ImageTexture.create_from_image(img)
