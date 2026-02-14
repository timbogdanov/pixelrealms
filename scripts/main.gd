extends Node2D

# ---------------------------------------------------------------------------
# References (from scene tree)
# ---------------------------------------------------------------------------
var _map_gen: Node2D
var _camera: Camera2D

# ---------------------------------------------------------------------------
# Game entities
# ---------------------------------------------------------------------------
var _players: Array = []
var _mobs: Array = []
var _projectiles: Array = []
var _particles: Array = []
var _shops: Array = []
var _hill: Hill
var _bot_ais: Array = []

# ---------------------------------------------------------------------------
# Human player shortcut
# ---------------------------------------------------------------------------
var _human: Player

# ---------------------------------------------------------------------------
# Entity rendering
# ---------------------------------------------------------------------------
var _entity_node: Node2D

# ---------------------------------------------------------------------------
# Fog of war (GPU shader)
# ---------------------------------------------------------------------------
var _fog_sprite: Sprite2D
var _fog_material: ShaderMaterial

# ---------------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------------
var _hud_node: Control
var _messages: Array = []  # [{text, timer, color}]

# ---------------------------------------------------------------------------
# Shop UI
# ---------------------------------------------------------------------------
var _shop_open: bool = false
var _shop_ref: Shop = null
var _shop_items: Array = []  # cached list of item IDs for number key buying
var _shop_tab: int = 0  # 0=equipment, 1=supplies, 2=skills
var _shop_flash_timer: float = 0.0
var _shop_flash_idx: int = -1
var _gold_floats: Array = []  # [{x, y, amount, timer, max_timer}]
var _turret_beams: Array = []  # [{from_x, from_y, to_x, to_y, timer}]

# ---------------------------------------------------------------------------
# Mob respawn queue
# ---------------------------------------------------------------------------
var _dead_mob_queue: Array = []
var _next_mob_id: int = 0
var _mob_by_id: Dictionary = {}

# ---------------------------------------------------------------------------
# Network multiplayer
# ---------------------------------------------------------------------------
var _pending_inputs: Dictionary = {}
var _pending_actions: Array = []
var _snapshot_timer: float = 0.0
var _lobby_broadcast_timer: float = 0.0

# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------
enum GameState { LOBBY, PLAYING, GAME_OVER }
var _game_state: int = GameState.LOBBY
var _game_over: bool = false
var _winner_id: int = -1
var _game_time: float = 0.0

# ---------------------------------------------------------------------------
# Lobby
# ---------------------------------------------------------------------------
var _lobby_timer: float = 60.0
var _lobby_player_count: int = 0
var _lobby_joined: bool = false
var _lobby_fill_timer: float = 0.0
var _lobby_map_index: int = 0


# ===========================================================================
# Initialization
# ===========================================================================

func _ready() -> void:
	_map_gen = $MapGenerator
	_camera = $Camera
	_setup_entity_layer()
	_setup_hud()
	_game_state = GameState.LOBBY

	# Connect network signals
	Net.game_starting.connect(_on_net_game_start)
	Net.state_snapshot_received.connect(_on_state_received)
	Net.input_received.connect(_on_input_received)
	Net.action_received.connect(_on_action_received)
	Net.game_event_received.connect(_on_game_event)
	Net.lobby_updated.connect(_on_lobby_updated)

	if Net.role == Net.Role.SERVER:
		_lobby_map_index = Net.lobby_map_index
	else:
		_add_wasd_input()
		_lobby_map_index = Net.lobby_map_index


func _start_game_server(seed_val: int) -> void:
	_game_state = GameState.PLAYING
	_map_gen.generate(seed_val, Net.lobby_map_index)
	_spawn_hill()
	_spawn_shops()
	_spawn_players_server()
	_spawn_mobs()


func _start_game_client(seed_val: int, my_index: int) -> void:
	_game_state = GameState.PLAYING
	_map_gen.generate(seed_val, _lobby_map_index)
	_setup_fog_layer()
	_spawn_hill()
	_spawn_shops()
	# Create all 20 player objects for rendering
	for i in Config.NUM_PLAYERS:
		var player := Player.new()
		var spawn_pos: Vector2 = _map_gen.spawn_positions[i]
		var color: Color = Config.PLAYER_COLORS[i]
		player.init(i, spawn_pos, color, i == my_index)
		player.map_generator = _map_gen
		_players.append(player)
		add_child(player)
	_human = _players[my_index]
	_camera.target = _human


func _add_wasd_input() -> void:
	var key_a := InputEventKey.new()
	key_a.keycode = KEY_A
	InputMap.action_add_event("ui_left", key_a)
	var key_d := InputEventKey.new()
	key_d.keycode = KEY_D
	InputMap.action_add_event("ui_right", key_d)
	var key_w := InputEventKey.new()
	key_w.keycode = KEY_W
	InputMap.action_add_event("ui_up", key_w)
	var key_s := InputEventKey.new()
	key_s.keycode = KEY_S
	InputMap.action_add_event("ui_down", key_s)


func _setup_entity_layer() -> void:
	_entity_node = Node2D.new()
	_entity_node.z_index = 1
	add_child(_entity_node)
	_entity_node.draw.connect(_draw_entities)


func _setup_fog_layer() -> void:
	# 1x1 white texture stretched to map size — shader does the rest
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)

	_fog_sprite = Sprite2D.new()
	_fog_sprite.texture = tex
	_fog_sprite.centered = false
	_fog_sprite.scale = Vector2(float(Config.MAP_WIDTH), float(Config.MAP_HEIGHT))
	_fog_sprite.z_index = 2

	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\n" \
		+ "uniform vec2 player_pos;\n" \
		+ "uniform float vision_radius;\n" \
		+ "uniform vec2 map_size;\n" \
		+ "void fragment() {\n" \
		+ "    vec2 world_pos = UV * map_size;\n" \
		+ "    float dist = distance(world_pos, player_pos);\n" \
		+ "    float fog = step(vision_radius, dist);\n" \
		+ "    COLOR = vec4(0.0, 0.0, 0.0, fog);\n" \
		+ "}\n"

	_fog_material = ShaderMaterial.new()
	_fog_material.shader = shader
	_fog_material.set_shader_parameter("map_size", Vector2(float(Config.MAP_WIDTH), float(Config.MAP_HEIGHT)))
	_fog_material.set_shader_parameter("player_pos", Vector2(0.0, 0.0))
	_fog_material.set_shader_parameter("vision_radius", 0.0)
	_fog_sprite.material = _fog_material

	add_child(_fog_sprite)


func _setup_hud() -> void:
	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 10
	add_child(canvas_layer)
	_hud_node = Control.new()
	_hud_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas_layer.add_child(_hud_node)
	_hud_node.draw.connect(_draw_hud)


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


func _spawn_players_server() -> void:
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
	var bot_indices: Array[int] = Net.get_bot_indices(Config.NUM_PLAYERS)
	for idx in bot_indices:
		var bot := BotAI.new()
		var personality: int = idx % 3
		bot.init(personality)
		_bot_ais.append({"player_idx": idx, "ai": bot})


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
			mob.init(zone_type, zone_pos + offset, _map_gen)
			mob.died.connect(_on_mob_died)
			_mobs.append(mob)
			_mob_by_id[mob.mob_id] = mob
			add_child(mob)


# ===========================================================================
# Main game loop
# ===========================================================================

func _physics_process(delta: float) -> void:
	if Net.role != Net.Role.SERVER:
		return
	# Server-only game logic
	if _game_state == GameState.LOBBY:
		_process_lobby_server(delta)
		return
	if _game_state == GameState.GAME_OVER:
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
			var spawn_idx: int = player.player_id % _map_gen.spawn_positions.size()
			player.respawn(_map_gen.spawn_positions[spawn_idx])

	# 5. Mobs
	for mob in _mobs:
		if mob.alive:
			mob.process_ai(delta, _players, _shops)

	# 6. Projectiles
	_process_projectiles(delta)

	# 7. Hill
	_hill.process_hill(delta, _players)

	# 8. Mob respawns
	_process_mob_respawns(delta)

	# 9. Snapshot broadcast
	_snapshot_timer += delta
	if _snapshot_timer >= 1.0 / float(Config.SNAPSHOT_RATE):
		_snapshot_timer = 0.0
		_broadcast_snapshot()


func _process(delta: float) -> void:
	if Net.role == Net.Role.SERVER:
		return
	# Client-only rendering and input
	if _game_state == GameState.LOBBY:
		_hud_node.queue_redraw()
		return
	if _game_state == GameState.GAME_OVER:
		_hud_node.queue_redraw()
		return

	# Send input to server
	_send_input_to_server()

	# Tick visual timers
	_tick_messages(delta)
	_tick_gold_floats(delta)
	_tick_turret_beams(delta)
	_tick_particles(delta)
	if _shop_flash_timer > 0.0:
		_shop_flash_timer -= delta
		if _shop_flash_timer < 0.0:
			_shop_flash_timer = 0.0

	# Auto-close shop if walked away
	if _shop_open and _shop_ref != null and _human != null:
		if not _shop_ref.is_player_nearby(_human):
			_shop_open = false
			_shop_ref = null
			_human.shop_open = false

	_render_entities()
	_render_fog()
	_hud_node.queue_redraw()


# ===========================================================================
# Lobby logic
# ===========================================================================

func _process_lobby_server(delta: float) -> void:
	# Broadcast lobby state to all clients periodically
	_lobby_broadcast_timer -= delta
	if _lobby_broadcast_timer <= 0.0:
		_lobby_broadcast_timer = 0.5
		_lobby_player_count = Net.connected_peers.size()
		Net.server_broadcast_lobby(_lobby_timer)

	# Timer only counts down after min players connected
	if Net.connected_peers.size() < Config.MIN_PLAYERS_TO_START:
		_lobby_timer = Config.LOBBY_TIMER
		return

	_lobby_timer -= delta
	if _lobby_timer <= 0.0:
		_lobby_player_count = Config.NUM_PLAYERS
		var seed_val: int = randi()
		Net.server_start_game(seed_val)
		_start_game_server(seed_val)


# ===========================================================================
# Human combat input
# ===========================================================================

