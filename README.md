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
- Advanced Container Networking Services with Cilium L7 policies
- AKS application monitoring preview enablement
- AKS control plane diagnostic settings
- Kubernetes namespace and Instrumentation custom resource required by the demo app

## Repository files

Application manifests are grouped in `k8s\application\`, and monitoring manifests in `k8s\monitoring\`. Single-file categories stay at the top level of `k8s\`.

| File | Description |
| --- | --- |
| [README.md](./README.md) | Setup, deployment, and telemetry-viewing instructions. |
| [setup.ps1](./setup.ps1) | Provisions Azure resources and AKS observability, then applies the namespace and monitoring configuration. |
| [k8s/namespace.yaml](./k8s/namespace.yaml) | Creates the shared `observability-demo` namespace. |
| [k8s/cilium-otel-policy.yaml](./k8s/cilium-otel-policy.yaml) | Restricts API ingress to web requests for `GET /api/message`, while allowing node health probes. |
| [k8s/application/demo-app-configmap.yaml](./k8s/application/demo-app-configmap.yaml) | Supplies the demo app's Node.js code, Prometheus metrics, and synthetic failures. |
| [k8s/application/demo-app.yaml](./k8s/application/demo-app.yaml) | Deploys the demo app with telemetry annotations and exposes it through a LoadBalancer Service. |
| [k8s/application/load-generator-job.yaml](./k8s/application/load-generator-job.yaml) | Sends 120 requests to the demo app, two seconds apart, to generate telemetry. |
| [k8s/application/otel-api.yaml](./k8s/application/otel-api.yaml) | Deploys the auto-instrumented Node.js API with synthetic exceptions and an internal ClusterIP Service. |
| [k8s/application/otel-web.yaml](./k8s/application/otel-web.yaml) | Deploys the auto-instrumented web frontend that calls the API and exposes a public LoadBalancer Service. |
| [k8s/monitoring/ama-metrics-settings-configmap.yaml](./k8s/monitoring/ama-metrics-settings-configmap.yaml) | Enables annotation-based Prometheus scraping in the demo namespace. |
| [k8s/monitoring/app-monitoring-instrumentation.yaml](./k8s/monitoring/app-monitoring-instrumentation.yaml) | Defines the shared Instrumentation resource; setup substitutes the Application Insights connection string before applying it. |

## Deploy the demo workload

After the script finishes, deploy the sample app:

```powershell
kubectl apply -f .\k8s\application\demo-app-configmap.yaml
kubectl apply -f .\k8s\application\demo-app.yaml
kubectl apply -f .\k8s\application\load-generator-job.yaml
```

The script renders and applies `k8s\monitoring\app-monitoring-instrumentation.yaml` for you with the live Application Insights connection string, so you do not apply that template file directly.

## Deploy the web and API workloads

The public web workload calls the internal API workload over HTTP. Both Node.js deployments use the same OpenTelemetry autoinstrumentation resource as the demo app.

```powershell
kubectl apply -f .\k8s\application\otel-api.yaml
kubectl apply -f .\k8s\application\otel-web.yaml
kubectl apply -f .\k8s\cilium-otel-policy.yaml
kubectl get service otel-web -n observability-demo
```

Open the external IP assigned to `otel-web` to generate a distributed web-to-API trace. The `otel-api` service remains internal to the cluster.

The Cilium policy allows only HTTP `GET /api/message` traffic from `otel-web` to `otel-api` on port 8080. Node-originated traffic remains allowed so Kubernetes health probes continue to work. View the resulting L7 traffic in Azure Managed Grafana under **Dashboards > Azure Managed Prometheus > Kubernetes/Networking/L7 (Workload)** or **L7 (Namespace)**.

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