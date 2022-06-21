#!/bin/bash

# Start Backend
cd /app
sh ./mealie/run.sh

# Start Frontend
# If the source would change the frontend
# code to just use the standard shell script
cd frontend
caddy start --config /app/frontend/Caddyfile
yarn start -p 3001
