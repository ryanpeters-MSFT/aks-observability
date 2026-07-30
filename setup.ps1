$location = "centralus"
$nodeVmSize = "Standard_DS2_v2"
$nodeCount = 2

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$resourceGroupName = "rg-aks-observability-appmon"
$clusterName = "aksobservability"
$virtualNetworkName = "vnet-aks-observability"
$aksSubnetName = "snet-aks"
$logAnalyticsWorkspaceName = "law-aks-observability"
$azureMonitorWorkspaceName = "amw-aks-observability"
$applicationInsightsName = "appi-aks-observability-appmon"
$diagnosticSettingName = "aks-control-plane-logs"
$demoNamespace = "observability-demo"
$featureName = "AzureMonitorAppMonitoringPreview"

$virtualNetworkAddressPrefix = "10.10.0.0/16"
$aksSubnetAddressPrefix = "10.10.0.0/24"
$serviceCidr = "10.20.0.0/16"
$dnsServiceIp = "10.20.0.10"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$namespaceFilePath = Join-Path $scriptRoot "k8s\namespace.yaml"
$metricsConfigFilePath = Join-Path $scriptRoot "k8s\ama-metrics-settings-configmap.yaml"
$instrumentationTemplateFilePath = Join-Path $scriptRoot "k8s\app-monitoring-instrumentation.yaml"

Write-Host "Checking Azure CLI login..."
$subscriptionId = az account show --query id --output tsv --only-show-errors

Write-Host "Ensuring aks-preview extension is installed..."

try {
    az extension show --name aks-preview --output none --only-show-errors 2>$null | Out-Null
}
catch {
    az extension add --name aks-preview --allow-preview true --output none --only-show-errors
}

az extension update --name aks-preview --output none --only-show-errors

Write-Host "Checking AKS app monitoring preview registration..."
$featureState = az feature show `
    --namespace Microsoft.ContainerService `
    --name $featureName `
    --query properties.state `
    --output tsv `
    --only-show-errors

if ($featureState -eq "NotRegistered") {
    Write-Host "Registering AKS app monitoring preview feature..."
    az feature register --namespace Microsoft.ContainerService --name $featureName --output none --only-show-errors
    $featureState = "Registering"
}

if ($featureState -ne "Registered") {
    throw "AKS app monitoring preview feature state is '$featureState'. Wait until it becomes 'Registered', then rerun .\setup.ps1."
}

Write-Host "Registering required resource providers..."
$providerNamespaces = @(
    "Microsoft.ContainerService",
    "Microsoft.Insights",
    "Microsoft.OperationalInsights",
    "Microsoft.Monitor",
    "Microsoft.AlertsManagement"
)

foreach ($providerNamespace in $providerNamespaces) {
    az provider register --namespace $providerNamespace --wait --only-show-errors | Out-Null
}

Write-Host "Creating resource group..."
az group create --name $resourceGroupName --location $location --output none --only-show-errors

Write-Host "Creating virtual network and AKS subnet..."
az network vnet create `
    --resource-group $resourceGroupName `
    --name $virtualNetworkName `
    --location $location `
    --address-prefixes $virtualNetworkAddressPrefix `
    --subnet-name $aksSubnetName `
    --subnet-prefixes $aksSubnetAddressPrefix `
    --output none `
    --only-show-errors

$aksSubnetId = az network vnet subnet show `
    --resource-group $resourceGroupName `
    --vnet-name $virtualNetworkName `
    --name $aksSubnetName `
    --query id `
    --output tsv `
    --only-show-errors

Write-Host "Creating Log Analytics workspace..."
$logAnalyticsWorkspaceId = $null

try {
    $logAnalyticsWorkspaceId = az monitor log-analytics workspace show `
        --resource-group $resourceGroupName `
        --workspace-name $logAnalyticsWorkspaceName `
        --query id `
        --output tsv `
        --only-show-errors 2>$null
}
catch {
    $logAnalyticsWorkspaceId = az monitor log-analytics workspace create `
        --resource-group $resourceGroupName `
        --workspace-name $logAnalyticsWorkspaceName `
        --location $location `
        --sku PerGB2018 `
        --query id `
        --output tsv `
        --only-show-errors
}

Write-Host "Creating Azure Monitor workspace for managed Prometheus..."
$azureMonitorWorkspaceId = $null

try {
    $azureMonitorWorkspaceId = az monitor account show `
        --resource-group $resourceGroupName `
        --name $azureMonitorWorkspaceName `
        --query id `
        --output tsv `
        --only-show-errors 2>$null
}
catch {
    $azureMonitorWorkspaceId = az monitor account create `
        --resource-group $resourceGroupName `
        --name $azureMonitorWorkspaceName `
        --location $location `
        --query id `
        --output tsv `
        --only-show-errors
}

