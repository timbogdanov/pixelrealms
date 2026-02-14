extends Camera2D

var target: Node2D = null

func _ready() -> void:
	zoom = Vector2(5.0, 5.0)

func _physics_process(_delta: float) -> void:
	if target and is_instance_valid(target):
		position = target.position

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = (zoom * 1.15).clampf(1.0, 10.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = (zoom / 1.15).clampf(1.0, 10.0)

func screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * screen_pos
