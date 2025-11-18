# Container Deployment Migration Plan

## Overview
Migrate from ZIP deployment to Azure Container Registry (ACR) based container deployment for the Streamlit chat UI application.

---

## Changes Required

### 1. Create Dockerfile
**File:** `Dockerfile` (root directory)

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install uv package manager
RUN pip install --no-cache-dir uv

# Copy dependency configuration
COPY pyproject.toml .

# Install dependencies using uv
RUN uv sync

# Copy application files
COPY app.py chat_history_manager.py ./
COPY .env .

# Expose port (documentation only - actual port set via WEBSITES_PORT)
EXPOSE 8000

# Start Streamlit application
CMD ["streamlit", "run", "app.py", "--server.port=8000", "--server.address=0.0.0.0"]
```

**Key points:**
- Use `python:3.12-slim` as base image (~150MB)
- Install `uv` package manager for dependency management
- Copy `pyproject.toml` and run `uv sync` to install dependencies
- Copy application files: `app.py`, `chat_history_manager.py`, **`.env`**
- Expose port 8000
- Set startup command: `streamlit run app.py --server.port=8000 --server.address=0.0.0.0`

**Note:** The `.env` file is included in the image as the source of truth for configuration. No app settings migration needed.

---

### 2. Create .dockerignore
**File:** `.dockerignore` (root directory)

```
# Virtual environments
.venv/
__pycache__/
*.pyc

# Local data
.chat_history/

# Git
.git/
.gitignore

# Deployment artifacts
deployment/
app_bundle.zip

# OS files
.DS_Store

# Documentation (optional - keep CLAUDE.md if needed)
README.md
*.md
```

**Important:** Do NOT exclude `.env` since it needs to be copied into the image.

---

### 3. Update Bicep Template
**File:** `deployment/simplified.bicep`

#### 3.1 Add Azure Container Registry

Add after the `userAssignedIdentity` resource (around line 35):

```bicep
// Azure Container Registry for storing Docker images
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: '${resourcePrefixShort}acr'  // e.g., stanleydevuiacr (no hyphens)
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false  // Use managed identity instead of admin credentials
  }
}
```

#### 3.2 Add RBAC Role Assignment (AcrPull for User-Assigned Identity)

Add after the `containerRegistry` resource:

```bicep
// Grant the user-assigned managed identity AcrPull role on the container registry
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, userAssignedIdentity.id, 'acrpull')
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')  // AcrPull role
    principalId: userAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
```

#### 3.3 Update App Service Configuration

Modify the `appService` resource (lines 84-147):

**Change the `properties` section:**

```bicep
resource appService 'Microsoft.Web/sites@2022-09-01' = {
  name: '${resourcePrefix}-app'
  location: location
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    keyVaultReferenceIdentity: userAssignedIdentity.id
    serverFarmId: serverFarm.id

    // Configure ACR authentication using managed identity
    acrUseManagedIdentityCreds: true
    acrUserManagedIdentityID: userAssignedIdentity.properties.clientId

    siteConfig: {
      // CHANGE: Use Docker container instead of Python runtime
      linuxFxVersion: 'DOCKER|${containerRegistry.properties.loginServer}/${resourcePrefix}-app:latest'
      alwaysOn: true

      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: userAssignedIdentity.properties.clientId
        }
        {
          name: 'RESOURCE_GROUP_NAME'
          value: resourceGroup().name
        }
        {
          name: 'SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'WEBSITE_LOAD_CERTIFICATES'
          value: '*'
        }
        // REMOVE: SCM_DO_BUILD_DURING_DEPLOYMENT (not needed for containers)

        // ACR configuration
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${containerRegistry.properties.loginServer}'
        }
        // Critical: Tell Azure the container listens on port 8000
        {
          name: 'WEBSITES_PORT'
          value: '8000'
        }
      ]
      ipSecurityRestrictionsDefaultAction: 'Allow'
    }
  }
  dependsOn: [
    acrPullRoleAssignment  // Ensure RBAC is configured before app starts
  ]
}
```

**Key changes:**
- Set `acrUseManagedIdentityCreds: true` to enable managed identity authentication
- Set `acrUserManagedIdentityID` to the client ID of the user-assigned identity
- Change `linuxFxVersion` from `PYTHON|3.12` to Docker container reference
- Add `DOCKER_REGISTRY_SERVER_URL` app setting
- **Add `WEBSITES_PORT=8000`** to tell Azure the container listens on port 8000
- Remove `SCM_DO_BUILD_DURING_DEPLOYMENT`
- **DO NOT** add .env variables to app settings (use .env in container)

#### 3.4 Add Outputs

Add at the end of the file (after line 337):

```bicep
output acrLoginServer string = containerRegistry.properties.loginServer
output acrName string = containerRegistry.name
```

---

### 4. Create Container Build Script
**File:** `deployment/build_container.sh`

```bash
#!/usr/bin/env bash
# ================================================================
# Container Build Script
# ================================================================
# Builds and pushes Docker images to Azure Container Registry
#
# Usage:
#   ./build_container.sh [build|push|all] [tag]
#
# Modes:
#   build - Build Docker image locally only
#   push  - Push previously built image to ACR
#   all   - Build and push (default)
#
# Parameters:
#   tag   - Optional version tag (default: latest)
#
# Prerequisites:
#   - Docker installed and running
#   - Azure CLI installed and logged in (for push mode)
#   - .env file configured with RESOURCE_PREFIX
# ================================================================

