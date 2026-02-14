class_name Hill
extends Node2D

signal captured(player_id: int)
signal won(player_id: int)

var radius: float = Config.HILL_RADIUS
var active: bool = false
var game_timer: float = 0.0

# Capture state
var capturing_player: int = -1
var capture_progress: float = 0.0  # 0 to HILL_CAPTURE_TIME

# Hold state
var holding_player: int = -1
var hold_timer: float = 0.0  # 0 to HILL_HOLD_TIME

func init(pos: Vector2) -> void:
	position = pos
	active = false
	capturing_player = -1
	capture_progress = 0.0
	holding_player = -1
	hold_timer = 0.0
	game_timer = 0.0

func process_hill(delta: float, players: Array) -> void:
	game_timer += delta

	# Hill activates after HILL_ACTIVATE_TIME
	if not active:
		if game_timer >= Config.HILL_ACTIVATE_TIME:
			active = true
		return

	# Find which players are on the hill
	var players_on_hill: Array = []
	for player in players:
		if not is_instance_valid(player) or not player.alive:
			continue
		if position.distance_to(player.position) <= radius:
			players_on_hill.append(player)

	# If someone is holding the hill
	if holding_player >= 0:
		# Check if holder is still on the hill and alive
		var holder_present := false
		for player in players_on_hill:
			if player.player_id == holding_player:
				holder_present = true
				break
		if holder_present:
			# Check if enemies are also on the hill (contested)
			var contested := false
			for player in players_on_hill:
				if player.player_id != holding_player:
					contested = true
					break
			if not contested:
				hold_timer += delta
				if hold_timer >= Config.HILL_HOLD_TIME:
					won.emit(holding_player)
			# If contested, hold timer pauses (doesn't reset)
		else:
			# Holder left or died — reset
			holding_player = -1
			hold_timer = 0.0
			capture_progress = 0.0
			capturing_player = -1
		return

	# No one holding — check for capture
	if players_on_hill.size() == 0:
		# No one on hill — reset capture
		capture_progress = 0.0
		capturing_player = -1
		return

	if players_on_hill.size() == 1:
		var player: Player = players_on_hill[0]
		if capturing_player == player.player_id:
			capture_progress += delta
			if capture_progress >= Config.HILL_CAPTURE_TIME:
				holding_player = player.player_id
				hold_timer = 0.0
				captured.emit(player.player_id)
		else:
			# New player capturing
			capturing_player = player.player_id
			capture_progress = 0.0
	else:
		# Multiple players — contested, no progress
		capture_progress = 0.0
		capturing_player = -1

func get_activate_progress() -> float:
	if active:
		return 1.0
	return clampf(game_timer / Config.HILL_ACTIVATE_TIME, 0.0, 1.0)

func get_capture_progress() -> float:
	return clampf(capture_progress / Config.HILL_CAPTURE_TIME, 0.0, 1.0)

func get_hold_progress() -> float:
	return clampf(hold_timer / Config.HILL_HOLD_TIME, 0.0, 1.0)
