#!/usr/bin/env bash
# ================================================================
# Infrastructure Deployment Script
# ================================================================
# Deploys Azure infrastructure using Bicep templates
#
# Usage:
#   ./deploy_infra.sh rg [--what-if]         - Deploy resource group only
#   ./deploy_infra.sh app [--what-if]        - Deploy full application infrastructure
#
# Options:
#   --what-if    Preview changes without deploying (dry run)
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - .env file configured with required parameters
#   - Appropriate permissions in target subscription
# ================================================================

set -euo pipefail

MODE=${1:-}
WHAT_IF=false

# Parse arguments
if [ -z "$MODE" ]; then
    echo "❌ Error: Mode not specified"
    echo ""
    echo "Usage: ./deploy_infra.sh [rg|app] [--what-if]"
    echo ""
    echo "Modes:"
    echo "  rg   - Deploy resource group only (rg.bicep)"
    echo "  app  - Deploy full infrastructure (simplified.bicep)"
    echo ""
    echo "Options:"
    echo "  --what-if  - Preview changes without deploying (dry run)"
    echo ""
    exit 1
fi

# Check for --what-if flag
if [ "${2:-}" = "--what-if" ]; then
    WHAT_IF=true
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
        "VNET_ADDRESS_SPACE"
        "SUBNET_ADDRESS_PREFIX"
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
    if [ "$WHAT_IF" = true ]; then
        echo ""
        echo "🔍 Previewing resource group deployment (what-if mode)..."
        echo "   Name: $AZURE_RESOURCE_GROUP"
        echo "   Location: $AZURE_LOCATION"
        echo ""
    else
        echo ""
        echo "🚀 Deploying resource group..."
        echo "   Name: $AZURE_RESOURCE_GROUP"
        echo "   Location: $AZURE_LOCATION"
        echo ""
    fi

    az account set --subscription "$AZURE_SUBSCRIPTION_ID"

    if [ "$WHAT_IF" = true ]; then
        az deployment sub what-if \
          --location "$AZURE_LOCATION" \
          --template-file "$SCRIPT_DIR/rg.bicep" \
          --parameters \
            resourceGroupName="$AZURE_RESOURCE_GROUP" \
            location="$AZURE_LOCATION"

        echo ""
        echo "✅ What-if analysis complete!"
        echo ""
        echo "📋 To deploy for real, run without --what-if:"
        echo "   ./deploy_infra.sh rg"
        echo ""
    else
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
    fi

elif [ "$MODE" = "app" ]; then
    if [ "$WHAT_IF" = true ]; then
        echo ""
        echo "🔍 Previewing application infrastructure deployment (what-if mode)..."
        echo "   Resource Group: $AZURE_RESOURCE_GROUP"
        echo "   Resource Prefix: $RESOURCE_PREFIX"
        echo "   App Service SKU: $APP_SERVICE_SKU"
        echo "   PostgreSQL SKU: $POSTGRES_SKU"
        echo "   VNet Address Space: $VNET_ADDRESS_SPACE"
        echo "   Subnet Address Prefix: $SUBNET_ADDRESS_PREFIX"
        echo ""
    else
        echo ""
        echo "🚀 Deploying application infrastructure..."
        echo "   Resource Group: $AZURE_RESOURCE_GROUP"
        echo "   Resource Prefix: $RESOURCE_PREFIX"
        echo "   App Service SKU: $APP_SERVICE_SKU"
        echo "   PostgreSQL SKU: $POSTGRES_SKU"
        echo "   VNet Address Space: $VNET_ADDRESS_SPACE"
        echo "   Subnet Address Prefix: $SUBNET_ADDRESS_PREFIX"
        echo ""
    fi

    # Check if resource group exists
    if ! az group show --name "$AZURE_RESOURCE_GROUP" &>/dev/null; then
        echo "❌ Error: Resource group '$AZURE_RESOURCE_GROUP' does not exist"
        echo ""
        echo "Please create it first:"
        echo "   ./deploy_infra.sh rg"
        echo ""
        exit 1
    fi

    if [ "$WHAT_IF" = true ]; then
        az deployment group what-if \
          --name "infra-whatif-$(date +%s)" \
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
            postgresDatabaseName="$POSTGRES_DATABASE" \
            vnetAddressSpace="$VNET_ADDRESS_SPACE" \
            subnetAddressPrefix="$SUBNET_ADDRESS_PREFIX"

        echo ""
        echo "✅ What-if analysis complete!"
        echo ""
        echo "📋 To deploy for real, run without --what-if:"
        echo "   ./deploy_infra.sh app"
        echo ""
    else
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
            postgresDatabaseName="$POSTGRES_DATABASE" \
            vnetAddressSpace="$VNET_ADDRESS_SPACE" \
            subnetAddressPrefix="$SUBNET_ADDRESS_PREFIX"

        echo ""
        echo "✅ Infrastructure deployed successfully!"
        echo ""
        echo "📋 Resources created:"
        echo "   - App Service: ${RESOURCE_PREFIX}-app"
        echo "   - App Service Plan: ${RESOURCE_PREFIX}-plan"
        echo "   - PostgreSQL: ${RESOURCE_PREFIX}-postgres"
        echo "   - Redis Cache: ${RESOURCE_PREFIX}-redis"
        echo "   - Container Registry: $(echo ${RESOURCE_PREFIX} | tr -d '-')acr"
        echo "   - Key Vault: $(echo ${RESOURCE_PREFIX} | tr -d '-')kv"
        echo "   - Application Insights: ${RESOURCE_PREFIX}-insights"
        echo "   - Managed Identity: ${RESOURCE_PREFIX}-uai"
        echo "   - Virtual Network: ${RESOURCE_PREFIX}-vnet"
        echo "   - NAT Gateway: ${RESOURCE_PREFIX}-nat-gateway"
        echo "   - Public IP: ${RESOURCE_PREFIX}-nat-pip"
        echo ""
        echo "📋 Next steps:"
        echo "   1. Get Redis credentials from Azure Portal or outputs"
        echo "   2. Initialize database and deploy app: ./deploy_script.sh"
        echo "   3. View your app: https://${RESOURCE_PREFIX}-app.azurewebsites.net"
        echo ""
    fi
fi