set -euo pipefail

# Get script directory and load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE"
    exit 1
fi

echo "📋 Loading configuration from .env..."
source "$ENV_FILE"

# Validate required variables
if [ -z "${RESOURCE_PREFIX:-}" ]; then
    echo "❌ Error: RESOURCE_PREFIX not set in .env"
    exit 1
fi

# Remove hyphens from resource prefix for ACR name
ACR_NAME=$(echo "${RESOURCE_PREFIX}" | tr -d '-')"acr"
IMAGE_NAME="${RESOURCE_PREFIX}-app"
TAG="${2:-latest}"  # Optional second parameter for version tag
MODE="${1:-all}"

# ================================================================
# Function: build_container
# ================================================================
build_container() {
    echo ""
    echo "================================================================"
    echo "Build Docker Image"
    echo "================================================================"
    echo ""

    echo "🔨 Building Docker image..."
    cd "$SCRIPT_DIR/.."

    docker build -t "$IMAGE_NAME:$TAG" -f Dockerfile .

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Image built successfully: $IMAGE_NAME:$TAG"
        echo ""
        echo "================================================================"
        echo "📋 Local Testing Instructions"
        echo "================================================================"
        echo ""
        echo "To run this container locally, use the following command:"
        echo ""
        echo "  docker run -p 8000:8000 $IMAGE_NAME:$TAG"
        echo ""
        echo "Then open your browser to: http://localhost:8000"
        echo ""
        echo "Note: The container uses the .env file bundled in the image."
        echo "================================================================"
    else
        echo "❌ Build failed"
        exit 1
    fi
}

# ================================================================
# Function: push_container
# ================================================================
push_container() {
    echo ""
    echo "================================================================"
    echo "Push Docker Image to ACR"
    echo "================================================================"
    echo ""

    echo "📤 Logging into ACR..."
    az acr login --name "$ACR_NAME"

    if [ $? -ne 0 ]; then
        echo "❌ Failed to login to ACR"
        exit 1
    fi

    echo ""
    echo "🏷️  Tagging image for ACR..."
    docker tag "$IMAGE_NAME:$TAG" "${ACR_NAME}.azurecr.io/$IMAGE_NAME:$TAG"

    echo ""
    echo "☁️  Pushing to ACR..."
    docker push "${ACR_NAME}.azurecr.io/$IMAGE_NAME:$TAG"

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Image pushed successfully!"
        echo ""
        echo "   Registry: ${ACR_NAME}.azurecr.io"
        echo "   Image: $IMAGE_NAME:$TAG"
    else
        echo "❌ Push failed"
        exit 1
    fi
}

# ================================================================
# Main Execution
# ================================================================

echo ""
echo "================================================================"
echo "Container Build Script"
echo "================================================================"
echo ""
echo "Configuration:"
echo "  Mode:       $MODE"
echo "  ACR Name:   $ACR_NAME"
echo "  Image:      $IMAGE_NAME"
echo "  Tag:        $TAG"
echo ""

# Validate mode parameter
if [[ ! "$MODE" =~ ^(build|push|all)$ ]]; then
    echo "❌ Error: Invalid mode '$MODE'"
    echo ""
    echo "Usage: ./build_container.sh [build|push|all] [tag]"
    echo ""
    echo "Modes:"
    echo "  build - Build Docker image locally only"
    echo "  push  - Push previously built image to ACR"
    echo "  all   - Build and push (default)"
    echo ""
    exit 1
fi

# Execute based on mode
case "$MODE" in
    build)
        build_container
        ;;
    push)
        push_container
        ;;
    all)
        build_container
        push_container
        ;;
esac

