class_name BotAI
extends RefCounted

## AI decision-making for bot players.
## Called by main.gd each frame for each non-human player.

enum State { FARMING, SHOPPING, FIGHTING, CONTESTING }

var state: int = State.FARMING
var target_pos: Vector2 = Vector2.ZERO
var decision_timer: float = 0.0
var personality: int = 0  # 0=aggressive, 1=cautious, 2=opportunist

func init(personality_type: int) -> void:
	personality = personality_type
	state = State.FARMING
	decision_timer = 0.0

func update(delta: float, player: Player, all_players: Array, mobs: Array,
			shops: Array, hill: Hill, map: Node2D) -> Dictionary:
	## Returns {move_dir: Vector2, attack_target: Vector2, try_buy: bool, switch_weapon: int}
	var result := {
		"move_dir": Vector2.ZERO,
		"attack_target": Vector2.ZERO,
		"try_buy": false,
		"attack": false,
		"switch_weapon": -1,
	}

	if not player.alive:
		return result

	decision_timer -= delta
	if decision_timer <= 0.0:
		decision_timer = randf_range(0.5, 1.5)
		_decide_state(player, all_players, mobs, shops, hill)

	match state:
		State.FARMING:
			result = _do_farming(player, mobs, map, shops)
		State.SHOPPING:
			result = _do_shopping(player, shops)
		State.FIGHTING:
			result = _do_fighting(player, all_players, shops)
		State.CONTESTING:
			result = _do_contesting(player, hill)

	return result

func _decide_state(player: Player, all_players: Array, mobs: Array,
				   shops: Array, hill: Hill) -> void:
	# Check if Hill is active and we're strong enough
	var should_contest := hill.active and _get_gear_score(player) >= 2

	# Check if we can afford useful upgrades
	var can_shop := false
	for shop in shops:
		if shop.get_available_items(player).size() > 0:
			can_shop = true
			break

	# Check for nearby enemy threats
	var enemy_nearby := false
	for other in all_players:
		if not is_instance_valid(other) or not other.alive or other.player_id == player.player_id:
			continue
		if player.position.distance_to(other.position) < 80.0:
			enemy_nearby = true
			break

	match personality:
		0:  # Aggressive: rush Hill early, fight often
			if enemy_nearby:
				state = State.FIGHTING
			elif should_contest:
				state = State.CONTESTING
			elif can_shop and player.gold >= 20:
				state = State.SHOPPING
			else:
				state = State.FARMING
		1:  # Cautious: farm fully, shop often, contest late
			if can_shop and player.gold >= 15:
				state = State.SHOPPING
			elif should_contest and _get_gear_score(player) >= 4:
				state = State.CONTESTING
			elif enemy_nearby:
				state = State.FIGHTING
			else:
				state = State.FARMING
		2:  # Opportunist: waits for fights, then swoops in
			if should_contest and hill.holding_player >= 0:
				state = State.CONTESTING
			elif enemy_nearby:
				state = State.FIGHTING
			elif can_shop and player.gold >= 20:
				state = State.SHOPPING
			else:
				state = State.FARMING

func _do_farming(player: Player, mobs: Array, _map: Node2D, shops: Array) -> Dictionary:
	var result := {"move_dir": Vector2.ZERO, "attack_target": Vector2.ZERO,
				   "try_buy": false, "attack": false, "switch_weapon": 0}

	# Check if the bot itself is in a safe zone
	var bot_in_safe_zone: bool = false
	for shop in shops:
		if player.position.distance_to(shop.position) <= Config.SHOP_SAFE_RADIUS:
			bot_in_safe_zone = true
			break

	# Find nearest alive mob
	var nearest_mob: Mob = null
	var nearest_dist := 999.0
	for mob in mobs:
		if not is_instance_valid(mob) or not mob.alive:
			continue
		var d := player.position.distance_to(mob.position)
		if d < nearest_dist:
			nearest_dist = d
			nearest_mob = mob

	if nearest_mob != null:
		if bot_in_safe_zone:
			# In safe zone: only move toward mobs, don't attack
			result["move_dir"] = (nearest_mob.position - player.position).normalized()
		# Switch to bow if has one and arrows, and mob is far; otherwise melee
		elif player.bow != "" and player.arrows > 0 and nearest_dist > 30.0 and nearest_dist <= 100.0:
			result["switch_weapon"] = 1
			result["attack"] = true
			result["attack_target"] = nearest_mob.position
		elif nearest_dist <= 18.0:
			result["switch_weapon"] = 0
			result["attack"] = true
			result["attack_target"] = nearest_mob.position
		else:
			result["move_dir"] = (nearest_mob.position - player.position).normalized()

	return result

func _do_shopping(player: Player, shops: Array) -> Dictionary:
	var result := {"move_dir": Vector2.ZERO, "attack_target": Vector2.ZERO,
				   "try_buy": false, "attack": false, "switch_weapon": -1}

	# Find nearest shop with affordable items
	var best_shop: Shop = null
	var best_dist := 999.0
	for shop in shops:
		if shop.get_available_items(player).size() > 0:
			var d := player.position.distance_to(shop.position)
			if d < best_dist:
				best_dist = d
				best_shop = shop

	if best_shop != null:
		if best_dist <= Config.SHOP_INTERACT_RADIUS:
			result["try_buy"] = true
		else:
			result["move_dir"] = (best_shop.position - player.position).normalized()

	return result

func _do_fighting(player: Player, all_players: Array, shops: Array) -> Dictionary:
	var result := {"move_dir": Vector2.ZERO, "attack_target": Vector2.ZERO,
				   "try_buy": false, "attack": false, "switch_weapon": 0}

	# Find nearest enemy
	var nearest: Player = null
	var nearest_dist := 999.0
	for other in all_players:
		if not is_instance_valid(other) or not other.alive or other.player_id == player.player_id:
			continue
		# Skip players in safe zones
		var in_safe_zone: bool = false
		for shop in shops:
			if other.position.distance_to(shop.position) <= Config.SHOP_SAFE_RADIUS:
				in_safe_zone = true
				break
		if in_safe_zone:
			continue
		var d := player.position.distance_to(other.position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = other

	if nearest != null:
		if player.bow != "" and player.arrows > 0 and nearest_dist > 30.0 and nearest_dist <= 120.0:
			result["switch_weapon"] = 1
			result["attack"] = true
			result["attack_target"] = nearest.position
		elif nearest_dist <= 20.0:
			result["switch_weapon"] = 0
			result["attack"] = true
			result["attack_target"] = nearest.position
		else:
			result["move_dir"] = (nearest.position - player.position).normalized()

	return result

func _do_contesting(player: Player, hill: Hill) -> Dictionary:
	var result := {"move_dir": Vector2.ZERO, "attack_target": Vector2.ZERO,
				   "try_buy": false, "attack": false, "switch_weapon": 0}

	var to_hill := hill.position - player.position
	if to_hill.length() > hill.radius * 0.5:
		result["move_dir"] = to_hill.normalized()
	# If on hill, just stand still (capture in progress)

	return result

func _get_gear_score(player: Player) -> int:
	var score := 0
	if player.weapon != "":
		var stats: Dictionary = Config.EQUIPMENT[player.weapon]
		score += stats["tier"]
	if player.bow != "":
		var stats: Dictionary = Config.EQUIPMENT[player.bow]
		score += stats["tier"]
	if player.armor != "":
		var stats: Dictionary = Config.EQUIPMENT[player.armor]
		score += stats["tier"]
	# Factor in skill levels
	for skill_id: String in Config.SKILLS:
		score += player.get_skill_level(skill_id)
	return score
