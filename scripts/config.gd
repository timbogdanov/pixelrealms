extends Node

# --- Map ---
const MAP_WIDTH := 800
const MAP_HEIGHT := 600
const TILE_SIZE := 1
const MAP_NAMES := ["United States", "Canada", "Europe"]

# --- Terrain ---
enum Terrain { WATER, SHALLOW_WATER, GRASS, FOREST, HILL, STONE, PATH }

const TERRAIN_COLORS := {
	Terrain.WATER: Color(0.18, 0.32, 0.58),
	Terrain.SHALLOW_WATER: Color(0.25, 0.42, 0.65),
	Terrain.GRASS: Color(0.35, 0.55, 0.25),
	Terrain.FOREST: Color(0.20, 0.38, 0.16),
	Terrain.HILL: Color(0.50, 0.48, 0.35),
	Terrain.STONE: Color(0.45, 0.44, 0.42),
	Terrain.PATH: Color(0.55, 0.48, 0.32),
}

# Terrain speed multipliers (1.0 = full speed)
const TERRAIN_SPEED := {
	Terrain.WATER: 0.15,
	Terrain.SHALLOW_WATER: 0.3,
	Terrain.GRASS: 1.0,
	Terrain.FOREST: 0.6,
	Terrain.HILL: 0.7,
	Terrain.STONE: 0.4,
	Terrain.PATH: 1.2,
}

# --- Players ---
const NUM_PLAYERS := 20
const PLAYER_COLORS := [
	Color(0.2, 0.5, 0.9),   # 0 Blue
	Color(0.9, 0.25, 0.2),  # 1 Red
	Color(0.2, 0.8, 0.3),   # 2 Green
	Color(0.9, 0.7, 0.1),   # 3 Yellow
	Color(0.8, 0.3, 0.8),   # 4 Purple
	Color(0.1, 0.8, 0.8),   # 5 Cyan
	Color(0.9, 0.5, 0.1),   # 6 Orange
	Color(0.6, 0.3, 0.1),   # 7 Brown
	Color(0.9, 0.4, 0.6),   # 8 Pink
	Color(0.5, 0.8, 0.5),   # 9 Light Green
	Color(0.4, 0.4, 0.9),   # 10 Indigo
	Color(0.9, 0.9, 0.3),   # 11 Gold
	Color(0.3, 0.6, 0.6),   # 12 Teal
	Color(0.7, 0.4, 0.3),   # 13 Rust
	Color(0.6, 0.6, 0.8),   # 14 Lavender
	Color(0.8, 0.6, 0.3),   # 15 Tan
	Color(0.4, 0.7, 0.3),   # 16 Forest
	Color(0.7, 0.3, 0.5),   # 17 Maroon
	Color(0.5, 0.5, 0.5),   # 18 Gray
	Color(0.9, 0.8, 0.7),   # 19 Cream
]
const PLAYER_SPEED := 35.0   # pixels/sec base speed (upgrade via Swift Feet)
const PLAYER_MAX_HP := 200.0  # base max HP (upgrade via Vitality)
const PLAYER_VISION := 35.0  # fog-of-war reveal radius (upgrade via Eagle Eye)
const PLAYER_START_GOLD := 0
const PLAYER_RESPAWN_TIME := 3.0
const PLAYER_RESPAWN_GOLD_PENALTY := 0.3  # lose 30% gold on death
const PLAYER_KILL_GOLD_STEAL := 0.5       # steal 50% of victim's gold

# --- Equipment ---
enum EquipSlot { WEAPON, BOW, ARMOR }