echo ""
echo "================================================================"
echo "✅ Complete!"
echo "================================================================"
echo ""
```

**Key features:**
- Three modes: `build`, `push`, `all`
- `build` mode shows local testing instructions
- Supports optional version tag as second parameter
- Loads configuration from `.env`
- Removes hyphens from resource prefix for ACR name

---

### 5. Update Deployment Script
**File:** `deployment/deploy_script.sh`

**Modify the `deploy_app()` function** (replace lines 185-237):

```bash
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
```

**Changes made:**
- Removed ZIP bundle creation (`rm -f app_bundle.zip`, `zip` commands)
- Removed `uv pip compile` step
- Removed `az webapp config set` for startup command (defined in Dockerfile)
- Removed `az webapp deployment source config-zip`
- Added `az webapp config container set` to update container image reference
- Added `az webapp restart` to pull and run new container
- Added support for optional version tag parameter

**Keep `deploy_database()` function unchanged** - database initialization is independent of app deployment method.

---

## Implementation Checklist

- [ ] **1. Create `Dockerfile`** in project root
  - python:3.12-slim base image
  - Install uv package manager
  - Copy pyproject.toml and run uv sync
  - Copy app.py, chat_history_manager.py, .env
  - Expose port 8000
  - Streamlit startup command

- [ ] **2. Create `.dockerignore`** in project root
  - Exclude build artifacts, .venv, .git, deployment/
  - Do NOT exclude .env

- [ ] **3. Update `deployment/simplified.bicep`**
  - Add ACR resource (admin disabled)
  - Add RBAC role assignment (AcrPull to user-assigned identity)
  - Update App Service with:
    - `acrUseManagedIdentityCreds: true`
    - `acrUserManagedIdentityID: <clientId>`
    - `linuxFxVersion` pointing to ACR container
    - `DOCKER_REGISTRY_SERVER_URL` app setting
    - **`WEBSITES_PORT: '8000'`** app setting
  - Remove `SCM_DO_BUILD_DURING_DEPLOYMENT`
  - Add outputs for ACR login server and name

- [ ] **4. Create `deployment/build_container.sh`**
  - Implement build_container() function
  - Implement push_container() function
  - Support build/push/all modes
  - Support optional version tag parameter
  - Show local run instructions after build

- [ ] **5. Update `deployment/deploy_script.sh`**
  - Modify deploy_app() to use az webapp config container set
  - Remove all ZIP-related code
  - Add support for optional tag parameter
  - Keep deploy_database() unchanged

---

## Deployment Workflow

### First-Time Setup (Infrastructure + Initial Deploy)

```bash
# 1. Deploy infrastructure (creates ACR, PostgreSQL, Redis, etc.)
cd deployment
./deploy_infra.sh all

# 2. Build and push initial container image
./build_container.sh all

# 3. Deploy application (initialize database + deploy container)
./deploy_script.sh all
```

### Subsequent Deployments (Code Updates)

```bash
# Build and push new version with tag
cd deployment
./build_container.sh all v1.2.3

# Deploy new version to App Service
./deploy_script.sh app v1.2.3
```

### Local Development & Testing

```bash
# Build container locally
cd deployment
./build_container.sh build

# Run container locally (command shown in output)
docker run -p 8000:8000 stanley-dev-ui-app:latest

# Open browser to http://localhost:8000
```

### Database-Only Operations

```bash
# Initialize or update database schema only
cd deployment
./deploy_script.sh db
```

---

## Key Implementation Details

### 1. Managed Identity ACR Authentication

Uses `acrUseManagedIdentityCreds` and `acrUserManagedIdentityID` properties in Bicep instead of deprecated `DOCKER_ENABLE_CI` app setting.

**How it works:**
1. Bicep creates user-assigned managed identity
2. Bicep grants AcrPull role to the identity
3. App Service uses the identity to pull images from ACR
4. No admin credentials needed in app settings

### 2. No .env Migration to App Settings

The `.env` file remains the source of truth and is bundled in the container image. This means:
- No need to duplicate configuration in Azure App Settings
- Same configuration locally and in Azure
- Simpler deployment (fewer moving parts)
- .env values can still be overridden by App Settings if needed in the future

### 3. WEBSITES_PORT Configuration

**Critical:** Azure App Service needs to know which port the container listens on.

- Default: Azure expects port 80
- Our app: Streamlit listens on port 8000
- Solution: Set `WEBSITES_PORT=8000` in app settings

**Without this setting:**
- Azure forwards requests to port 80 in container
- Streamlit is not listening on port 80
- Result: Connection refused, app fails to start

**With this setting:**
- Azure forwards requests to port 8000 in container
- Streamlit is listening on port 8000
- Result: ✅ Connection successful

### 4. Build Script Modes

Separate `build` and `push` modes allow:
- Local testing before pushing to ACR
- CI/CD pipelines can call build and push separately
- Faster iteration during development

### 5. RBAC in Bicep

Role assignment is declarative in Bicep, avoiding manual `az resource update` commands. The `dependsOn` ensures proper sequencing.

---

## Port Mapping Explained

### Local Docker Run
```bash
docker run -p 8000:8000 myapp:latest
         ↑   ↑
         │   └─ Container internal port (where Streamlit listens)
         └───── Host port (where you access it)
