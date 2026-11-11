# AKS Observability Storefront

This repo provisions a minimal AKS environment and a Node.js storefront that demonstrates Application Insights through injected OpenTelemetry instrumentation:

- AKS cluster named `aksobservability`
- Resource group named `rg-aks-observability-appmon`
- BYO virtual network and subnet
- Log Analytics workspace for Container Insights and control plane logs
- Azure Monitor workspace for managed Prometheus
- Workspace-based Application Insights for AKS autoinstrumentation
- Managed Gateway API CRDs and the Istio-based application routing add-on

```text
Browser -> Gateway / HTTPRoute -> Storefront -> Orders API -> Inventory API
```

Only the Gateway has a public LoadBalancer. All three application Services are ClusterIP. The APIs use in-memory sample products: there is no database, payment processing, or persistent order storage.

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
- AKS cluster with 4 nodes, including headroom for the managed Istio controller and gateway replicas
- Container Insights
- Managed Prometheus
- Advanced Container Networking Services with Cilium L7 policies
- AKS application monitoring preview enablement
- AKS control plane diagnostic settings
- Kubernetes namespace and Instrumentation custom resource required by the demo app
- Managed Gateway API and Istio application routing on newly created clusters

Gateway enablement flags are intentionally present only on `az aks create`. Existing clusters must already have managed Gateway API and Istio application routing enabled; this script does not add or update those features on existing clusters. This uses the ingress-only `approuting-istio` GatewayClass, not the Istio service mesh add-on or application sidecars.

## Repository files

Manifests are grouped into application, monitoring, and networking folders. Each application manifest combines its Deployment and Service.

| File | Description |
| --- | --- |
| [README.md](./README.md) | Setup, deployment, and telemetry-viewing instructions. |
| [setup.ps1](./setup.ps1) | Provisions Azure resources and AKS observability, then applies the namespace and monitoring configuration. |
| [k8s/namespace.yaml](./k8s/namespace.yaml) | Creates the shared `observability-demo` namespace. |
| [k8s/application/storefront-configmap.yaml](./k8s/application/storefront-configmap.yaml) | Shared Node.js service code and the storefront HTML page, including six deterministic telemetry scenarios. |
| [k8s/application/storefront.yaml](./k8s/application/storefront.yaml) | Injected frontend Deployment and internal Service; serves the page and forwards checkout requests to Orders. |
| [k8s/application/orders.yaml](./k8s/application/orders.yaml) | Injected Orders Deployment and internal Service; validates orders, calls Inventory, and demonstrates exceptions and retries. |
| [k8s/application/inventory.yaml](./k8s/application/inventory.yaml) | Injected Inventory Deployment and internal Service; returns products and simulates delays and outages. |
| [k8s/application/load-generator-job.yaml](./k8s/application/load-generator-job.yaml) | Optional Job that runs all six scenarios five times and fails if an HTTP status differs from the expected outcome. |
| [k8s/monitoring/ama-metrics-settings-configmap.yaml](./k8s/monitoring/ama-metrics-settings-configmap.yaml) | Enables annotation-based Prometheus scraping in the demo namespace. |
| [k8s/monitoring/app-monitoring-instrumentation.yaml](./k8s/monitoring/app-monitoring-instrumentation.yaml) | Defines the shared Instrumentation resource; setup substitutes the Application Insights connection string before applying it. |
| [k8s/networking/storefront-gateway.yaml](./k8s/networking/storefront-gateway.yaml) | Public HTTP Gateway using `approuting-istio`, an Azure public-IP DNS label, and a hostname-restricted HTTPRoute to the frontend. |
| [k8s/networking/cilium-storefront-policy.yaml](./k8s/networking/cilium-storefront-policy.yaml) | Limits Orders ingress to Storefront and Inventory ingress to Orders; permits node probes and monitoring scrapes. |
| [tests/storefront.test.cjs](./tests/storefront.test.cjs) | Dependency-free Node.js endpoint tests covering the UI, six scenarios, input validation, latency, and nonzero trace IDs. |

