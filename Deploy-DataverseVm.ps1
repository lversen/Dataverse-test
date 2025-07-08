# Deploy-DataverseVM.ps1
# Non-Production Dataverse VM Deployment for Azure (Northern Europe)

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "dataverse-nonprod-rg",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "northeurope",
    
    [Parameter(Mandatory=$false)]
    [string]$VMName = "dataverse-dev-vm",
    
    [Parameter(Mandatory=$false)]
    [string]$VMSize = "Standard_B2as_v2",  # Burstable for cost savings
    
    [Parameter(Mandatory=$false)]
    [bool]$UseSpotVM = $true,  # Use Spot VM for maximum savings
    
    [Parameter(Mandatory=$false)]
    [string]$AdminUsername = "azureuser",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('SSH','Password','Auto')]
    [string]$AuthType = "Auto",
    
    [Parameter(Mandatory=$false)]
    [string]$SSHKeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub",
    
    [Parameter(Mandatory=$false)]
    [SecureString]$AdminPassword
)

# Function to check for SSH key
function Test-SSHKey {
    param([string]$Path)
    
    if (Test-Path $Path) {
        Write-Host "✓ Found SSH key at: $Path" -ForegroundColor Green
        return $true
    }
    return $false
}

# Determine authentication method
$useSSHKey = $false
$sshPublicKey = ""
$plainPassword = ""

