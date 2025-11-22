# Voting Application - AKS Deployment Guide

This guide provides step-by-step instructions to deploy the Voting Application on Azure Kubernetes Service (AKS).

## Prerequisites

1. **Azure CLI** installed and configured

   ```bash
   az --version
   az login
   ```

2. **kubectl** installed

   ```bash
   kubectl version --client
   ```

3. **Docker** installed (for building images)

4. **Azure Subscription** with appropriate permissions

5. **Azure Container Registry (ACR)** - We'll create this in the guide

## Architecture Overview

The Voting Application consists of:

- **Vote Service** (Python/Flask) - Frontend for voting
- **Result Service** (Node.js) - Frontend for viewing results
- **Worker Service** (C#/.NET) - Background worker processing votes
- **PostgreSQL** - Database for storing votes
- **Redis** - Cache/Message queue

## Step 1: Create Azure Resources

### 1.1 Set Variables

```bash
# Set your variables
RESOURCE_GROUP="voting-app-rg"
LOCATION="eastus"  # Change to your preferred region
AKS_CLUSTER_NAME="voting-app-aks"
ACR_NAME="votingapp$(openssl rand -hex 3)"  # ACR name must be globally unique
NODE_COUNT=3
NODE_VM_SIZE="Standard_B2s"  # Adjust based on your needs
```

### 1.2 Create Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

### 1.3 Create Azure Container Registry (ACR)

```bash
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --admin-enabled true
```

### 1.4 Create AKS Cluster

```bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --node-count $NODE_COUNT \
  --node-vm-size $NODE_VM_SIZE \
  --enable-managed-identity \
  --attach-acr $ACR_NAME \
  --generate-ssh-keys
```

**Note:** This may take 10-15 minutes to complete.

### 1.5 Get AKS Credentials

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --overwrite-existing
```

### 1.6 Verify Cluster Connection

```bash
kubectl get nodes
```

## Step 2: Build and Push Docker Images

### 2.1 Login to ACR

```bash
az acr login --name $ACR_NAME
```

### 2.2 Build and Push Images

```bash
# Get ACR login server
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv)

# Build and push Vote service
cd ../vote
docker build -t $ACR_LOGIN_SERVER/vote:v2 .
docker push $ACR_LOGIN_SERVER/vote:v2

# Build and push Result service
cd ../result
docker build -t $ACR_LOGIN_SERVER/result:v2 .
docker push $ACR_LOGIN_SERVER/result:v2

# Build and push Worker service
cd ../worker
docker build -t $ACR_LOGIN_SERVER/worker:v2 .
docker push $ACR_LOGIN_SERVER/worker:v2

cd ../aks
```

## Step 3: Update Kubernetes Manifests

### 3.1 Replace ACR Name in Deployment Files

Replace `<ACR_NAME>` with your actual ACR login server in the deployment files:

```bash
# Get ACR login server
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv)

# Update deployment files (Linux/Mac)
sed -i "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" vote-deployment.yaml
sed -i "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" result-deployment.yaml
sed -i "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" worker-deployment.yaml

# For Windows PowerShell
(Get-Content vote-deployment.yaml) -replace '<ACR_NAME>', $ACR_LOGIN_SERVER | Set-Content vote-deployment.yaml
(Get-Content result-deployment.yaml) -replace '<ACR_NAME>', $ACR_LOGIN_SERVER | Set-Content result-deployment.yaml
(Get-Content worker-deployment.yaml) -replace '<ACR_NAME>', $ACR_LOGIN_SERVER | Set-Content worker-deployment.yaml
```

**Or manually edit the files:**

- `vote-deployment.yaml` - Replace `<ACR_NAME>` with your ACR login server
- `result-deployment.yaml` - Replace `<ACR_NAME>` with your ACR login server
- `worker-deployment.yaml` - Replace `<ACR_NAME>` with your ACR login server

### 3.2 Update Secrets (Optional - for Production)

For production, generate secure passwords:

```bash
# Generate secure password
POSTGRES_PASSWORD=$(openssl rand -base64 32)

# Update secret.yaml with the new password
# Or use Azure Key Vault for production deployments
```

## Step 4: Deploy to AKS

### 4.1 Create Namespace

```bash
kubectl apply -f namespace.yaml
```

### 4.2 Create ConfigMap and Secrets

```bash
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
```

### 4.3 Deploy Database Services

```bash
# Deploy PostgreSQL
kubectl apply -f postgres-deployment.yaml
kubectl apply -f postgres-service.yaml

# Deploy Redis
kubectl apply -f redis-deployment.yaml
kubectl apply -f redis-service.yaml
```

### 4.4 Wait for Database Services to be Ready

```bash
kubectl wait --for=condition=ready pod -l app=postgres -n voting-app --timeout=300s
kubectl wait --for=condition=ready pod -l app=redis -n voting-app --timeout=300s
```

### 4.5 Deploy Application Services

```bash
# Deploy Worker (processes votes)
kubectl apply -f worker-deployment.yaml

# Deploy Vote service
kubectl apply -f vote-deployment.yaml
kubectl apply -f vote-service.yaml

# Deploy Result service
kubectl apply -f result-deployment.yaml
kubectl apply -f result-service.yaml
```

### 4.6 Verify Deployments

```bash
# Check all pods are running
kubectl get pods -n voting-app

# Check services
kubectl get services -n voting-app

