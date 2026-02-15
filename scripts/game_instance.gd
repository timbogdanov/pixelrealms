class_name GameInstance
extends Node

# ---------------------------------------------------------------------------
# GameInstance — One complete game running on the server.
# Encapsulates map, players, mobs, projectiles, hill, shops, bot AIs.
# Server can run many GameInstances simultaneously.
# ---------------------------------------------------------------------------

signal game_ended(game_id: int)

var game_id: int = -1
var seed_val: int = 0
var map_index: int = 0

# Map generator (own instance, not the scene's)
var _map_gen: Node2D = null

# Entities
var _players: Array = []
var _mobs: Array = []
var _projectiles: Array = []
var _shops: Array = []
var _hill: Hill = null
var _bot_ais: Array = []

# Mob respawn
var _dead_mob_queue: Array = []
var _next_mob_id: int = 0
var _mob_by_id: Dictionary = {}
var _pickups: Array = []
var _next_pickup_id: int = 0
var _bounty_pulse_timers: Dictionary = {}

# Peer tracking (peers in THIS game)
var _game_peers: Dictionary = {}   # peer_id -> player_index
var _player_to_peer: Dictionary = {}  # player_index -> peer_id

# Input/action queues
var _pending_inputs: Dictionary = {}
var _pending_actions: Array = []

# Timing
var _game_time: float = 0.0
var _snapshot_timer: float = 0.0

# Game over
var _game_over: bool = false
var _game_over_timer: float = 10.0  # seconds before returning to lobby
var _winner_id: int = -1


# ===========================================================================
# Start
# ===========================================================================

func start(p_seed: int, p_map_index: int, peers: Dictionary, map_gen_scene: PackedScene) -> void:
	seed_val = p_seed
	map_index = p_map_index
	_game_peers = peers.duplicate()
	for peer_id: int in _game_peers:
		var player_idx: int = _game_peers[peer_id]
		_player_to_peer[player_idx] = peer_id

	# Create own MapGenerator
	_map_gen = map_gen_scene.instantiate()
	add_child(_map_gen)
	_map_gen.generate(seed_val, map_index)

	_spawn_hill()
	_spawn_shops()
	_spawn_players()
	_spawn_mobs()

	# Notify clients
	var total_humans: int = _game_peers.size()
	for pid: int in _game_peers:
		var idx: int = _game_peers[pid]
		Net.rpc_game_start.rpc_id(pid, seed_val, map_index, idx, total_humans)


# ===========================================================================
# Per-frame tick (called by main.gd from _physics_process)
# ===========================================================================

func process_tick(delta: float) -> void:
	if _game_over:
		_game_over_timer -= delta
		if _game_over_timer <= 0.0:
			game_ended.emit(game_id)
		return

	_game_time += delta

	# 1. Apply pending human inputs
	_apply_pending_inputs(delta)

	# 2. Apply pending reliable actions
	_apply_pending_actions()

	# 3. Bot AI
	_process_bots(delta)

	# 4. All players: timers + movement + respawn
	for player in _players:
		player.process_timers(delta)
		if player.alive and _is_in_safe_zone(player.position):
			player.hp = minf(player.hp + Config.SAFE_ZONE_REGEN * delta, player.max_hp)
		player.process_movement(delta)
		if not player.alive and player.respawn_timer <= 0.0:
			var nearest_shop_pos: Vector2 = _nearest_shop_to(player.position)
			var respawn_pos: Vector2 = _map_gen.find_grass_or_path_near(nearest_shop_pos, 40)
			player.respawn(respawn_pos)

	# 5. Mobs
	for mob in _mobs:
		if mob.alive:
			mob.process_ai(delta, _players, _shops)

	# 6. Projectiles
	_process_projectiles(delta)

	# 6.5. Pickups
	_process_pickups(delta)

	# 6.6. Bounty pulses
	_process_bounty_pulses(delta)

	# 7. Hill
	_hill.process_hill(delta, _players)

	# 8. Mob respawns
	_process_mob_respawns(delta)

	# 9. Snapshot broadcast
	_snapshot_timer += delta
	if _snapshot_timer >= 1.0 / float(Config.SNAPSHOT_RATE):
		_snapshot_timer = 0.0
		_broadcast_snapshot()


# ===========================================================================
# Input / Action from human peers
# ===========================================================================

func apply_input(peer_id: int, input_data: PackedByteArray) -> void:
	_pending_inputs[peer_id] = input_data