const EQUIPMENT := {
	# Weapons (melee)
	"wooden_sword":  { "slot": EquipSlot.WEAPON, "tier": 1, "damage": 25.0, "cost": 0,  "name": "Wooden Sword",  "cooldown": 0.5, "range": 20.0 },
	"iron_sword":    { "slot": EquipSlot.WEAPON, "tier": 2, "damage": 32.0, "cost": 30, "name": "Iron Sword",    "cooldown": 0.45, "range": 22.0 },
	"steel_sword":   { "slot": EquipSlot.WEAPON, "tier": 3, "damage": 40.0, "cost": 80, "name": "Steel Sword",   "cooldown": 0.4, "range": 24.0 },
	# Bows (ranged)
	"short_bow":     { "slot": EquipSlot.BOW, "tier": 1, "damage": 15.0, "cost": 15, "name": "Short Bow",     "cooldown": 0.8, "range": 100.0, "speed": 200.0 },
	"long_bow":      { "slot": EquipSlot.BOW, "tier": 2, "damage": 25.0, "cost": 50, "name": "Long Bow",      "cooldown": 0.7, "range": 140.0, "speed": 250.0 },
	"crossbow":      { "slot": EquipSlot.BOW, "tier": 3, "damage": 40.0, "cost": 100, "name": "Crossbow",     "cooldown": 1.0, "range": 160.0, "speed": 300.0 },
	# Armor
	"leather":       { "slot": EquipSlot.ARMOR, "tier": 1, "dr": 0.10, "cost": 20,  "name": "Leather Armor" },
	"chainmail":     { "slot": EquipSlot.ARMOR, "tier": 2, "dr": 0.25, "cost": 60,  "name": "Chainmail" },
	"plate":         { "slot": EquipSlot.ARMOR, "tier": 3, "dr": 0.40, "cost": 120, "name": "Plate Armor" },
}

# --- Consumables ---
const CONSUMABLES := {
	"arrow_10":       { "name": "Arrow Pack (10)",  "cost": 5,  "type": "arrows",  "amount": 10 },
	"arrow_30":       { "name": "Arrow Bundle (30)", "cost": 12, "type": "arrows",  "amount": 30 },
	"health_potion":  { "name": "Health Potion",    "cost": 8,  "type": "potion",  "subtype": "health", "max_carry": 5 },
	"speed_potion":   { "name": "Speed Elixir",     "cost": 15, "type": "potion",  "subtype": "speed",  "max_carry": 3 },
	"shield_potion":  { "name": "Shield Draught",   "cost": 12, "type": "potion",  "subtype": "shield", "max_carry": 3 },
}

const POTION_HEAL_AMOUNT := 30.0
const SPEED_POTION_MULT := 1.5
const SPEED_POTION_DURATION := 10.0
const SHIELD_POTION_DR := 0.30
const SHIELD_POTION_DURATION := 8.0

# --- Skills (each level: [cost, value]) ---
const SKILLS := {
	"swift_feet":   { "name": "Swift Feet",   "desc": "Move speed",   "levels": [[8, 0.15], [22, 0.30], [45, 0.50]] },
	"regeneration": { "name": "Regeneration",  "desc": "HP/sec regen", "levels": [[12, 0.5],  [35, 1.0],  [70, 2.0]] },
	"vitality":     { "name": "Vitality",      "desc": "Max HP bonus", "levels": [[10, 20.0], [30, 50.0], [60, 100.0]] },
	"eagle_eye":    { "name": "Eagle Eye",     "desc": "Vision range", "levels": [[8, 30.0], [18, 60.0], [38, 100.0]] },
	"gold_rush":    { "name": "Gold Rush",     "desc": "Mob gold +%",  "levels": [[20, 0.15], [50, 0.30], [90, 0.50]] },
	"quick_draw":   { "name": "Quick Draw",    "desc": "Attack CD -%", "levels": [[15, 0.10], [40, 0.20], [75, 0.35]] },
}

# --- Combat ---
const MELEE_ARC := 90.0         # degrees of swing arc
const KNOCKBACK_FORCE := 60.0   # pixels
const ATTACK_COOLDOWN_MULT := 1.0
const BOT_MELEE_RANGE_MULT := 0.6  # bots must be closer to land melee hits

# --- Mobs ---
enum MobType { SLIME, SKELETON, KNIGHT, BANDIT }