# ===========================================================================
# Bot AI processing (server only)
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
		var result: Dictionary = bot.update(delta, player, _players, _mobs, _shops, _hill, _map_gen)
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
	# Each personality prefers different skills
	var personality: int = 0
	for bot_entry in _bot_ais:
		if bot_entry["player_idx"] == player.player_id:
			personality = bot_entry["ai"].personality
			break
	var preferred: Array = []
	match personality:
		0:  # Aggressive: Quick Draw, Swift Feet, Gold Rush
			preferred = ["quick_draw", "swift_feet", "gold_rush"]
		1:  # Cautious: Regeneration, Vitality, Eagle Eye
			preferred = ["regeneration", "vitality", "eagle_eye"]
		2:  # Opportunist: Swift Feet, Gold Rush, Quick Draw
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
	if not Net.is_human_player(attacker_id):
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
			# Safe zone turret — check BEFORE dealing damage
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
				attacker.add_gold(stolen)
				_broadcast_game_event({"type": "player_killed",
					"victim_id": target.player_id, "killer_id": attacker_id,
					"gold_stolen": stolen,
					"x": target.position.x, "y": target.position.y})

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
					# Safe zone turret — check BEFORE dealing damage
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
								attacker.add_gold(stolen)
								_broadcast_game_event({"type": "player_killed",
									"victim_id": player.player_id, "killer_id": proj.owner_id,
									"gold_stolen": stolen,
									"x": player.position.x, "y": player.position.y})
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

	# Broadcast mob death event to clients
	_broadcast_game_event({"type": "mob_killed",
		"x": mob.position.x, "y": mob.position.y,
		"mob_type": mob.mob_type, "gold": gold_amount})

	# Queue respawn
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
		mob.init(mob_type, spawn_pos + offset, _map_gen)
		mob.died.connect(_on_mob_died)
		_mobs.append(mob)
		_mob_by_id[mob.mob_id] = mob
		add_child(mob)


# ===========================================================================
# Player death
# ===========================================================================

func _on_player_died(_player: Player) -> void:
	pass  # Respawn handled in main loop


# ===========================================================================
# Win condition
# ===========================================================================

func _on_hill_won(player_id: int) -> void:
	if Net.role != Net.Role.SERVER:
		return
	_game_over = true
	_game_state = GameState.GAME_OVER
	_winner_id = player_id
	_broadcast_game_event({"type": "game_over", "winner_id": player_id})


# ===========================================================================
# Entity rendering
# ===========================================================================

func _render_entities() -> void:
	_entity_node.queue_redraw()


func _draw_entities() -> void:
	if _game_state == GameState.LOBBY:
		return
	_draw_hill_zone()

	for shop in _shops:
		_draw_shop(shop)

	for mob in _mobs:
		if mob.alive:
			_draw_mob(mob)

	for proj in _projectiles:
		if proj.alive:
			_entity_node.draw_rect(Rect2(proj.position.x, proj.position.y, 1.0, 1.0), Color(1.0, 1.0, 0.6))
			_entity_node.draw_rect(Rect2(proj.position.x + 1.0, proj.position.y, 1.0, 1.0), Color(1.0, 0.9, 0.4))

	for player in _players:
		_draw_player(player)

	_draw_particles()
	_draw_turret_beams()


func _draw_hill_zone() -> void:
	if not _hill.active:
		var progress: float = _hill.get_activate_progress()
		if progress > 0.0:
			var alpha: float = progress * 0.3
			_draw_circle_outline(_hill.position.x, _hill.position.y,
								Config.HILL_RADIUS, Color(0.7, 0.65, 0.2, alpha))
		return

	var ring_color := Color(1.0, 0.85, 0.2, 0.5)
	if _hill.holding_player >= 0:
		var holder_color: Color = Config.PLAYER_COLORS[_hill.holding_player % Config.PLAYER_COLORS.size()]
		ring_color = Color(holder_color.r, holder_color.g, holder_color.b, 0.6)
	elif _hill.capturing_player >= 0:
		var cap_color: Color = Config.PLAYER_COLORS[_hill.capturing_player % Config.PLAYER_COLORS.size()]
		ring_color = Color(cap_color.r, cap_color.g, cap_color.b, 0.3)

	_draw_circle_outline(_hill.position.x, _hill.position.y,
						Config.HILL_RADIUS, ring_color)


func _draw_shop(shop: Shop) -> void:
	var cx: float = shop.position.x
	var cy: float = shop.position.y
	var wall := Color(0.85, 0.65, 0.25)
	var roof := Color(0.6, 0.2, 0.15)
	var door := Color(0.45, 0.3, 0.15)
	var border_col := wall.darkened(0.4)

	# 9x9 house body with border
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var col: Color
			if abs(dx) == 4 or abs(dy) == 4:
				col = border_col
			elif dy <= -2:
				col = roof
			elif dy >= 2 and abs(dx) <= 1:
				col = door
			else:
				col = wall
			_entity_node.draw_rect(Rect2(cx + float(dx), cy + float(dy), 1.0, 1.0), col)

	# Turret towers (flanking the building)
	var turret_base := Color(0.5, 0.48, 0.42)
	var turret_barrel := Color(0.35, 0.33, 0.30)
	var turret_tip := Color(0.8, 0.2, 0.15)
	for tx in [-7.0, 6.0]:
		# Stone base (3x2)
		_entity_node.draw_rect(Rect2(cx + tx, cy, 3.0, 2.0), turret_base)
		# Barrel (1x2)
		_entity_node.draw_rect(Rect2(cx + tx + 1.0, cy - 2.0, 1.0, 2.0), turret_barrel)
		# Red tip (1x1)
		_entity_node.draw_rect(Rect2(cx + tx + 1.0, cy - 3.0, 1.0, 1.0), turret_tip)

	# Pulsing interact radius circle
	var pulse: float = 0.15 + sin(_game_time * 3.0) * 0.1
	_draw_circle_outline(cx, cy, Config.SHOP_INTERACT_RADIUS, Color(0.9, 0.75, 0.3, pulse))

	# Safe zone circle
	_draw_circle_outline(shop.position.x, shop.position.y, Config.SHOP_SAFE_RADIUS, Color(0.3, 0.8, 0.3, 0.15))


func _draw_mob(mob: Mob) -> void:
	var cx: float = mob.position.x
	var cy: float = mob.position.y
	var mob_color: Color
	match mob.mob_type:
		Config.MobType.SLIME:
			mob_color = Color(0.3, 0.8, 0.3)
		Config.MobType.SKELETON:
			mob_color = Color(0.85, 0.85, 0.8)
		Config.MobType.KNIGHT:
			mob_color = Color(0.55, 0.45, 0.55)
		_:
			mob_color = Color(0.8, 0.3, 0.3)

	# 3x3 body
	_entity_node.draw_rect(Rect2(cx - 1.0, cy - 1.0, 3.0, 3.0), mob_color)

	# HP bar above mob
	var hp_frac: float = mob.hp / mob.max_hp
	var bar_y: float = cy - 3.0
	var bar_w: float = 5.0
	_entity_node.draw_rect(Rect2(cx - 2.0, bar_y, bar_w, 1.0), Color(0.3, 0.1, 0.1))
	if hp_frac > 0.0:
		_entity_node.draw_rect(Rect2(cx - 2.0, bar_y, bar_w * hp_frac, 1.0), Color(0.2, 0.9, 0.2))


func _draw_player(player: Player) -> void:
	var cx: float = player.position.x
	var cy: float = player.position.y

	if not player.alive:
		var alpha: float = 0.2 + sin(_game_time * 5.0) * 0.1
		var ghost := Color(player.player_color.r, player.player_color.g, player.player_color.b, alpha)
		_entity_node.draw_rect(Rect2(cx - 1.0, cy - 2.0, 3.0, 1.0), ghost)
		_entity_node.draw_rect(Rect2(cx - 2.0, cy - 1.0, 5.0, 3.0), ghost)
		_entity_node.draw_rect(Rect2(cx - 1.0, cy + 2.0, 3.0, 1.0), ghost)
		return

	var body := player.player_color
	var border_col := body.darkened(0.4)

	# Outer circle (border) — 5px diameter disc
	_entity_node.draw_rect(Rect2(cx - 1.0, cy - 2.0, 3.0, 1.0), border_col)
	_entity_node.draw_rect(Rect2(cx - 2.0, cy - 1.0, 5.0, 3.0), border_col)
	_entity_node.draw_rect(Rect2(cx - 1.0, cy + 2.0, 3.0, 1.0), border_col)
	# Inner fill (body) — 3px core
	_entity_node.draw_rect(Rect2(cx - 1.0, cy - 1.0, 3.0, 3.0), body)

	# HP bar above
	var hp_frac: float = player.hp / player.max_hp
	var bar_y: float = cy - 4.0
	var bar_w: float = 7.0
	_entity_node.draw_rect(Rect2(cx - 3.0, bar_y, bar_w, 1.0), Color(0.4, 0.1, 0.1))
	if hp_frac > 0.0:
		_entity_node.draw_rect(Rect2(cx - 3.0, bar_y, bar_w * hp_frac, 1.0), Color(0.2, 0.9, 0.2))

	# Attack visual (melee swing arc)
	if player.is_attacking and player.active_slot == 0:
		var swing_len: float = 4.0
		var base_angle: float = player.facing_dir.angle()
		var arc_half: float = deg_to_rad(Config.MELEE_ARC * 0.5)
		for step in 7:
			var a: float = base_angle - arc_half + arc_half * 2.0 * float(step) / 6.0
			var tip: Vector2 = player.position + Vector2(cos(a), sin(a)) * swing_len
			_entity_node.draw_rect(Rect2(tip.x, tip.y, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.8))


func _draw_circle_outline(cx: float, cy: float, r: float, color: Color) -> void:
	var ri: int = int(r)
	var x: int = ri
	var y: int = 0
	var d: int = 1 - ri
	while x >= y:
		_entity_node.draw_rect(Rect2(cx + float(x), cy + float(y), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx - float(x), cy + float(y), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx + float(x), cy - float(y), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx - float(x), cy - float(y), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx + float(y), cy + float(x), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx - float(y), cy + float(x), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx + float(y), cy - float(x), 1.0, 1.0), color)
		_entity_node.draw_rect(Rect2(cx - float(y), cy - float(x), 1.0, 1.0), color)
		y += 1
		if d <= 0:
			d += 2 * y + 1
		else:
			x -= 1
			d += 2 * (y - x) + 1


