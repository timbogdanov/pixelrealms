extends Node

# ---------------------------------------------------------------------------
# NetworkManager — Autoloaded as "Net"
# Handles WebSocket server/client, peer tracking, RPCs
# ---------------------------------------------------------------------------

enum Role { NONE, SERVER, CLIENT }
var role: int = Role.NONE

# Server state
var connected_peers: Array[int] = []
var peer_to_player: Dictionary = {}   # peer_id -> player_index
var player_to_peer: Dictionary = {}   # player_index -> peer_id
var _next_player_slot: int = 0

# Client state
var my_player_index: int = -1
var server_url: String = ""

# Lobby state (server-authoritative)
var lobby_player_count: int = 0
var lobby_timer: float = 60.0
var lobby_map_index: int = 0
var lobby_started: bool = false

# Signals for main.gd
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal lobby_updated(player_count: int, timer: float, map_index: int)
signal game_starting(seed_val: int, map_index: int, my_index: int, total_humans: int)
signal state_snapshot_received(snapshot: PackedByteArray)
signal input_received(peer_id: int, input_data: PackedByteArray)
signal action_received(peer_id: int, action_data: PackedByteArray)
signal game_event_received(event_data: PackedByteArray)


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var is_server: bool = false
	for arg in args:
		if arg == "--server":
			is_server = true
			break

	if is_server:
		_start_server()
	else:
		_start_client()


func _start_server() -> void:
	role = Role.SERVER
	var peer := WebSocketMultiplayerPeer.new()
	var err: int = peer.create_server(Config.SERVER_PORT)
	if err != OK:
		push_error("Failed to create WebSocket server on port %d: %d" % [Config.SERVER_PORT, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	lobby_map_index = randi() % Config.MAP_NAMES.size()
	print("Server started on port %d, map: %s" % [Config.SERVER_PORT, Config.MAP_NAMES[lobby_map_index]])


func _start_client() -> void:
	role = Role.CLIENT
	server_url = _get_server_url()
	var peer := WebSocketMultiplayerPeer.new()
	var err: int = peer.create_client(server_url)
	if err != OK:
		push_error("Failed to connect to server at %s: %d" % [server_url, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("Connecting to server: %s" % server_url)


func _get_server_url() -> String:
	if OS.has_feature("web"):
		var js_url: String = JavaScriptBridge.eval("window.GAME_SERVER_URL || ''")
		if js_url != "":
			return js_url
	return Config.SERVER_URL


# ---------------------------------------------------------------------------
# Server: connection handlers
# ---------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if role != Role.SERVER:
		return
	connected_peers.append(peer_id)
	print("Peer connected: %d (total: %d)" % [peer_id, connected_peers.size()])
	peer_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if role != Role.SERVER:
		return
	connected_peers.erase(peer_id)
	var player_idx: int = peer_to_player.get(peer_id, -1)
	if player_idx >= 0:
		player_to_peer.erase(player_idx)
		peer_to_player.erase(peer_id)
	print("Peer disconnected: %d (total: %d)" % [peer_id, connected_peers.size()])
	peer_left.emit(peer_id)


# ---------------------------------------------------------------------------
# Client: connection handlers
# ---------------------------------------------------------------------------

func _on_connected_to_server() -> void:
	print("Connected to server!")
	rpc_join_lobby.rpc_id(1)


func _on_server_disconnected() -> void:
	print("Disconnected from server!")
	role = Role.NONE


# ---------------------------------------------------------------------------
# Server: lobby management
# ---------------------------------------------------------------------------

func server_assign_player(peer_id: int) -> int:
	var slot: int = _next_player_slot
	_next_player_slot += 1
	peer_to_player[peer_id] = slot
	player_to_peer[slot] = peer_id
	return slot


func server_broadcast_lobby(timer: float) -> void:
	lobby_timer = timer
	lobby_player_count = connected_peers.size()
	for pid in connected_peers:
		rpc_lobby_update.rpc_id(pid, lobby_player_count, timer, lobby_map_index)


func server_start_game(seed_val: int) -> void:
	lobby_started = true
	var total_humans: int = connected_peers.size()
	for pid in connected_peers:
		var idx: int = peer_to_player.get(pid, -1)
		rpc_game_start.rpc_id(pid, seed_val, lobby_map_index, idx, total_humans)


func server_send_snapshot(snapshot: PackedByteArray) -> void:
	for pid in connected_peers:
		rpc_state_snapshot.rpc_id(pid, snapshot)


func server_send_event(event: PackedByteArray) -> void:
	for pid in connected_peers:
		rpc_game_event.rpc_id(pid, event)


func is_human_player(player_idx: int) -> bool:
	return player_to_peer.has(player_idx)


func get_bot_indices(total_players: int) -> Array[int]:
	var bots: Array[int] = []
	for i in total_players:
		if not player_to_peer.has(i):
			bots.append(i)
	return bots


# ---------------------------------------------------------------------------
# Client: send helpers
# ---------------------------------------------------------------------------

func client_send_input(input_bytes: PackedByteArray) -> void:
	if role != Role.CLIENT:
		return
	rpc_player_input.rpc_id(1, input_bytes)


func client_send_action(action_bytes: PackedByteArray) -> void:
	if role != Role.CLIENT:
		return
	rpc_player_action.rpc_id(1, action_bytes)


# ---------------------------------------------------------------------------
# RPCs: Client → Server
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func rpc_join_lobby() -> void:
	if role != Role.SERVER:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if peer_to_player.has(sender):
		return  # already joined
	var slot: int = server_assign_player(sender)
	rpc_assign_player.rpc_id(sender, slot)
	print("Player %d assigned slot %d" % [sender, slot])


@rpc("any_peer", "call_remote", "unreliable")
func rpc_player_input(input_bytes: PackedByteArray) -> void:
	if role != Role.SERVER:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	input_received.emit(sender, input_bytes)


@rpc("any_peer", "call_remote", "reliable")
func rpc_player_action(action_bytes: PackedByteArray) -> void:
	if role != Role.SERVER:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	action_received.emit(sender, action_bytes)


# ---------------------------------------------------------------------------
# RPCs: Server → Client
# ---------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func rpc_assign_player(player_index: int) -> void:
	if role != Role.CLIENT:
		return
	my_player_index = player_index
	print("Assigned player index: %d" % player_index)


@rpc("authority", "call_remote", "reliable")
func rpc_lobby_update(player_count: int, timer: float, map_index: int) -> void:
	if role != Role.CLIENT:
		return
	lobby_player_count = player_count
	lobby_timer = timer
	lobby_map_index = map_index
	lobby_updated.emit(player_count, timer, map_index)


@rpc("authority", "call_remote", "reliable")
func rpc_game_start(seed_val: int, map_index: int, my_index: int, total_humans: int) -> void:
	if role != Role.CLIENT:
		return
	my_player_index = my_index
	lobby_map_index = map_index
	lobby_started = true
	game_starting.emit(seed_val, map_index, my_index, total_humans)


@rpc("authority", "call_remote", "unreliable")
func rpc_state_snapshot(snapshot: PackedByteArray) -> void:
	if role != Role.CLIENT:
		return
	state_snapshot_received.emit(snapshot)


@rpc("authority", "call_remote", "reliable")
func rpc_game_event(event_bytes: PackedByteArray) -> void:
	if role != Role.CLIENT:
		return
	game_event_received.emit(event_bytes)
