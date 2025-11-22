# Quick Start Guide - AKS Deployment

This is a condensed quick start guide. For detailed instructions, see [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md).

## Prerequisites Check

```bash
# Check Azure CLI
az --version

# Check kubectl
kubectl version --client

# Check Docker
docker --version

# Login to Azure
az login
```

## Step 1: Set Variables

```bash
RESOURCE_GROUP="voting-app-rg"
LOCATION="eastus"
AKS_CLUSTER_NAME="voting-app-aks"
ACR_NAME="votingapp$(openssl rand -hex 3)"
```

## Step 2: Create Azure Resources

```bash
# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create ACR
az acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Basic --admin-enabled true

# Create AKS cluster (takes 10-15 minutes)
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --node-count 3 \
  --node-vm-size Standard_B2s \
  --enable-managed-identity \
  --attach-acr $ACR_NAME \
  --generate-ssh-keys

# Get credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --overwrite-existing
```

## Step 3: Build and Push Images

```bash
# Get ACR login server
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv)

# Login to ACR
az acr login --name $ACR_NAME

# Build and push images
cd ../vote && docker build -t $ACR_LOGIN_SERVER/vote:v2 . && docker push $ACR_LOGIN_SERVER/vote:v2
cd ../result && docker build -t $ACR_LOGIN_SERVER/result:v2 . && docker push $ACR_LOGIN_SERVER/result:v2
cd ../worker && docker build -t $ACR_LOGIN_SERVER/worker:v2 . && docker push $ACR_LOGIN_SERVER/worker:v2
cd ../aks
```

## Step 4: Update Deployment Files

```bash
# Replace <ACR_NAME> in deployment files
sed -i "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" vote-deployment.yaml
sed -i "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" result-deployment.yaml
sed -i "s|<ACR_NAME>|$ACR_LOGIN_SERVER|g" worker-deployment.yaml
```

**Windows PowerShell:**
```powershell
$ACR_LOGIN_SERVER = az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query loginServer --output tsv
(Get-Content vote-deployment.yaml) -replace '<ACR_NAME>', $ACR_LOGIN_SERVER | Set-Content vote-deployment.yaml
(Get-Content result-deployment.yaml) -replace '<ACR_NAME>', $ACR_LOGIN_SERVER | Set-Content result-deployment.yaml
(Get-Content worker-deployment.yaml) -replace '<ACR_NAME>', $ACR_LOGIN_SERVER | Set-Content worker-deployment.yaml
```

## Step 5: Deploy to AKS

```bash
# Deploy all resources using kustomize
kubectl apply -k .

# Or deploy manually
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f postgres-deployment.yaml
kubectl apply -f postgres-service.yaml
kubectl apply -f redis-deployment.yaml
kubectl apply -f redis-service.yaml

# Wait for databases
kubectl wait --for=condition=ready pod -l app=postgres -n voting-app --timeout=300s
kubectl wait --for=condition=ready pod -l app=redis -n voting-app --timeout=300s

# Deploy application
kubectl apply -f worker-deployment.yaml
kubectl apply -f vote-deployment.yaml
kubectl apply -f vote-service.yaml
kubectl apply -f result-deployment.yaml
kubectl apply -f result-service.yaml
```

## Step 6: Verify Deployment

```bash
# Check pods
kubectl get pods -n voting-app

# Check services
kubectl get services -n voting-app

# Check logs
kubectl logs -f deployment/vote -n voting-app
```

## Step 7: Access the Application

### Option A: Port Forwarding (Quick Test)

```bash
# Terminal 1 - Vote service
kubectl port-forward service/vote 8080:80 -n voting-app

# Terminal 2 - Result service
kubectl port-forward service/result 8081:4000 -n voting-app
```

Access:
- Vote: http://localhost:8080
- Result: http://localhost:8081

### Option B: LoadBalancer Services

```bash
# Create LoadBalancer services
kubectl expose deployment vote -n voting-app --type=LoadBalancer --port=80 --target-port=80 --name=vote-lb
kubectl expose deployment result -n voting-app --type=LoadBalancer --port=4000 --target-port=4000 --name=result-lb

# Get external IPs (wait a few minutes)
kubectl get services -n voting-app
```

### Option C: NGINX Ingress

```bash
# Install NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer

# Wait for LoadBalancer IP
kubectl get service ingress-nginx-controller -n ingress-nginx

# Deploy ingress
kubectl apply -f ingress-nginx.yaml

# Get ingress IP
INGRESS_IP=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Access at: http://$INGRESS_IP/vote and http://$INGRESS_IP/result"
```

## Common Commands

```bash
# View all resources
kubectl get all -n voting-app

# View pod logs
kubectl logs <pod-name> -n voting-app

# Describe a resource
kubectl describe pod <pod-name> -n voting-app

# Scale deployment
kubectl scale deployment vote -n voting-app --replicas=3

# Restart deployment
kubectl rollout restart deployment/vote -n voting-app

# Delete everything
kubectl delete namespace voting-app
```

## Cleanup

```bash
# Delete AKS cluster
az aks delete --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --yes

# Delete ACR
az acr delete --resource-group $RESOURCE_GROUP --name $ACR_NAME --yes

# Delete resource group (deletes everything)
az group delete --name $RESOURCE_GROUP --yes
```

## Troubleshooting

```bash
# Pod not starting?
kubectl describe pod <pod-name> -n voting-app
kubectl logs <pod-name> -n voting-app

# Image pull errors?
# Check ACR credentials and image names in deployments

# Database connection issues?
kubectl get pods -l app=postgres -n voting-app
kubectl logs <postgres-pod-name> -n voting-app
```

## Next Steps

- Read [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) for detailed instructions
- Review production considerations in the deployment guide
- Set up monitoring and logging
- Configure backup and disaster recovery