# ===========================================================================
# Particle effects
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


func _spawn_particles(origin: Vector2, count: int, color: Color, speed: float, lifetime: float, size: float = 1.0) -> void:
	for i in count:
		var angle: float = randf() * TAU
		var spd: float = speed * randf_range(0.5, 1.0)
		var vel := Vector2(cos(angle), sin(angle)) * spd
		_particles.append({
			"pos": origin + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)),
			"vel": vel,
			"life": lifetime,
			"max_life": lifetime,
			"color": color,
			"size": size,
		})


func _tick_particles(delta: float) -> void:
	var i: int = _particles.size() - 1
	while i >= 0:
		var p: Dictionary = _particles[i]
		p["pos"] += p["vel"] * delta
		p["vel"] *= 0.95  # drag
		p["life"] -= delta
		if p["life"] <= 0.0:
			_particles.remove_at(i)
		i -= 1


func _draw_particles() -> void:
	for p: Dictionary in _particles:
		var alpha: float = clampf(p["life"] / p["max_life"], 0.0, 1.0)
		var c: Color = p["color"]
		c.a = alpha
		var s: float = p["size"]
		_entity_node.draw_rect(Rect2(p["pos"].x, p["pos"].y, s, s), c)


# ===========================================================================
# Fog of war
# ===========================================================================

func _render_fog() -> void:
	if _human == null or _fog_material == null:
		return
	if _human.alive:
		var radius: float = Config.PLAYER_VISION + _human.get_vision_bonus()
		_fog_material.set_shader_parameter("player_pos", _human.position)
		_fog_material.set_shader_parameter("vision_radius", radius)
	elif _human.respawn_timer > 0.0:
		_fog_material.set_shader_parameter("player_pos", _human.position)
		_fog_material.set_shader_parameter("vision_radius", 30.0)
	else:
		_fog_material.set_shader_parameter("vision_radius", 0.0)


# ===========================================================================
# HUD drawing
# ===========================================================================

func _draw_hud() -> void:
	if _game_state == GameState.LOBBY:
		_draw_lobby()
		return
	if _game_state == GameState.GAME_OVER:
		_draw_game_over()
		return

	var vp: Vector2 = _hud_node.get_viewport_rect().size

	# --- Bottom-center: Inventory Bar + HP bar ---
	_draw_inventory_bar(vp)

	# --- Top bar background ---
	_hud_node.draw_rect(Rect2(0, 0, vp.x, 40), Color(0.04, 0.04, 0.03, 0.7))
	_hud_node.draw_rect(Rect2(0, 40, vp.x, 1), Color(0.35, 0.30, 0.20, 0.5))

	# --- Top-center: Hill + Gold ---
	var hill_cx: float = vp.x * 0.5
	var hill_color: Color = Color(0.7, 0.65, 0.3)
	var bar_start_x: float = hill_cx - 10.0
	var bar_width: float = 120.0

	# Gold (left of hill)
	_draw_gold_coin(_hud_node, hill_cx - 75.0, 8.0)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(hill_cx - 63.0, 18.0),
		"%d" % _human.gold, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Config.UI_TEXT_GOLD)

	# Hill status
	if not _hill.active:
		var time_left: float = Config.HILL_ACTIVATE_TIME - _hill.game_timer
		var inactive_color := Color(0.5, 0.45, 0.25)
		_draw_crown_icon(_hud_node, bar_start_x, 5.0, inactive_color)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_start_x + 12.0, 15.0),
			"Hill in %d:%02d" % [int(time_left) / 60, int(time_left) % 60],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, hill_color)
		var prog: float = _hill.get_activate_progress()
		_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width, 7.0), Color(0.1, 0.1, 0.08))
		_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width * prog, 7.0), hill_color)
		_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width, 7.0), Color(0.4, 0.35, 0.2), false, 1.0)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_start_x + bar_width + 4.0, 27.0),
			"%d%%" % int(prog * 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, hill_color)
	else:
		if _hill.holding_player >= 0:
			var hold_progress: float = _hill.get_hold_progress()
			var holder_name: String = "You" if _hill.holding_player == Net.my_player_index else "Player %d" % (_hill.holding_player + 1)
			var hold_color := Color(1.0, 0.5, 0.3)
			_draw_crown_icon(_hud_node, bar_start_x, 5.0, hold_color)
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_start_x + 12.0, 15.0),
				"%s holds Hill!" % holder_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, hold_color)
			_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width, 7.0), Color(0.1, 0.1, 0.08))
			_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width * hold_progress, 7.0), Color(1.0, 0.4, 0.2))
			_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width, 7.0), Color(0.6, 0.5, 0.3), false, 1.0)
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_start_x + bar_width + 4.0, 27.0),
				"%d%%" % int(hold_progress * 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, hold_color)
		elif _hill.capturing_player >= 0:
			var cap_progress: float = _hill.get_capture_progress()
			var cap_name: String = "You" if _hill.capturing_player == Net.my_player_index else "Player %d" % (_hill.capturing_player + 1)
			var cap_color := Color(0.9, 0.85, 0.4)
			_draw_crown_icon(_hud_node, bar_start_x, 5.0, cap_color)
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_start_x + 12.0, 15.0),
				"%s capturing..." % cap_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, cap_color)
			_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width, 7.0), Color(0.1, 0.1, 0.08))
			_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width * cap_progress, 7.0), cap_color)
			_hud_node.draw_rect(Rect2(bar_start_x, 20.0, bar_width, 7.0), Color(0.5, 0.45, 0.25), false, 1.0)
		else:
			_draw_crown_icon(_hud_node, bar_start_x, 5.0, hill_color)
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_start_x + 12.0, 15.0),
				"Hill is active!", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, hill_color)

	# --- Gold float animations ---
	_draw_gold_floats(vp)

	# --- Top-right: Stats panel ---
	_draw_stats_panel(vp)

	# --- Top-right: Game timer + player count ---
	var timer_text: String = "%d:%02d" % [int(_game_time) / 60, int(_game_time) % 60]
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x - 60.0, 18.0),
		timer_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Config.UI_TEXT)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x - 75.0, 32.0),
		"%d Players" % _lobby_player_count, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.6, 0.58, 0.48))

	# --- Death overlay ---
	if not _human.alive:
		var respawn_text: String = "Respawning in %.1f..." % _human.respawn_timer
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x * 0.5 - 60, vp.y * 0.5),
			respawn_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 0.3, 0.3))

	# --- Nearby shop hint (keyboard icon near player) ---
	if _human.alive:
		var near_shop: bool = false
		for shop in _shops:
			if shop.is_player_nearby(_human):
				near_shop = true
				var screen_pos: Vector2 = _camera.get_canvas_transform() * _human.position
				var key_x: float = screen_pos.x + 18.0
				var key_y: float = screen_pos.y - 12.0
				var key_w: float = 18.0
				var key_h: float = 18.0
				var key_bg: Color = Color(0.1, 0.1, 0.08, 0.85) if _shop_open else Color(0.15, 0.15, 0.12, 0.9)
				var key_border: Color = Color(0.4, 0.4, 0.3) if _shop_open else Color(0.6, 0.55, 0.35)
				var key_text_col: Color = Config.UI_TEXT if _shop_open else Config.UI_TEXT_GOLD
				_hud_node.draw_rect(Rect2(key_x, key_y, key_w, key_h), key_bg)
				_hud_node.draw_rect(Rect2(key_x, key_y, key_w, key_h), key_border, false, 1.5)
				_hud_node.draw_string(ThemeDB.fallback_font,
					Vector2(key_x + 4.0, key_y + key_h - 4.0),
					"E", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, key_text_col)
				break

		# Shop direction arrows on screen edges
		if not near_shop:
			_draw_shop_arrows(vp)
			_draw_hill_arrow(vp)

	# --- Shop panel ---
	if _shop_open and _shop_ref != null:
		_draw_shop_panel(vp)

	# --- Floating messages ---
	_draw_messages(vp)


