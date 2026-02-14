FROM barichello/godot-ci:4.6

# Install nginx
RUN apt-get update && apt-get install -y nginx && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Import project resources (registers class_names)
RUN godot --headless --import

# Export HTML5 client
RUN mkdir -p /app/export/web && \
    godot --headless --export-release "Web" /app/export/web/index.html

# Inject config.js script tag into exported HTML
RUN sed -i 's|</head>|<script src="config.js"></script></head>|' /app/export/web/index.html

# Copy exported files to nginx web root (Godot game at /play/)
RUN cp -r /app/export/web/* /var/www/html/

# Copy HTML lobby page to /var/www/lobby/
RUN mkdir -p /var/www/lobby && cp /app/web/index.html /var/www/lobby/

# Copy nginx config
COPY nginx.conf /etc/nginx/sites-available/default

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
