# AKS Observability Setup

This repo provisions a minimal AKS environment with Azure-native observability components:

- AKS cluster named `aksobservability`
- Resource group named `rg-aks-observability-appmon`
- BYO virtual network and subnet
- Log Analytics workspace for Container Insights and control plane logs
- Azure Monitor workspace for managed Prometheus
- Workspace-based Application Insights for AKS autoinstrumentation

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
- AKS cluster with 2 nodes
- Container Insights
- Managed Prometheus
- AKS application monitoring preview enablement
- AKS control plane diagnostic settings
- Kubernetes namespace and Instrumentation custom resource required by the demo app

## Deploy the demo workload

After the script finishes, deploy the sample app:

```powershell
kubectl apply -f .\k8s\demo-app-configmap.yaml
kubectl apply -f .\k8s\demo-app-deployment.yaml
kubectl apply -f .\k8s\demo-app-service.yaml
kubectl apply -f .\k8s\load-generator-job.yaml
```

The script renders and applies `k8s\app-monitoring-instrumentation.yaml` for you with the live Application Insights connection string, so you do not apply that template file directly.

## Deploy the web and API workloads

The public web workload calls the internal API workload over HTTP. Both Node.js deployments use the same OpenTelemetry autoinstrumentation resource as the demo app.

```powershell
kubectl apply -f .\k8s\otel-api.yaml
kubectl apply -f .\k8s\otel-web.yaml
kubectl get service otel-web -n observability-demo
```

Open the external IP assigned to `otel-web` to generate a distributed web-to-API trace. The `otel-api` service remains internal to the cluster.

## What to expect

- Container stdout and stderr logs flow into Container Insights
- AKS control plane logs flow into Log Analytics
- Managed Prometheus collects cluster metrics and the demo app's `/metrics` endpoint
- AKS autoinstrumentation sends Node.js request telemetry into Application Insights
- Application logs can also flow into Application Insights through pod annotations

## View Application Insights data

Open the Azure portal, go to `Application Insights`, and select `appi-aks-observability-appmon` in resource group `rg-aks-observability-appmon`.

Useful portal blades:

- Overview
- Transaction search
- Failures
- Performance
- Application map
- Logs

In the `Logs` blade, these sample queries were validated against the live demo environment:

```kusto
requests
| where timestamp > ago(30m)
| where cloud_RoleName == "observability-demo"
| project timestamp, name, resultCode, success, duration, operation_Id
| order by timestamp desc
| take 10
```

```kusto
traces
| where timestamp > ago(30m)
| where cloud_RoleName == "observability-demo"
| project timestamp, message, severityLevel, operation_Id
| order by timestamp desc
| take 10
```

```kusto
exceptions
| where timestamp > ago(30m)
| where cloud_RoleName == "observability-demo"
| project timestamp, type, outerMessage, operation_Id
| order by timestamp desc
| take 10
```

The `exceptions` query is valid, but it can return no rows for this sample because the demo currently emits failed requests and error logs without throwing unhandled exceptions that Application Insights records in the `exceptions` table.

## Notes

- The script assumes you are already logged into Azure CLI.
- The script requires the `AzureMonitorAppMonitoringPreview` feature to already be `Registered`. If it is still `Registering`, the script exits after requesting registration so you can rerun it later.
- The sample app installs its Node.js dependencies at startup to keep this repo small and easy to read.