func _draw_shop_panel(vp: Vector2) -> void:
	var panel_w: float = 300.0
	var row_h: float = 22.0
	var panel_h: float = 52.0 + _shop_items.size() * row_h + 10.0
	var px: float = vp.x * 0.5 - panel_w * 0.5
	var py: float = vp.y * 0.5 - panel_h * 0.5

	# Background
	_hud_node.draw_rect(Rect2(px, py, panel_w, panel_h), Color(0.08, 0.08, 0.06, 0.92))
	_hud_node.draw_rect(Rect2(px, py, panel_w, panel_h), Config.UI_BORDER, false, 1.5)

	# Header bar
	_hud_node.draw_rect(Rect2(px + 1, py + 1, panel_w - 2, 16), Color(0.12, 0.11, 0.08, 0.9))
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + 8, py + 13),
		"SHOP", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Config.UI_TEXT_GOLD)
	# Gold in header
	_draw_gold_coin(_hud_node, px + panel_w - 85, py + 4)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + panel_w - 73, py + 13),
		"%d" % _human.gold, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Config.UI_TEXT_GOLD)
	# Close X button
	var close_x: float = px + panel_w - 16
	var close_y: float = py + 2
	_hud_node.draw_rect(Rect2(close_x, close_y, 13, 13), Color(0.5, 0.15, 0.15, 0.7))
	_hud_node.draw_rect(Rect2(close_x, close_y, 13, 13), Color(0.7, 0.3, 0.3), false, 1.0)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(close_x + 3, close_y + 10),
		"X", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.9, 0.7, 0.6))

	# Tab buttons
	var tab_names: Array = ["Equipment", "Supplies", "Skills"]
	for t in 3:
		var tw: float = 80.0
		var tx: float = px + 8 + float(t) * (tw + 4)
		var ty: float = py + 20
		var th: float = 18.0
		var is_active: bool = t == _shop_tab
		var bg: Color = Color(0.12, 0.12, 0.09, 0.9) if is_active else Color(0.06, 0.06, 0.04, 0.6)
		var border: Color = Config.UI_TEXT_GOLD if is_active else Color(0.3, 0.28, 0.2, 0.6)
		_hud_node.draw_rect(Rect2(tx, ty, tw, th), bg)
		_hud_node.draw_rect(Rect2(tx, ty, tw, th), border, false, 1.0)
		var tcol: Color = Config.UI_TEXT_GOLD if is_active else Color(0.5, 0.45, 0.35)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(tx + 8, ty + 13),
			tab_names[t], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, tcol)
	# TAB keycap icon
	var tab_key_x: float = px + panel_w - 40
	var tab_key_y: float = py + 22
	_hud_node.draw_rect(Rect2(tab_key_x, tab_key_y, 30, 14), Color(0.15, 0.15, 0.12, 0.9))
	_hud_node.draw_rect(Rect2(tab_key_x, tab_key_y, 30, 14), Color(0.5, 0.45, 0.3), false, 1.0)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(tab_key_x + 3, tab_key_y + 11),
		"TAB", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.7, 0.65, 0.5))

	# Items
	for i in _shop_items.size():
		var item_id: String = _shop_items[i]
		var row_y: float = py + 52.0 + float(i) * row_h

		# Purchase flash overlay
		if _shop_flash_timer > 0.0 and i == _shop_flash_idx:
			var flash_alpha: float = _shop_flash_timer / 0.3
			_hud_node.draw_rect(Rect2(px + 4, row_y, panel_w - 8, row_h - 2),
				Color(0.2, 0.9, 0.2, flash_alpha * 0.25))

		match _shop_tab:
			0:  # Equipment
				_draw_shop_equip_row(px, row_y, i, item_id, panel_w)
			1:  # Consumables
				_draw_shop_consumable_row(px, row_y, i, item_id, panel_w)
			2:  # Skills
				_draw_shop_skill_row(px, row_y, i, item_id, panel_w)

	# Tooltip on hover
	if _shop_open:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		for i in _shop_items.size():
			var row_y: float = py + 52.0 + float(i) * row_h
			if mouse_pos.x >= px and mouse_pos.x <= px + panel_w and mouse_pos.y >= row_y and mouse_pos.y < row_y + row_h:
				_draw_shop_tooltip(mouse_pos, _shop_items[i])
				break


func _draw_shop_equip_row(px: float, row_y: float, idx: int, item_id: String, panel_w: float) -> void:
	var info: Dictionary = Config.EQUIPMENT[item_id]
	var item_name: String = info.get("name", "???")
	var cost: int = info.get("cost", 0)
	var slot: int = info.get("slot", -1)
	var tier: int = info.get("tier", 0)

	var current_id: String = ""
	match slot:
		Config.EquipSlot.WEAPON:
			current_id = _human.weapon
		Config.EquipSlot.BOW:
			current_id = _human.bow
		Config.EquipSlot.ARMOR:
			current_id = _human.armor

	var owned: bool = false
	var is_upgrade: bool = true
	if current_id != "":
		var cur_info: Dictionary = Config.EQUIPMENT.get(current_id, {})
		var cur_tier: int = cur_info.get("tier", 0)
		if current_id == item_id:
			owned = true
		elif tier <= cur_tier:
			is_upgrade = false

	# Item icon color by slot type
	var icon_color: Color
	match slot:
		Config.EquipSlot.WEAPON:
			icon_color = Color(0.85, 0.85, 0.8)
		Config.EquipSlot.BOW:
			icon_color = Color(0.5, 0.8, 0.3)
		_:
			icon_color = Color(0.5, 0.55, 0.7)

	var text_color: Color
	var badge_text: String = ""
	var badge_color: Color = Color.WHITE
	if owned:
		text_color = Color(0.4, 0.4, 0.35)
		icon_color = icon_color.darkened(0.5)
		badge_text = "OWNED"
		badge_color = Color(0.3, 0.7, 0.3)
	elif not is_upgrade:
		text_color = Color(0.5, 0.3, 0.3)
		icon_color = icon_color.darkened(0.5)
		badge_text = "DOWN"
		badge_color = Color(0.7, 0.3, 0.3)
	elif cost > _human.gold:
		text_color = Color(0.55, 0.45, 0.35)
	else:
		text_color = Color(0.9, 0.88, 0.78)

	# Icon
	_hud_node.draw_rect(Rect2(px + 10, row_y + 3, 10, 10), icon_color)
	_hud_node.draw_rect(Rect2(px + 10, row_y + 3, 10, 10), icon_color.darkened(0.3), false, 1.0)
	# Number + Name
	var name_text: String = "%d. %s" % [idx + 1, item_name]
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + 24, row_y + 13),
		name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, text_color)
	# Cost with coin
	if not owned:
		var cost_color: Color = Color(1.0, 0.3, 0.3) if cost > _human.gold else Config.UI_TEXT_GOLD
		_draw_gold_coin(_hud_node, px + panel_w - 58, row_y + 3)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + panel_w - 48, row_y + 13),
			"%d" % cost, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, cost_color)
	# Stat comparison
	if not owned and is_upgrade and current_id != "":
		var stat_text: String = ""
		var cur_info: Dictionary = Config.EQUIPMENT.get(current_id, {})
		if info.has("damage"):
			var delta: float = info.get("damage", 0.0) - cur_info.get("damage", 0.0)
			if delta > 0:
				stat_text = "+%.0f" % delta
		elif info.has("dr"):
			var delta: float = (info.get("dr", 0.0) - cur_info.get("dr", 0.0)) * 100.0
			if delta > 0:
				stat_text = "+%d%%" % int(delta)
		if stat_text != "":
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + panel_w - 95, row_y + 13),
				stat_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.3, 0.9, 0.3))
	# Badge
	if badge_text != "":
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + panel_w - 95, row_y + 13),
			badge_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, badge_color)


func _draw_shop_consumable_row(px: float, row_y: float, idx: int, item_id: String, _panel_w: float) -> void:
	var info: Dictionary = Config.CONSUMABLES[item_id]
	var item_name: String = info.get("name", "???")
	var cost: int = info.get("cost", 0)
	var ctype: String = info.get("type", "")

	# Icon color
	var icon_color: Color
	if ctype == "arrows":
		icon_color = Color(0.6, 0.45, 0.25)
	else:
		var subtype: String = info.get("subtype", "")
		match subtype:
			"health":
				icon_color = Color(0.9, 0.3, 0.3)
			"speed":
				icon_color = Color(0.3, 0.8, 0.9)
			"shield":
				icon_color = Color(0.5, 0.4, 0.9)
			_:
				icon_color = Color(0.7, 0.7, 0.6)

	var count_text: String = ""
	if ctype == "arrows":
		count_text = "(%d)" % _human.arrows
	elif ctype == "potion":
		var subtype: String = info.get("subtype", "")
		var max_carry: int = info.get("max_carry", 5)
		var current: int = 0
		match subtype:
			"health":
				current = _human.health_potions
			"speed":
				current = _human.speed_potions
			"shield":
				current = _human.shield_potions
		count_text = "(%d/%d)" % [current, max_carry]

	var text_color: Color = Color(0.55, 0.45, 0.35) if cost > _human.gold else Color(0.9, 0.88, 0.78)
	var cost_color: Color = Color(1.0, 0.3, 0.3) if cost > _human.gold else Config.UI_TEXT_GOLD

	# Icon
	_hud_node.draw_rect(Rect2(px + 10, row_y + 3, 10, 10), icon_color)
	_hud_node.draw_rect(Rect2(px + 10, row_y + 3, 10, 10), icon_color.darkened(0.3), false, 1.0)
	# Number + Name
	var name_text: String = "%d. %s" % [idx + 1, item_name]
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + 24, row_y + 13),
		name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, text_color)
	# Count
	if count_text != "":
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + _panel_w - 100, row_y + 13),
			count_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.6, 0.58, 0.48))
	# Cost with coin
	_draw_gold_coin(_hud_node, px + _panel_w - 58, row_y + 3)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + _panel_w - 48, row_y + 13),
		"%d" % cost, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, cost_color)


func _draw_shop_skill_row(px: float, row_y: float, idx: int, skill_id: String, _panel_w: float) -> void:
	var info: Dictionary = Config.SKILLS[skill_id]
	var skill_name: String = info.get("name", "???")
	var desc: String = info.get("desc", "")
	var levels: Array = info["levels"]
	var cur_level: int = _human.get_skill_level(skill_id)
	var is_maxed: bool = cur_level >= levels.size()

	var icon_color := Color(0.9, 0.8, 0.3)
	var text_color: Color
	var badge_text: String = ""
	var badge_color: Color = Color.WHITE

	if is_maxed:
		text_color = Color(0.4, 0.4, 0.35)
		icon_color = icon_color.darkened(0.5)
		badge_text = "MAX"
		badge_color = Config.UI_TEXT_GOLD
	else:
		var level_data: Array = levels[cur_level]
		var cost: int = level_data[0]
		if cost > _human.gold:
			text_color = Color(0.55, 0.45, 0.35)
		else:
			text_color = Color(0.9, 0.88, 0.78)

	# Icon
	_hud_node.draw_rect(Rect2(px + 10, row_y + 3, 10, 10), icon_color)
	_hud_node.draw_rect(Rect2(px + 10, row_y + 3, 10, 10), icon_color.darkened(0.3), false, 1.0)
	# Level pips inside icon
	for pip in cur_level:
		_hud_node.draw_rect(Rect2(px + 12 + float(pip) * 3, row_y + 10, 2, 2), Color(1, 1, 1, 0.8))
	# Number + Name + desc
	var level_str: String = "Lv%d/%d" % [cur_level, levels.size()]
	var name_text: String = "%d. %s (%s) %s" % [idx + 1, skill_name, desc, level_str]
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + 24, row_y + 13),
		name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, text_color)
	# Cost with coin (if not maxed)
	if not is_maxed:
		var level_data: Array = levels[cur_level]
		var cost: int = level_data[0]
		var cost_color: Color = Color(1.0, 0.3, 0.3) if cost > _human.gold else Config.UI_TEXT_GOLD
		_draw_gold_coin(_hud_node, px + _panel_w - 58, row_y + 3)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + _panel_w - 48, row_y + 13),
			"%d" % cost, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, cost_color)
	# Badge
	if badge_text != "":
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + _panel_w - 48, row_y + 13),
			badge_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, badge_color)