Write-Host "Creating workspace-based Application Insights..."
try {
    $applicationInsightsConnectionString = az monitor app-insights component show `
        --app $applicationInsightsName `
        --resource-group $resourceGroupName `
        --query connectionString `
        --output tsv `
        --only-show-errors 2>$null
}
catch {
    az monitor app-insights component create `
        --app $applicationInsightsName `
        --resource-group $resourceGroupName `
        --location $location `
        --kind web `
        --application-type web `
        --workspace $logAnalyticsWorkspaceId `
        --output none `
        --only-show-errors

    $applicationInsightsConnectionString = az monitor app-insights component show `
        --app $applicationInsightsName `
        --resource-group $resourceGroupName `
        --query connectionString `
        --output tsv `
        --only-show-errors
}

$clusterExists = $true

try {
    az aks show `
        --resource-group $resourceGroupName `
        --name $clusterName `
        --query id `
        --output none `
        --only-show-errors 2>$null | Out-Null
}
catch {
    $clusterExists = $false
}

if (-not $clusterExists) {
    Write-Host "Creating AKS cluster with Azure Monitor logs, managed Prometheus, and app monitoring enabled..."
    az aks create `
        --resource-group $resourceGroupName `
        --name $clusterName `
        --location $location `
        --node-count $nodeCount `
        --node-vm-size $nodeVmSize `
        --enable-managed-identity `
        --network-plugin azure `
        --vnet-subnet-id $aksSubnetId `
        --service-cidr $serviceCidr `
        --dns-service-ip $dnsServiceIp `
        --tier free `
        --generate-ssh-keys `
        --enable-addons monitoring `
        --workspace-resource-id $logAnalyticsWorkspaceId `
        --enable-azure-monitor-metrics `
        --azure-monitor-workspace-resource-id $azureMonitorWorkspaceId `
        --enable-azure-monitor-app-monitoring `
        --no-wait `
        --output none `
        --only-show-errors

    Write-Host "Waiting for AKS cluster resource to become available..."
    az aks wait `
        --resource-group $resourceGroupName `
        --name $clusterName `
        --exists `
        --interval 15 `
        --timeout 1800 `
        --only-show-errors
}
else {
    Write-Host "AKS cluster already exists. Ensuring monitoring features are enabled..."

    $currentNodeCount = az aks nodepool list `
        --resource-group $resourceGroupName `
        --cluster-name $clusterName `
        --query "[?mode=='System'] | [0].count" `
        --output tsv `
        --only-show-errors

    if ([int]$currentNodeCount -lt $nodeCount) {
        Write-Host "Scaling AKS cluster to $nodeCount nodes..."
        az aks scale `
            --resource-group $resourceGroupName `
            --name $clusterName `
            --node-count $nodeCount `
            --output none `
            --only-show-errors
    }

    $monitoringAddonEnabled = az aks show `
        --resource-group $resourceGroupName `
        --name $clusterName `
        --query addonProfiles.omsagent.enabled `
        --output tsv `
        --only-show-errors

    if ($monitoringAddonEnabled -ne "true") {
        az aks enable-addons `
            --resource-group $resourceGroupName `
            --name $clusterName `
            --addons monitoring `
            --workspace-resource-id $logAnalyticsWorkspaceId `
            --output none `
            --only-show-errors
    }

    az aks update `
        --resource-group $resourceGroupName `
        --name $clusterName `
        --enable-azure-monitor-metrics `
        --azure-monitor-workspace-resource-id $azureMonitorWorkspaceId `
        --enable-azure-monitor-app-monitoring `
        --no-wait `
        --output none `
        --only-show-errors

    Write-Host "Waiting for AKS cluster update to become visible..."
    az aks wait `
        --resource-group $resourceGroupName `
        --name $clusterName `
        --exists `
        --interval 15 `
        --timeout 1800 `
        --only-show-errors
}

$clusterResourceId = az aks show `
    --resource-group $resourceGroupName `
    --name $clusterName `
    --query id `
    --output tsv `
    --only-show-errors

Write-Host "Enabling AKS control plane logs to Log Analytics..."
$diagnosticCategories = (az monitor diagnostic-settings categories list `
    --resource $clusterResourceId `
    --output json `
    --only-show-errors | ConvertFrom-Json).value

