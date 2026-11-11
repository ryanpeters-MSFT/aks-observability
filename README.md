# AKS Observability Storefront

An AKS demo combining distributed tracing in Application Insights, managed Prometheus, and HTTP visibility through Cilium/Hubble.

```text
Browser -> Gateway / HTTPRoute -> Storefront -> Orders API -> Inventory API
```

Only the managed Istio Gateway is public; application Services are ClusterIP. Products and orders are in-memory demo data, with no database or real payments.

## Main workloads

| Workload | Purpose |
| --- | --- |
| [Storefront](./k8s/application/storefront.yaml) | Serves the UI and forwards checkout requests to Orders. |
| [Orders](./k8s/application/orders.yaml) | Validates orders, calls Inventory, and demonstrates exceptions and retries. |
| [Inventory](./k8s/application/inventory.yaml) | Returns stock information and simulates delays and outages. |

The shared [application ConfigMap](./k8s/application/storefront-configmap.yaml) contains the Node.js code, UI, and scenario routes. Its `POST /orders` and `GET /inventory/:productId` calls match the [Cilium L7 policies](./k8s/networking/cilium-storefront-policy.yaml), which enforce HTTP methods/paths and make those service calls visible in Hubble.

## Setup and deployment

[setup.ps1](./setup.ps1) provisions `aksobservability` in `rg-aks-observability-appmon`, including a BYO VNet, four nodes, ACNS, Application Insights instrumentation, managed Prometheus, and Log Analytics for Container Insights and control plane logs.

Sign in to Azure CLI, then run:

```powershell
.\setup.ps1
```

New clusters also get managed Gateway API and Istio application routing. Existing clusters must already have those features enabled. Use a kubectl context for the target AKS cluster, then deploy:

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

Setup applies the instrumentation with the live Application Insights connection string; do not apply the instrumentation template directly.

