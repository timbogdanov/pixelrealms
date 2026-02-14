class_name Shop
extends Node2D

var shop_id: int = 0

func init(id: int, pos: Vector2) -> void:
	shop_id = id
	position = pos

func get_equipment_list() -> Array:
	## Returns all purchasable equipment IDs (cost > 0).
	var result: Array = []
	for key: String in Config.EQUIPMENT:
		var info: Dictionary = Config.EQUIPMENT[key]
		var cost: int = info.get("cost", 0)
		if cost > 0:
			result.append(key)
	return result

func get_consumable_list() -> Array:
	## Returns all consumable IDs.
	var result: Array = []
	for key: String in Config.CONSUMABLES:
		result.append(key)
	return result

func get_skill_list() -> Array:
	## Returns all skill IDs.
	var result: Array = []
	for key: String in Config.SKILLS:
		result.append(key)
	return result

func get_available_items(player: Player) -> Array:
	## Returns items the player can buy (affordable + upgrade) — used by bot AI.
	var available: Array = []
	# Equipment upgrades
	for item_id: String in Config.EQUIPMENT:
		var stats: Dictionary = Config.EQUIPMENT[item_id]
		var cost: int = stats["cost"]
		if cost <= 0 or cost > player.gold:
			continue
		var slot: int = stats["slot"]
		var tier: int = stats["tier"]
		var current_tier := 0
		match slot:
			Config.EquipSlot.WEAPON:
				if player.weapon != "":
					var cur: Dictionary = Config.EQUIPMENT[player.weapon]
					current_tier = cur["tier"]
			Config.EquipSlot.BOW:
				if player.bow != "":
					var cur: Dictionary = Config.EQUIPMENT[player.bow]
					current_tier = cur["tier"]
			Config.EquipSlot.ARMOR:
				if player.armor != "":
					var cur: Dictionary = Config.EQUIPMENT[player.armor]
					current_tier = cur["tier"]
		if tier > current_tier:
			available.append(item_id)
	# Affordable consumables
	for item_id: String in Config.CONSUMABLES:
		var info: Dictionary = Config.CONSUMABLES[item_id]
		var cost: int = info.get("cost", 0)
		if cost <= player.gold:
			available.append(item_id)
	# Affordable next-level skills
	for skill_id: String in Config.SKILLS:
		var info: Dictionary = Config.SKILLS[skill_id]
		var levels: Array = info["levels"]
		var current_level: int = player.get_skill_level(skill_id)
		if current_level < levels.size():
			var level_data: Array = levels[current_level]
			var cost: int = level_data[0]
			if cost <= player.gold:
				available.append(skill_id)
	return available

func is_player_nearby(player: Player) -> bool:
	return position.distance_to(player.position) <= Config.SHOP_INTERACT_RADIUS
