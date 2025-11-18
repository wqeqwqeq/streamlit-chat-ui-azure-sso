#!/usr/bin/env bash
# ================================================================
# Application Deployment Script
# ================================================================
# Initializes PostgreSQL database and deploys the Streamlit app
# to Azure Web App
#
# Usage:
#   ./deploy_script.sh [db|app|all]
#
# Modes:
#   db   - Initialize PostgreSQL database only
#   app  - Deploy application only
#   all  - Deploy both database and application (default)
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - .env file configured with required parameters
#   - Infrastructure already deployed (run deploy_infra.sh first)
#   - psql client installed for database initialization (for db mode)
# ================================================================

set -euo pipefail

MODE=${1:-all}

# Validate mode parameter
if [[ ! "$MODE" =~ ^(db|app|all)$ ]]; then
    echo "❌ Error: Invalid mode '$MODE'"
    echo ""
    echo "Usage: ./deploy_script.sh [db|app|all]"
    echo ""
    echo "Modes:"
    echo "  db   - Initialize PostgreSQL database only"
    echo "  app  - Deploy application only"
    echo "  all  - Deploy both database and application (default)"
    echo ""
    exit 1
fi

# Get script directory and load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE"
    echo ""
    echo "Please copy .env.example to .env and configure your settings:"
    echo "  cp .env.example .env"
    echo "  nano .env"
    echo ""
    exit 1
fi

echo "📋 Loading configuration from .env..."
source "$ENV_FILE"

# Validate required variables
REQUIRED_VARS=(
    "AZURE_RESOURCE_GROUP"
    "RESOURCE_PREFIX"
    "POSTGRES_ADMIN_LOGIN"
    "POSTGRES_ADMIN_PASSWORD"
)

MISSING_VARS=()
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR:-}" ]; then
        MISSING_VARS+=("$VAR")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "❌ Error: Missing required environment variables:"
    printf '   - %s\n' "${MISSING_VARS[@]}"
    echo ""
    echo "Please configure these in your .env file"
    exit 1
fi

# Construct resource names
APP_NAME="${RESOURCE_PREFIX}-app"
POSTGRES_SERVER="${RESOURCE_PREFIX}-postgres"
POSTGRES_HOST="${POSTGRES_SERVER}.postgres.database.azure.com"

