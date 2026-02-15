class_name Player
extends Node2D

signal died(player: Player)
signal gold_changed(player: Player, amount: int)

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
var player_id: int = -1
var player_color: Color
var is_human: bool = false

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------
var hp: float = 100.0
var max_hp: float = 100.0
var gold: int = 0
var alive: bool = true
var respawn_timer: float = 0.0

# ---------------------------------------------------------------------------
# Equipment (keys into Config.EQUIPMENT)
# ---------------------------------------------------------------------------
var weapon: String = "wooden_sword"
var bow: String = ""       # empty = no bow
var armor: String = ""     # empty = no armor
var active_slot: int = 0   # 0 = weapon (melee), 1 = bow (ranged)

# ---------------------------------------------------------------------------
# Consumables & Skills
# ---------------------------------------------------------------------------
var arrows: int = 0
var health_potions: int = 0
var speed_potions: int = 0
var shield_potions: int = 0
var skills: Dictionary = {}  # skill_id -> level, e.g. {"swift_feet": 2}
var speed_buff_timer: float = 0.0
var shield_buff_timer: float = 0.0
var shop_open: bool = false  # set by main.gd to block weapon switching while in shop

# ---------------------------------------------------------------------------
# Combat state
# ---------------------------------------------------------------------------
var attack_cooldown: float = 0.0
var facing_dir: Vector2 = Vector2.RIGHT
var is_attacking: bool = false
var attack_timer: float = 0.0  # visual swing duration

# ---------------------------------------------------------------------------
# Bounty
# ---------------------------------------------------------------------------
var kill_streak: int = 0
var has_bounty: bool = false

# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------
var velocity: Vector2 = Vector2.ZERO
var speed_mult: float = 1.0  # from terrain

# ---------------------------------------------------------------------------
# References (set by main.gd)
# ---------------------------------------------------------------------------
var map_generator: Node2D = null


# ===========================================================================
# Initialization
# ===========================================================================

func init(id: int, pos: Vector2, color: Color, human: bool) -> void:
	player_id = id
	position = pos
	player_color = color
	is_human = human

	# Reset stats
	max_hp = Config.PLAYER_MAX_HP
	hp = max_hp
	gold = Config.PLAYER_START_GOLD
	alive = true
	respawn_timer = 0.0

	# Reset equipment
	weapon = "wooden_sword"
	bow = ""
	armor = ""
	active_slot = 0

	# Reset consumables (skills persist through init — they are session-level)
	arrows = 0
	health_potions = 0
	speed_potions = 0
	shield_potions = 0
	skills = {}
	speed_buff_timer = 0.0
	shield_buff_timer = 0.0

	# Reset combat
	attack_cooldown = 0.0
	facing_dir = Vector2.RIGHT
	is_attacking = false
	attack_timer = 0.0

	# Reset bounty
	kill_streak = 0
	has_bounty = false

	# Reset movement
	velocity = Vector2.ZERO
	speed_mult = 1.0


# ===========================================================================
# Input (human player only)
# ===========================================================================

func process_input(delta: float) -> void:
	if not is_human or not alive:
		return

	# --- Movement via WASD (built-in ui_ actions) ---
	var input_dir: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("ui_left"):
		input_dir.x -= 1.0
	if Input.is_action_pressed("ui_right"):
		input_dir.x += 1.0
	if Input.is_action_pressed("ui_up"):
		input_dir.y -= 1.0
	if Input.is_action_pressed("ui_down"):
		input_dir.y += 1.0

	if input_dir.length_squared() > 0.0:
		input_dir = input_dir.normalized()
		velocity = input_dir * Config.PLAYER_SPEED * speed_mult * get_speed_bonus()
		facing_dir = input_dir
	else:
		velocity = Vector2.ZERO
		# When stationary, face the mouse cursor
		var mouse_pos: Vector2 = get_global_mouse_position()
		var dir_to_mouse: Vector2 = (mouse_pos - global_position).normalized()
		if dir_to_mouse.length_squared() > 0.0:
			facing_dir = dir_to_mouse

	# --- Slot switching via number keys ---
	if not shop_open:
		if Input.is_key_pressed(KEY_1):
			active_slot = 0
		elif Input.is_key_pressed(KEY_2):
			# Only switch to bow slot if a bow is equipped
			if bow != "":
				active_slot = 1