func _draw_shop_tooltip(mouse_pos: Vector2, item_id: String) -> void:
	var lines: Array = []
	var title: String = ""
	var title_color: Color = Config.UI_TEXT_GOLD

	if _shop_tab == 0 and Config.EQUIPMENT.has(item_id):
		var info: Dictionary = Config.EQUIPMENT[item_id]
		title = info.get("name", "???")
		if info.has("damage"):
			lines.append("Damage: %.0f" % info.get("damage", 0.0))
		if info.has("range"):
			lines.append("Range: %.0f" % info.get("range", 0.0))
		if info.has("cooldown"):
			lines.append("Cooldown: %.2fs" % info.get("cooldown", 0.0))
		if info.has("speed"):
			lines.append("Proj Speed: %.0f" % info.get("speed", 0.0))
		if info.has("dr"):
			lines.append("Damage Reduction: %d%%" % int(info.get("dr", 0.0) * 100.0))
	elif _shop_tab == 1 and Config.CONSUMABLES.has(item_id):
		var info: Dictionary = Config.CONSUMABLES[item_id]
		title = info.get("name", "???")
		var ctype: String = info.get("type", "")
		if ctype == "arrows":
			lines.append("Restocks your arrow supply")
		elif ctype == "potion":
			var subtype: String = info.get("subtype", "")
			match subtype:
				"health":
					lines.append("Heals %.0f HP instantly" % Config.POTION_HEAL_AMOUNT)
				"speed":
					lines.append("+%.0f%% speed for %.0fs" % [(Config.SPEED_POTION_MULT - 1.0) * 100, Config.SPEED_POTION_DURATION])
				"shield":
					lines.append("+%d%% DR for %.0fs" % [int(Config.SHIELD_POTION_DR * 100), Config.SHIELD_POTION_DURATION])
	elif _shop_tab == 2 and Config.SKILLS.has(item_id):
		var info: Dictionary = Config.SKILLS[item_id]
		title = info.get("name", "???")
		var levels: Array = info["levels"]
		var cur_level: int = _human.get_skill_level(item_id)
		if cur_level < levels.size():
			var next_val: float = levels[cur_level][1]
			lines.append("Next: +%s" % _format_skill_val(item_id, next_val))
		if cur_level > 0:
			var cur_val: float = levels[cur_level - 1][1]
			lines.append("Current: +%s" % _format_skill_val(item_id, cur_val))

	if title == "":
		return

	var tip_w: float = 160.0
	var tip_h: float = 18.0 + lines.size() * 13.0
	var tx: float = mouse_pos.x + 12
	var ty: float = mouse_pos.y - tip_h - 4
	# Keep on screen
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if tx + tip_w > vp.x:
		tx = mouse_pos.x - tip_w - 4
	if ty < 0:
		ty = mouse_pos.y + 16

	_hud_node.draw_rect(Rect2(tx, ty, tip_w, tip_h), Color(0.06, 0.06, 0.04, 0.95))
	_hud_node.draw_rect(Rect2(tx, ty, tip_w, tip_h), Color(0.5, 0.45, 0.3), false, 1.0)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(tx + 6, ty + 13),
		title, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, title_color)
	for i in lines.size():
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(tx + 6, ty + 26 + float(i) * 13),
			lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.75, 0.72, 0.62))


func _format_skill_val(skill_id: String, val: float) -> String:
	match skill_id:
		"swift_feet":
			return "%d%% speed" % int(val * 100)
		"regeneration":
			return "%.1f HP/s" % val
		"vitality":
			return "%.0f max HP" % val
		"eagle_eye":
			return "%.0f vision" % val
		"gold_rush":
			return "%d%% gold" % int(val * 100)
		"quick_draw":
			return "%d%% CD" % int(val * 100)
	return "%.1f" % val


func _draw_inventory_bar(vp: Vector2) -> void:
	var slot_size: float = 36.0
	var gap: float = 4.0
	var slot_count: int = 6
	var bar_w: float = slot_count * slot_size + (slot_count - 1) * gap
	var bar_x: float = (vp.x - bar_w) * 0.5
	var bar_y: float = vp.y - slot_size - 22.0

	# HP bar above everything
	var hp_bar_h: float = 10.0
	var hp_bar_y: float = bar_y - 28.0
	var hp_frac: float = _human.hp / _human.max_hp if _human.max_hp > 0.0 else 0.0
	var in_safe: bool = _human.alive and _is_in_safe_zone(_human.position)
	var hp_fill_color: Color = Color(0.3, 0.9, 0.3) if in_safe else Color(0.8, 0.2, 0.15)
	var hp_border_color: Color = Color(0.3, 0.7, 0.3) if in_safe else Color(0.5, 0.4, 0.25)
	_hud_node.draw_rect(Rect2(bar_x, hp_bar_y, bar_w, hp_bar_h), Color(0.15, 0.05, 0.05, 0.8))
	_hud_node.draw_rect(Rect2(bar_x, hp_bar_y, bar_w * hp_frac, hp_bar_h), hp_fill_color)
	_hud_node.draw_rect(Rect2(bar_x, hp_bar_y, bar_w, hp_bar_h), hp_border_color, false, 1.0)
	var hp_text: String = "%d / %d" % [int(_human.hp), int(_human.max_hp)]
	var hp_text_col: Color = Color(0.05, 0.15, 0.05) if in_safe else Config.UI_TEXT
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_x + bar_w * 0.5 - 20, hp_bar_y + hp_bar_h - 2),
		hp_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, hp_text_col)
	if in_safe:
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_x + bar_w * 0.5 - 25, hp_bar_y - 4),
			"SAFE ZONE", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.3, 0.9, 0.3, 0.9))

	# Buff timer bars between HP bar and inventory slots
	var buff_bar_y: float = bar_y - 10.0
	if _human.shield_buff_timer > 0.0:
		var frac: float = _human.shield_buff_timer / Config.SHIELD_POTION_DURATION
		_hud_node.draw_rect(Rect2(bar_x, buff_bar_y, bar_w, 4), Color(0.15, 0.15, 0.2, 0.6))
		_hud_node.draw_rect(Rect2(bar_x, buff_bar_y, bar_w * frac, 4), Color(0.4, 0.5, 1.0, 0.9))
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_x + bar_w + 4, buff_bar_y + 4),
			"SHIELD", HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(0.4, 0.5, 1.0))
		buff_bar_y -= 7.0
	if _human.speed_buff_timer > 0.0:
		var frac: float = _human.speed_buff_timer / Config.SPEED_POTION_DURATION
		_hud_node.draw_rect(Rect2(bar_x, buff_bar_y, bar_w, 4), Color(0.1, 0.15, 0.2, 0.6))
		_hud_node.draw_rect(Rect2(bar_x, buff_bar_y, bar_w * frac, 4), Color(0.3, 0.8, 1.0, 0.9))
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(bar_x + bar_w + 4, buff_bar_y + 4),
			"SPEED", HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(0.3, 0.8, 1.0))

	# Slot data: [hotkey, icon_color, label, count_text, is_active, has_item]
	var slots: Array = []

	# Slot 0: Melee weapon
	var wep_name: String = ""
	if _human.weapon != "":
		var info: Dictionary = Config.EQUIPMENT.get(_human.weapon, {})
		wep_name = info.get("name", "???")
	slots.append({
		"key": "1", "icon": Color(0.9, 0.9, 0.85), "label": wep_name,
		"count": "", "active": _human.active_slot == 0, "has": _human.weapon != ""
	})

	# Slot 1: Bow + arrows
	var bow_label: String = ""
	if _human.bow != "":
		var info: Dictionary = Config.EQUIPMENT.get(_human.bow, {})
		bow_label = info.get("name", "???")
	slots.append({
		"key": "2", "icon": Color(0.7, 0.85, 0.3), "label": bow_label,
		"count": str(_human.arrows) if _human.bow != "" else "",
		"active": _human.active_slot == 1, "has": _human.bow != ""
	})

	# Slot 2: Health potion
	slots.append({
		"key": "Q", "icon": Color(0.9, 0.3, 0.35), "label": "Health",
		"count": str(_human.health_potions) if _human.health_potions > 0 else "",
		"active": false, "has": _human.health_potions > 0
	})

	# Slot 3: Speed potion
	slots.append({
		"key": "F", "icon": Color(0.3, 0.8, 0.95), "label": "Speed",
		"count": str(_human.speed_potions) if _human.speed_potions > 0 else "",
		"active": _human.speed_buff_timer > 0.0, "has": _human.speed_potions > 0
	})

	# Slot 4: Shield potion
	slots.append({
		"key": "F", "icon": Color(0.4, 0.5, 0.95), "label": "Shield",
		"count": str(_human.shield_potions) if _human.shield_potions > 0 else "",
		"active": _human.shield_buff_timer > 0.0, "has": _human.shield_potions > 0
	})

	# Slot 5: Armor
	var armor_label: String = ""
	if _human.armor != "":
		var info: Dictionary = Config.EQUIPMENT.get(_human.armor, {})
		armor_label = info.get("name", "???")
	slots.append({
		"key": "A", "icon": Color(0.6, 0.6, 0.58), "label": armor_label,
		"count": "", "active": false, "has": _human.armor != ""
	})

	# Draw each slot
	for i in slots.size():
		var slot: Dictionary = slots[i]
		var sx: float = bar_x + float(i) * (slot_size + gap)
		var sy: float = bar_y

		# Background
		var bg_color := Color(0.08, 0.08, 0.06, 0.85)
		_hud_node.draw_rect(Rect2(sx, sy, slot_size, slot_size), bg_color)

		# Border
		var border_color: Color
		if slot["active"]:
			border_color = Config.UI_TEXT_GOLD
		elif slot["has"]:
			border_color = Color(0.4, 0.38, 0.28, 0.9)
		else:
			border_color = Color(0.25, 0.24, 0.2, 0.6)
		_hud_node.draw_rect(Rect2(sx, sy, slot_size, slot_size), border_color, false, 1.5)

		# Icon square (centered, 14x14)
		var icon_size: float = 14.0
		var ix: float = sx + (slot_size - icon_size) * 0.5
		var iy: float = sy + (slot_size - icon_size) * 0.5 - 2.0
		var icon_col: Color = slot["icon"]
		if not slot["has"]:
			icon_col = Color(icon_col.r * 0.3, icon_col.g * 0.3, icon_col.b * 0.3, 0.4)
		_hud_node.draw_rect(Rect2(ix, iy, icon_size, icon_size), icon_col)

		# Hotkey label (top-left)
		var key_str: String = slot["key"]
		var key_color: Color = Color(0.85, 0.8, 0.6) if slot["has"] else Color(0.4, 0.38, 0.3)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(sx + 2, sy + 9),
			key_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, key_color)

		# Count (bottom-right)
		var count_str: String = slot["count"]
		if count_str != "":
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(sx + slot_size - 14, sy + slot_size - 3),
				count_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Config.UI_TEXT)

		# Label below slot
		var label_str: String = slot["label"]
		if label_str != "":
			# Truncate long names
			if label_str.length() > 7:
				label_str = label_str.substr(0, 6) + "."
			var label_color: Color = Config.UI_TEXT if slot["has"] else Color(0.35, 0.34, 0.3)
			_hud_node.draw_string(ThemeDB.fallback_font, Vector2(sx, sy + slot_size + 9),
				label_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 7, label_color)


