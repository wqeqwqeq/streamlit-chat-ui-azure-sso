
#!/usr/bin/env bash

set -euo pipefail

# Simple ZIP deploy for Azure Web App
# Usage: ./deploy_script.sh [APP_NAME] [RESOURCE_GROUP]
# Defaults to APP_NAME=stanley-test-ui-app; RESOURCE_GROUP is required if not set via az default.

APP_NAME="${1:-stanley-test-ui-app}"
RESOURCE_GROUP="${2:?Usage: ./deploy_script.sh <app-name> <resource-group>}"

# 1) Create a minimal bundle
rm -f app_bundle.zip
zip -j -q app_bundle.zip app.py chat_history_manager.py
[ -f requirements.txt ] && zip -j -q -u app_bundle.zip requirements.txt
[ -f pyproject.toml ] && zip -j -q -u app_bundle.zip pyproject.toml
[ -f uv.lock ] && zip -j -q -u app_bundle.zip uv.lock

# 2) Ensure build on deploy and a Streamlit startup command
az webapp config appsettings set -g "$RESOURCE_GROUP" -n "$APP_NAME" --settings SCM_DO_BUILD_DURING_DEPLOYMENT=true >/dev/null
az webapp config set -g "$RESOURCE_GROUP" -n "$APP_NAME" --startup-file "python -m streamlit run app.py --server.port 8000 --server.address 0.0.0.0" 

# 3) ZIP deploy
az webapp deployment source config-zip -g "$RESOURCE_GROUP" -n "$APP_NAME" --src app_bundle.zip

echo "Deployed to $APP_NAME in $RESOURCE_GROUP"