if ($AuthType -eq "Auto" -or $AuthType -eq "SSH") {
    # Check for SSH keys in order of preference
    $sshKeyPaths = @(
        "$env:USERPROFILE\.ssh\id_ed25519.pub",
        "$env:USERPROFILE\.ssh\id_rsa.pub",
        "$HOME\.ssh\id_ed25519.pub",
        "$HOME\.ssh\id_rsa.pub"
    )
    
    if ($SSHKeyPath -and (Test-SSHKey $SSHKeyPath)) {
        $useSSHKey = $true
        $sshPublicKey = Get-Content $SSHKeyPath -Raw
        Write-Host "Using SSH key authentication" -ForegroundColor Cyan
    } else {
        foreach ($keyPath in $sshKeyPaths) {
            if (Test-SSHKey $keyPath) {
                $useSSHKey = $true
                $sshPublicKey = Get-Content $keyPath -Raw
                $SSHKeyPath = $keyPath
                Write-Host "Using SSH key authentication" -ForegroundColor Cyan
                break
            }
        }
    }
    
    if (-not $useSSHKey -and $AuthType -eq "SSH") {
        Write-Error "SSH key not found! Checked locations:"
        $sshKeyPaths | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host "`nTo generate an SSH key, run:" -ForegroundColor Cyan
        Write-Host "  ssh-keygen -t ed25519 -C `"your_email@example.com`"" -ForegroundColor White
        exit 1
    }
}

# Fall back to password if no SSH key or forced password auth
if (-not $useSSHKey) {
    if (-not $AdminPassword) {
        Add-Type -AssemblyName System.Web
        $plainPassword = [System.Web.Security.Membership]::GeneratePassword(16, 4)
        $AdminPassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
        Write-Host "Generated Admin Password: $plainPassword" -ForegroundColor Yellow
        Write-Host "SAVE THIS PASSWORD! You'll need it to access the VM." -ForegroundColor Red
        Write-Host "TIP: Use SSH keys for better security. Run: ssh-keygen -t ed25519" -ForegroundColor Cyan
    } else {
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    }
    Write-Host "Using password authentication" -ForegroundColor Yellow
}

Write-Host "Starting Dataverse VM deployment..." -ForegroundColor Green

# Create Resource Group
Write-Host "Creating Resource Group: $ResourceGroupName in $Location" -ForegroundColor Cyan
try {
    $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force
} catch {
    Write-Error "Failed to create resource group: $_"
    exit 1
}

# Create Virtual Network
Write-Host "Creating Virtual Network..." -ForegroundColor Cyan
$subnetConfig = New-AzVirtualNetworkSubnetConfig `
    -Name "default" `
    -AddressPrefix "10.0.1.0/24"

$vnet = New-AzVirtualNetwork `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "$VMName-vnet" `
    -AddressPrefix "10.0.0.0/16" `
    -Subnet $subnetConfig

# Create Public IP (Basic tier for cost savings)
Write-Host "Creating Public IP..." -ForegroundColor Cyan
$pip = New-AzPublicIpAddress `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "$VMName-pip" `
    -AllocationMethod Dynamic `
    -Sku Basic

# Create Network Security Group and rules
Write-Host "Creating Network Security Group..." -ForegroundColor Cyan
$nsgRuleSSH = New-AzNetworkSecurityRuleConfig `
    -Name "SSH" `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 1000 `
    -SourceAddressPrefix * `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 22 `
    -Access Allow

$nsgRuleHTTP = New-AzNetworkSecurityRuleConfig `
    -Name "HTTP" `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 1001 `
    -SourceAddressPrefix * `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 80 `
    -Access Allow

$nsgRuleHTTPS = New-AzNetworkSecurityRuleConfig `
    -Name "HTTPS" `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 1002 `
    -SourceAddressPrefix * `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 443 `
    -Access Allow

$nsgRuleDataverse = New-AzNetworkSecurityRuleConfig `
    -Name "Dataverse" `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 1003 `
    -SourceAddressPrefix * `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 8080 `
    -Access Allow

$nsg = New-AzNetworkSecurityGroup `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "$VMName-nsg" `
    -SecurityRules $nsgRuleSSH,$nsgRuleHTTP,$nsgRuleHTTPS,$nsgRuleDataverse

# Create Network Interface
Write-Host "Creating Network Interface..." -ForegroundColor Cyan
$nic = New-AzNetworkInterface `
    -Name "$VMName-nic" `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -SubnetId $vnet.Subnets[0].Id `
    -PublicIpAddressId $pip.Id `
    -NetworkSecurityGroupId $nsg.Id

# Create VM Configuration
Write-Host "Creating VM Configuration..." -ForegroundColor Cyan
$vmConfig = New-AzVMConfig -VMName $VMName -VMSize $VMSize

# Configure Spot VM if requested (massive cost savings)
if ($UseSpotVM) {
    Write-Host "Configuring as Spot VM for cost savings..." -ForegroundColor Yellow
    $vmConfig.Priority = "Spot"
    $vmConfig.EvictionPolicy = "Deallocate"
}

# Set OS and credentials
if ($useSSHKey) {
    # Configure for SSH key authentication
    # Create a dummy credential object (required by Azure even for SSH key auth)
    $dummyPassword = ConvertTo-SecureString "DummyPassword123!" -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, $dummyPassword)
    
    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Linux `
        -ComputerName $VMName `
        -Credential $cred `
        -DisablePasswordAuthentication
    
    # Add SSH public key
    $vmConfig = Add-AzVMSshPublicKey `
        -VM $vmConfig `
        -KeyData $sshPublicKey `
        -Path "/home/$AdminUsername/.ssh/authorized_keys"
} else {
    # Configure for password authentication
    $cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, $AdminPassword)
    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Linux `
        -ComputerName $VMName `
        -Credential $cred
}

# Set source image (AlmaLinux 8)
$vmConfig = Set-AzVMSourceImage `
    -VM $vmConfig `
    -PublisherName "almalinux" `
    -Offer "almalinux-x86_64" `
    -Skus "8-gen2" `
    -Version "latest"

# Add Network Interface
$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

# Configure OS disk (Standard SSD for cost savings)
$vmConfig = Set-AzVMOSDisk `
    -VM $vmConfig `
    -CreateOption FromImage `
    -StorageAccountType StandardSSD_LRS `
    -DiskSizeInGB 64

# Add data disk for Dataverse files
$vmConfig = Add-AzVMDataDisk `
    -VM $vmConfig `
    -Name "$VMName-datadisk" `
    -Lun 0 `
    -CreateOption Empty `
    -DiskSizeInGB 128 `
    -StorageAccountType StandardSSD_LRS

# Disable boot diagnostics (saves storage costs)
$vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

# Create the VM
Write-Host "Creating Virtual Machine (this may take several minutes)..." -ForegroundColor Cyan
try {
    $vm = New-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -VM $vmConfig
} catch {
    Write-Error "Failed to create VM: $_"
    exit 1
}

# Get Public IP Address
$publicIp = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name "$VMName-pip"
$ipAddress = $publicIp.IpAddress

# Create Auto-Shutdown Schedule (saves costs!)
if ($vm -and $vm.Id) {
    Write-Host "Setting up auto-shutdown at 19:00 CET..." -ForegroundColor Cyan
    $shutdownTime = "1900"
    $timeZone = "W. Europe Standard Time"

    $properties = @{
        "status" = "Enabled"
        "taskType" = "ComputeVmShutdownTask"
        "dailyRecurrence" = @{
            "time" = $shutdownTime
        }
        "timeZoneId" = $timeZone
        "targetResourceId" = $vm.Id
        "notificationSettings" = @{
            "status" = "Disabled"
        }
    }

    New-AzResource `
        -ResourceId "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$VMName" `
        -Location $Location `
        -Properties $properties `
        -Force | Out-Null
} else {
    Write-Host "VM creation failed - skipping auto-shutdown configuration" -ForegroundColor Yellow
}

if ($vm) {
    Write-Host "`nDeployment completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "VM Name: $VMName" -ForegroundColor White
    Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor White
    Write-Host "Public IP: $ipAddress" -ForegroundColor White
    Write-Host "SSH Command: ssh $AdminUsername@$ipAddress" -ForegroundColor Yellow
    Write-Host "Username: $AdminUsername" -ForegroundColor White
    Write-Host "VM Size: $VMSize" -ForegroundColor White
    if ($useSSHKey) {
        Write-Host "Authentication: SSH Key" -ForegroundColor Green
        Write-Host "SSH Key Used: $SSHKeyPath" -ForegroundColor Green
    } else {
        Write-Host "Authentication: Password" -ForegroundColor Yellow
        Write-Host "Password: $plainPassword" -ForegroundColor Yellow
    }
    if ($UseSpotVM) {
        Write-Host "VM Type: SPOT VM (Maximum cost savings!)" -ForegroundColor Green
    }
    Write-Host "Auto-shutdown: Daily at $shutdownTime $timeZone" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan

    # Output connection details to file
    $outputFile = ".\dataverse-vm-connection.txt"
    if ($useSSHKey) {
        @"
Dataverse VM Connection Details
==============================
VM Name: $VMName
Resource Group: $ResourceGroupName
Public IP: $ipAddress
SSH Command: ssh $AdminUsername@$ipAddress
Username: $AdminUsername
Authentication: SSH Key ($SSHKeyPath)

Dataverse URL (after installation): http://$ipAddress:8080

Auto-shutdown configured for 19:00 CET daily

To connect:
  ssh $AdminUsername@$ipAddress

If connection fails, ensure your SSH agent has the key loaded:
  ssh-add $($SSHKeyPath -replace '\.pub','')
"@ | Out-File -FilePath $outputFile
    } else {
        @"
Dataverse VM Connection Details
==============================
VM Name: $VMName
Resource Group: $ResourceGroupName
Public IP: $ipAddress
SSH Command: ssh $AdminUsername@$ipAddress
Username: $AdminUsername
Password: $plainPassword

Dataverse URL (after installation): http://$ipAddress:8080

Auto-shutdown configured for 19:00 CET daily

SECURITY TIP: Consider using SSH keys instead of passwords!
Generate one with: ssh-keygen -t ed25519
"@ | Out-File -FilePath $outputFile
    }

    Write-Host "`nConnection details saved to: $outputFile" -ForegroundColor Green

    # Estimated costs
    Write-Host "`nEstimated Monthly Costs (Non-Production):" -ForegroundColor Yellow
    if ($UseSpotVM) {
        Write-Host "  Spot VM ($VMSize): ~€10-15/month" -ForegroundColor Green
        Write-Host "  OS Disk (64GB SSD): ~€5/month" -ForegroundColor Green
        Write-Host "  Data Disk (128GB SSD): ~€10/month" -ForegroundColor Green
        Write-Host "  Public IP: ~€3/month" -ForegroundColor Green
        Write-Host "  Total: ~€28-33/month (with auto-shutdown)" -ForegroundColor Cyan
    } else {
        Write-Host "  VM ($VMSize): ~€52/month" -ForegroundColor Green
        Write-Host "  OS Disk (64GB SSD): ~€5/month" -ForegroundColor Green
        Write-Host "  Data Disk (128GB SSD): ~€10/month" -ForegroundColor Green
        Write-Host "  Public IP: ~€3/month" -ForegroundColor Green
        Write-Host "  Total: ~€70/month (€35/month with auto-shutdown)" -ForegroundColor Cyan
    }
} else {
    Write-Error "VM deployment failed! Check the error messages above."
    exit 1
}