const MOB_STATS := {
	MobType.SLIME:    { "name": "Slime",    "hp": 15.0,  "damage": 3.0,  "speed": 25.0, "gold": 1,  "aggro_range": 40.0, "attack_range": 12.0, "attack_cooldown": 1.0 },
	MobType.SKELETON: { "name": "Skeleton", "hp": 35.0,  "damage": 6.0,  "speed": 35.0, "gold": 4,  "aggro_range": 60.0, "attack_range": 14.0, "attack_cooldown": 0.8 },
	MobType.KNIGHT:   { "name": "Knight",   "hp": 80.0,  "damage": 12.0, "speed": 30.0, "gold": 10, "aggro_range": 70.0, "attack_range": 16.0, "attack_cooldown": 0.7 },
	MobType.BANDIT:   { "name": "Bandit",   "hp": 50.0,  "damage": 8.0,  "speed": 40.0, "gold": 8,  "aggro_range": 65.0, "attack_range": 14.0, "attack_cooldown": 0.7 },
}
const MOB_RESPAWN_TIME := 15.0  # seconds
const MOB_WANDER_RADIUS := 40.0
const MOB_LEASH_RADIUS := 80.0  # return to spawn if too far

# --- King of the Hill ---
const HILL_RADIUS := 30.0           # pixels, capture zone radius
const HILL_CAPTURE_TIME := 10.0     # seconds to capture
const HILL_HOLD_TIME := 45.0        # seconds to win after capture
const HILL_ACTIVATE_TIME := 300.0   # 5 minutes before Hill activates
const MOUNTAIN_STONE_RADIUS := 25.0   # STONE peak radius in pixels
const MOUNTAIN_TOTAL_RADIUS := 90.0   # Total mountain radius (STONE + HILL slopes)

# --- Shops ---
const SHOP_INTERACT_RADIUS := 25.0
const SHOP_SAFE_RADIUS := 35.0    # safe zone radius (slightly larger than interact)
const SAFE_ZONE_REGEN := 5.0     # HP/sec while in safe zone
const SHOP_MIN_DIST_FROM_HILL := 150.0
const SHOP_MIN_DIST_APART := 100.0
const MOB_MIN_DIST_FROM_SHOP := 60.0
const PLAYER_SPAWN_MIN_DIST_FROM_SHOP := 30.0

# --- Pickups ---
enum PickupType { GOLD, HEALTH_POTION }
const PICKUP_DESPAWN_TIME := 15.0
const PICKUP_COLLECT_RADIUS := 8.0
const DEATH_GOLD_DROP_FRACTION := 0.25
const RARE_DROP_GOLD_CHANCE := 0.05
const RARE_DROP_GOLD_MULT_MIN := 2.0
const RARE_DROP_GOLD_MULT_MAX := 3.0
const RARE_DROP_POTION_CHANCE := 0.03

# --- Bounty ---
const BOUNTY_KILL_STREAK := 3
const BOUNTY_GOLD_THRESHOLD := 50
const BOUNTY_PULSE_INTERVAL := 12.0
const BOUNTY_PULSE_DURATION := 1.5
const BOUNTY_KILL_BONUS_PER_STREAK := 5
const BOUNTY_GOLD_BONUS_FRACTION := 0.10

# --- Fog of War ---
const FOG_COLOR := Color(0, 0, 0, 0.85)

# --- Network ---
const SERVER_PORT := 9090
const SERVER_URL := "wss://pixelrealms.io/ws"
const SNAPSHOT_RATE := 20  # Hz
const LOBBY_TIMER := 60.0
const MIN_PLAYERS_TO_START := 1
const LOBBY_WS_PORT := 9091
const GAME_LOAD_LEAD_TIME := 15.0  # seconds before timer=0 to tell HTML clients to load Godot

# --- UI ---
const UI_BG := Color(0.12, 0.14, 0.10, 0.85)
const UI_BORDER := Color(0.45, 0.40, 0.25, 0.9)
const UI_TEXT := Color(0.9, 0.88, 0.78)
const UI_TEXT_GOLD := Color(1.0, 0.85, 0.3)
