# AKS Observability Setup

This repo provisions a minimal AKS environment with Azure-native observability components:

- AKS cluster named `aksobservability`
- Resource group named `rg-aks-observability`
- BYO virtual network and subnet
- Log Analytics workspace for Container Insights and control plane logs
- Azure Monitor workspace for managed Prometheus
- Workspace-based Application Insights for application telemetry

## What the script creates

Run the setup script from this folder:

```powershell
.\setup.ps1
```

The script creates or updates with Azure CLI commands:

- Resource group
- Virtual network and subnet
- Log Analytics workspace
- Azure Monitor workspace
- Application Insights resource
- AKS cluster with 1 node
- Container Insights addon
- Managed Prometheus addon
- AKS control plane diagnostic settings
- Kubernetes namespace and secret required by the demo app

## Deploy the demo workload

After the script finishes, deploy the sample app:

```powershell
kubectl apply -f .\k8s\demo-app-configmap.yaml
kubectl apply -f .\k8s\demo-app-deployment.yaml
kubectl apply -f .\k8s\demo-app-service.yaml
kubectl apply -f .\k8s\load-generator-job.yaml
```

## What to expect

- Container stdout and stderr logs flow into Container Insights
- AKS control plane logs flow into Log Analytics
- Managed Prometheus collects cluster metrics and the demo app's `/metrics` endpoint
- OpenTelemetry traces from the demo app flow into Application Insights

## Notes

- The script assumes you are already logged into Azure CLI.
- The script removes the `aks-preview` extension because current AKS monitoring guidance recommends not using it for this flow.
- The sample app installs its Node.js dependencies at startup to keep this repo small and easy to read.