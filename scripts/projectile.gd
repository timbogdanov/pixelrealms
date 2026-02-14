class_name Projectile
extends Node2D

var direction: Vector2 = Vector2.RIGHT
var speed: float = 200.0
var damage: float = 4.0
var owner_id: int = -1
var lifetime: float = 2.0
var alive: bool = true

func init(pos: Vector2, dir: Vector2, spd: float, dmg: float, pid: int) -> void:
	position = pos
	direction = dir.normalized()
	speed = spd
	damage = dmg
	owner_id = pid
	alive = true
	lifetime = 2.0

func process_projectile(delta: float) -> void:
	if not alive:
		return
	position += direction * speed * delta
	lifetime -= delta
	if lifetime <= 0.0:
		alive = false
	# Bounds check
	if position.x < 0 or position.x >= Config.MAP_WIDTH or position.y < 0 or position.y >= Config.MAP_HEIGHT:
		alive = false

func hit() -> void:
	alive = false
