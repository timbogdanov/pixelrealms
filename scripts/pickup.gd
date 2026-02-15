class_name Pickup
extends Node2D

var pickup_id: int = 0
var pickup_type: int = Config.PickupType.GOLD
var amount: int = 0
var despawn_timer: float = Config.PICKUP_DESPAWN_TIME
var alive: bool = true


func init(id: int, type: int, pos: Vector2, amt: int) -> void:
	pickup_id = id
	pickup_type = type
	position = pos
	amount = amt
	alive = true
	despawn_timer = Config.PICKUP_DESPAWN_TIME


func process_pickup(delta: float) -> void:
	if not alive:
		return
	despawn_timer -= delta
	if despawn_timer <= 0.0:
		alive = false