# Check deployments
kubectl get deployments -n voting-app
```

## Step 5: Expose the Application

You have several options to expose the application:

### Option A: Using LoadBalancer Services (Quick Testing)

Create LoadBalancer services for external access:

```bash
# Create LoadBalancer for Vote service
kubectl expose deployment vote -n voting-app --type=LoadBalancer --port=80 --target-port=80 --name=vote-lb

# Create LoadBalancer for Result service
kubectl expose deployment result -n voting-app --type=LoadBalancer --port=4000 --target-port=4000 --name=result-lb

# Get external IPs
kubectl get services -n voting-app
```

### Option B: Using NGINX Ingress Controller (Recommended)

#### 5.1 Install NGINX Ingress Controller

```bash
# Add NGINX Ingress Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install NGINX Ingress Controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer
```

#### 5.2 Get Ingress Controller IP

```bash
# Wait for LoadBalancer IP
kubectl get service ingress-nginx-controller -n ingress-nginx

# Get the EXTERNAL-IP (this may take a few minutes)
INGRESS_IP=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress IP: $INGRESS_IP"
```

#### 5.3 Deploy Ingress

```bash
# Update ingress-nginx.yaml with your domain or use the LoadBalancer IP
# Then apply
kubectl apply -f ingress-nginx.yaml
```

#### 5.4 Access the Application

```bash
# Get the ingress IP
INGRESS_IP=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Access Vote service
curl http://$INGRESS_IP/vote

# Access Result service
curl http://$INGRESS_IP/result
```

### Option C: Using Azure Application Gateway Ingress Controller (AGIC)

For production, consider using AGIC. See Azure documentation for setup.

## Step 6: Verify Deployment

### 6.1 Check Pod Status

```bash
kubectl get pods -n voting-app -o wide
```

All pods should be in `Running` state.

### 6.2 Check Logs

```bash
# Check Vote service logs
kubectl logs -f deployment/vote -n voting-app

# Check Result service logs
kubectl logs -f deployment/result -n voting-app

# Check Worker logs
kubectl logs -f deployment/worker -n voting-app
```

### 6.3 Test the Application

1. Access the Vote service and cast votes
2. Access the Result service to see the results
3. Verify votes are being processed by checking worker logs

## Step 7: Monitoring and Troubleshooting

### 7.1 View Resource Usage

```bash
kubectl top pods -n voting-app
kubectl top nodes
```

### 7.2 Describe Resources

```bash
# Describe a pod
kubectl describe pod <pod-name> -n voting-app

# Describe a deployment
kubectl describe deployment vote -n voting-app
```

### 7.3 Common Issues

**Pods not starting:**

```bash
kubectl describe pod <pod-name> -n voting-app
kubectl logs <pod-name> -n voting-app
```

**Image pull errors:**

- Verify ACR credentials
- Check image names in deployments
- Ensure AKS has access to ACR

**Database connection issues:**

- Verify PostgreSQL pod is running
- Check connection strings in secrets
- Verify network policies

## Step 8: Scaling

### Scale Deployments

```bash
# Scale Vote service
kubectl scale deployment vote -n voting-app --replicas=3

# Scale Result service
kubectl scale deployment result -n voting-app --replicas=3

# Scale Worker
kubectl scale deployment worker -n voting-app --replicas=3
```

### Auto-scaling (HPA)

Create Horizontal Pod Autoscaler:

```bash
kubectl autoscale deployment vote -n voting-app --cpu-percent=70 --min=2 --max=10
kubectl autoscale deployment result -n voting-app --cpu-percent=70 --min=2 --max=10
```

## Step 9: Production Considerations

### 9.1 Use Azure Key Vault for Secrets

```bash
# Install Azure Key Vault Provider for Secrets Store CSI Driver
# See: https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-driver
```

### 9.2 Enable Azure Monitor

```bash
az aks enable-addons \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --addons monitoring
```

### 9.3 Use Azure Database for PostgreSQL

For production, consider using Azure Database for PostgreSQL instead of in-cluster PostgreSQL.

### 9.4 Use Azure Cache for Redis

For production, consider using Azure Cache for Redis instead of in-cluster Redis.

### 9.5 Enable HTTPS/TLS

- Configure TLS certificates in ingress
- Use Azure Key Vault for certificate management
- Enable HTTPS redirect

### 9.6 Network Policies

Review and update `network-policy.yaml` for production security requirements.

## Step 10: Cleanup (Optional)

To delete all resources:

```bash
# Delete AKS cluster
az aks delete \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --yes

# Delete ACR
az acr delete \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --yes

# Delete resource group (this deletes everything)
az group delete \
  --name $RESOURCE_GROUP \
  --yes
```

## Quick Reference Commands

```bash
# Get ACR login server
az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME

# View pods
kubectl get pods -n voting-app

# View services
kubectl get services -n voting-app

# View logs
kubectl logs -f deployment/vote -n voting-app

# Port forward for local testing
kubectl port-forward service/vote 8080:80 -n voting-app
kubectl port-forward service/result 8081:4000 -n voting-app

# Restart a deployment
kubectl rollout restart deployment/vote -n voting-app
```

## Support

For issues or questions:

1. Check pod logs: `kubectl logs <pod-name> -n voting-app`
2. Describe resources: `kubectl describe <resource> <name> -n voting-app`
3. Check Azure portal for AKS cluster status
4. Review Azure documentation for AKS troubleshooting
