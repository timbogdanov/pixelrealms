extends Node

# ---------------------------------------------------------------------------
# NetworkManager — Autoloaded as "Net"
# Handles WebSocket server/client, peer tracking, RPCs
# ---------------------------------------------------------------------------

enum Role { NONE, SERVER, CLIENT }
var role: int = Role.NONE

# Server state
var connected_peers: Array[int] = []
var peer_to_player: Dictionary = {}   # peer_id -> player_index (LOBBY only)
var player_to_peer: Dictionary = {}   # player_index -> peer_id (LOBBY only)
var _next_player_slot: int = 0

# Multi-game routing (server)
var peer_to_game: Dictionary = {}  # peer_id -> game_id (-1 or absent = in lobby)
var _next_game_id: int = 0

# Username tracking (server)
var peer_usernames: Dictionary = {}  # peer_id -> String
var active_game_count: int = 0  # updated by main.gd

# HTML lobby WebSocket (lightweight, separate from multiplayer peer)
var _lobby_tcp_server: TCPServer = null
var _lobby_ws_clients: Array = []  # Array of {ws: WebSocketPeer, name: String, last_hb: float}
var _html_player_count: int = 0
var _game_loading_started: bool = false  # prevents timer reset during transition

# Client state
var my_player_index: int = -1
var server_url: String = ""

# Lobby state (server-authoritative)
var lobby_player_count: int = 0
var lobby_timer: float = 60.0
var lobby_map_index: int = 0
var lobby_seed: int = 0
var lobby_started: bool = false

# Signals for main.gd
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal lobby_updated(player_count: int, timer: float, map_index: int, seed_val: int)
signal game_starting(seed_val: int, map_index: int, my_index: int, total_humans: int)
signal state_snapshot_received(snapshot: PackedByteArray)
signal input_received(peer_id: int, input_data: PackedByteArray)
signal action_received(peer_id: int, action_data: PackedByteArray)
signal game_event_received(event_data: PackedByteArray)
signal returned_to_lobby()


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
	_reset_lobby()
	_start_lobby_ws_server()
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
# Server: HTML lobby WebSocket (lightweight JSON protocol on port 9091)
# ---------------------------------------------------------------------------

func _start_lobby_ws_server() -> void:
	_lobby_tcp_server = TCPServer.new()
	var err: int = _lobby_tcp_server.listen(Config.LOBBY_WS_PORT)
	if err != OK:
		push_error("Failed to start lobby WS server on port %d: %d" % [Config.LOBBY_WS_PORT, err])
		return
	print("Lobby WebSocket server started on port %d" % Config.LOBBY_WS_PORT)


func _process(_delta: float) -> void:
	if role != Role.SERVER or _lobby_tcp_server == null:
		return
	_process_lobby_ws_server()


func _process_lobby_ws_server() -> void:
	# Accept new TCP connections
	while _lobby_tcp_server.is_connection_available():
		var tcp: StreamPeerTCP = _lobby_tcp_server.take_connection()
		var ws: WebSocketPeer = WebSocketPeer.new()
		ws.accept_stream(tcp)
		var client: Dictionary = {
			"ws": ws,
			"name": "",
			"last_hb": Time.get_unix_time_from_system(),
		}
		_lobby_ws_clients.append(client)

	# Poll existing clients
	var to_remove: Array = []
	var now: float = Time.get_unix_time_from_system()

	for i in _lobby_ws_clients.size():
		var client: Dictionary = _lobby_ws_clients[i]
		var ws: WebSocketPeer = client["ws"]
		ws.poll()

		var state: int = ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			to_remove.append(i)
			continue

		if state != WebSocketPeer.STATE_OPEN:
			continue

		# Read messages
		while ws.get_available_packet_count() > 0:
			var packet: PackedByteArray = ws.get_packet()
			var text: String = packet.get_string_from_utf8()
			_handle_lobby_ws_message(client, text)

		# Check heartbeat staleness (10 second timeout)
		var last_hb: float = client["last_hb"]
		if now - last_hb > 10.0:
			ws.close()
			to_remove.append(i)

	# Remove disconnected (reverse order to preserve indices)
	to_remove.reverse()
	for idx: int in to_remove:
		_lobby_ws_clients.remove_at(idx)

	_html_player_count = _lobby_ws_clients.size()