func apply_action(peer_id: int, action_data: PackedByteArray) -> void:
	_pending_actions.append({"peer_id": peer_id, "data": action_data})


# ===========================================================================
# Peer management
# ===========================================================================

func has_peer(peer_id: int) -> bool:
	return _game_peers.has(peer_id)


func remove_peer(peer_id: int) -> void:
	if _game_peers.has(peer_id):
		var player_idx: int = _game_peers[peer_id]
		_player_to_peer.erase(player_idx)
		_game_peers.erase(peer_id)
	_pending_inputs.erase(peer_id)
	# If all humans disconnected, end the game
	if _game_peers.is_empty() and not _game_over:
		_game_over = true
		_game_over_timer = 0.0
		game_ended.emit(game_id)


func get_peer_ids() -> Array:
	return _game_peers.keys()


func is_human_player(player_idx: int) -> bool:
	return _player_to_peer.has(player_idx)


# ===========================================================================
# Spawning
# ===========================================================================

func _spawn_hill() -> void:
	_hill = Hill.new()
	_hill.init(_map_gen.hill_position)
	add_child(_hill)
	_hill.won.connect(_on_hill_won)


func _spawn_shops() -> void:
	for i in _map_gen.shop_positions.size():
		var shop := Shop.new()
		shop.init(i, _map_gen.shop_positions[i])
		_shops.append(shop)
		add_child(shop)


func _spawn_players() -> void:
	for i in Config.NUM_PLAYERS:
		var player := Player.new()
		var spawn_pos: Vector2 = _map_gen.spawn_positions[i]
		var color: Color = Config.PLAYER_COLORS[i]
		player.init(i, spawn_pos, color, false)
		player.map_generator = _map_gen
		player.died.connect(_on_player_died)
		_players.append(player)
		add_child(player)

	# Create bot AIs for non-human slots
	var bot_indices: Array[int] = _get_bot_indices()
	for idx in bot_indices:
		var bot := BotAI.new()
		var personality: int = idx % 3
		bot.init(personality)
		_bot_ais.append({"player_idx": idx, "ai": bot})


func _get_bot_indices() -> Array[int]:
	var bots: Array[int] = []
	for i in Config.NUM_PLAYERS:
		if not _player_to_peer.has(i):
			bots.append(i)
	return bots


func _spawn_pickup(type: int, pos: Vector2, amount: int) -> void:
	var pickup := Pickup.new()
	pickup.init(_next_pickup_id, type, pos, amount)
	_next_pickup_id += 1
	_pickups.append(pickup)
	add_child(pickup)


func _spawn_mobs() -> void:
	for zone in _map_gen.mob_spawn_zones:
		var zone_pos: Vector2 = zone["pos"]
		var zone_type: int = zone["type"]
		var zone_count: int = zone["count"]
		for j in zone_count:
			var mob := Mob.new()
			mob.mob_id = _next_mob_id
			_next_mob_id += 1
			var offset := Vector2(randf_range(-15, 15), randf_range(-15, 15))
			var mob_pos: Vector2 = zone_pos + offset
			var mob_pos_i: Vector2i = Vector2i(int(mob_pos.x), int(mob_pos.y))
			if not _map_gen.is_walkable(mob_pos_i):
				mob_pos = _map_gen.find_walkable_near(mob_pos, 20)
			mob.init(zone_type, mob_pos, _map_gen)
			mob.died.connect(_on_mob_died)
			_mobs.append(mob)
			_mob_by_id[mob.mob_id] = mob
			add_child(mob)


# ===========================================================================
# Bot AI processing
# ===========================================================================

func _process_bots(delta: float) -> void:
	for entry in _bot_ais:
		var player_idx: int = entry["player_idx"]
		var bot: BotAI = entry["ai"]
		if player_idx >= _players.size():
			continue
		var player: Player = _players[player_idx]
		if not player.alive:
			continue
		var result: Dictionary = bot.update(delta, player, _players, _mobs, _shops, _hill, _map_gen, _projectiles)
		_apply_bot_action(player, result)