```

### Azure App Service
```
Internet → Azure LB (443/80) → App Service → Container (port WEBSITES_PORT)
                                             ↑
                                             └─ 8000 (set via WEBSITES_PORT app setting)
```

- Azure automatically handles external → internal mapping
- You only configure which port the container listens on
- No manual port mapping needed (unlike `docker run -p`)

---

## Benefits of Container Deployment

### Performance
- **Faster deployments:** 30-60 seconds (vs 2-3 minutes for ZIP + Oryx build)
- **Faster cold starts:** Pre-built dependencies in image
- **Consistent performance:** No build step during deployment

### Reliability
- **Reproducible builds:** Locked dependencies in container image
- **Same image across environments:** Dev, staging, prod use identical container
- **Easy rollbacks:** Reference previous container tags
- **No build failures in production:** Build happens before deployment

### Security
- **Managed identity authentication:** No admin credentials in app settings
- **Immutable deployments:** Container images are read-only
- **Secrets in .env:** Configuration bundled in image (can migrate to Key Vault later)

### Developer Experience
- **Local/prod parity:** Test exact production container locally
- **Simpler deployment:** No `requirements.txt` generation needed
- **Version tagging:** Semantic versioning for deployments
- **Better debugging:** Run production image locally with same environment

---

## Troubleshooting

### Container won't start

**Check logs:**
```bash
az webapp log tail -g <resource-group> -n <app-name>
```

**Common issues:**
- Missing `WEBSITES_PORT=8000` (app expects port 80)
- .env file missing from container
- Dependencies not installed correctly
- Streamlit command syntax error

### Can't push to ACR

**Check authentication:**
```bash
az acr login --name <acr-name>
```

**Check RBAC:**
```bash
az role assignment list --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr-name>
```

### App Service can't pull image

**Check managed identity:**
```bash
az webapp identity show -g <resource-group> -n <app-name>
```

**Check ACR configuration:**
```bash
az webapp config show -g <resource-group> -n <app-name> --query "acrUseManagedIdentityCreds"
az webapp config show -g <resource-group> -n <app-name> --query "acrUserManagedIdentityID"
```

---

## Future Enhancements (Optional)

### Multi-stage Docker Build
Optimize image size by using builder stage:
```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY pyproject.toml .
RUN pip install uv && uv sync

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /app/.venv .venv
COPY app.py chat_history_manager.py .env ./
CMD [".venv/bin/streamlit", "run", "app.py", "--server.port=8000", "--server.address=0.0.0.0"]
```

### VNet Integration
Lock down PostgreSQL and Redis to VNet only:
- Add VNet to Bicep
- Enable VNet integration on App Service
- Update PostgreSQL/Redis firewall rules to deny public access

### Key Vault for Secrets
Migrate .env secrets to Azure Key Vault:
- Store sensitive values (passwords, keys) in Key Vault
- Reference in Bicep: `@Microsoft.KeyVault(SecretUri=...)`
- Keep non-sensitive config in .env

### Health Check Endpoint
Add health check to Streamlit app:
```python
# In app.py before main()
if st.query_params.get('health') == 'check':
    st.write('OK')
    st.stop()
```

Configure in Bicep:
```bicep
healthCheckPath: '/?health=check'
```

### CI/CD Pipeline
Automate build and deployment:
```yaml
# GitHub Actions / Azure DevOps
- Build container on commit
- Push to ACR with commit SHA tag
- Deploy to dev environment automatically
- Manual approval for production
```

---

## Summary

This migration moves from ZIP-based deployment with Oryx build to containerized deployment with Azure Container Registry. The key changes are:

1. **New files:** Dockerfile, .dockerignore, build_container.sh
2. **Bicep updates:** Add ACR, RBAC, update App Service config
3. **Script updates:** Replace ZIP deployment with container deployment
4. **Configuration:** WEBSITES_PORT=8000, managed identity authentication

The migration maintains the same application functionality while improving deployment speed, reliability, and developer experience.
