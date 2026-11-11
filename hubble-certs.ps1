#!/usr/bin/env pwsh
# PowerShell script to extract and configure Hubble certificates

$errorActionPreference = "Stop"

# Directory where certificates will be stored
$certDir = Join-Path (Get-Location) ".certs"
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

# Define certificate files and their corresponding config keys
$certFiles = @{
    "tls.crt" = "tls-client-cert-file"
    "tls.key" = "tls-client-key-file"
    "ca.crt"  = "tls-ca-cert-files"
}

foreach ($file in $certFiles.Keys) {
    $configKey = $certFiles[$file]
    $certPath = Join-Path $certDir $file
    
    Write-Host "Extracting $file..." -ForegroundColor Cyan

    $escapedFile = $file -replace '\.', '\.'

    # Retrieve the secret and decode it
    $base64Data = kubectl get secret hubble-relay-client-certs -n kube-system -o jsonpath="{.data.$escapedFile}"
    
    if ([string]::IsNullOrEmpty($base64Data)) {
        Write-Error "Failed to retrieve $file from secret"
        exit 1
    }
    
    # Decode base64 and save to file
    $bytes = [System.Convert]::FromBase64String($base64Data)
    [System.IO.File]::WriteAllBytes($certPath, $bytes)
    
    # Set the appropriate hubble CLI config
    hubble config set $configKey $certPath
    
    Write-Host "Configured $configKey" -ForegroundColor Green
}

# Configure TLS settings
Write-Host "Configuring TLS settings..." -ForegroundColor Cyan
hubble config set tls true
hubble config set tls-server-name instance.hubble-relay.cilium.io

Write-Host "Certificate extraction and configuration complete!" -ForegroundColor Green
Write-Host "Certificates saved to: $certDir" -ForegroundColor Yellow