func _apply_bot_action(player: Player, action: Dictionary) -> void:
	# Movement
	var move_dir: Vector2 = action.get("move_dir", Vector2.ZERO)
	if move_dir.length_squared() > 0.0:
		player.velocity = move_dir.normalized() * Config.PLAYER_SPEED * player.speed_mult * player.get_speed_bonus()
		player.facing_dir = move_dir.normalized()
	else:
		player.velocity = Vector2.ZERO

	# Attack
	var do_attack: bool = action.get("attack", false)
	if do_attack and not _is_in_safe_zone(player.position):
		var target_pos: Vector2 = action.get("attack_target", player.position + player.facing_dir * 20.0)
		var attack: Dictionary = player.try_attack(target_pos)
		if not attack.is_empty():
			_resolve_attack(attack)

	# Bot uses health potions when low HP
	if player.hp < player.max_hp * 0.4:
		player.use_health_potion()

	# Bot uses speed potion when fighting or contesting
	if player.speed_buff_timer <= 0.0 and player.speed_potions > 0:
		for bot_entry in _bot_ais:
			if bot_entry["player_idx"] == player.player_id:
				var bot_state: int = bot_entry["ai"].state
				if bot_state == BotAI.State.FIGHTING or bot_state == BotAI.State.CONTESTING:
					player.use_speed_potion()
				break

	# Bot uses shield potion when fighting or contesting
	if player.shield_buff_timer <= 0.0 and player.shield_potions > 0:
		for bot_entry in _bot_ais:
			if bot_entry["player_idx"] == player.player_id:
				var bot_state: int = bot_entry["ai"].state
				if bot_state == BotAI.State.FIGHTING or bot_state == BotAI.State.CONTESTING:
					player.use_shield_potion()
				break

	# Shopping
	var try_buy: bool = action.get("try_buy", false)
	if try_buy:
		_bot_try_buy(player)

	# Weapon switch
	var switch_weapon: int = action.get("switch_weapon", -1)
	if switch_weapon >= 0:
		if switch_weapon == 1 and player.bow != "":
			player.active_slot = 1
		else:
			player.active_slot = 0


func _bot_try_buy(player: Player) -> void:
	for shop in _shops:
		if not shop.is_player_nearby(player):
			continue

		# Priority 1: Buy arrows if has bow and low arrows
		if player.bow != "" and player.arrows < 10:
			player.buy_consumable("arrow_10")

		# Priority 2: Buy health potions if can carry
		if player.health_potions < 3 and player.gold >= 8:
			player.buy_consumable("health_potion")

		# Priority 2.5: Buy shield potions if can carry
		if player.shield_potions < 2 and player.gold >= 12:
			player.buy_consumable("shield_potion")

		# Priority 3: Equipment upgrades
		var equip_items: Array = shop.get_equipment_list()
		var best_equip: String = ""
		var best_cost: int = 99999
		for item_id: String in equip_items:
			var info: Dictionary = Config.EQUIPMENT[item_id]
			var cost: int = info.get("cost", 99999)
			if cost <= player.gold and cost < best_cost:
				var slot: int = info.get("slot", -1)
				var tier: int = info.get("tier", 0)
				var current_id: String = ""
				match slot:
					Config.EquipSlot.WEAPON:
						current_id = player.weapon
					Config.EquipSlot.BOW:
						current_id = player.bow
					Config.EquipSlot.ARMOR:
						current_id = player.armor
				var cur_tier: int = 0
				if current_id != "":
					var cur: Dictionary = Config.EQUIPMENT.get(current_id, {})
					cur_tier = cur.get("tier", 0)
				if tier > cur_tier:
					best_cost = cost
					best_equip = item_id
		if best_equip != "":
			player.buy_equipment(best_equip)

		# Priority 4: Skills (personality-driven)
		_bot_buy_skill(player)
		break


func _bot_buy_skill(player: Player) -> void:
	var personality: int = 0
	for bot_entry in _bot_ais:
		if bot_entry["player_idx"] == player.player_id:
			personality = bot_entry["ai"].personality
			break
	var preferred: Array = []
	match personality:
		0:  # Aggressive
			preferred = ["quick_draw", "swift_feet", "gold_rush"]
		1:  # Cautious
			preferred = ["regeneration", "vitality", "eagle_eye"]
		2:  # Opportunist
			preferred = ["swift_feet", "gold_rush", "quick_draw"]

	for skill_id: String in preferred:
		if not Config.SKILLS.has(skill_id):
			continue
		var info: Dictionary = Config.SKILLS[skill_id]
		var levels: Array = info["levels"]
		var cur_level: int = player.get_skill_level(skill_id)
		if cur_level >= levels.size():
			continue
		var level_data: Array = levels[cur_level]
		var cost: int = level_data[0]
		if cost <= player.gold:
			player.buy_skill(skill_id)
			break


