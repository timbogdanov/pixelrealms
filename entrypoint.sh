#!/bin/bash
# Generate client config from environment variable
echo "window.GAME_SERVER_URL = '${GAME_SERVER_URL:-wss://pixelrealms.io/ws}';" > /var/www/html/config.js

# Start nginx in background
nginx -g 'daemon on;'

# Start Godot headless game server (foreground, PID 1)
exec godot --headless --path /app -- --server
