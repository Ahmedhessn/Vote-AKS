# Voting Application AKS Deployment Script (PowerShell)
# This script automates the deployment process for Windows

param(
    [string]$ResourceGroup = "voting-app-rg",
    [string]$Location = "eastus",
    [string]$AksClusterName = "voting-app-aks",
    [string]$AcrName = "",
    [int]$NodeCount = 3,
    [string]$NodeVmSize = "Standard_B2s",
    [switch]$SkipAzureResources,
    [switch]$SkipBuildImages,
    [switch]$SkipDeploy
)

# Function to print colored output
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# Check prerequisites
function Test-Prerequisites {
    Write-Info "Checking prerequisites..."
    
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Error "Azure CLI is not installed. Please install it first."
        exit 1
    }
    
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Error "kubectl is not installed. Please install it first."
        exit 1
    }
    
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Docker is not installed. Please install it first."
        exit 1
    }
    
    Write-Info "All prerequisites are installed."
}

# Create Azure resources
function New-AzureResources {
    param(
        [string]$ResourceGroup,
        [string]$Location,
        [string]$AksClusterName,
        [string]$AcrName,
        [int]$NodeCount,
        [string]$NodeVmSize
    )
    
    Write-Info "Creating Azure resources..."
    
    # Create resource group
    Write-Info "Creating resource group..."
    az group create --name $ResourceGroup --location $Location | Out-Null
    
    # Generate ACR name if not provided
    if ([string]::IsNullOrEmpty($AcrName)) {
        $randomSuffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object {[char]$_})
        $AcrName = "votingapp$randomSuffix"
        Write-Info "Generated ACR name: $AcrName"
    }
    
    # Create ACR
    Write-Info "Creating Azure Container Registry..."
    az acr create `
        --resource-group $ResourceGroup `
        --name $AcrName `
        --sku Basic `
        --admin-enabled true | Out-Null
    
    # Create AKS cluster
    Write-Info "Creating AKS cluster (this may take 10-15 minutes)..."
    az aks create `
        --resource-group $ResourceGroup `
        --name $AksClusterName `
        --node-count $NodeCount `
        --node-vm-size $NodeVmSize `
        --enable-managed-identity `
        --attach-acr $AcrName `
        --generate-ssh-keys | Out-Null
    
    # Get AKS credentials
    Write-Info "Getting AKS credentials..."
    az aks get-credentials `
        --resource-group $ResourceGroup `
        --name $AksClusterName `
        --overwrite-existing | Out-Null
    
    Write-Info "Azure resources created successfully."
    return $AcrName
}

# Build and push images
function Build-AndPushImages {
    param(
        [string]$AcrName,
        [string]$ResourceGroup
    )
    
    Write-Info "Building and pushing Docker images..."
    
    $AcrLoginServer = az acr show --name $AcrName --resource-group $ResourceGroup --query loginServer --output tsv
    
    Write-Info "ACR Login Server: $AcrLoginServer"
    
    # Login to ACR
    az acr login --name $AcrName | Out-Null
    
    # Build and push Vote service
    Write-Info "Building Vote service..."
    Set-Location ..\vote
    docker build -t "$AcrLoginServer/vote:v2" .
    docker push "$AcrLoginServer/vote:v2"
    
    # Build and push Result service
    Write-Info "Building Result service..."
    Set-Location ..\result
    docker build -t "$AcrLoginServer/result:v2" .
    docker push "$AcrLoginServer/result:v2"
    
    # Build and push Worker service
    Write-Info "Building Worker service..."
    Set-Location ..\worker
    docker build -t "$AcrLoginServer/worker:v2" .
    docker push "$AcrLoginServer/worker:v2"
    
    Set-Location ..\aks
    Write-Info "Images built and pushed successfully."
}