# ===========================================================================
# Combat resolution
# ===========================================================================

func _resolve_attack(attack: Dictionary) -> void:
	var attack_type: String = attack.get("type", "")
	var attacker_id: int = attack.get("player_id", -1)

	if attack_type == "melee":
		_resolve_melee(attack, attacker_id)
	elif attack_type == "ranged":
		_spawn_projectile(attack)


func _resolve_melee(attack: Dictionary, attacker_id: int) -> void:
	var dmg: float = attack.get("damage", 0.0)
	var direction: Vector2 = attack.get("direction", Vector2.RIGHT)
	var attack_range: float = attack.get("range", 20.0)
	if not is_human_player(attacker_id):
		attack_range *= Config.BOT_MELEE_RANGE_MULT

	var attacker: Player = null
	for p in _players:
		if p.player_id == attacker_id:
			attacker = p
			break
	if attacker == null:
		return

	var origin: Vector2 = attacker.position
	var arc_rad: float = deg_to_rad(Config.MELEE_ARC * 0.5)

	# Check against other players
	for target in _players:
		if target.player_id == attacker_id or not target.alive:
			continue
		var to_target: Vector2 = target.position - origin
		if to_target.length() > attack_range:
			continue
		var angle_diff: float = absf(direction.angle_to(to_target.normalized()))
		if angle_diff <= arc_rad:
			# Safe zone turret
			if _is_in_safe_zone(target.position):
				var turret_pos: Vector2 = _nearest_shop_to(target.position)
				attacker.take_damage(200.0)
				_broadcast_game_event({"type": "turret_fire",
					"from_x": turret_pos.x, "from_y": turret_pos.y,
					"to_x": attacker.position.x, "to_y": attacker.position.y})
				if not attacker.alive:
					_broadcast_game_event({"type": "player_killed",
						"victim_id": attacker_id, "killer_id": -1, "gold_stolen": 0,
						"x": attacker.position.x, "y": attacker.position.y})
				continue
			target.take_damage(dmg)
			_broadcast_game_event({"type": "hit",
				"x": target.position.x, "y": target.position.y})
			target.apply_knockback(direction, Config.KNOCKBACK_FORCE)
			if not target.alive:
				var stolen: int = int(target.gold * Config.PLAYER_KILL_GOLD_STEAL)
				# Bounty bonus
				if target.has_bounty:
					var bounty_bonus: int = target.kill_streak * Config.BOUNTY_KILL_BONUS_PER_STREAK + int(float(target.gold) * Config.BOUNTY_GOLD_BONUS_FRACTION)
					stolen += bounty_bonus
					_broadcast_game_event({"type": "bounty_claimed",
						"killer_id": attacker_id, "victim_id": target.player_id,
						"bonus": bounty_bonus,
						"x": target.position.x, "y": target.position.y})
				attacker.add_gold(stolen)
				attacker.kill_streak += 1
				attacker.update_bounty()
				_broadcast_game_event({"type": "player_killed",
					"victim_id": target.player_id, "killer_id": attacker_id,
					"gold_stolen": stolen,
					"x": target.position.x, "y": target.position.y})
				# Gold drop pickup
				var gold_lost: int = target.gold - int(float(target.gold) * (1.0 - Config.PLAYER_RESPAWN_GOLD_PENALTY))
				var drop_amount: int = int(float(gold_lost) * Config.DEATH_GOLD_DROP_FRACTION)
				if drop_amount > 0:
					_spawn_pickup(Config.PickupType.GOLD, target.position, drop_amount)

	# Check against mobs
	for mob in _mobs:
		if not mob.alive:
			continue
		var to_mob: Vector2 = mob.position - origin
		if to_mob.length() > attack_range:
			continue
		var angle_diff: float = absf(direction.angle_to(to_mob.normalized()))
		if angle_diff <= arc_rad:
			mob.take_damage(dmg)
			_broadcast_game_event({"type": "hit",
				"x": mob.position.x, "y": mob.position.y})
			mob.apply_knockback(direction, Config.KNOCKBACK_FORCE)


