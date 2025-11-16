#!/usr/bin/env bash
# ================================================================
# Infrastructure Deployment Script
# ================================================================
# Deploys Azure infrastructure using Bicep templates
#
# Usage:
#   ./deploy_infra.sh rg   - Deploy resource group only
#   ./deploy_infra.sh app  - Deploy full application infrastructure
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - .env file configured with required parameters
#   - Appropriate permissions in target subscription
# ================================================================

set -euo pipefail

MODE=${1:-}

if [ -z "$MODE" ]; then
    echo "❌ Error: Mode not specified"
    echo ""
    echo "Usage: ./deploy_infra.sh [rg|app]"
    echo ""
    echo "Modes:"
    echo "  rg   - Deploy resource group only (rg.bicep)"
    echo "  app  - Deploy full infrastructure (simplified.bicep)"
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

# Validate required variables based on mode
if [ "$MODE" = "rg" ]; then
    if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_LOCATION:-}" ]; then
        echo "❌ Error: Missing required environment variables"
        echo "   Required: AZURE_RESOURCE_GROUP, AZURE_LOCATION"
        exit 1
    fi
elif [ "$MODE" = "app" ]; then
    REQUIRED_VARS=(
        "AZURE_SUBSCRIPTION_ID"
        "AZURE_RESOURCE_GROUP"
        "AZURE_LOCATION"
        "RESOURCE_PREFIX"
        "APP_SERVICE_SKU"
        "TOKEN_PROVIDER_APP_ID"
        "POSTGRES_ADMIN_LOGIN"
        "POSTGRES_ADMIN_PASSWORD"
        "POSTGRES_SKU"
        "POSTGRES_STORAGE_GB"
        "POSTGRES_DATABASE"
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
else
    echo "❌ Invalid mode: $MODE"
    echo "   Valid modes: rg, app"
    exit 1
fi

# Deploy based on mode
if [ "$MODE" = "rg" ]; then
    echo ""
    echo "🚀 Deploying resource group..."
    echo "   Name: $AZURE_RESOURCE_GROUP"
    echo "   Location: $AZURE_LOCATION"
    echo ""

    az account set --subscription "$AZURE_SUBSCRIPTION_ID"

    az deployment sub create \
      --location "$AZURE_LOCATION" \
      --template-file "$SCRIPT_DIR/rg.bicep" \
      --parameters \
        resourceGroupName="$AZURE_RESOURCE_GROUP" \
        location="$AZURE_LOCATION"

    echo ""
    echo "✅ Resource group deployed successfully!"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Deploy application infrastructure: ./deploy_infra.sh app"
    echo ""

elif [ "$MODE" = "app" ]; then
    echo ""
    echo "🚀 Deploying application infrastructure..."
    echo "   Resource Group: $AZURE_RESOURCE_GROUP"
    echo "   Resource Prefix: $RESOURCE_PREFIX"
    echo "   App Service SKU: $APP_SERVICE_SKU"
    echo "   PostgreSQL SKU: $POSTGRES_SKU"
    echo ""

    # Check if resource group exists
    if ! az group show --name "$AZURE_RESOURCE_GROUP" &>/dev/null; then
        echo "❌ Error: Resource group '$AZURE_RESOURCE_GROUP' does not exist"
        echo ""
        echo "Please create it first:"
        echo "   ./deploy_infra.sh rg"
        echo ""
        exit 1
    fi

    az deployment group create \
      --name "infra-$(date +%s)" \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --template-file "$SCRIPT_DIR/simplified.bicep" \
      --parameters \
        location="$AZURE_LOCATION" \
        resourcePrefix="$RESOURCE_PREFIX" \
        skuName="$APP_SERVICE_SKU" \
        tokenProviderAppId="$TOKEN_PROVIDER_APP_ID" \
        postgresAdminLogin="$POSTGRES_ADMIN_LOGIN" \
        postgresAdminPassword="$POSTGRES_ADMIN_PASSWORD" \
        postgresSku="$POSTGRES_SKU" \
        postgresStorageSizeGB="$POSTGRES_STORAGE_GB" \
        postgresDatabaseName="$POSTGRES_DATABASE"

    echo ""
    echo "✅ Infrastructure deployed successfully!"
    echo ""
    echo "📋 Resources created:"
    echo "   - App Service: ${RESOURCE_PREFIX}-app"
    echo "   - App Service Plan: ${RESOURCE_PREFIX}-plan"
    echo "   - PostgreSQL: ${RESOURCE_PREFIX}-postgres"
    echo "   - Key Vault: $(echo ${RESOURCE_PREFIX} | tr -d '-')kv"
    echo "   - Application Insights: ${RESOURCE_PREFIX}-insights"
    echo "   - Managed Identity: ${RESOURCE_PREFIX}-uai"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Initialize database and deploy app: ./deploy_script.sh"
    echo "   2. View your app: https://${RESOURCE_PREFIX}-app.azurewebsites.net"
    echo ""
fi
