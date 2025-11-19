# DAPE OpsAgent Manager

A Streamlit-based chat UI (ChatGPT-like interface) with persistent chat history, multiple model support, Azure Easy Auth SSO integration, and PostgreSQL/Redis backend.

## Features

- ChatGPT-like interface with persistent conversation history
- Multiple LLM model support (configurable)
- Azure Easy Auth (SSO) integration
- PostgreSQL database for conversation persistence
- **Write-through Redis caching** for improved performance (all writes go to both cache and database)
- **Flexible storage modes** configured via `CHAT_HISTORY_MODE` in `.env` (local, postgres, redis)
- Container-based deployment to Azure App Service
- **VNet Integration with NAT Gateway** for network isolation and static outbound IP
- **Network-isolated PostgreSQL** with IP whitelisting (only App Service can connect)
- Secure infrastructure with Managed Identity and Key Vault

## Table of Contents

- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Local Development](#local-development)
- [Deployment Sequence](#deployment-sequence)
- [Deployment Scripts Reference](#deployment-scripts-reference)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Tools

- **Azure CLI**: [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- **Docker**: [Install Docker](https://docs.docker.com/get-docker/)
- **PostgreSQL Client (psql)**: For database initialization
  - macOS: `brew install postgresql`
  - Ubuntu: `sudo apt-get install postgresql-client`
  - Windows: [Download PostgreSQL](https://www.postgresql.org/download/)
- **Python 3.12+**: For local development
- **uv** (recommended): `pip install uv` or [install uv](https://github.com/astral-sh/uv)

### Azure Requirements

- Azure subscription with appropriate permissions
- Azure AD App Registration for Easy Auth (SSO)
  - Note: Not required for sandbox environments (resource prefix containing 'sbx')

## Configuration

### 1. Setup Environment File

Copy the example environment file and configure it with your values:

```bash
cp .env.example .env
```

### 2. Configure Required Variables

Edit `.env` and set the following **minimum required** values:

```bash
# Azure Configuration
AZURE_SUBSCRIPTION_ID=your-subscription-id
AZURE_RESOURCE_GROUP=your-resource-group-name
AZURE_LOCATION=eastus
RESOURCE_PREFIX=stanley-dev-ui

# Virtual Network Configuration
VNET_ADDRESS_SPACE=10.0.0.0/16
SUBNET_ADDRESS_PREFIX=10.0.1.0/26

# PostgreSQL Configuration
POSTGRES_ADMIN_LOGIN=pgadmin
POSTGRES_ADMIN_PASSWORD=YourSecurePassword123!
POSTGRES_DATABASE=chat_history
POSTGRES_SKU=Standard_B1ms
POSTGRES_STORAGE_GB=32

# App Service Configuration
APP_SERVICE_SKU=b1
TOKEN_PROVIDER_APP_ID=your-azure-ad-app-id

# Chat History Mode - CONFIGURES STORAGE BACKEND
# Options: local | local_psql | postgres | local_redis | redis
# Redis modes use write-through caching (writes to both cache and database)
CHAT_HISTORY_MODE=local
```

**IMPORTANT**: `CHAT_HISTORY_MODE` in `.env` controls where chat conversations are stored. For production with caching, use `redis` mode (write-through to PostgreSQL + Redis).

See `.env.example` for complete configuration options and descriptions.

## Local Development

### Install Dependencies

Using **uv** (recommended):
```bash
uv sync
```

Using **pip**:
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
uv pip compile pyproject.toml -o requirements.txt
pip install -r requirements.txt
```

### Run the Application

```bash
streamlit run app.py
```

The app will be available at `http://localhost:8501`.

### Testing with Azure PostgreSQL Locally

1. Deploy infrastructure first (see [Deployment Sequence](#deployment-sequence))
2. Update `.env` with your PostgreSQL hostname and **set `CHAT_HISTORY_MODE`**:
   ```bash
   # Set storage mode in .env
   CHAT_HISTORY_MODE=local_psql
   POSTGRES_HOST=your-prefix-postgres.postgres.database.azure.com
   ```
3. Run the app locally - it will connect to Azure PostgreSQL with test credentials

**Testing Write-Through Redis Cache Locally**:
```bash
# Set storage mode to local_redis in .env
CHAT_HISTORY_MODE=local_redis
REDIS_HOST=your-prefix-redis.redis.cache.windows.net
REDIS_PASSWORD=your-redis-key
```
This mode writes to both PostgreSQL and Redis simultaneously (write-through caching).

## Deployment Sequence

Follow these steps in order to deploy the complete solution to Azure:

### Step 1: Deploy Resource Group

```bash
cd deployment
./deploy_infra.sh rg
```

This creates the Azure resource group in your specified location.

### Step 2: Deploy Infrastructure

```bash
./deploy_infra.sh app
```

This provisions all Azure resources using Bicep:
- App Service Plan (Linux)
- App Service (Python 3.12 runtime) with VNet integration
- Virtual Network with delegated subnet for App Service
- NAT Gateway with static public IP for outbound traffic
- PostgreSQL Flexible Server (network-isolated, NAT Gateway IP whitelisted)
- Redis Cache
- Azure Container Registry (ACR)
- Key Vault
- Application Insights + Log Analytics
- User-assigned Managed Identity
- Easy Auth configuration (if not sandbox)

### Step 3: Build Container Image

```bash
./build_container.sh build
```

This builds the Docker image for the Streamlit application:
- Platform: `linux/amd64`
- Bundles app code and dependencies
- Tags as `{RESOURCE_PREFIX}-app:latest`

To test locally before pushing:
```bash
docker run -p 8000:8000 stanley-dev-ui-app:latest
```

### Step 4: Push Container to ACR

```bash
./build_container.sh push
```

This pushes the built image to your Azure Container Registry.

**Alternative**: Build and push in one step:
```bash
./build_container.sh all
```

### Step 5: Initialize Database

```bash
./deploy_script.sh db
```

This initializes the PostgreSQL database:
- Adds your client IP to firewall rules (persistent)
- Runs `init.sql` to create tables and schema
- Configures database for chat history storage

### Step 6: Deploy Application

```bash
./deploy_script.sh app
```

This deploys the containerized app to Azure App Service:
- Configures App Service to pull from ACR
- Sets up Managed Identity for ACR authentication
- Restarts the app with new container image

**Alternative**: Deploy database and app together:
```bash
./deploy_script.sh all
```

### Access Your Application

After deployment completes (wait ~2 minutes for app startup):

```
https://{RESOURCE_PREFIX}-app.azurewebsites.net
```

Example: `https://stanley-dev-ui-app.azurewebsites.net`

## Deployment Scripts Reference

### deploy_infra.sh

Deploys Azure infrastructure using Bicep templates.

```bash
# Usage
./deploy_infra.sh [rg|app] [--what-if]

# Examples
./deploy_infra.sh rg              # Deploy resource group
./deploy_infra.sh app             # Deploy infrastructure
./deploy_infra.sh app --what-if   # Preview changes (dry run)
```

**Modes:**
- `rg`: Creates resource group only (`rg.bicep`)
- `app`: Deploys full infrastructure (`simplified.bicep`)

**Options:**
- `--what-if`: Preview changes without deploying

### build_container.sh

Builds and pushes Docker images to Azure Container Registry.

```bash
# Usage
./build_container.sh [build|push|all] [tag]

# Examples
./build_container.sh build         # Build image locally
./build_container.sh push          # Push existing image to ACR
./build_container.sh all           # Build and push
./build_container.sh all v1.2.3    # Build and push with version tag
```

**Modes:**
- `build`: Build Docker image locally only
- `push`: Push previously built image to ACR
- `all`: Build and push (default)

**Parameters:**
- `tag`: Optional version tag (default: `latest`)

### deploy_script.sh

Initializes database and deploys the application.

```bash
# Usage
./deploy_script.sh [db|app|all]

# Examples
./deploy_script.sh db    # Initialize database only
./deploy_script.sh app   # Deploy application only
./deploy_script.sh all   # Deploy both (default)
```

**Modes:**
- `db`: Initialize PostgreSQL database only
- `app`: Deploy application container only
- `all`: Deploy both database and application (default)

## Architecture

### Application Components

```
┌────────────────────────────────────────────────────────────┐
│              Virtual Network (10.0.0.0/16)                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │        App Service Subnet (10.0.1.0/26)              │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │     Azure App Service (Linux)                  │  │  │
│  │  │  ┌──────────────────────────────────────────┐  │  │  │
│  │  │  │  Streamlit Container (Python 3.12)       │  │  │  │
│  │  │  │  - app.py (main UI)                     │  │  │  │
│  │  │  │  - chat_history_manager.py (storage)    │  │  │  │
│  │  │  │  - Azure Easy Auth (SSO headers)        │  │  │  │
│  │  │  └──────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                           │                                 │
│                           │ (NAT Gateway)                   │
│                           ▼                                 │
│                  ┌─────────────────┐                        │
│                  │   Static Public  │                        │
│                  │   IP Address     │                        │
│                  └─────────────────┘                        │
└────────────────────────────────────────────────────────────┘
                            │
              All outbound traffic uses this IP
                            │
          ┌─────────────────┴─────────────────┐
          ▼                                   ▼
┌──────────────────────┐          ┌──────────────────┐
│  PostgreSQL          │          │  Redis Cache     │
│  Flexible Server     │          │  (Premium)       │
│                      │          │                  │
│  - Conversations     │          │  - WRITE-THROUGH │
│  - Messages          │          │  - 30min TTL     │
│  - PRIMARY STORE     │          │  - Cache Layer   │
│  - Firewall:         │          └──────────────────┘
│    Only NAT Gateway  │
│    IP whitelisted    │
└──────────────────────┘
    (writes go to both simultaneously)
```

### Key Components

- **App Service**: Hosts the containerized Streamlit application with VNet integration
- **Virtual Network**: Isolated network with delegated subnet for App Service integration
- **NAT Gateway**: Provides static outbound public IP for all App Service traffic
- **PostgreSQL**: Primary persistent storage for chat conversations and messages (network-isolated with IP whitelisting)
- **Redis**: Write-through caching layer for improved performance (optional, controlled by `CHAT_HISTORY_MODE` in `.env`)
- **Container Registry**: Private Docker registry for app images
- **Key Vault**: Secure storage for secrets (DB passwords, Redis keys)
- **Application Insights**: Monitoring and logging
- **Managed Identity**: Secure authentication between Azure services

**Write-Through Caching**: When `CHAT_HISTORY_MODE=redis` or `CHAT_HISTORY_MODE=local_redis`, the application writes to both Redis and PostgreSQL simultaneously. This ensures data consistency while providing fast read access from cache.

### Storage Modes

**IMPORTANT**: The application uses **write-through caching** - all writes go to both Redis cache and PostgreSQL database simultaneously, ensuring data consistency and durability.

The storage backend is configured via the **`CHAT_HISTORY_MODE`** environment variable in your `.env` file:

| Mode | Description | Use Case |
|------|-------------|----------|
| `local` | JSON files (`.chat_history/`) | Local development, no database |
| `local_psql` | Azure PostgreSQL + test user | Local dev with Azure DB |
| `postgres` | Azure PostgreSQL + SSO user | Production (Azure-deployed) |
| `local_redis` | **PostgreSQL + Redis + test user (write-through)** | Local dev with cache |
| `redis` | **PostgreSQL + Redis + SSO user (write-through)** | Production with caching |

**Configuration Location**: Set `CHAT_HISTORY_MODE=<mode>` in your `.env` file

### Security Features

- **VNet Integration**: App Service runs in isolated Virtual Network with dedicated subnet
- **NAT Gateway**: All outbound traffic routed through static public IP for consistent IP whitelisting
- **Network Isolation**: PostgreSQL firewall only allows connections from NAT Gateway IP (no public access)
- **Managed Identity**: No credentials in code, secure service-to-service auth
- **Key Vault**: Centralized secret management
- **Easy Auth**: Azure AD SSO integration (production)
- **SSL/TLS**: All connections encrypted (PostgreSQL, Redis, HTTPS)
- **Route All Traffic**: `vnetRouteAllEnabled` ensures all App Service outbound traffic uses VNet/NAT Gateway

### Network Architecture

The application uses **VNet Integration** with a **NAT Gateway** to provide network isolation and consistent outbound IP addressing:

**How it works:**
1. App Service is integrated into a dedicated subnet (`appServiceSubnet`) within a Virtual Network
2. The subnet is delegated to `Microsoft.Web/serverFarms` for App Service use
3. A NAT Gateway is attached to the subnet, providing a static public IP
4. All outbound traffic from the App Service routes through the NAT Gateway
5. PostgreSQL firewall is configured to **only allow** connections from the NAT Gateway's public IP

**Benefits:**
- **Consistent IP**: All outbound traffic uses a single, predictable static IP address
- **Network Security**: PostgreSQL is not publicly accessible - only App Service can connect
- **Compliance**: Meets security requirements for network isolation and IP whitelisting
- **Scalability**: NAT Gateway handles multiple App Service instances seamlessly

**Configuration:**
- VNet CIDR: Configurable via `VNET_ADDRESS_SPACE` in `.env` (default: `10.0.0.0/16`)
- Subnet CIDR: Configurable via `SUBNET_ADDRESS_PREFIX` in `.env` (default: `10.0.1.0/26` - 64 addresses)
- NAT Gateway IP: Automatically provisioned and output after deployment

**Viewing NAT Gateway IP:**
```bash
# Get the NAT Gateway public IP (used to whitelist in PostgreSQL)
az deployment group show \
  -g $AZURE_RESOURCE_GROUP \
  -n <deployment-name> \
  --query properties.outputs.natGatewayPublicIP.value -o tsv
```

## Troubleshooting

### View Application Logs

```bash
az webapp log tail -g $AZURE_RESOURCE_GROUP -n ${RESOURCE_PREFIX}-app
```

### View Configuration

```bash
az webapp config appsettings list -g $AZURE_RESOURCE_GROUP -n ${RESOURCE_PREFIX}-app
```

### Restart Application

```bash
az webapp restart -g $AZURE_RESOURCE_GROUP -n ${RESOURCE_PREFIX}-app
```

### SSH into Container

```bash
az webapp ssh -g $AZURE_RESOURCE_GROUP -n ${RESOURCE_PREFIX}-app
```

### Check PostgreSQL Connection

```bash
# From your local machine (requires firewall rule)
psql -h ${RESOURCE_PREFIX}-postgres.postgres.database.azure.com \
     -U $POSTGRES_ADMIN_LOGIN \
     -d $POSTGRES_DATABASE
```

### Common Issues

**Issue**: Database initialization fails with connection timeout
- **Cause**: PostgreSQL firewall is configured to only allow NAT Gateway IP (network-isolated)
- **Solution**: Temporarily add your local IP to access database during initialization
  ```bash
  # Add your IP for database initialization
  az postgres flexible-server firewall-rule create \
    -g $AZURE_RESOURCE_GROUP \
    -n ${RESOURCE_PREFIX}-postgres \
    --rule-name temp-local-access \
    --start-ip-address $(curl -s https://api.ipify.org) \
    --end-ip-address $(curl -s https://api.ipify.org)

  # Remove after initialization (optional - keeps production secure)
  az postgres flexible-server firewall-rule delete \
    -g $AZURE_RESOURCE_GROUP \
    -n ${RESOURCE_PREFIX}-postgres \
    --rule-name temp-local-access --yes
  ```
- **Note**: The `deploy_script.sh db` command automatically adds/removes your IP during initialization

**Issue**: Container deployment fails
- **Solution**: Check ACR authentication and image availability
  ```bash
  # Login to ACR
  az acr login --name $(echo ${RESOURCE_PREFIX} | tr -d '-')acr

  # List images
  az acr repository list --name $(echo ${RESOURCE_PREFIX} | tr -d '-')acr
  ```

**Issue**: App won't start after deployment
- **Solution**: Check app service logs for errors
  ```bash
  az webapp log tail -g $AZURE_RESOURCE_GROUP -n ${RESOURCE_PREFIX}-app
  ```

**Issue**: "Local Mode" showing instead of username
- **Solution**: Verify Easy Auth is enabled (not for sandbox environments)
  ```bash
  az webapp auth show -g $AZURE_RESOURCE_GROUP -n ${RESOURCE_PREFIX}-app
  ```

## Project Structure

```
streamlit-ui/
├── app.py                          # Main Streamlit application
├── chat_history_manager.py         # Chat persistence layer
├── pyproject.toml                  # Python dependencies
├── Dockerfile                      # Container image definition
├── .env.example                    # Environment configuration template
├── deployment/
│   ├── deploy_infra.sh            # Infrastructure deployment script
│   ├── build_container.sh         # Container build/push script
│   ├── deploy_script.sh           # App deployment script
│   ├── rg.bicep                   # Resource group Bicep template
│   ├── simplified.bicep           # Main infrastructure Bicep template
│   └── init.sql                   # Database initialization SQL
└── README.md                       # This file
```

## Contributing

When modifying the application:

1. Test locally first with `CHAT_HISTORY_MODE=local`
2. Test with Azure PostgreSQL using `CHAT_HISTORY_MODE=local_psql`
3. Build and test container locally
4. Deploy to Azure and verify

## License

[Add your license here]

## Support

For issues and questions:
- Check [Troubleshooting](#troubleshooting) section
- Review application logs
- Check Azure Portal for resource status
