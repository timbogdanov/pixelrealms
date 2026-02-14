class_name Mob
extends Node2D

signal died(mob: Mob)

var mob_id: int = 0
var mob_type: int = Config.MobType.SLIME
var hp: float = 15.0
var max_hp: float = 15.0
var gold_reward: int = 2
var damage: float = 3.0
var speed: float = 25.0
var aggro_range: float = 40.0
var attack_range: float = 12.0
var attack_cooldown_time: float = 1.0

var alive: bool = true
var spawn_pos: Vector2
var target: Node2D = null  # player being chased
var velocity: Vector2 = Vector2.ZERO
var attack_cooldown: float = 0.0
var wander_target: Vector2 = Vector2.ZERO
var wander_timer: float = 0.0

var map_generator: Node2D = null

func init(type: int, pos: Vector2, map: Node2D) -> void:
	mob_type = type
	position = pos
	spawn_pos = pos
	map_generator = map
	var stats: Dictionary = Config.MOB_STATS[type]
	hp = stats["hp"]
	max_hp = stats["hp"]
	gold_reward = stats["gold"]
	damage = stats["damage"]
	speed = stats["speed"]
	aggro_range = stats["aggro_range"]
	attack_range = stats["attack_range"]
	attack_cooldown_time = stats["attack_cooldown"]
	wander_target = pos
	alive = true

func process_ai(delta: float, players: Array, shops: Array) -> void:
	if not alive:
		return

	attack_cooldown = maxf(0.0, attack_cooldown - delta)

	# Find nearest alive player in aggro range (skip safe-zone players)
	var nearest: Node2D = null
	var nearest_dist := aggro_range
	for player in players:
		if not is_instance_valid(player) or not player.alive:
			continue
		# Skip players in safe zones
		var in_safe: bool = false
		for shop in shops:
			if player.position.distance_to(shop.position) <= Config.SHOP_SAFE_RADIUS:
				in_safe = true
				break
		if in_safe:
			continue
		var d := position.distance_to(player.position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = player

	# Leash check: return to spawn if too far
	if position.distance_to(spawn_pos) > Config.MOB_LEASH_RADIUS:
		nearest = null
		target = null

	if nearest != null:
		target = nearest
		# Move toward target
		var dir := (target.position - position).normalized()
		var terrain_speed := 1.0
		if map_generator:
			terrain_speed = map_generator.get_speed_mult(Vector2i(int(position.x), int(position.y)))
		velocity = dir * speed * terrain_speed

		# Attack if in range
		if nearest_dist <= attack_range and attack_cooldown <= 0.0:
			attack_cooldown = attack_cooldown_time
			if is_instance_valid(target) and target.has_method("take_damage"):
				target.take_damage(damage)
				# Knockback
				if target.has_method("apply_knockback"):
					target.apply_knockback(dir, Config.KNOCKBACK_FORCE * 0.5)
	else:
		target = null
		# Wander
		wander_timer -= delta
		if wander_timer <= 0.0:
			wander_timer = randf_range(2.0, 5.0)
			var angle := randf() * TAU
			var dist := randf_range(10.0, Config.MOB_WANDER_RADIUS)
			wander_target = spawn_pos + Vector2(cos(angle), sin(angle)) * dist
		var to_wander := wander_target - position
		if to_wander.length() > 2.0:
			velocity = to_wander.normalized() * speed * 0.4
		else:
			velocity = Vector2.ZERO

	# Apply movement
	var new_pos := position + velocity * delta
	var new_pos_i := Vector2i(int(new_pos.x), int(new_pos.y))
	if map_generator and map_generator.is_walkable(new_pos_i):
		position = new_pos
	else:
		velocity = Vector2.ZERO

func take_damage(amount: float) -> void:
	if not alive:
		return
	hp -= amount
	if hp <= 0.0:
		hp = 0.0
		alive = false
		died.emit(self)

func apply_knockback(direction: Vector2, force: float) -> void:
	position += direction * force * 0.1