func _draw_stats_panel(vp: Vector2) -> void:
	# Collect visible stats (only show upgraded ones)
	var stats: Array = []

	# Swift Feet (speed)
	var sf_level: int = _human.get_skill_level("swift_feet")
	if sf_level > 0 or _human.speed_buff_timer > 0.0:
		var bonus: float = (_human.get_speed_bonus() - 1.0) * 100.0
		stats.append({"col": Color(0.3, 0.8, 0.9), "text": "Spd +%d%%" % int(bonus), "lv": sf_level, "max": 3})

	# Eagle Eye (vision)
	var ee_level: int = _human.get_skill_level("eagle_eye")
	if ee_level > 0:
		var bonus: float = _human.get_vision_bonus()
		stats.append({"col": Color(0.9, 0.85, 0.3), "text": "Vis +%d" % int(bonus), "lv": ee_level, "max": 3})

	# Vitality (max HP)
	var vit_level: int = _human.get_skill_level("vitality")
	if vit_level > 0:
		var bonus: float = _human.max_hp - Config.PLAYER_MAX_HP
		stats.append({"col": Color(0.9, 0.3, 0.3), "text": "HP +%d" % int(bonus), "lv": vit_level, "max": 3})

	# Regeneration
	var regen: float = _human.get_regen_rate()
	if regen > 0.0:
		var rg_level: int = _human.get_skill_level("regeneration")
		stats.append({"col": Color(0.3, 0.9, 0.3), "text": "Reg %.1f/s" % regen, "lv": rg_level, "max": 3})

	# Quick Draw
	var qd_level: int = _human.get_skill_level("quick_draw")
	if qd_level > 0:
		var cd_reduction: float = (1.0 - _human.get_cooldown_mult()) * 100.0
		stats.append({"col": Color(0.9, 0.6, 0.2), "text": "CD -%d%%" % int(cd_reduction), "lv": qd_level, "max": 3})

	# Gold Rush
	var gr_level: int = _human.get_skill_level("gold_rush")
	if gr_level > 0:
		var gr_bonus: float = (_human.get_gold_mult() - 1.0) * 100.0
		stats.append({"col": Color(1.0, 0.85, 0.3), "text": "Gold +%d%%" % int(gr_bonus), "lv": gr_level, "max": 3})

	if stats.is_empty():
		return

	var line_h: float = 14.0
	var panel_w: float = 110.0
	var panel_h: float = 8.0 + float(stats.size()) * line_h + 4.0
	var px: float = vp.x - panel_w - 8.0
	var py: float = 46.0

	# Background
	_hud_node.draw_rect(Rect2(px, py, panel_w, panel_h), Color(0.04, 0.04, 0.03, 0.7))
	_hud_node.draw_rect(Rect2(px, py, panel_w, panel_h), Color(0.3, 0.28, 0.2, 0.5), false, 1.0)

	for i in stats.size():
		var stat: Dictionary = stats[i]
		var sy: float = py + 6.0 + float(i) * line_h
		# Icon square
		_hud_node.draw_rect(Rect2(px + 4.0, sy + 1.0, 6.0, 6.0), stat["col"])
		# Text
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(px + 14.0, sy + 8.0),
			stat["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.8, 0.78, 0.68))
		# Level pips (right side)
		var max_lv: int = stat["max"]
		var cur_lv: int = stat["lv"]
		for p in max_lv:
			var pip_x: float = px + panel_w - 16.0 + float(p) * 5.0
			var pip_col: Color = stat["col"] if p < cur_lv else Color(0.2, 0.2, 0.18)
			_hud_node.draw_rect(Rect2(pip_x, sy + 2.0, 3.0, 3.0), pip_col)


func _draw_messages(vp: Vector2) -> void:
	var msg_x: float = vp.x * 0.5
	var msg_y: float = vp.y * 0.35
	for i in _messages.size():
		var msg: Dictionary = _messages[i]
		var text: String = msg["text"]
		var timer: float = msg["timer"]
		var duration: float = msg["duration"]
		var color: Color = msg["color"]
		# Fade out in last 0.5s
		if timer < 0.5:
			color.a = timer / 0.5
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(msg_x - 60, msg_y + float(i) * 16.0),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


func _draw_gold_coin(node: CanvasItem, x: float, y: float) -> void:
	var gold := Color(1.0, 0.85, 0.3)
	var dark := Color(0.7, 0.55, 0.15)
	var shine := Color(1.0, 0.95, 0.6)
	node.draw_rect(Rect2(x + 2, y, 4, 1), gold)
	node.draw_rect(Rect2(x + 1, y + 1, 6, 6), gold)
	node.draw_rect(Rect2(x + 2, y + 7, 4, 1), gold)
	node.draw_rect(Rect2(x + 3, y + 3, 2, 2), dark)
	node.draw_rect(Rect2(x + 2, y + 1, 1, 1), shine)


func _draw_crown_icon(node: CanvasItem, x: float, y: float, color: Color) -> void:
	node.draw_rect(Rect2(x + 1, y + 5, 6, 3), color)
	node.draw_rect(Rect2(x + 1, y + 2, 1, 3), color)
	node.draw_rect(Rect2(x + 3, y, 2, 5), color)
	node.draw_rect(Rect2(x + 6, y + 2, 1, 3), color)


func _spawn_gold_float(world_pos: Vector2, amount: int) -> void:
	_gold_floats.append({"x": world_pos.x, "y": world_pos.y, "amount": amount, "timer": 1.5, "max_timer": 1.5})


func _tick_gold_floats(delta: float) -> void:
	var remaining: Array = []
	for gf in _gold_floats:
		gf["timer"] -= delta
		gf["y"] -= 15.0 * delta
		if gf["timer"] > 0.0:
			remaining.append(gf)
	_gold_floats = remaining


func _draw_gold_floats(_vp: Vector2) -> void:
	var transform: Transform2D = _camera.get_canvas_transform()
	for gf in _gold_floats:
		var world_pos := Vector2(gf["x"], gf["y"])
		var screen_pos: Vector2 = transform * world_pos
		var alpha: float = gf["timer"] / gf["max_timer"]
		var text: String = "+%d" % gf["amount"]
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(screen_pos.x - 8, screen_pos.y),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.85, 0.3, alpha))


func _spawn_turret_beam(shop_pos: Vector2, target_pos: Vector2) -> void:
	_turret_beams.append({"from_x": shop_pos.x, "from_y": shop_pos.y,
		"to_x": target_pos.x, "to_y": target_pos.y, "timer": 0.3})


func _tick_turret_beams(delta: float) -> void:
	var remaining: Array = []
	for beam in _turret_beams:
		beam["timer"] -= delta
		if beam["timer"] > 0.0:
			remaining.append(beam)
	_turret_beams = remaining


func _draw_turret_beams() -> void:
	for beam in _turret_beams:
		var alpha: float = beam["timer"] / 0.3
		var from := Vector2(beam["from_x"], beam["from_y"])
		var to := Vector2(beam["to_x"], beam["to_y"])
		var steps: int = 12
		for s in steps:
			var t: float = float(s) / float(steps - 1)
			var p: Vector2 = from.lerp(to, t)
			var size: float = 1.0 if s == 0 or s == steps - 1 else 0.6
			_entity_node.draw_rect(Rect2(p.x - size * 0.5, p.y - size * 0.5, size, size),
				Color(1.0, 0.2, 0.1, alpha * 0.9))