func _spawn_projectile(attack: Dictionary) -> void:
	var proj := Projectile.new()
	var origin: Vector2 = attack.get("origin", Vector2.ZERO)
	var direction: Vector2 = attack.get("direction", Vector2.RIGHT)
	var spd: float = attack.get("speed", 200.0)
	var dmg: float = attack.get("damage", 4.0)
	var pid: int = attack.get("player_id", -1)
	proj.init(origin, direction, spd, dmg, pid)
	_projectiles.append(proj)
	add_child(proj)


func _process_projectiles(delta: float) -> void:
	var i: int = _projectiles.size() - 1
	while i >= 0:
		var proj: Projectile = _projectiles[i]
		proj.process_projectile(delta)

		if proj.alive:
			# Check collision with players
			for player in _players:
				if player.player_id == proj.owner_id or not player.alive:
					continue
				if proj.position.distance_to(player.position) <= 6.0:
					proj.hit()
					_broadcast_game_event({"type": "hit",
						"x": proj.position.x, "y": proj.position.y})
					# Safe zone turret
					if _is_in_safe_zone(player.position):
						var turret_pos: Vector2 = _nearest_shop_to(player.position)
						for attacker in _players:
							if attacker.player_id == proj.owner_id:
								attacker.take_damage(200.0)
								_broadcast_game_event({"type": "turret_fire",
									"from_x": turret_pos.x, "from_y": turret_pos.y,
									"to_x": attacker.position.x, "to_y": attacker.position.y})
								if not attacker.alive:
									_broadcast_game_event({"type": "player_killed",
										"victim_id": attacker.player_id, "killer_id": -1,
										"gold_stolen": 0,
										"x": attacker.position.x, "y": attacker.position.y})
								break
						break
					player.take_damage(proj.damage)
					player.apply_knockback(proj.direction, Config.KNOCKBACK_FORCE * 0.5)
					if not player.alive:
						for attacker in _players:
							if attacker.player_id == proj.owner_id:
								var stolen: int = int(player.gold * Config.PLAYER_KILL_GOLD_STEAL)
								# Bounty bonus
								if player.has_bounty:
									var bounty_bonus: int = player.kill_streak * Config.BOUNTY_KILL_BONUS_PER_STREAK + int(float(player.gold) * Config.BOUNTY_GOLD_BONUS_FRACTION)
									stolen += bounty_bonus
									_broadcast_game_event({"type": "bounty_claimed",
										"killer_id": attacker.player_id, "victim_id": player.player_id,
										"bonus": bounty_bonus,
										"x": player.position.x, "y": player.position.y})
								attacker.add_gold(stolen)
								attacker.kill_streak += 1
								attacker.update_bounty()
								_broadcast_game_event({"type": "player_killed",
									"victim_id": player.player_id, "killer_id": proj.owner_id,
									"gold_stolen": stolen,
									"x": player.position.x, "y": player.position.y})
								# Gold drop pickup
								var gold_lost: int = player.gold - int(float(player.gold) * (1.0 - Config.PLAYER_RESPAWN_GOLD_PENALTY))
								var drop_amount: int = int(float(gold_lost) * Config.DEATH_GOLD_DROP_FRACTION)
								if drop_amount > 0:
									_spawn_pickup(Config.PickupType.GOLD, player.position, drop_amount)
								break
					break

		if proj.alive:
			# Check collision with mobs
			for mob in _mobs:
				if not mob.alive:
					continue
				if proj.position.distance_to(mob.position) <= 5.0:
					mob.take_damage(proj.damage)
					mob.apply_knockback(proj.direction, Config.KNOCKBACK_FORCE * 0.3)
					proj.hit()
					_broadcast_game_event({"type": "hit",
						"x": proj.position.x, "y": proj.position.y})
					break

		if not proj.alive:
			_projectiles.remove_at(i)
			proj.queue_free()

		i -= 1


func _process_pickups(delta: float) -> void:
	var to_remove: Array = []
	for pickup in _pickups:
		pickup.process_pickup(delta)
		if not pickup.alive:
			to_remove.append(pickup)
			continue
		for player in _players:
			if not player.alive:
				continue
			if player.position.distance_to(pickup.position) <= Config.PICKUP_COLLECT_RADIUS:
				_collect_pickup(player, pickup)
				to_remove.append(pickup)
				break
	for pickup in to_remove:
		_pickups.erase(pickup)
		pickup.queue_free()


