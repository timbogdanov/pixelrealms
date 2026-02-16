extends Camera2D

var target: Node2D = null
var _shake_intensity: float = 0.0

func _ready() -> void:
	zoom = Vector2(5.0, 5.0)

func _physics_process(delta: float) -> void:
	if target and is_instance_valid(target):
		position = target.position
	# Screen shake
	if _shake_intensity > 0.1:
		_shake_intensity = lerpf(_shake_intensity, 0.0, 8.0 * delta)
		offset = Vector2(randf_range(-_shake_intensity, _shake_intensity),
			randf_range(-_shake_intensity, _shake_intensity))
	elif _shake_intensity > 0.0:
		_shake_intensity = 0.0
		offset = Vector2.ZERO

func apply_shake(intensity: float) -> void:
	_shake_intensity = maxf(_shake_intensity, intensity)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = (zoom * 1.15).clampf(0.5, 10.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = (zoom / 1.15).clampf(0.5, 10.0)

func screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * screen_pos