# ===========================================================================
# Movement
# ===========================================================================

func process_movement(delta: float) -> void:
	if not alive:
		return

	var prev_pos: Vector2 = position

	# Apply velocity
	position += velocity * delta

	# Clamp to map bounds
	position.x = clampf(position.x, 0.0, float(Config.MAP_WIDTH - 1))
	position.y = clampf(position.y, 0.0, float(Config.MAP_HEIGHT - 1))

	# Check terrain walkability
	if map_generator != null:
		var terrain_type: int = map_generator.get_terrain(position)
		var spd: float = Config.TERRAIN_SPEED.get(terrain_type, 1.0)
		if spd <= 0.0:
			# Terrain is not walkable -- revert
			position = prev_pos
		else:
			speed_mult = spd
	else:
		speed_mult = 1.0


# ===========================================================================
# Combat
# ===========================================================================

func try_attack(target_pos: Vector2) -> Dictionary:
	if not alive:
		return {}

	if attack_cooldown > 0.0:
		return {}

	var result: Dictionary = {}

	if active_slot == 0:
		# Melee attack using equipped weapon
		var stats: Dictionary = get_weapon_stats()
		if stats.is_empty():
			return {}

		var direction: Vector2 = (target_pos - global_position).normalized()
		facing_dir = direction

		var dmg: float = stats.get("damage", 0.0)
		var rng: float = stats.get("range", 0.0)
		var cd: float = stats.get("cooldown", 0.5)

		result = {
			"type": "melee",
			"damage": dmg,
			"direction": direction,
			"range": rng,
			"player_id": player_id,
		}

		attack_cooldown = cd * Config.ATTACK_COOLDOWN_MULT * get_cooldown_mult()
		is_attacking = true
		attack_timer = 0.2

	elif active_slot == 1:
		# Ranged attack using equipped bow
		if bow == "":
			return {}
		if arrows <= 0:
			return {}

		var stats: Dictionary = get_weapon_stats()
		if stats.is_empty():
			return {}

		var direction: Vector2 = (target_pos - global_position).normalized()
		facing_dir = direction

		var dmg: float = stats.get("damage", 0.0)
		var rng: float = stats.get("range", 0.0)
		var cd: float = stats.get("cooldown", 0.8)
		var spd: float = stats.get("speed", 200.0)

		result = {
			"type": "ranged",
			"damage": dmg,
			"direction": direction,
			"range": rng,
			"speed": spd,
			"origin": global_position,
			"player_id": player_id,
		}

		arrows -= 1
		attack_cooldown = cd * Config.ATTACK_COOLDOWN_MULT * get_cooldown_mult()
		is_attacking = true
		attack_timer = 0.2

	return result


func take_damage(amount: float) -> void:
	if not alive:
		return

	var reduction: float = get_damage_reduction()
	var final_damage: float = amount * (1.0 - reduction)
	hp -= final_damage

	if hp <= 0.0:
		hp = 0.0
		die()


func die() -> void:
	alive = false
	respawn_timer = Config.PLAYER_RESPAWN_TIME
	velocity = Vector2.ZERO
	is_attacking = false
	attack_timer = 0.0
	kill_streak = 0
	has_bounty = false
	died.emit(self)


func update_bounty() -> void:
	has_bounty = kill_streak >= Config.BOUNTY_KILL_STREAK or gold >= Config.BOUNTY_GOLD_THRESHOLD


func respawn(pos: Vector2) -> void:
	position = pos
	max_hp = Config.PLAYER_MAX_HP + _get_total_vitality_bonus()
	hp = max_hp
	alive = true
	respawn_timer = 0.0
	gold = int(gold * (1.0 - Config.PLAYER_RESPAWN_GOLD_PENALTY))
	velocity = Vector2.ZERO
	attack_cooldown = 0.0
	is_attacking = false
	attack_timer = 0.0
	speed_buff_timer = 0.0
	shield_buff_timer = 0.0


# ===========================================================================
# Gold & Equipment
# ===========================================================================

func add_gold(amount: int) -> void:
	gold += amount
	gold_changed.emit(self, gold)


