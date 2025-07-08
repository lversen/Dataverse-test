# Quick-Deploy-Dataverse.ps1
# Complete example of deploying Dataverse with SSH keys

Write-Host @"
╔═══════════════════════════════════════════╗
║   Dataverse Quick Deploy for Azure        ║
║   Non-Production Environment              ║
╚═══════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# Step 1: Check prerequisites
Write-Host "`n📋 Checking prerequisites..." -ForegroundColor Yellow

# Check Azure PowerShell
if (-not (Get-Module -ListAvailable -Name Az)) {
    Write-Host "❌ Azure PowerShell not found" -ForegroundColor Red
    Write-Host "   Install with: Install-Module -Name Az -Force" -ForegroundColor White
    exit 1
} else {
    Write-Host "✓ Azure PowerShell installed" -ForegroundColor Green
}

# Check Azure connection
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Connecting to Azure..." -ForegroundColor Yellow
        Connect-AzAccount
    } else {
        Write-Host "✓ Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Failed to connect to Azure" -ForegroundColor Red
    exit 1
}

# Step 2: Check for SSH keys
Write-Host "`n🔑 Checking SSH keys..." -ForegroundColor Yellow
$sshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub"
$hasSSHKey = Test-Path $sshKeyPath

if ($hasSSHKey) {
    Write-Host "✓ Found SSH key at: $sshKeyPath" -ForegroundColor Green
} else {
    Write-Host "❌ No SSH key found" -ForegroundColor Red
    $createKey = Read-Host "Would you like to create one now? (Y/n)"
    
    if ($createKey -ne 'n') {
        Write-Host "`nGenerating SSH key..." -ForegroundColor Cyan
        if (Test-Path ".\Setup-SSHKeys.ps1") {
            .\Setup-SSHKeys.ps1
        } else {
            ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519" -N '""'
        }
        $hasSSHKey = Test-Path $sshKeyPath
    }
}

# Step 3: Get deployment parameters
Write-Host "`n🚀 Deployment Configuration" -ForegroundColor Yellow
$resourceGroup = Read-Host "Resource Group Name (dataverse-nonprod-rg)"
if (-not $resourceGroup) { $resourceGroup = "dataverse-nonprod-rg" }

$vmName = Read-Host "VM Name (dataverse-dev-vm)"
if (-not $vmName) { $vmName = "dataverse-dev-vm" }

$AdminUsername = Read-Host "Admin Username (azureuser)"
if (-not $AdminUsername) { $AdminUsername = "azureuser" }

$vmSize = Read-Host "VM Size (Standard_B2as_v2)"
if (-not $vmSize) { $vmSize = "Standard_B2as_v2" }

$useSpot = Read-Host "Use Spot VM for cost savings? (Y/n)"
$useSpotVM = $useSpot -ne 'n'

# Step 4: Deploy VM
Write-Host "`n🏗️  Deploying VM..." -ForegroundColor Cyan
Write-Host "This will take about 5-10 minutes..." -ForegroundColor White

$deployParams = @{
    ResourceGroupName = $resourceGroup
    VMName = $vmName
    VMSize = $vmSize
    UseSpotVM = $useSpotVM
    AdminUsername = $AdminUsername
}

if ($hasSSHKey) {
    $deployParams.AuthType = "SSH"
}

# Deploy the VM
$deploymentSuccess = $false
try {
    if (Test-Path ".\Deploy-DataverseVM.ps1") {
        .\Deploy-DataverseVM.ps1 @deployParams
        
        # Check if VM was actually created
        Start-Sleep -Seconds 5
        $vmCheck = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName -ErrorAction SilentlyContinue
        if ($vmCheck) {
            $deploymentSuccess = $true
            Write-Host "✓ VM deployment verified!" -ForegroundColor Green
        }
    } else {
        Write-Error "Deploy-DataverseVM.ps1 not found!"
        exit 1
    }
} catch {
    Write-Error "Deployment failed: $_"
}

if (-not $deploymentSuccess) {
    # Double-check if VM exists (sometimes the check is too quick)
    Start-Sleep -Seconds 10
    $vmCheck = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName -ErrorAction SilentlyContinue
    if ($vmCheck) {
        $deploymentSuccess = $true
        Write-Host "✓ VM deployment verified on second check!" -ForegroundColor Green
    }
}

if (-not $deploymentSuccess) {
    Write-Error "VM deployment failed. Please check the error messages above and try again."
    exit 1
}

# Step 5: Wait for VM to be ready
Write-Host "`n⏳ Waiting for VM to be fully ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# Get VM details
$vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM not found. Deployment may have failed."
    exit 1
}