func _draw_lobby() -> void:
	var vp: Vector2 = _hud_node.get_viewport_rect().size

	# Dark background
	_hud_node.draw_rect(Rect2(0, 0, vp.x, vp.y), Color(0.06, 0.07, 0.05))

	# Title
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x * 0.5 - 80.0, vp.y * 0.18),
		"PIXEL REALMS", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color(1.0, 0.85, 0.3))
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x * 0.5 - 65.0, vp.y * 0.18 + 18.0),
		"Battle Arena", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.65, 0.5))

	# Server card
	var card_w: float = 280.0
	var card_h: float = 180.0
	var card_x: float = vp.x * 0.5 - card_w * 0.5
	var card_y: float = vp.y * 0.5 - card_h * 0.5

	# Card background
	_hud_node.draw_rect(Rect2(card_x, card_y, card_w, card_h), Config.UI_BG)
	_hud_node.draw_rect(Rect2(card_x, card_y, card_w, card_h), Config.UI_BORDER, false, 2.0)

	# Card header bar
	_hud_node.draw_rect(Rect2(card_x, card_y, card_w, 28.0), Color(0.08, 0.09, 0.06, 0.9))
	_hud_node.draw_rect(Rect2(card_x, card_y + 28.0, card_w, 1.0), Config.UI_BORDER)

	# Map name
	var map_name: String = Config.MAP_NAMES[_lobby_map_index]
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(card_x + 12.0, card_y + 19.0),
		map_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Config.UI_TEXT)

	# Green dot (server status)
	var dot_col: Color = Color(0.3, 0.9, 0.3) if Net.my_player_index >= 0 else Color(0.6, 0.6, 0.4)
	_hud_node.draw_rect(Rect2(card_x + card_w - 18.0, card_y + 10.0, 8.0, 8.0), dot_col)

	# Player count
	var count_text: String = "Players: %d / 20" % _lobby_player_count
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(card_x + 12.0, card_y + 52.0),
		count_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Config.UI_TEXT_GOLD)

	# Player count progress bar
	var bar_x: float = card_x + 12.0
	var bar_y: float = card_y + 60.0
	var bar_w: float = card_w - 24.0
	var bar_h: float = 8.0
	var fill: float = float(_lobby_player_count) / 20.0
	_hud_node.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.1, 0.1, 0.08))
	_hud_node.draw_rect(Rect2(bar_x, bar_y, bar_w * fill, bar_h), Color(0.3, 0.7, 0.3))
	_hud_node.draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.3, 0.28, 0.2), false, 1.0)

	# Min players note
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(card_x + 12.0, card_y + 84.0),
		"Min 2 players to start", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.5, 0.48, 0.38))

	# Timer (only when assigned a slot)
	if Net.my_player_index >= 0:
		var secs: int = maxi(0, int(ceil(_lobby_timer)))
		var timer_text: String = "Starting in 0:%02d" % secs
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(card_x + 12.0, card_y + 104.0),
			timer_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.9, 0.85, 0.4))

	# Join button / status
	var btn_w: float = 160.0
	var btn_h: float = 30.0
	var btn_x: float = card_x + card_w * 0.5 - btn_w * 0.5
	var btn_y: float = card_y + card_h - btn_h - 16.0

	if Net.my_player_index < 0:
		# Pulsing join button (waiting for connection/assignment)
		var pulse: float = 0.8 + sin(float(Time.get_ticks_msec()) * 0.004) * 0.2
		_hud_node.draw_rect(Rect2(btn_x, btn_y, btn_w, btn_h), Color(0.2, 0.15, 0.05, 0.9))
		_hud_node.draw_rect(Rect2(btn_x, btn_y, btn_w, btn_h), Color(1.0, 0.85, 0.3, pulse), false, 2.0)
		var label: String = "Connecting..." if not _lobby_joined else "Joining..."
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(btn_x + 28.0, btn_y + 20.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.85, 0.3, pulse))
	else:
		_hud_node.draw_rect(Rect2(btn_x, btn_y, btn_w, btn_h), Color(0.1, 0.2, 0.1, 0.9))
		_hud_node.draw_rect(Rect2(btn_x, btn_y, btn_w, btn_h), Color(0.3, 0.7, 0.3), false, 1.5)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(btn_x + 18.0, btn_y + 20.0),
			"Joined! Waiting...", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.3, 0.9, 0.3))


func _draw_game_over() -> void:
	var vp: Vector2 = _hud_node.get_viewport_rect().size
	_hud_node.draw_rect(Rect2(0, 0, vp.x, vp.y), Color(0, 0, 0, 0.6))

	var winner_text: String
	if _winner_id == Net.my_player_index:
		winner_text = "YOU WIN!"
	else:
		winner_text = "Player %d wins!" % (_winner_id + 1)

	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x * 0.5 - 60, vp.y * 0.5 - 10),
		winner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1.0, 0.85, 0.2))
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(vp.x * 0.5 - 70, vp.y * 0.5 + 20),
		"Press R to restart", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Config.UI_TEXT)


func _draw_shop_arrows(vp: Vector2) -> void:
	var center: Vector2 = vp * 0.5
	var margin: float = 30.0
	var arrow_color := Color(0.9, 0.75, 0.3, 0.7)

	for shop in _shops:
		var dir: Vector2 = shop.position - _human.position
		var dist: float = dir.length()
		if dist < 1.0:
			continue
		dir = dir.normalized()

		# Project arrow to screen edge
		var ax: float = center.x + dir.x * (center.x - margin)
		var ay: float = center.y + dir.y * (center.y - margin)
		ax = clampf(ax, margin, vp.x - margin)
		ay = clampf(ay, margin, vp.y - margin)

		# Triangle arrow pointing toward shop
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		var tip: Vector2 = Vector2(ax, ay) + dir * 6.0
		var base_l: Vector2 = Vector2(ax, ay) - dir * 4.0 + perp * 4.0
		var base_r: Vector2 = Vector2(ax, ay) - dir * 4.0 - perp * 4.0
		_hud_node.draw_colored_polygon(PackedVector2Array([tip, base_l, base_r]), arrow_color)

		# Distance label
		var dist_text: String = "%dm" % int(dist)
		_hud_node.draw_string(ThemeDB.fallback_font, Vector2(ax - 8, ay + 16),
			dist_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, arrow_color)


func _draw_hill_arrow(vp: Vector2) -> void:
	if not _hill.active and _hill.get_activate_progress() < 0.5:
		return

	var dir: Vector2 = _hill.position - _human.position
	var dist: float = dir.length()
	if dist < 1.0:
		return
	dir = dir.normalized()

	var center: Vector2 = vp * 0.5
	var margin: float = 30.0
	var arrow_color := Color(1.0, 0.85, 0.2, 0.7)

	var ax: float = center.x + dir.x * (center.x - margin)
	var ay: float = center.y + dir.y * (center.y - margin)
	ax = clampf(ax, margin, vp.x - margin)
	ay = clampf(ay, margin, vp.y - margin)

	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var tip: Vector2 = Vector2(ax, ay) + dir * 6.0
	var base_l: Vector2 = Vector2(ax, ay) - dir * 4.0 + perp * 4.0
	var base_r: Vector2 = Vector2(ax, ay) - dir * 4.0 - perp * 4.0
	_hud_node.draw_colored_polygon(PackedVector2Array([tip, base_l, base_r]), arrow_color)

	var dist_text: String = "%dm" % int(dist)
	_hud_node.draw_string(ThemeDB.fallback_font, Vector2(ax - 8, ay + 16),
		dist_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, arrow_color)


# ===========================================================================
# Messages
# ===========================================================================

func _show_message(text: String, color: Color, duration: float = 2.0) -> void:
	for msg in _messages:
		if msg["text"] == text:
			msg["timer"] = duration
			msg["color"] = color
			return
	_messages.append({"text": text, "timer": duration, "duration": duration, "color": color})


func _tick_messages(delta: float) -> void:
	var remaining: Array = []
	for msg in _messages:
		msg["timer"] -= delta
		if msg["timer"] > 0.0:
			remaining.append(msg)
	_messages = remaining


# ===========================================================================
# Input events
# ===========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if Net.role == Net.Role.SERVER:
		return

	# Lobby: click to join
	if _game_state == GameState.LOBBY:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if not _lobby_joined:
				_lobby_joined = true
		return

	if not (event is InputEventKey and event.pressed):
		return

	var key: int = event.keycode

	# Restart
	if key == KEY_R and _game_over:
		get_tree().reload_current_scene()
		return

	if _human == null or not _human.alive:
		return

	# Shop toggle (client-side UI only)
	if key == KEY_E:
		if _shop_open:
			_shop_open = false
			_shop_ref = null
			_human.shop_open = false
		else:
			for shop in _shops:
				if shop.is_player_nearby(_human):
					_shop_open = true
					_shop_ref = shop
					_shop_tab = 0
					_human.shop_open = true
					_build_shop_list()
					break
		return

	# Tab cycles shop tabs
	if _shop_open and key == KEY_TAB:
		_shop_tab = (_shop_tab + 1) % 3
		_build_shop_list()
		return

	# Shop buy with number keys while open — send action to server
	if _shop_open and key >= KEY_1 and key <= KEY_9:
		var idx: int = key - KEY_1
		if idx < _shop_items.size():
			_try_buy_item(_shop_items[idx])
		return

	# Slot switching (send to server)
	if not _shop_open:
		if key == KEY_1:
			Net.client_send_action(var_to_bytes({"type": "switch_slot", "slot": 0}))
		elif key == KEY_2:
			Net.client_send_action(var_to_bytes({"type": "switch_slot", "slot": 1}))

	# Health potion (Q) — send to server
	if key == KEY_Q and not _shop_open:
		Net.client_send_action(var_to_bytes({"type": "use_health_potion"}))
		return

	# Speed / Shield potion (F) — send to server
	if key == KEY_F and not _shop_open:
		if _human.speed_potions > 0:
			Net.client_send_action(var_to_bytes({"type": "use_speed_potion"}))
		elif _human.shield_potions > 0:
			Net.client_send_action(var_to_bytes({"type": "use_shield_potion"}))
		return


func _build_shop_list() -> void:
	_shop_items.clear()
	if _shop_ref == null:
		return
	match _shop_tab:
		0:  # Equipment
			var weapons: Array = []
			var bows: Array = []
			var armors: Array = []
			for item_id: String in _shop_ref.get_equipment_list():
				var info: Dictionary = Config.EQUIPMENT[item_id]
				var slot: int = info.get("slot", -1)
				match slot:
					Config.EquipSlot.WEAPON:
						weapons.append(item_id)
					Config.EquipSlot.BOW:
						bows.append(item_id)
					Config.EquipSlot.ARMOR:
						armors.append(item_id)
			_shop_items = weapons + bows + armors
		1:  # Supplies
			_shop_items = _shop_ref.get_consumable_list()
		2:  # Skills
			_shop_items = _shop_ref.get_skill_list()


func _flash_shop_item(item_id: String) -> void:
	for i in _shop_items.size():
		if _shop_items[i] == item_id:
			_shop_flash_idx = i
			_shop_flash_timer = 0.3
			return