func buy_equipment(equip_id: String) -> bool:
	if not Config.EQUIPMENT.has(equip_id):
		return false

	var info: Dictionary = Config.EQUIPMENT[equip_id]
	var cost: int = info.get("cost", 0)
	var slot: int = info.get("slot", -1)
	var tier: int = info.get("tier", 0)

	# Check if can afford
	if gold < cost:
		return false

	# Determine current item in the same slot and check tier
	var current_id: String = ""
	match slot:
		Config.EquipSlot.WEAPON:
			current_id = weapon
		Config.EquipSlot.BOW:
			current_id = bow
		Config.EquipSlot.ARMOR:
			current_id = armor
		_:
			return false

	# If we already have an item in this slot, it must be a higher tier
	if current_id != "":
		var current_info: Dictionary = Config.EQUIPMENT.get(current_id, {})
		var current_tier: int = current_info.get("tier", 0)
		if tier <= current_tier:
			return false

	# Purchase: deduct gold and equip
	gold -= cost
	gold_changed.emit(self, gold)

	match slot:
		Config.EquipSlot.WEAPON:
			weapon = equip_id
		Config.EquipSlot.BOW:
			bow = equip_id
		Config.EquipSlot.ARMOR:
			armor = equip_id

	return true


func get_damage_reduction() -> float:
	var dr: float = 0.0
	if armor != "" and Config.EQUIPMENT.has(armor):
		var armor_info: Dictionary = Config.EQUIPMENT[armor]
		dr = armor_info.get("dr", 0.0)
	if shield_buff_timer > 0.0:
		dr += Config.SHIELD_POTION_DR
	return minf(dr, 0.50)  # cap at 50%


func get_weapon_stats() -> Dictionary:
	var equip_id: String = ""
	if active_slot == 0:
		equip_id = weapon
	elif active_slot == 1:
		equip_id = bow

	if equip_id == "":
		return {}

	if not Config.EQUIPMENT.has(equip_id):
		return {}

	var stats: Dictionary = Config.EQUIPMENT[equip_id]
	return stats


func apply_knockback(direction: Vector2, force: float) -> void:
	if not alive:
		return

	var knockback: Vector2 = direction.normalized() * force * 0.15
	position += knockback

	# Clamp to map bounds after knockback
	position.x = clampf(position.x, 0.0, float(Config.MAP_WIDTH - 1))
	position.y = clampf(position.y, 0.0, float(Config.MAP_HEIGHT - 1))

	# Check terrain walkability after knockback
	if map_generator != null:
		var terrain_type: int = map_generator.get_terrain(position)
		var spd: float = Config.TERRAIN_SPEED.get(terrain_type, 1.0)
		if spd <= 0.0:
			# Revert knockback if it pushed into unwalkable terrain
			position -= knockback
			position.x = clampf(position.x, 0.0, float(Config.MAP_WIDTH - 1))
			position.y = clampf(position.y, 0.0, float(Config.MAP_HEIGHT - 1))


# ===========================================================================
# Timers
# ===========================================================================

func process_timers(delta: float) -> void:
	# Attack cooldown
	if attack_cooldown > 0.0:
		attack_cooldown -= delta
		if attack_cooldown < 0.0:
			attack_cooldown = 0.0

	# Attack visual timer
	if attack_timer > 0.0:
		attack_timer -= delta
		if attack_timer <= 0.0:
			attack_timer = 0.0
			is_attacking = false

	# Buff timers
	if speed_buff_timer > 0.0:
		speed_buff_timer -= delta
		if speed_buff_timer < 0.0:
			speed_buff_timer = 0.0

	if shield_buff_timer > 0.0:
		shield_buff_timer -= delta
		if shield_buff_timer < 0.0:
			shield_buff_timer = 0.0

	# Regeneration (only while alive)
	if alive:
		var regen: float = get_regen_rate()
		if regen > 0.0:
			hp = minf(hp + regen * delta, max_hp)

	# Respawn timer (ticks while dead)
	if not alive:
		if respawn_timer > 0.0:
			respawn_timer -= delta
			if respawn_timer < 0.0:
				respawn_timer = 0.0


# ===========================================================================
# Consumables
# ===========================================================================

func use_health_potion() -> bool:
	if health_potions <= 0 or not alive:
		return false
	if hp >= max_hp:
		return false
	health_potions -= 1
	hp = minf(hp + Config.POTION_HEAL_AMOUNT, max_hp)
	return true


