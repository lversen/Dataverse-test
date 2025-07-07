# Setup-SSHKeys.ps1
# Helper script to set up SSH keys for Azure VM authentication

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('ed25519','rsa')]
    [string]$KeyType = 'ed25519',
    
    [Parameter(Mandatory=$false)]
    [string]$Comment = "$env:USERNAME@$env:COMPUTERNAME"
)

Write-Host "SSH Key Setup for Azure VMs" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan

# Check if OpenSSH is available
$sshPath = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $sshPath) {
    Write-Error "ssh-keygen not found! OpenSSH client needs to be installed."
    Write-Host "`nTo install OpenSSH on Windows 10/11:" -ForegroundColor Yellow
    Write-Host "1. Open Settings > Apps > Optional Features" -ForegroundColor White
    Write-Host "2. Add 'OpenSSH Client'" -ForegroundColor White
    Write-Host "`nOr run this PowerShell command as Administrator:" -ForegroundColor Yellow
    Write-Host "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -ForegroundColor Cyan
    exit 1
}

# Define key paths
$sshDir = "$env:USERPROFILE\.ssh"
$keyPath = Join-Path $sshDir "id_$KeyType"
$pubKeyPath = "$keyPath.pub"

# Create .ssh directory if it doesn't exist
if (-not (Test-Path $sshDir)) {
    Write-Host "Creating SSH directory: $sshDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

# Check if key already exists
if (Test-Path $keyPath) {
    Write-Host "SSH key already exists at: $keyPath" -ForegroundColor Yellow
    $overwrite = Read-Host "Do you want to overwrite it? (y/N)"
    if ($overwrite -ne 'y') {
        Write-Host "Using existing key." -ForegroundColor Green
        
        # Display the public key
        if (Test-Path $pubKeyPath) {
            Write-Host "`nYour public key:" -ForegroundColor Cyan
            Get-Content $pubKeyPath
            Write-Host "`nThis is the key that will be used for Azure VM authentication." -ForegroundColor Green
        }
        exit 0
    }
}

# Generate new SSH key
Write-Host "`nGenerating new SSH key pair..." -ForegroundColor Cyan
Write-Host "Key Type: $KeyType" -ForegroundColor White
Write-Host "Location: $keyPath" -ForegroundColor White
Write-Host "Comment: $Comment" -ForegroundColor White

# Run ssh-keygen
$keyGenArgs = @(
    "-t", $KeyType,
    "-C", $Comment,
    "-f", $keyPath,
    "-N", '""'  # Empty passphrase for automation
)

Write-Host "`nGenerating key (no passphrase for easier automation)..." -ForegroundColor Yellow
$result = Start-Process ssh-keygen -ArgumentList $keyGenArgs -NoNewWindow -Wait -PassThru

if ($result.ExitCode -eq 0) {
    Write-Host "`n✓ SSH key generated successfully!" -ForegroundColor Green
    
    # Display the public key
    Write-Host "`nYour public key:" -ForegroundColor Cyan
    $publicKey = Get-Content $pubKeyPath
    Write-Host $publicKey -ForegroundColor White
    
    # Copy to clipboard if available
    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
        $publicKey | Set-Clipboard
        Write-Host "`n✓ Public key copied to clipboard!" -ForegroundColor Green
    }
    
    # Set proper permissions on Windows
    Write-Host "`nSetting file permissions..." -ForegroundColor Cyan
    $acl = Get-Acl $keyPath
    $acl.SetAccessRuleProtection($true, $false)
    $permission = "$env:USERNAME","FullControl","Allow"
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
    $acl.SetAccessRule($accessRule)
    Set-Acl $keyPath $acl
    
    # Instructions
    Write-Host "`n📋 Next Steps:" -ForegroundColor Cyan
    Write-Host "1. Your SSH key pair has been created" -ForegroundColor White
    Write-Host "2. Private key: $keyPath" -ForegroundColor White
    Write-Host "3. Public key: $pubKeyPath" -ForegroundColor White
    Write-Host "`n🚀 To deploy a VM with this key:" -ForegroundColor Cyan
    Write-Host "   .\Deploy-DataverseVM.ps1 -AuthType SSH" -ForegroundColor Yellow
    
    # Test SSH agent
    Write-Host "`n🔐 SSH Agent Status:" -ForegroundColor Cyan
    $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($sshAgentService) {
        if ($sshAgentService.Status -ne 'Running') {
            Write-Host "SSH Agent is not running. Starting it..." -ForegroundColor Yellow
            Start-Service ssh-agent
            Set-Service ssh-agent -StartupType Automatic
        }
        
        # Add key to agent
        Write-Host "Adding key to SSH agent..." -ForegroundColor Cyan
        ssh-add $keyPath
        Write-Host "✓ Key added to SSH agent" -ForegroundColor Green
    } else {
        Write-Host "SSH Agent service not found. You may need to add the key manually:" -ForegroundColor Yellow
        Write-Host "  ssh-add $keyPath" -ForegroundColor White
    }
    
} else {
    Write-Error "Failed to generate SSH key!"
    exit 1
}

# Create config file template
$configPath = Join-Path $sshDir "config"
if (-not (Test-Path $configPath)) {
    Write-Host "`nCreating SSH config file..." -ForegroundColor Cyan
    @"
# Azure Dataverse VM
Host dataverse-*
    User azureuser
    IdentityFile $keyPath
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
"@ | Out-File -FilePath $configPath -Encoding UTF8
    Write-Host "✓ SSH config created at: $configPath" -ForegroundColor Green
}

Write-Host "`n✅ SSH setup complete!" -ForegroundColor Green
Write-Host "You can now deploy VMs with SSH authentication." -ForegroundColor Cyan