Open [the storefront](http://aksobservability-storefront.centralus.cloudapp.azure.com/). The [Gateway and HTTPRoute](./k8s/networking/storefront-gateway.yaml) use this hostname; direct-IP requests require a matching Host header. If changing the DNS label or region, update both the Gateway annotation and HTTPRoute hostname.

After editing the application ConfigMap, restart the affected Deployments: their init containers copy code at startup. UI-only changes require only a Storefront restart.

### Test or generate traffic

Run the [endpoint tests](./tests/storefront.test.cjs) through the public Gateway:

```powershell
$env:STOREFRONT_URL = "http://aksobservability-storefront.centralus.cloudapp.azure.com"
node --test .\tests\storefront.test.cjs
```

Optionally generate a short burst of scenario traffic:

```powershell
kubectl apply -f .\k8s\application\load-generator-job.yaml
kubectl logs -f job/storefront-loadgen -n observability-demo
```

## Demonstration scenarios

Choose a product and scenario. The UI displays HTTP status, elapsed time, trace ID, and JSON response.

| Scenario | Expected result | Application Insights story |
| --- | --- | --- |
| Successful checkout | HTTP 200 | One trace across Storefront, Orders, and Inventory; automatic HTTP requests and dependencies. |
| Slow inventory | HTTP 200, at least 1.5 seconds | Use the transaction waterfall and Performance view to locate the downstream delay. |
| Inventory outage | HTTP 503 | Follow a failed Inventory dependency and its upstream effect. |
| Order exception | HTTP 500 | Inspect the recorded order exception and stack trace in its operation context. |
| Retry and recover | HTTP 200, two application attempts | A failed Inventory call followed by a successful call inside an overall successful checkout; L7 proxies can add their own retries. |
| Validation rejection | HTTP 400 | An expected client error stops at Orders without an Inventory call. |

## View Application Insights data

AKS injects OpenTelemetry to capture server requests and HTTP dependencies across all three services. The app adds business spans, correlated logs, and explicit exceptions. Browser activity is not instrumented; managed Prometheus separately scrapes `/metrics`.

In `appi-aks-observability-appmon`, use **Application map**, **Performance**, **Failures**, or **Transaction search** to inspect the checkout waterfall.

In **Logs**, paste the storefront's trace ID to follow one checkout:

```kusto
let traceId = "paste-trace-id-here";
union withsource=telemetry requests, dependencies, exceptions, traces
| where timestamp > ago(30m)
| where operation_Id == traceId
| order by timestamp asc
```

Telemetry ingestion can take several minutes. Recording a controlled exception is different from merely returning a failed HTTP status.

## Observe HTTP traffic with Hubble

With Hubble connected, run a command below and generate traffic in another terminal or the UI. Press Ctrl+C to stop.

HTTP filters:

```powershell
# All HTTP traffic
hubble observe --namespace observability-demo --protocol http --follow

# Storefront -> Orders requests
hubble observe --namespace observability-demo --from-label app=storefront --to-label app=orders --protocol http --follow

# Storefront <-> Orders requests and responses
hubble observe --namespace observability-demo --from-label app=storefront --from-label app=orders --to-label app=storefront --to-label app=orders --protocol http --follow

# Orders -> Inventory requests
hubble observe --namespace observability-demo --from-label app=orders --to-label app=inventory --protocol http --follow
```

Repeated source labels are OR conditions, as are destination labels. Responses show status and latency, not bodies.

Failures and diagnostics:

```powershell
# Outage, exception, and validation responses (run separately)
hubble observe --namespace observability-demo --protocol http --http-status 503 --follow
hubble observe --namespace observability-demo --protocol http --http-status 500 --follow
hubble observe --namespace observability-demo --protocol http --http-status 400 --follow

# Recent history
hubble observe --namespace observability-demo --protocol http --since 5m

# Detailed HTTP events
hubble observe --namespace observability-demo --protocol http --output jsonpb --follow

# Network-policy drops, not HTTP error statuses
hubble observe --namespace observability-demo --verdict DROPPED --follow
```

The L7 policies expose HTTP on Storefront -> Orders -> Inventory, not Gateway -> Storefront. A 503 is an application response, not a network-policy drop; proxy retries can produce extra calls.

### Which pods enforce the network policies?

These are node-level components, not application sidecars:

| Component in `kube-system` | Role |
| --- | --- |
| `cilium-*` | Programs eBPF networking, Service load balancing, L3/L4 enforcement, and redirection to the L7 proxy. |
| `acns-security-agent-*` / `cilium-envoy` | Receives redirected HTTP traffic and enforces method/path rules on the destination node. |
| `hubble-relay-*` | Aggregates observations; does not enforce policy. |

Istio Gateway pods handle public ingress, not Cilium policy enforcement. Find the current node placement:

```powershell
kubectl get pods -n observability-demo -o wide
kubectl get pods -n kube-system -o wide | Select-String 'NAME|cilium-|acns-security-agent-'
```

### Observe Storefront DNS queries

DNS details require a DNS L7 policy; the checked-in policies enable HTTP inspection only. Storefront resolves `orders` during checkout, subject to caching.

```powershell
# Outbound DNS queries
hubble observe --namespace observability-demo --from-label app=storefront --protocol dns --follow

# Queries and replies
hubble observe --namespace observability-demo --label app=storefront --protocol dns --follow

# L4 fallback without DNS inspection: shows traffic, not names or answers
hubble observe --namespace observability-demo --from-label app=storefront --to-port 53 --follow
```

## Notes

- Azure CLI 2.86.0 or later is required for the managed Gateway API and application routing options. See [AKS application routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api).
- `AzureMonitorAppMonitoringPreview` must be `Registered`; if setup requests registration and exits, rerun it once registration completes.
- Init containers install dependencies from npm, requiring outbound access. Production images should include locked dependencies.
- Keep `@opentelemetry/api` pinned to 1.9.1 for compatibility with the injected agent; recheck before upgrading.
- The public Gateway is HTTP-only and unauthenticated. Do not use real customer data; add TLS/authentication before production use.