$pip = Get-AzPublicIpAddress -ResourceGroupName $resourceGroup -Name "$vmName-pip" -ErrorAction SilentlyContinue
if ($pip) {
    $ipAddress = $pip.IpAddress
}

if (-not $ipAddress) {
    Write-Host "Waiting for IP address assignment..." -ForegroundColor Yellow
    Start-Sleep -Seconds 20
    $pip = Get-AzPublicIpAddress -ResourceGroupName $resourceGroup -Name "$vmName-pip" -ErrorAction SilentlyContinue
    if ($pip) {
        $ipAddress = $pip.IpAddress
    }
}

if (-not $ipAddress) {
    Write-Error "Failed to get public IP address. VM may not have been created properly."
    exit 1
}

Write-Host "✓ VM is ready! IP: $ipAddress" -ForegroundColor Green

# Step 6: Install prerequisites
$installPrereqs = Read-Host "`nInstall Dataverse prerequisites now? (Y/n)"
if ($installPrereqs -ne 'n') {
    Write-Host "`n📦 Installing Dataverse prerequisites..." -ForegroundColor Cyan
    Write-Host "This will take about 10-15 minutes..." -ForegroundColor White
    
    $setupParams = @{
        VMIPAddress = $ipAddress
        Username = $AdminUsername
    }
    
    if ($hasSSHKey) {
        $setupParams.UseSSHKey = $true
    } else {
        $setupParams.Password = Read-Host "Enter VM Password" -AsSecureString
    }
    
    if (Test-Path ".\Setup-DataversePrerequisites.ps1") {
        .\Setup-DataversePrerequisites.ps1 @setupParams
    } else {
        Write-Host "Setup script not found. Manual setup required." -ForegroundColor Yellow
    }
}

# Step 7: Display summary and next steps
Write-Host "`n✨ Deployment Summary" -ForegroundColor Green
Write-Host "═══════════════════════════════════════" -ForegroundColor Green
Write-Host "Resource Group: $resourceGroup" -ForegroundColor White
Write-Host "VM Name: $vmName" -ForegroundColor White
Write-Host "VM Size: $vmSize" -ForegroundColor White
Write-Host "Public IP: $ipAddress" -ForegroundColor White
Write-Host "SSH Command: ssh $AdminUsername@$ipAddress" -ForegroundColor Yellow
if ($useSpotVM) {
    Write-Host "VM Type: Spot VM (Cost Optimized)" -ForegroundColor Green
}
Write-Host "Auto-shutdown: 19:00 CET daily" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════" -ForegroundColor Green

# Cost estimate
Write-Host "`n💰 Estimated Monthly Cost:" -ForegroundColor Cyan
if ($useSpotVM) {
    Write-Host "   ~€15-25/month (with auto-shutdown)" -ForegroundColor Green
} else {
    Write-Host "   ~€35-40/month (with auto-shutdown)" -ForegroundColor Yellow
}

# Next steps
Write-Host "`n📝 Next Steps:" -ForegroundColor Cyan
Write-Host "1. SSH to your VM:" -ForegroundColor White
Write-Host "   ssh $AdminUsername@$ipAddress" -ForegroundColor Yellow
Write-Host "`n2. Download Dataverse installer:" -ForegroundColor White
Write-Host "   wget https://github.com/IQSS/dataverse/releases/download/v6.1/dvinstall.zip" -ForegroundColor Yellow
Write-Host "   unzip dvinstall.zip" -ForegroundColor Yellow
Write-Host "   cd dvinstall" -ForegroundColor Yellow
Write-Host "`n3. Run Dataverse installer:" -ForegroundColor White
Write-Host "   ./install.py" -ForegroundColor Yellow
Write-Host "`n4. Access Dataverse at:" -ForegroundColor White
Write-Host "   http://$ipAddress:8080" -ForegroundColor Green

# Management tips
Write-Host "`n💡 Management Tips:" -ForegroundColor Cyan
Write-Host "• Stop VM when not in use: .\Manage-DataverseVM.ps1 -Action Stop" -ForegroundColor White
Write-Host "• Check costs: .\Manage-DataverseVM.ps1 -Action Costs" -ForegroundColor White
Write-Host "• Create backup: .\Manage-DataverseVM.ps1 -Action Backup" -ForegroundColor White

# Save quick connect script
$quickConnect = @"
# Quick connect to Dataverse VM
ssh $AdminUsername@$ipAddress

# Or open in browser
Start-Process "http://${ipAddress}:8080"
"@
$quickConnect | Out-File -FilePath ".\quick-connect-dataverse.ps1"
Write-Host "`n✓ Quick connect script saved to: .\quick-connect-dataverse.ps1" -ForegroundColor Green

Write-Host "`n🎉 Deployment complete!" -ForegroundColor Green