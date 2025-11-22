#!/bin/bash

# Voting Application AKS Deployment Script
# This script automates the deployment process

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install it first."
        exit 1
    fi
    
    print_info "All prerequisites are installed."
}

# Set variables
set_variables() {
    print_info "Setting up variables..."
    
    read -p "Enter Resource Group name (default: voting-app-rg): " RESOURCE_GROUP
    RESOURCE_GROUP=${RESOURCE_GROUP:-voting-app-rg}
    
    read -p "Enter Location (default: eastus): " LOCATION
    LOCATION=${LOCATION:-eastus}
    
    read -p "Enter AKS Cluster name (default: voting-app-aks): " AKS_CLUSTER_NAME
    AKS_CLUSTER_NAME=${AKS_CLUSTER_NAME:-voting-app-aks}
    
    read -p "Enter ACR name (must be globally unique, leave empty for auto-generated): " ACR_NAME
    if [ -z "$ACR_NAME" ]; then
        ACR_NAME="votingapp$(openssl rand -hex 3)"
        print_info "Generated ACR name: $ACR_NAME"
    fi
    
    NODE_COUNT=${NODE_COUNT:-3}
    NODE_VM_SIZE=${NODE_VM_SIZE:-Standard_B2s}
    
    print_info "Variables set:"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Location: $LOCATION"
    echo "  AKS Cluster: $AKS_CLUSTER_NAME"
    echo "  ACR Name: $ACR_NAME"
}

# Create Azure resources
create_azure_resources() {
    print_info "Creating Azure resources..."
    
    # Create resource group
    print_info "Creating resource group..."
    az group create --name $RESOURCE_GROUP --location $LOCATION || true
    
    # Create ACR
    print_info "Creating Azure Container Registry..."
    az acr create \
        --resource-group $RESOURCE_GROUP \
        --name $ACR_NAME \
        --sku Basic \
        --admin-enabled true || print_warn "ACR may already exist"
    
    # Create AKS cluster
    print_info "Creating AKS cluster (this may take 10-15 minutes)..."
    az aks create \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --node-count $NODE_COUNT \
        --node-vm-size $NODE_VM_SIZE \
        --enable-managed-identity \
        --attach-acr $ACR_NAME \
        --generate-ssh-keys || print_warn "AKS cluster may already exist"
    
    # Get AKS credentials
    print_info "Getting AKS credentials..."
    az aks get-credentials \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --overwrite-existing
    
    print_info "Azure resources created successfully."
}

# Build and push images
build_and_push_images() {
    print_info "Building and pushing Docker images..."
    
    ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv)
    print_info "ACR Login Server: $ACR_LOGIN_SERVER"
    
    # Login to ACR
    az acr login --name $ACR_NAME
    
    # Build and push Vote service
    print_info "Building Vote service..."
    cd ../vote
    docker build -t $ACR_LOGIN_SERVER/vote:v2 .
    docker push $ACR_LOGIN_SERVER/vote:v2
    
    # Build and push Result service
    print_info "Building Result service..."
    cd ../result
    docker build -t $ACR_LOGIN_SERVER/result:v2 .
    docker push $ACR_LOGIN_SERVER/result:v2
    
    # Build and push Worker service
    print_info "Building Worker service..."
    cd ../worker
    docker build -t $ACR_LOGIN_SERVER/worker:v2 .
    docker push $ACR_LOGIN_SERVER/worker:v2
    
    cd ../aks
    print_info "Images built and pushed successfully."
}

# Update deployment files with ACR name
update_deployment_files() {
    print_info "Updating deployment files with ACR name..."
    
    ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv)
    
    # Update deployment files
    sed -i.bak "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" vote-deployment.yaml
    sed -i.bak "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" result-deployment.yaml
    sed -i.bak "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" worker-deployment.yaml
    
    # Clean up backup files
    rm -f *.bak
    
    print_info "Deployment files updated."
}

# Deploy to Kubernetes
deploy_to_kubernetes() {
    print_info "Deploying to Kubernetes..."
    
    # Create namespace
    kubectl apply -f namespace.yaml
    
    # Create ConfigMap and Secrets
    kubectl apply -f configmap.yaml
    kubectl apply -f secret.yaml
    
    # Deploy database services
    print_info "Deploying PostgreSQL..."
    kubectl apply -f postgres-deployment.yaml
    kubectl apply -f postgres-service.yaml
    
    print_info "Deploying Redis..."
    kubectl apply -f redis-deployment.yaml
    kubectl apply -f redis-service.yaml
    
    # Wait for database services
    print_info "Waiting for database services to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgres -n voting-app --timeout=300s || true
    kubectl wait --for=condition=ready pod -l app=redis -n voting-app --timeout=300s || true
    
    # Deploy application services
    print_info "Deploying Worker..."
    kubectl apply -f worker-deployment.yaml
    
    print_info "Deploying Vote service..."
    kubectl apply -f vote-deployment.yaml
    kubectl apply -f vote-service.yaml
    
    print_info "Deploying Result service..."
    kubectl apply -f result-deployment.yaml
    kubectl apply -f result-service.yaml
    
    print_info "Deployment completed."
}

# Verify deployment
verify_deployment() {
    print_info "Verifying deployment..."
    
    echo ""
    print_info "Pod Status:"
    kubectl get pods -n voting-app
    
    echo ""
    print_info "Service Status:"
    kubectl get services -n voting-app
    
    echo ""
    print_info "Deployment Status:"
    kubectl get deployments -n voting-app
}

# Main execution
main() {
    print_info "Starting Voting Application AKS Deployment..."
    
    check_prerequisites
    set_variables
    
    read -p "Do you want to create Azure resources? (y/n): " create_resources
    if [[ $create_resources == "y" ]]; then
        create_azure_resources
    fi
    
    read -p "Do you want to build and push images? (y/n): " build_images
    if [[ $build_images == "y" ]]; then
        build_and_push_images
        update_deployment_files
    fi
    
    read -p "Do you want to deploy to Kubernetes? (y/n): " deploy_k8s
    if [[ $deploy_k8s == "y" ]]; then
        deploy_to_kubernetes
        verify_deployment
    fi
    
    print_info "Deployment script completed!"
    print_info "Use 'kubectl get pods -n voting-app' to check pod status"
    print_info "Use 'kubectl get services -n voting-app' to check services"
}

# Run main function
main