func use_speed_potion() -> bool:
	if speed_potions <= 0 or not alive:
		return false
	speed_potions -= 1
	speed_buff_timer = Config.SPEED_POTION_DURATION
	return true


func use_shield_potion() -> bool:
	if shield_potions <= 0 or not alive:
		return false
	shield_potions -= 1
	shield_buff_timer = Config.SHIELD_POTION_DURATION
	return true


func buy_consumable(consumable_id: String) -> bool:
	if not Config.CONSUMABLES.has(consumable_id):
		return false
	var info: Dictionary = Config.CONSUMABLES[consumable_id]
	var cost: int = info.get("cost", 0)
	if gold < cost:
		return false
	var ctype: String = info.get("type", "")
	if ctype == "arrows":
		var amount: int = info.get("amount", 0)
		gold -= cost
		arrows += amount
		gold_changed.emit(self, gold)
		return true
	elif ctype == "potion":
		var subtype: String = info.get("subtype", "")
		var max_carry: int = info.get("max_carry", 5)
		match subtype:
			"health":
				if health_potions >= max_carry:
					return false
				gold -= cost
				health_potions += 1
			"speed":
				if speed_potions >= max_carry:
					return false
				gold -= cost
				speed_potions += 1
			"shield":
				if shield_potions >= max_carry:
					return false
				gold -= cost
				shield_potions += 1
			_:
				return false
		gold_changed.emit(self, gold)
		return true
	return false


# ===========================================================================
# Skills
# ===========================================================================

func get_skill_level(skill_id: String) -> int:
	if skills.has(skill_id):
		return skills[skill_id]
	return 0


func buy_skill(skill_id: String) -> bool:
	if not Config.SKILLS.has(skill_id):
		return false
	var info: Dictionary = Config.SKILLS[skill_id]
	var levels: Array = info["levels"]
	var current_level: int = get_skill_level(skill_id)
	if current_level >= levels.size():
		return false  # max level
	var level_data: Array = levels[current_level]
	var cost: int = level_data[0]
	if gold < cost:
		return false
	gold -= cost
	skills[skill_id] = current_level + 1
	gold_changed.emit(self, gold)
	# Apply vitality immediately
	if skill_id == "vitality":
		var bonus: float = level_data[1]
		max_hp = Config.PLAYER_MAX_HP + _get_total_vitality_bonus()
		hp = minf(hp + bonus, max_hp)  # heal by the bonus amount
	return true


func _get_total_vitality_bonus() -> float:
	var level: int = get_skill_level("vitality")
	if level <= 0:
		return 0.0
	var info: Dictionary = Config.SKILLS["vitality"]
	var levels: Array = info["levels"]
	var level_data: Array = levels[level - 1]
	return level_data[1]


func get_speed_bonus() -> float:
	var mult: float = 1.0
	var level: int = get_skill_level("swift_feet")
	if level > 0:
		var info: Dictionary = Config.SKILLS["swift_feet"]
		var levels: Array = info["levels"]
		var level_data: Array = levels[level - 1]
		mult += level_data[1]
	if speed_buff_timer > 0.0:
		mult *= Config.SPEED_POTION_MULT
	return mult


func get_vision_bonus() -> float:
	var level: int = get_skill_level("eagle_eye")
	if level <= 0:
		return 0.0
	var info: Dictionary = Config.SKILLS["eagle_eye"]
	var levels: Array = info["levels"]
	var level_data: Array = levels[level - 1]
	return level_data[1]


func get_gold_mult() -> float:
	var level: int = get_skill_level("gold_rush")
	if level <= 0:
		return 1.0
	var info: Dictionary = Config.SKILLS["gold_rush"]
	var levels: Array = info["levels"]
	var level_data: Array = levels[level - 1]
	return 1.0 + level_data[1]


func get_cooldown_mult() -> float:
	var level: int = get_skill_level("quick_draw")
	if level <= 0:
		return 1.0
	var info: Dictionary = Config.SKILLS["quick_draw"]
	var levels: Array = info["levels"]
	var level_data: Array = levels[level - 1]
	return 1.0 - level_data[1]


func get_regen_rate() -> float:
	var level: int = get_skill_level("regeneration")
	if level <= 0:
		return 0.0
	var info: Dictionary = Config.SKILLS["regeneration"]
	var levels: Array = info["levels"]
	var level_data: Array = levels[level - 1]
	return level_data[1]