func _handle_lobby_ws_message(client: Dictionary, text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return
	var msg: Dictionary = parsed
	var msg_type: String = msg.get("type", "")

	if msg_type == "join":
		var name_val: String = msg.get("name", "Player")
		name_val = name_val.strip_edges().left(20)
		if name_val.length() < 1:
			name_val = "Player"
		client["name"] = name_val
		client["last_hb"] = Time.get_unix_time_from_system()
	elif msg_type == "heartbeat":
		client["last_hb"] = Time.get_unix_time_from_system()


func lobby_ws_broadcast(timer: float) -> void:
	var map_name: String = Config.MAP_NAMES[lobby_map_index] if lobby_map_index < Config.MAP_NAMES.size() else "Unknown"
	var total_count: int = peer_to_player.size() + _html_player_count
	var data: Dictionary = {
		"type": "lobby_update",
		"player_count": total_count,
		"timer": timer,
		"map_name": map_name,
		"active_games": active_game_count,
	}
	var json_str: String = JSON.stringify(data)
	for client: Dictionary in _lobby_ws_clients:
		var ws: WebSocketPeer = client["ws"]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(json_str)


func lobby_ws_send_load_game() -> void:
	_game_loading_started = true
	var msg: String = JSON.stringify({"type": "load_game"})
	for client: Dictionary in _lobby_ws_clients:
		var ws: WebSocketPeer = client["ws"]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(msg)
	print("Sent load_game to %d HTML lobby clients" % _lobby_ws_clients.size())


func get_total_lobby_count() -> int:
	return peer_to_player.size() + _html_player_count


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
	# Clean up lobby assignment if in lobby
	var player_idx: int = peer_to_player.get(peer_id, -1)
	if player_idx >= 0:
		player_to_peer.erase(player_idx)
		peer_to_player.erase(peer_id)
	# Clean up game assignment (main.gd handles notifying the GameInstance)
	peer_to_game.erase(peer_id)
	peer_usernames.erase(peer_id)
	print("Peer disconnected: %d (total: %d)" % [peer_id, connected_peers.size()])
	peer_left.emit(peer_id)


# ---------------------------------------------------------------------------
# Client: connection handlers
# ---------------------------------------------------------------------------

func _on_connected_to_server() -> void:
	print("Connected to server!")


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
	lobby_player_count = peer_to_player.size() + _html_player_count
	# Only broadcast to Godot peers in the lobby (not in a game)
	for pid in connected_peers:
		if not peer_to_game.has(pid):
			rpc_lobby_update.rpc_id(pid, lobby_player_count, timer, lobby_map_index, lobby_seed)
	_write_lobby_state_json()
	lobby_ws_broadcast(timer)


func _write_lobby_state_json() -> void:
	var map_name: String = Config.MAP_NAMES[lobby_map_index] if lobby_map_index < Config.MAP_NAMES.size() else "Unknown"
	var leaderboard: Array = _read_leaderboard()
	var data: Dictionary = {
		"player_count": lobby_player_count,
		"timer": lobby_timer,
		"map_name": map_name,
		"active_games": active_game_count,
		"leaderboard": leaderboard,
	}
	var json_str: String = JSON.stringify(data)
	# Atomic write: write to tmp file then rename
	var tmp_path: String = "/tmp/lobby_state.json.tmp"
	var final_path: String = "/tmp/lobby_state.json"
	var f: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if f != null:
		f.store_string(json_str)
		f.close()
		DirAccess.rename_absolute(tmp_path, final_path)


func _read_leaderboard() -> Array:
	var path: String = "/tmp/leaderboard.json"
	if not FileAccess.file_exists(path):
		return []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var entries: Variant = parsed.get("entries", [])
		if entries is Array:
			return entries
	return []


func get_username_for_peer(peer_id: int) -> String:
	return peer_usernames.get(peer_id, "Player")


func _reset_lobby() -> void:
	## Resets lobby state for a new round. Called after game starts.
	peer_to_player.clear()
	player_to_peer.clear()
	_next_player_slot = 0
	lobby_map_index = randi() % Config.MAP_NAMES.size()
	lobby_seed = randi()
	lobby_started = false
	lobby_timer = Config.LOBBY_TIMER
	# Clear HTML lobby clients (they've navigated to /play/)
	_lobby_ws_clients.clear()
	_html_player_count = 0
	_game_loading_started = false


func server_start_game_for_lobby() -> Dictionary:
	## Moves current lobby peers into a new game. Returns {game_id, peers}.
	var gid: int = _next_game_id
	_next_game_id += 1
	var peers_copy: Dictionary = peer_to_player.duplicate()
	# Move lobby peers into the game
	for pid: int in peers_copy:
		peer_to_game[pid] = gid
	# Reset lobby for next wave of players
	_reset_lobby()
	print("Game #%d started with %d human players. New lobby ready." % [gid, peers_copy.size()])
	return {"game_id": gid, "peers": peers_copy}


func server_end_game(game_id: int, peer_ids: Array) -> void:
	## Sends return-to-lobby RPC to all peers that were in this game.
	for pid: int in peer_ids:
		if connected_peers.has(pid):
			peer_to_game.erase(pid)
			rpc_return_to_lobby.rpc_id(pid)
	print("Game #%d ended, %d peers returned to lobby." % [game_id, peer_ids.size()])


func get_game_id_for_peer(peer_id: int) -> int:
	## Returns game_id for a peer, or -1 if in lobby.
	return peer_to_game.get(peer_id, -1)


func is_peer_in_lobby(peer_id: int) -> bool:
	return not peer_to_game.has(peer_id)


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
func rpc_set_username(username: String) -> void:
	if role != Role.SERVER:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	# Sanitize: strip whitespace, limit length
	var clean: String = username.strip_edges().left(20)
	if clean.length() < 1:
		clean = "Player"
	peer_usernames[sender] = clean


@rpc("any_peer", "call_remote", "reliable")
func rpc_join_lobby() -> void:
	if role != Role.SERVER:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	# Can only join lobby if not in a game
	if peer_to_game.has(sender):
		return
	if peer_to_player.has(sender):
		return  # already joined
	var slot: int = server_assign_player(sender)
	rpc_assign_player.rpc_id(sender, slot)
	print("Player %d assigned slot %d" % [sender, slot])


@rpc("any_peer", "call_remote", "reliable")
func rpc_leave_lobby() -> void:
	if role != Role.SERVER:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not peer_to_player.has(sender):
		return
	var slot: int = peer_to_player[sender]
	peer_to_player.erase(sender)
	player_to_peer.erase(slot)
	rpc_unassign_player.rpc_id(sender)
	print("Player %d left lobby (slot %d)" % [sender, slot])


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
func rpc_lobby_update(player_count: int, timer: float, map_index: int, seed_val: int) -> void:
	if role != Role.CLIENT:
		return
	lobby_player_count = player_count
	lobby_timer = timer
	lobby_map_index = map_index
	lobby_seed = seed_val
	lobby_updated.emit(player_count, timer, map_index, seed_val)


@rpc("authority", "call_remote", "reliable")
func rpc_unassign_player() -> void:
	if role != Role.CLIENT:
		return
	my_player_index = -1
	print("Unassigned from lobby")


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


@rpc("authority", "call_remote", "reliable")
func rpc_return_to_lobby() -> void:
	if role != Role.CLIENT:
		return
	my_player_index = -1
	lobby_started = false
	print("Returned to lobby")
	returned_to_lobby.emit()