func _try_buy_item(item_id: String) -> void:
	# Client sends buy action to server; server validates and processes
	match _shop_tab:
		0:  # Equipment
			Net.client_send_action(var_to_bytes({"type": "buy_equip", "item_id": item_id}))
			_flash_shop_item(item_id)
		1:  # Consumables
			Net.client_send_action(var_to_bytes({"type": "buy_consumable", "item_id": item_id}))
			_flash_shop_item(item_id)
		2:  # Skills
			Net.client_send_action(var_to_bytes({"type": "buy_skill", "skill_id": item_id}))
			_flash_shop_item(item_id)


# ===========================================================================
# Network signal handlers
# ===========================================================================

func _on_net_game_start(seed_val: int, map_index: int, my_index: int, _total_humans: int) -> void:
	_lobby_map_index = map_index
	_start_game_client(seed_val, my_index)


func _on_state_received(snapshot: PackedByteArray) -> void:
	_apply_snapshot(snapshot)


func _on_input_received(peer_id: int, input_data: PackedByteArray) -> void:
	_pending_inputs[peer_id] = input_data


func _on_action_received(peer_id: int, action_data: PackedByteArray) -> void:
	_pending_actions.append({"peer_id": peer_id, "data": action_data})


func _on_game_event(event_data: PackedByteArray) -> void:
	_handle_game_event(event_data)


func _on_lobby_updated(player_count: int, timer: float, map_index: int) -> void:
	_lobby_player_count = player_count
	_lobby_timer = timer
	_lobby_map_index = map_index


# ===========================================================================
# Server: input & action processing
# ===========================================================================

func _apply_pending_inputs(_delta: float) -> void:
	for peer_id: int in _pending_inputs:
		var data: PackedByteArray = _pending_inputs[peer_id]
		var input: Dictionary = bytes_to_var(data)
		var player_idx: int = Net.peer_to_player.get(peer_id, -1)
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
		var player_idx: int = Net.peer_to_player.get(peer_id, -1)
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
# Server: state snapshot broadcast
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

	var snapshot: Dictionary = {
		"t": _game_time,
		"p": player_data,
		"m": mob_data,
		"pr": proj_data,
		"h": {
			"a": _hill.active,
			"gt": _hill.game_timer,
			"cp": _hill.capturing_player,
			"cprog": _hill.capture_progress,
			"hp": _hill.holding_player,
			"ht": _hill.hold_timer,
		},
	}

	Net.server_send_snapshot(var_to_bytes(snapshot))


# ===========================================================================
# Client: apply state snapshot
# ===========================================================================

func _apply_snapshot(data: PackedByteArray) -> void:
	var snapshot: Dictionary = bytes_to_var(data)
	if snapshot.is_empty():
		return

	_game_time = snapshot.get("t", 0.0)

	# Update players
	var player_data: Array = snapshot.get("p", [])
	for pd: Dictionary in player_data:
		var idx: int = pd.get("id", -1)
		if idx < 0 or idx >= _players.size():
			continue
		var player: Player = _players[idx]
		player.position = Vector2(pd.get("x", 0.0), pd.get("y", 0.0))
		player.hp = pd.get("hp", 0.0)
		player.max_hp = pd.get("max_hp", 100.0)
		player.gold = pd.get("gold", 0)
		player.alive = pd.get("alive", true)
		player.respawn_timer = pd.get("rt", 0.0)
		player.weapon = pd.get("weapon", "")
		player.bow = pd.get("bow", "")
		player.armor = pd.get("armor", "")
		player.active_slot = pd.get("slot", 0)
		player.arrows = pd.get("arrows", 0)
		player.health_potions = pd.get("hpot", 0)
		player.speed_potions = pd.get("spot", 0)
		player.shield_potions = pd.get("shpot", 0)
		player.facing_dir = Vector2(pd.get("fx", 1.0), pd.get("fy", 0.0))
		player.is_attacking = pd.get("atk", false)
		player.speed_buff_timer = pd.get("spd_t", 0.0)
		player.shield_buff_timer = pd.get("shd_t", 0.0)
		player.skills = pd.get("skills", {})

	# Update mobs — reconcile with existing mob objects
	var mob_data: Array = snapshot.get("m", [])
	var seen_ids: Dictionary = {}
	for md: Dictionary in mob_data:
		var mid: int = md.get("mid", -1)
		seen_ids[mid] = true
		if _mob_by_id.has(mid):
			var mob: Mob = _mob_by_id[mid]
			mob.position = Vector2(md.get("x", 0.0), md.get("y", 0.0))
			mob.hp = md.get("hp", 0.0)
			mob.max_hp = md.get("mhp", 0.0)
			mob.alive = true
		else:
			# New mob — create it
			var mob := Mob.new()
			mob.mob_id = mid
			mob.mob_type = md.get("type", 0)
			mob.position = Vector2(md.get("x", 0.0), md.get("y", 0.0))
			mob.hp = md.get("hp", 0.0)
			mob.max_hp = md.get("mhp", 0.0)
			mob.alive = true
			_mobs.append(mob)
			_mob_by_id[mid] = mob
			add_child(mob)

	# Remove mobs that are no longer in snapshot
	var to_remove: Array = []
	for mob in _mobs:
		if not seen_ids.has(mob.mob_id):
			to_remove.append(mob)
	for mob in to_remove:
		_mobs.erase(mob)
		_mob_by_id.erase(mob.mob_id)
		mob.queue_free()

	# Update projectiles — replace all
	for proj in _projectiles:
		proj.queue_free()
	_projectiles.clear()
	var proj_data: Array = snapshot.get("pr", [])
	for ppd: Dictionary in proj_data:
		var proj := Projectile.new()
		proj.position = Vector2(ppd.get("x", 0.0), ppd.get("y", 0.0))
		proj.direction = Vector2(ppd.get("dx", 0.0), ppd.get("dy", 0.0))
		proj.owner_id = ppd.get("oid", -1)
		proj.alive = true
		_projectiles.append(proj)
		add_child(proj)

	# Update hill
	var hill_data: Dictionary = snapshot.get("h", {})
	_hill.active = hill_data.get("a", false)
	_hill.game_timer = hill_data.get("gt", 0.0)
	_hill.capturing_player = hill_data.get("cp", -1)
	_hill.capture_progress = hill_data.get("cprog", 0.0)
	_hill.holding_player = hill_data.get("hp", -1)
	_hill.hold_timer = hill_data.get("ht", 0.0)


# ===========================================================================
# Client: send input to server
# ===========================================================================

func _send_input_to_server() -> void:
	if _human == null or not _human.alive:
		Net.client_send_input(var_to_bytes({"move_x": 0.0, "move_y": 0.0, "attack": false}))
		return

	var move_x: float = 0.0
	var move_y: float = 0.0
	if Input.is_action_pressed("ui_left"):
		move_x -= 1.0
	if Input.is_action_pressed("ui_right"):
		move_x += 1.0
	if Input.is_action_pressed("ui_up"):
		move_y -= 1.0
	if Input.is_action_pressed("ui_down"):
		move_y += 1.0

	var do_attack: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _shop_open
	var attack_x: float = 0.0
	var attack_y: float = 0.0
	if do_attack:
		var screen_pos: Vector2 = get_viewport().get_mouse_position()
		var world_pos: Vector2 = _camera.screen_to_world(screen_pos)
		attack_x = world_pos.x
		attack_y = world_pos.y

	var input: Dictionary = {
		"move_x": move_x,
		"move_y": move_y,
		"attack": do_attack,
		"attack_x": attack_x,
		"attack_y": attack_y,
	}

	Net.client_send_input(var_to_bytes(input))


# ===========================================================================
# Server: game event broadcast
# ===========================================================================

func _broadcast_game_event(event: Dictionary) -> void:
	if Net.role != Net.Role.SERVER:
		return
	Net.server_send_event(var_to_bytes(event))


# ===========================================================================
# Client: handle game events
# ===========================================================================

func _handle_game_event(event_data: PackedByteArray) -> void:
	var event: Dictionary = bytes_to_var(event_data)
	var event_type: String = event.get("type", "")
	match event_type:
		"player_killed":
			var pos_x: float = event.get("x", 0.0)
			var pos_y: float = event.get("y", 0.0)
			var pos := Vector2(pos_x, pos_y)
			_spawn_particles(pos, randi_range(10, 15), Color(0.9, 0.15, 0.1), 35.0, 0.6)
			var stolen: int = event.get("gold_stolen", 0)
			if stolen > 0:
				_spawn_gold_float(pos, stolen)
		"mob_killed":
			var pos_x: float = event.get("x", 0.0)
			var pos_y: float = event.get("y", 0.0)
			var mob_type: int = event.get("mob_type", 0)
			var gold_val: int = event.get("gold", 0)
			var pos := Vector2(pos_x, pos_y)
			var mob_color: Color
			match mob_type:
				Config.MobType.SLIME:
					mob_color = Color(0.3, 0.8, 0.3)
				Config.MobType.SKELETON:
					mob_color = Color(0.85, 0.85, 0.8)
				Config.MobType.KNIGHT:
					mob_color = Color(0.55, 0.45, 0.55)
				_:
					mob_color = Color(0.8, 0.3, 0.3)
			_spawn_particles(pos, randi_range(8, 12), mob_color, 25.0, 0.5)
			_spawn_particles(pos, randi_range(3, 5), Color(1.0, 0.85, 0.3), 15.0, 0.4)
			if gold_val > 0:
				_spawn_gold_float(pos, gold_val)
		"turret_fire":
			var from_pos := Vector2(event.get("from_x", 0.0), event.get("from_y", 0.0))
			var to_pos := Vector2(event.get("to_x", 0.0), event.get("to_y", 0.0))
			_spawn_turret_beam(from_pos, to_pos)
			_spawn_particles(to_pos, 15, Color(1.0, 0.2, 0.1), 40.0, 0.5)
			_spawn_particles(from_pos, 10, Color(1.0, 0.5, 0.1), 30.0, 0.4)
			_show_message("Shop turret fires!", Color(1.0, 0.3, 0.2), 2.0)
		"hit":
			var pos := Vector2(event.get("x", 0.0), event.get("y", 0.0))
			_spawn_particles(pos, randi_range(5, 8), Color(1.0, 0.95, 0.7), 30.0, 0.3)
		"game_over":
			var winner: int = event.get("winner_id", -1)
			_winner_id = winner
			_game_over = true
			_game_state = GameState.GAME_OVER