# ================================================================
# Function: deploy_database
# ================================================================
# Initializes the PostgreSQL database by:
# 1. Adding temporary firewall rule for client IP
# 2. Running init.sql script
# 3. Cleaning up firewall rule
# ================================================================
deploy_database() {
    echo ""
    echo "================================================================"
    echo "Initialize PostgreSQL Database"
    echo "================================================================"
    echo ""

    # Check for psql
    if ! command -v psql &> /dev/null; then
        echo "❌ Error: psql client not found"
        echo ""
        echo "Please install PostgreSQL client:"
        echo "  macOS:   brew install postgresql"
        echo "  Ubuntu:  sudo apt-get install postgresql-client"
        echo "  Windows: Download from https://www.postgresql.org/download/"
        echo ""
        exit 1
    fi

    # Get client IP
    echo "🌐 Detecting client IP address..."
    CLIENT_IP=$(curl -s https://api.ipify.org)
    if [ -z "$CLIENT_IP" ]; then
        echo "❌ Error: Failed to detect client IP"
        exit 1
    fi
    echo "   ✓ Client IP: $CLIENT_IP"

    # Check if client IP is already whitelisted
    echo ""
    echo "🔐 Checking firewall rules..."
    # TODO!!! THIS COULD ALSO BE AN IP RANGE 
    EXISTING_RULES=$(az postgres flexible-server firewall-rule list \
      -g "$AZURE_RESOURCE_GROUP" \
      -n "$POSTGRES_SERVER" \
      --query "[?startIpAddress=='$CLIENT_IP' && endIpAddress=='$CLIENT_IP'].name" \
      -o tsv)

    if [ -n "$EXISTING_RULES" ]; then
        echo "   ✓ Client IP already whitelisted (rule: $(echo $EXISTING_RULES | head -n1))"
    else
        # Add persistent firewall rule for this client IP
        RULE_NAME="client-ip-$(echo $CLIENT_IP | tr '.' '-')"
        echo "   Adding firewall rule for client IP..."
        az postgres flexible-server firewall-rule create \
          -g "$AZURE_RESOURCE_GROUP" \
          -n "$POSTGRES_SERVER" \
          --rule-name "$RULE_NAME" \
          --start-ip-address "$CLIENT_IP" \
          --end-ip-address "$CLIENT_IP" \
          --output none

        if [ $? -eq 0 ]; then
            echo "   ✓ Firewall rule added: $RULE_NAME (persistent)"
        else
            echo "   ❌ Failed to add firewall rule"
            exit 1
        fi
    fi

    # Run init.sql
    echo ""
    echo "📊 Running database initialization script..."
    export PGHOST="$POSTGRES_HOST"
    export PGUSER="$POSTGRES_ADMIN_LOGIN"
    export PGPORT="5432"
    export PGDATABASE="postgres"
    export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"
    export PGSSLMODE="require"

    if psql -f "$SCRIPT_DIR/init.sql" 2>&1 | tee /tmp/init_sql.log; then
        echo "   ✓ Database initialized successfully"
    else
        echo "   ❌ Database initialization failed"
        echo "   Check logs above for details"
        exit 1
    fi

    echo ""
    echo "✅ Database deployment complete!"
}

# ================================================================
# Function: deploy_app
# ================================================================
# Deploys the containerized Streamlit application by:
# 1. Updating App Service container configuration
# 2. Restarting the app to pull new image
# ================================================================
deploy_app() {
    echo ""
    echo "================================================================"
    echo "Deploy Application Container"
    echo "================================================================"
    echo ""

    # Get ACR name (remove hyphens from resource prefix)
    ACR_NAME=$(echo "${RESOURCE_PREFIX}" | tr -d '-')"acr"
    IMAGE_NAME="${RESOURCE_PREFIX}-app"
    TAG="${2:-latest}"  # Optional tag parameter (default: latest)

    echo "📋 Container configuration:"
    echo "   ACR:       ${ACR_NAME}.azurecr.io"
    echo "   Image:     ${IMAGE_NAME}:${TAG}"
    echo "   Full path: ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${TAG}"
    echo ""

    # Update app service to use new container image
    echo "🔄 Updating container configuration..."
    az webapp config container set \
      -g "$AZURE_RESOURCE_GROUP" \
      -n "$APP_NAME" \
      --docker-custom-image-name "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${TAG}" \
      --docker-registry-server-url "https://${ACR_NAME}.azurecr.io" \
      --output none

    if [ $? -eq 0 ]; then
        echo "   ✓ Container configuration updated"
    else
        echo "   ❌ Failed to update container configuration"
        exit 1
    fi

    # Restart app to pull new image
    echo ""
    echo "🔄 Restarting app service to pull new container..."
    az webapp restart -g "$AZURE_RESOURCE_GROUP" -n "$APP_NAME"

    if [ $? -eq 0 ]; then
        echo "   ✓ App service restarted"
    else
        echo "   ❌ Failed to restart app service"
        exit 1
    fi

    echo ""
    echo "✅ Application deployment complete!"
}

# ================================================================
# Main Execution
# ================================================================

echo ""
echo "================================================================"
echo "Deployment Mode: $MODE"
echo "================================================================"

case "$MODE" in
    db)
        deploy_database
        ;;
    app)
        deploy_app
        ;;
    all)
        deploy_database
        deploy_app
        ;;
esac

# Display summary
echo ""
echo "================================================================"
echo "✅ Deployment Complete!"
echo "================================================================"
echo ""
echo "📋 Summary:"
echo "   Mode:           $MODE"
echo "   App Name:       $APP_NAME"
echo "   Resource Group: $AZURE_RESOURCE_GROUP"

if [[ "$MODE" == "app" || "$MODE" == "all" ]]; then
    echo "   App URL:        https://${APP_NAME}.azurewebsites.net"
fi

echo ""
echo "📊 Next Steps:"

if [[ "$MODE" == "app" || "$MODE" == "all" ]]; then
    echo "   1. Wait ~2 minutes for app to start"
    echo "   2. Visit: https://${APP_NAME}.azurewebsites.net"
    echo "   3. Check logs: az webapp log tail -g $AZURE_RESOURCE_GROUP -n $APP_NAME"
fi

echo ""
echo "🔍 Troubleshooting:"
echo "   View config:     az webapp config appsettings list -g $AZURE_RESOURCE_GROUP -n $APP_NAME"
echo "   View logs:       az webapp log tail -g $AZURE_RESOURCE_GROUP -n $APP_NAME"
echo "   Restart app:     az webapp restart -g $AZURE_RESOURCE_GROUP -n $APP_NAME"
echo "   SSH to app:      az webapp ssh -g $AZURE_RESOURCE_GROUP -n $APP_NAME"
echo ""