func _collect_pickup(player: Player, pickup: Pickup) -> void:
	match pickup.pickup_type:
		Config.PickupType.GOLD:
			player.add_gold(pickup.amount)
			_broadcast_game_event({"type": "pickup_collected",
				"pickup_type": Config.PickupType.GOLD,
				"amount": pickup.amount,
				"collector_id": player.player_id,
				"x": pickup.position.x, "y": pickup.position.y})
		Config.PickupType.HEALTH_POTION:
			var max_carry: int = 5
			if player.health_potions < max_carry:
				player.health_potions += pickup.amount
				_broadcast_game_event({"type": "pickup_collected",
					"pickup_type": Config.PickupType.HEALTH_POTION,
					"amount": pickup.amount,
					"collector_id": player.player_id,
					"x": pickup.position.x, "y": pickup.position.y})


func _process_bounty_pulses(delta: float) -> void:
	for player in _players:
		if not player.alive or not player.has_bounty:
			_bounty_pulse_timers.erase(player.player_id)
			continue
		var timer: float = _bounty_pulse_timers.get(player.player_id, 0.0)
		timer -= delta
		if timer <= 0.0:
			timer = Config.BOUNTY_PULSE_INTERVAL
			_broadcast_game_event({"type": "bounty_pulse",
				"player_id": player.player_id,
				"x": player.position.x, "y": player.position.y})
		_bounty_pulse_timers[player.player_id] = timer


# ===========================================================================
# Mob death & respawn
# ===========================================================================