## Deploy the storefront

After setup finishes, confirm the managed controller is ready, then deploy:

```powershell
kubectl wait --for=condition=Accepted gatewayclass/approuting-istio --timeout=10m
kubectl apply -f .\k8s\application\storefront-configmap.yaml
kubectl apply -f .\k8s\application\inventory.yaml -f .\k8s\application\orders.yaml -f .\k8s\application\storefront.yaml
kubectl apply -f .\k8s\networking
kubectl rollout status deployment/inventory -n observability-demo --timeout=5m
kubectl rollout status deployment/orders -n observability-demo --timeout=5m
kubectl rollout status deployment/storefront -n observability-demo --timeout=5m
kubectl wait --for=condition=Programmed gateway/storefront -n observability-demo --timeout=10m
kubectl get gateway storefront -n observability-demo
```

The script renders and applies `k8s\monitoring\app-monitoring-instrumentation.yaml` for you with the live Application Insights connection string, so you do not apply that template file directly.

Open [the storefront](http://aksobservability-storefront.centralus.cloudapp.azure.com/) over HTTP. The Gateway annotation assigns the public IP the DNS label `aksobservability-storefront`; the HTTPRoute accepts `aksobservability-storefront.centralus.cloudapp.azure.com`. Direct IP requests no longer match the route unless they supply that Host header.

The DNS label must be available in Central US. If changing the label or deploying to another region, update both the Gateway annotation and HTTPRoute hostname.

```powershell
$gatewayAddress = kubectl get gateway storefront -n observability-demo -o jsonpath='{.status.addresses[0].value}'
```

If an existing subnet NSG denies Internet ingress, it must also allow TCP/80 to the Gateway public IP; the AKS-managed node NSG alone is not enough. This cluster required that additional rule. When needed, run the following after resolving `$gatewayAddress` (priority 300 must be unused or already belong to this rule):

```powershell
$subnetNsgId = az network vnet subnet show -g rg-aks-observability-appmon --vnet-name vnet-aks-observability -n snet-aks --query networkSecurityGroup.id -o tsv
if ($subnetNsgId) {
    $nsgName = $subnetNsgId.Split('/')[-1]
    $nsgResourceGroup = $subnetNsgId.Split('/')[4]
    az network nsg rule create -g $nsgResourceGroup --nsg-name $nsgName --name Allow-Storefront-HTTP --priority 300 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet --source-port-ranges '*' --destination-address-prefixes $gatewayAddress --destination-port-ranges 80 --output none
}
```

Update this rule if recreating the Gateway changes its public IP.

Run the endpoint tests through the public Gateway:

```powershell
$env:STOREFRONT_URL = "http://aksobservability-storefront.centralus.cloudapp.azure.com"
node --test .\tests\storefront.test.cjs
```

Optionally generate a short burst of scenario traffic:

```powershell
kubectl apply -f .\k8s\application\load-generator-job.yaml
kubectl logs -f job/storefront-loadgen -n observability-demo
```

After changing the code ConfigMap, restart the three application Deployments because their init containers copy code at startup.

### Replacing the previous demo

Once the storefront is healthy, remove only the old resources from this repo. Do not delete the namespace or unrelated workloads:

```powershell
kubectl delete deployment,service observability-demo otel-web otel-api -n observability-demo --ignore-not-found
kubectl delete configmap observability-demo-app -n observability-demo --ignore-not-found
kubectl delete job observability-demo-loadgen -n observability-demo --ignore-not-found
kubectl delete ciliumnetworkpolicy allow-otel-web-to-api -n observability-demo --ignore-not-found
```

## Demonstration scenarios

Choose a product and click a color-coded scenario card in the dark-themed storefront. The response panel displays each checkout's HTTP status, elapsed time, server-side trace ID, and JSON response. The layout adapts to mobile screens and supports keyboard navigation and reduced motion.

| Scenario | Expected result | Application Insights story |
| --- | --- | --- |
| Successful checkout | HTTP 200 | One trace across Storefront, Orders, and Inventory; automatic HTTP requests and dependencies. |
| Slow inventory | HTTP 200, at least 1.5 seconds | Use the transaction waterfall and Performance view to locate the downstream delay. |
| Inventory outage | HTTP 503 | Follow a failed Inventory dependency and its upstream effect. |
| Order exception | HTTP 500 | Inspect the recorded order exception and stack trace in its operation context. |
| Retry and recover | HTTP 200, two application attempts | A failed Inventory call followed by a successful call inside an overall successful checkout; L7 proxies can add their own retries. |
| Validation rejection | HTTP 400 | An expected client error stops at Orders without an Inventory call. |

## What to expect

- AKS injects the Node.js instrumentation into each application pod using `demo-instrumentation`. There is no application-owned telemetry SDK initialization or exporter.
- Automatic instrumentation captures Express requests and Node HTTP dependencies, including cross-service trace propagation. Browser `fetch` is not instrumented; the trace begins at the server.
- Small calls to `@opentelemetry/api` add business spans (`storefront.checkout`, `orders.checkout`, `inventory.check-stock`), scenario attributes, retry events, and explicit exception recording.
- `OTEL_SERVICE_NAME` separates the three services in Application Map. `always_on` sampling keeps the demo scenarios visible; revisit sampling before production use.
- Structured logs include trace/span IDs, and application-log annotations enable forwarding to Application Insights. Container Insights also receives stdout/stderr.
- Managed Prometheus scrapes `/metrics` on all three services, independently of Application Insights.
- ACNS Cilium policies expose API HTTP traffic for networking dashboards while keeping the APIs internal.
- AKS control plane logs flow into Log Analytics.

## View Application Insights data

Open the Azure portal, go to `Application Insights`, and select `appi-aks-observability-appmon` in resource group `rg-aks-observability-appmon`.

Start with **Application map**, **Performance**, **Failures**, and **Transaction search**. In the Application Insights **Logs** blade, inspect service-level requests:

```kusto
requests
| where timestamp > ago(30m)
| where cloud_RoleName in ("storefront", "orders", "inventory")
| project timestamp, cloud_RoleName, name, resultCode, success, duration, operation_Id
| order by timestamp desc
| take 10
```

Paste the trace ID from the storefront into this query to follow one checkout:

```kusto
let traceId = "paste-trace-id-here";
union withsource=telemetry requests, dependencies, exceptions, traces
| where timestamp > ago(30m)
| where operation_Id == traceId
| order by timestamp desc
```

```kusto
exceptions
| where timestamp > ago(30m)
| where cloud_RoleName in ("storefront", "orders", "inventory")
| project timestamp, cloud_RoleName, type, outerMessage, operation_Id
| order by timestamp desc
| take 10
```

Telemetry ingestion can take several minutes. Recording a controlled exception is different from merely returning a failed HTTP status.

## Notes

- The script assumes you are already logged into Azure CLI.
- Azure CLI 2.86.0 or later is required for the managed Gateway API and application routing options. See [AKS application routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api).
- The script requires the `AzureMonitorAppMonitoringPreview` feature to already be `Registered`. If it is still `Registering`, the script exits after requesting registration so you can rerun it later.
- The sample apps install Node.js dependencies in init containers to avoid an image build/registry workflow. This requires npm egress and is for demos; production images should bake in locked dependencies.
- `@opentelemetry/api` is pinned to 1.9.1 to match the currently injected agent. API 1.10 requires a newer registered API and otherwise produces no-op custom spans with this agent; recheck compatibility when upgrading.
- The public Gateway is HTTP-only and unauthenticated. Do not use real customer data; add TLS/authentication before production use.
- AKS injection covers server-side telemetry, not browser page views or browser exceptions.