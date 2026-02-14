#!/bin/bash
# Generate client config from environment variable
echo "window.GAME_SERVER_URL = '${GAME_SERVER_URL:-wss://pixelrealms.io/ws}';" > /var/www/html/config.js
echo "window.GAME_SERVER_URL = '${GAME_SERVER_URL:-wss://pixelrealms.io/ws}';" > /var/www/lobby/config.js

# Initialize lobby state and leaderboard JSON files
echo '{"player_count":0,"timer":60,"map_name":"-","active_games":0,"leaderboard":[]}' > /tmp/lobby_state.json
echo '{"entries":[]}' > /tmp/leaderboard.json

# Start nginx in background
nginx -g 'daemon on;'

# Start Godot headless game server (foreground, PID 1)
exec godot --headless --path /app -- --server
