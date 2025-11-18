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

    docker buildx build --platform linux/amd64 -t "$IMAGE_NAME:$TAG" -f Dockerfile .

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