func _on_mob_died(mob: Mob) -> void:
	# Award gold to nearest alive player
	var nearest: Player = null
	var nearest_dist: float = mob.aggro_range + 20.0
	for player in _players:
		if not player.alive:
			continue
		var d: float = player.position.distance_to(mob.position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = player
	var gold_amount: int = 0
	if nearest != null:
		gold_amount = int(float(mob.gold_reward) * nearest.get_gold_mult())
		nearest.add_gold(gold_amount)

	_broadcast_game_event({"type": "mob_killed",
		"x": mob.position.x, "y": mob.position.y,
		"mob_type": mob.mob_type, "gold": gold_amount})

	# Rare drops
	var drop_rng: float = randf()
	if drop_rng < Config.RARE_DROP_GOLD_CHANCE:
		var mult: float = randf_range(Config.RARE_DROP_GOLD_MULT_MIN, Config.RARE_DROP_GOLD_MULT_MAX)
		var bonus_gold: int = int(float(mob.gold_reward) * mult)
		_spawn_pickup(Config.PickupType.GOLD, mob.position, bonus_gold)
		_broadcast_game_event({"type": "rare_drop", "x": mob.position.x, "y": mob.position.y,
			"drop_type": Config.PickupType.GOLD, "amount": bonus_gold})
	elif drop_rng < Config.RARE_DROP_GOLD_CHANCE + Config.RARE_DROP_POTION_CHANCE:
		_spawn_pickup(Config.PickupType.HEALTH_POTION, mob.position, 1)
		_broadcast_game_event({"type": "rare_drop", "x": mob.position.x, "y": mob.position.y,
			"drop_type": Config.PickupType.HEALTH_POTION, "amount": 1})

	_dead_mob_queue.append({
		"type": mob.mob_type,
		"spawn_pos": mob.spawn_pos,
		"timer": Config.MOB_RESPAWN_TIME,
	})

	_mob_by_id.erase(mob.mob_id)
	_mobs.erase(mob)
	mob.queue_free()


func _process_mob_respawns(delta: float) -> void:
	var to_spawn: Array = []
	var remaining: Array = []
	for entry in _dead_mob_queue:
		entry["timer"] -= delta
		if entry["timer"] <= 0.0:
			to_spawn.append(entry)
		else:
			remaining.append(entry)
	_dead_mob_queue = remaining

	for entry in to_spawn:
		var mob := Mob.new()
		mob.mob_id = _next_mob_id
		_next_mob_id += 1
		var mob_type: int = entry["type"]
		var spawn_pos: Vector2 = entry["spawn_pos"]
		var offset := Vector2(randf_range(-15, 15), randf_range(-15, 15))
		var mob_pos: Vector2 = spawn_pos + offset
		var mob_pos_i: Vector2i = Vector2i(int(mob_pos.x), int(mob_pos.y))
		if not _map_gen.is_walkable(mob_pos_i):
			mob_pos = _map_gen.find_walkable_near(mob_pos, 20)
		mob.init(mob_type, mob_pos, _map_gen)
		mob.died.connect(_on_mob_died)
		_mobs.append(mob)
		_mob_by_id[mob.mob_id] = mob
		add_child(mob)


# ===========================================================================
# Player death & win condition
# ===========================================================================

func _on_player_died(_player: Player) -> void:
	pass  # Respawn handled in main loop


func _on_hill_won(player_id: int) -> void:
	_game_over = true
	_winner_id = player_id
	_broadcast_game_event({"type": "game_over", "winner_id": player_id})
	_write_leaderboard_entry(player_id)


func _write_leaderboard_entry(player_id: int) -> void:
	# Determine winner name
	var winner_name: String = "Bot"
	var winner_peer: int = _player_to_peer.get(player_id, -1)
	if winner_peer > 0:
		winner_name = Net.get_username_for_peer(winner_peer)
	var map_name: String = Config.MAP_NAMES[map_index] if map_index < Config.MAP_NAMES.size() else "Unknown"

	var entry: Dictionary = {
		"name": winner_name,
		"map": map_name,
		"timestamp": int(Time.get_unix_time_from_system()),
		"players": _game_peers.size(),
	}

	# Read existing leaderboard
	var path: String = "/tmp/leaderboard.json"
	var entries: Array = []
	if FileAccess.file_exists(path):
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		if f != null:
			var text: String = f.get_as_text()
			f.close()
			var parsed: Variant = JSON.parse_string(text)
			if parsed is Dictionary:
				var existing: Variant = parsed.get("entries", [])
				if existing is Array:
					entries = existing

	entries.append(entry)
	# Keep last 50
	if entries.size() > 50:
		entries = entries.slice(entries.size() - 50)

	var data: Dictionary = {"entries": entries}
	var json_str: String = JSON.stringify(data)
	var tmp_path: String = "/tmp/leaderboard.json.tmp"
	var f: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if f != null:
		f.store_string(json_str)
		f.close()
		DirAccess.rename_absolute(tmp_path, path)


# ===========================================================================
# Safe zone helpers
# ===========================================================================

func _is_in_safe_zone(pos: Vector2) -> bool:
	for shop in _shops:
		if pos.distance_to(shop.position) <= Config.SHOP_SAFE_RADIUS:
			return true
	return false


func _nearest_shop_to(pos: Vector2) -> Vector2:
	var best: Vector2 = _shops[0].position
	var best_dist: float = pos.distance_squared_to(best)
	for i in range(1, _shops.size()):
		var d: float = pos.distance_squared_to(_shops[i].position)
		if d < best_dist:
			best_dist = d
			best = _shops[i].position
	return best


# ===========================================================================
# Input & action processing
# ===========================================================================

func _apply_pending_inputs(_delta: float) -> void:
	for peer_id: int in _pending_inputs:
		var data: PackedByteArray = _pending_inputs[peer_id]
		var input: Dictionary = bytes_to_var(data)
		var player_idx: int = _game_peers.get(peer_id, -1)
		if player_idx < 0 or player_idx >= _players.size():
			continue
		var player: Player = _players[player_idx]
		if not player.alive:
			player.velocity = Vector2.ZERO
			continue

		# Movement
		var move_x: float = input.get("move_x", 0.0)
		var move_y: float = input.get("move_y", 0.0)
		var move_dir := Vector2(move_x, move_y)
		if move_dir.length_squared() > 0.0:
			move_dir = move_dir.normalized()
			player.velocity = move_dir * Config.PLAYER_SPEED * player.speed_mult * player.get_speed_bonus()
			player.facing_dir = move_dir
		else:
			player.velocity = Vector2.ZERO

		# Attack
		var do_attack: bool = input.get("attack", false)
		if do_attack and not _is_in_safe_zone(player.position):
			var attack_x: float = input.get("attack_x", 0.0)
			var attack_y: float = input.get("attack_y", 0.0)
			var attack_result: Dictionary = player.try_attack(Vector2(attack_x, attack_y))
			if not attack_result.is_empty():
				_resolve_attack(attack_result)


func _apply_pending_actions() -> void:
	for action_entry in _pending_actions:
		var peer_id: int = action_entry["peer_id"]
		var data: PackedByteArray = action_entry["data"]
		var action: Dictionary = bytes_to_var(data)
		var player_idx: int = _game_peers.get(peer_id, -1)
		if player_idx < 0 or player_idx >= _players.size():
			continue
		var player: Player = _players[player_idx]

		var action_type: String = action.get("type", "")
		match action_type:
			"buy_equip":
				var item_id: String = action.get("item_id", "")
				player.buy_equipment(item_id)
			"buy_consumable":
				var item_id: String = action.get("item_id", "")
				player.buy_consumable(item_id)
			"buy_skill":
				var skill_id: String = action.get("skill_id", "")
				player.buy_skill(skill_id)
			"use_health_potion":
				player.use_health_potion()
			"use_speed_potion":
				player.use_speed_potion()
			"use_shield_potion":
				player.use_shield_potion()
			"switch_slot":
				var slot: int = action.get("slot", 0)
				if slot == 1 and player.bow != "":
					player.active_slot = 1
				else:
					player.active_slot = 0
	_pending_actions.clear()


# ===========================================================================
# Snapshot broadcast (sends directly to this game's peers)
# ===========================================================================

func _broadcast_snapshot() -> void:
	var player_data: Array = []
	for player in _players:
		player_data.append({
			"id": player.player_id,
			"x": player.position.x,
			"y": player.position.y,
			"hp": player.hp,
			"max_hp": player.max_hp,
			"gold": player.gold,
			"alive": player.alive,
			"rt": player.respawn_timer,
			"weapon": player.weapon,
			"bow": player.bow,
			"armor": player.armor,
			"slot": player.active_slot,
			"arrows": player.arrows,
			"hpot": player.health_potions,
			"spot": player.speed_potions,
			"shpot": player.shield_potions,
			"fx": player.facing_dir.x,
			"fy": player.facing_dir.y,
			"atk": player.is_attacking,
			"spd_t": player.speed_buff_timer,
			"shd_t": player.shield_buff_timer,
			"skills": player.skills.duplicate(),
			"ks": player.kill_streak,
			"bounty": player.has_bounty,
		})

	var mob_data: Array = []
	for mob in _mobs:
		if mob.alive:
			mob_data.append({
				"mid": mob.mob_id,
				"type": mob.mob_type,
				"x": mob.position.x,
				"y": mob.position.y,
				"hp": mob.hp,
				"mhp": mob.max_hp,
			})

	var proj_data: Array = []
	for proj in _projectiles:
		if proj.alive:
			proj_data.append({
				"x": proj.position.x,
				"y": proj.position.y,
				"dx": proj.direction.x,
				"dy": proj.direction.y,
				"oid": proj.owner_id,
			})

	var pickup_data: Array = []
	for pickup in _pickups:
		if pickup.alive:
			pickup_data.append({
				"pid": pickup.pickup_id,
				"type": pickup.pickup_type,
				"x": pickup.position.x,
				"y": pickup.position.y,
				"amt": pickup.amount,
			})

	var snapshot: Dictionary = {
		"t": _game_time,
		"p": player_data,
		"m": mob_data,
		"pr": proj_data,
		"pk": pickup_data,
		"h": {
			"a": _hill.active,
			"gt": _hill.game_timer,
			"cp": _hill.capturing_player,
			"cprog": _hill.capture_progress,
			"hp": _hill.holding_player,
			"ht": _hill.hold_timer,
		},
	}

	var snapshot_bytes: PackedByteArray = var_to_bytes(snapshot)
	for pid: int in _game_peers:
		Net.rpc_state_snapshot.rpc_id(pid, snapshot_bytes)


# ===========================================================================
# Game event broadcast (sends directly to this game's peers)
# ===========================================================================

func _broadcast_game_event(event: Dictionary) -> void:
	var event_bytes: PackedByteArray = var_to_bytes(event)
	for pid: int in _game_peers:
		Net.rpc_game_event.rpc_id(pid, event_bytes)


# ===========================================================================
# Cleanup
# ===========================================================================

func cleanup() -> void:
	for player in _players:
		player.queue_free()
	_players.clear()
	for mob in _mobs:
		mob.queue_free()
	_mobs.clear()
	_mob_by_id.clear()
	for proj in _projectiles:
		proj.queue_free()
	_projectiles.clear()
	for pickup in _pickups:
		pickup.queue_free()
	_pickups.clear()
	_next_pickup_id = 0
	for shop in _shops:
		shop.queue_free()
	_shops.clear()
	if _hill != null:
		_hill.queue_free()
		_hill = null
	if _map_gen != null:
		_map_gen.queue_free()
		_map_gen = null
	_bot_ais.clear()
	_dead_mob_queue.clear()
	_pending_inputs.clear()
	_pending_actions.clear()