# Update deployment files with ACR name
function Update-DeploymentFiles {
    param(
        [string]$AcrName,
        [string]$ResourceGroup
    )
    
    Write-Info "Updating deployment files with ACR name..."
    
    $AcrLoginServer = az acr show --name $AcrName --resource-group $ResourceGroup --query loginServer --output tsv
    
    # Update deployment files
    (Get-Content vote-deployment.yaml) -replace '<ACR_NAME>', $AcrLoginServer | Set-Content vote-deployment.yaml
    (Get-Content result-deployment.yaml) -replace '<ACR_NAME>', $AcrLoginServer | Set-Content result-deployment.yaml
    (Get-Content worker-deployment.yaml) -replace '<ACR_NAME>', $AcrLoginServer | Set-Content worker-deployment.yaml
    
    Write-Info "Deployment files updated."
}

# Deploy to Kubernetes
function Deploy-ToKubernetes {
    Write-Info "Deploying to Kubernetes..."
    
    # Create namespace
    kubectl apply -f namespace.yaml | Out-Null
    
    # Create ConfigMap and Secrets
    kubectl apply -f configmap.yaml | Out-Null
    kubectl apply -f secret.yaml | Out-Null
    
    # Deploy database services
    Write-Info "Deploying PostgreSQL..."
    kubectl apply -f postgres-deployment.yaml | Out-Null
    kubectl apply -f postgres-service.yaml | Out-Null
    
    Write-Info "Deploying Redis..."
    kubectl apply -f redis-deployment.yaml | Out-Null
    kubectl apply -f redis-service.yaml | Out-Null
    
    # Wait for database services
    Write-Info "Waiting for database services to be ready..."
    Start-Sleep -Seconds 10
    kubectl wait --for=condition=ready pod -l app=postgres -n voting-app --timeout=300s -ErrorAction SilentlyContinue | Out-Null
    kubectl wait --for=condition=ready pod -l app=redis -n voting-app --timeout=300s -ErrorAction SilentlyContinue | Out-Null
    
    # Deploy application services
    Write-Info "Deploying Worker..."
    kubectl apply -f worker-deployment.yaml | Out-Null
    
    Write-Info "Deploying Vote service..."
    kubectl apply -f vote-deployment.yaml | Out-Null
    kubectl apply -f vote-service.yaml | Out-Null
    
    Write-Info "Deploying Result service..."
    kubectl apply -f result-deployment.yaml | Out-Null
    kubectl apply -f result-service.yaml | Out-Null
    
    Write-Info "Deployment completed."
}

# Verify deployment
function Test-Deployment {
    Write-Info "Verifying deployment..."
    
    Write-Host ""
    Write-Info "Pod Status:"
    kubectl get pods -n voting-app
    
    Write-Host ""
    Write-Info "Service Status:"
    kubectl get services -n voting-app
    
    Write-Host ""
    Write-Info "Deployment Status:"
    kubectl get deployments -n voting-app
}

# Main execution
function Main {
    Write-Info "Starting Voting Application AKS Deployment..."
    
    Test-Prerequisites
    
    if (-not $SkipAzureResources) {
        $script:AcrName = New-AzureResources -ResourceGroup $ResourceGroup -Location $Location -AksClusterName $AksClusterName -AcrName $AcrName -NodeCount $NodeCount -NodeVmSize $NodeVmSize
    } else {
        if ([string]::IsNullOrEmpty($AcrName)) {
            Write-Error "ACR name must be provided when skipping Azure resource creation."
            exit 1
        }
        $script:AcrName = $AcrName
    }
    
    if (-not $SkipBuildImages) {
        Build-AndPushImages -AcrName $script:AcrName -ResourceGroup $ResourceGroup
        Update-DeploymentFiles -AcrName $script:AcrName -ResourceGroup $ResourceGroup
    }
    
    if (-not $SkipDeploy) {
        Deploy-ToKubernetes
        Test-Deployment
    }
    
    Write-Info "Deployment script completed!"
    Write-Info "Use 'kubectl get pods -n voting-app' to check pod status"
    Write-Info "Use 'kubectl get services -n voting-app' to check services"
}

# Run main function
Main