$logSettings = @($diagnosticCategories | Where-Object { $_.categoryType -eq "Logs" } | ForEach-Object {
    @{
        category = $_.name
        enabled = $true
    }
})

$metricSettings = @($diagnosticCategories | Where-Object { $_.categoryType -eq "Metrics" } | ForEach-Object {
    @{
        category = $_.name
        enabled = $true
    }
})

$diagnosticArguments = @(
    "monitor", "diagnostic-settings", "create",
    "--name", $diagnosticSettingName,
    "--resource", $clusterResourceId,
    "--workspace", $logAnalyticsWorkspaceId,
    "--export-to-resource-specific", "true",
    "--output", "none",
    "--only-show-errors"
)

$diagnosticLogsFilePath = $null
$diagnosticMetricsFilePath = $null

if ($logSettings.Count -gt 0) {
    $diagnosticLogsFilePath = Join-Path $env:TEMP "aks-control-plane-logs.json"
    $logSettings | ConvertTo-Json -Compress -AsArray | Set-Content -Path $diagnosticLogsFilePath -Encoding utf8
    $diagnosticArguments += @("--logs", ("@" + $diagnosticLogsFilePath))
}

if ($metricSettings.Count -gt 0) {
    $diagnosticMetricsFilePath = Join-Path $env:TEMP "aks-control-plane-metrics.json"
    $metricSettings | ConvertTo-Json -Compress -AsArray | Set-Content -Path $diagnosticMetricsFilePath -Encoding utf8
    $diagnosticArguments += @("--metrics", ("@" + $diagnosticMetricsFilePath))
}

az @diagnosticArguments

if ($diagnosticLogsFilePath -and (Test-Path $diagnosticLogsFilePath)) {
    Remove-Item $diagnosticLogsFilePath -Force
}

if ($diagnosticMetricsFilePath -and (Test-Path $diagnosticMetricsFilePath)) {
    Remove-Item $diagnosticMetricsFilePath -Force
}

Write-Host "Getting AKS credentials..."
az aks get-credentials `
    --resource-group $resourceGroupName `
    --name $clusterName `
    --overwrite-existing `
    --output none `
    --only-show-errors

Write-Host "Waiting for at least one Kubernetes node to report Ready..."
kubectl wait --for=condition=Ready node --all --timeout=30m | Out-Null

if (Test-Path $metricsConfigFilePath) {
    Write-Host "Applying managed Prometheus scrape configuration..."
    kubectl apply -f $metricsConfigFilePath | Out-Null
}

if (Test-Path $namespaceFilePath) {
    Write-Host "Creating demo namespace..."
    kubectl apply -f $namespaceFilePath | Out-Null
}

if (Test-Path $instrumentationTemplateFilePath) {
        Write-Host "Applying app monitoring onboarding manifest..."
        $instrumentationFilePath = Join-Path $env:TEMP "app-monitoring-instrumentation.yaml"
        $instrumentationManifest = Get-Content -Path $instrumentationTemplateFilePath -Raw
        $instrumentationManifest = $instrumentationManifest.Replace("__APPLICATION_INSIGHTS_CONNECTION_STRING__", $applicationInsightsConnectionString)
        $instrumentationManifest | Set-Content -Path $instrumentationFilePath -Encoding utf8
        kubectl apply -f $instrumentationFilePath | Out-Null
        Remove-Item $instrumentationFilePath -Force
}

Write-Host "Collecting a quick status summary..."
kubectl get daemonset ama-logs -n kube-system --ignore-not-found
kubectl get daemonset ama-metrics-node -n kube-system --ignore-not-found

Write-Host ""
Write-Host "Environment is ready."
Write-Host "Resource group: $resourceGroupName"
Write-Host "Cluster:        $clusterName"
Write-Host "Subscription:   $subscriptionId"
Write-Host "Namespace:      $demoNamespace"
Write-Host ""
Write-Host "Deploy the demo workload with:"
Write-Host "kubectl apply -f .\k8s\demo-app-configmap.yaml"
Write-Host "kubectl apply -f .\k8s\demo-app-deployment.yaml"
Write-Host "kubectl apply -f .\k8s\demo-app-service.yaml"
Write-Host "kubectl apply -f .\k8s\load-generator-job.yaml"