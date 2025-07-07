# Setup-DataversePrerequisites.ps1
# This script copies and executes the setup script on the remote VM

param(
    [Parameter(Mandatory=$true)]
    [string]$VMIPAddress,
    
    [Parameter(Mandatory=$true)]
    [string]$Username,
    
    [Parameter(Mandatory=$false)]
    [SecureString]$Password,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseSSHKey
)

# Check if we're using SSH key authentication
if ($UseSSHKey -or -not $Password) {
    Write-Host "Using SSH key authentication" -ForegroundColor Cyan
    $authMethod = "key"
} else {
    Write-Host "Using password authentication" -ForegroundColor Yellow
    $authMethod = "password"
    
    # Convert SecureString to plain text for SSH
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

# Create the setup script
$setupScript = @'
#!/bin/bash
# Dataverse Prerequisites Installation Script

set -e

echo "Starting Dataverse prerequisites installation..."

# Update system
echo "Updating system packages..."
sudo dnf update -y

# Install required packages
echo "Installing base packages..."
sudo dnf install -y epel-release
sudo dnf install -y wget unzip curl vim git python3 python3-pip java-11-openjdk-devel ImageMagick

# Mount and format data disk
echo "Setting up data disk..."
if [ ! -d "/dataverse" ]; then
    DATA_DISK=$(lsblk -nd --output NAME | grep -v sda | grep -v sdb | head -1)
    if [ ! -z "$DATA_DISK" ]; then
        sudo mkfs.ext4 /dev/${DATA_DISK}
        sudo mkdir -p /dataverse
        sudo mount /dev/${DATA_DISK} /dataverse
        echo "/dev/${DATA_DISK} /dataverse ext4 defaults 0 0" | sudo tee -a /etc/fstab
    fi
fi

# Install PostgreSQL 13
echo "Installing PostgreSQL 13..."
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql13-server postgresql13-contrib

# Initialize PostgreSQL
echo "Initializing PostgreSQL..."
sudo /usr/pgsql-13/bin/postgresql-13-setup initdb
sudo systemctl enable postgresql-13
sudo systemctl start postgresql-13

# Configure PostgreSQL
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"
sudo sed -i 's/local   all             all                                     peer/local   all             all                                     md5/' /var/lib/pgsql/13/data/pg_hba.conf
sudo sed -i 's/host    all             all             127.0.0.1\/32            ident/host    all             all             127.0.0.1\/32            md5/' /var/lib/pgsql/13/data/pg_hba.conf
sudo systemctl restart postgresql-13

# Install Payara 6
echo "Installing Payara 6..."
cd /tmp
wget -q https://s3-eu-west-1.amazonaws.com/payara.fish/Payara+Downloads/6.2024.3/payara-6.2024.3.zip
sudo unzip -q payara-6.2024.3.zip -d /usr/local/
sudo mv /usr/local/payara6 /usr/local/payara6
rm payara-6.2024.3.zip

# Create payara user
sudo useradd -s /bin/false -d /usr/local/payara6 payara || true
sudo chown -R payara:payara /usr/local/payara6

# Create Payara systemd service
sudo tee /etc/systemd/system/payara.service > /dev/null <<EOF
[Unit]
Description=Payara Server
After=network.target

[Service]
Type=forking
User=payara
Group=payara
ExecStart=/usr/local/payara6/bin/asadmin start-domain domain1
ExecStop=/usr/local/payara6/bin/asadmin stop-domain domain1
TimeoutStartSec=300
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable payara
sudo systemctl start payara

# Install Solr 9.3.0
echo "Installing Solr 9.3.0..."
cd /tmp
wget -q https://archive.apache.org/dist/solr/solr/9.3.0/solr-9.3.0.tgz
tar xzf solr-9.3.0.tgz
cd solr-9.3.0
sudo ./bin/install_solr_service.sh ../solr-9.3.0.tgz
sudo systemctl enable solr
sudo systemctl start solr

# Create Solr collection
sleep 10
sudo -u solr /opt/solr/bin/solr create_core -c collection1

# Create directories
sudo mkdir -p /dataverse/files /dataverse/docroot /dataverse/logs
sudo chown -R payara:payara /dataverse

# Open firewall ports
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=8983/tcp
sudo firewall-cmd --reload

# Create info file
cat > ~/dataverse-info.txt <<EOL
Dataverse Prerequisites Installed!

PostgreSQL: Running on port 5432 (password: postgres)
Payara: Running on port 8080
Solr: Running on port 8983

Next steps:
1. Download Dataverse installer
2. Run installation script
3. Access at http://$VMIPAddress:8080

To download and run Dataverse installer:
wget https://github.com/IQSS/dataverse/releases/download/v6.1/dvinstall.zip
unzip dvinstall.zip
cd dvinstall
./install.py
EOL

echo "Setup complete! Check ~/dataverse-info.txt for details."
'@

# Save script locally
$setupScript | Out-File -FilePath ".\dataverse-setup.sh" -Encoding UTF8

Write-Host "Copying setup script to VM..." -ForegroundColor Cyan

# Try native SSH/SCP first (works with SSH keys)
if ($authMethod -eq "key") {
    try {
        # Test SSH connection
        $testConnection = ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$Username@$VMIPAddress" "echo 'SSH connection successful'"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ SSH connection established" -ForegroundColor Green
            
            # Copy the setup script
            scp -o StrictHostKeyChecking=no ".\dataverse-setup.sh" "${Username}@${VMIPAddress}:~/"
            
            # Execute the script
            Write-Host "Executing setup script on VM (this will take 10-15 minutes)..." -ForegroundColor Cyan
            ssh -o StrictHostKeyChecking=no "$Username@$VMIPAddress" "chmod +x ~/dataverse-setup.sh && bash ~/dataverse-setup.sh"
            
            Write-Host "`n✅ Setup completed!" -ForegroundColor Green
            Write-Host "Next steps:" -ForegroundColor Cyan
            Write-Host "1. SSH to VM: ssh $Username@$VMIPAddress" -ForegroundColor White
            Write-Host "2. Install Dataverse: cd dvinstall && ./install.py" -ForegroundColor White
            return
        }
    } catch {
        Write-Host "Native SSH failed, trying Posh-SSH module..." -ForegroundColor Yellow
    }
}

# Fall back to Posh-SSH module for password authentication
if (Get-Module -ListAvailable -Name Posh-SSH) {
    Import-Module Posh-SSH
    
    if ($authMethod -eq "password") {
        $cred = New-Object System.Management.Automation.PSCredential ($Username, $Password)
    } else {
        # For SSH key with Posh-SSH
        $keyPath = "$env:USERPROFILE\.ssh\id_ed25519"
        if (-not (Test-Path $keyPath)) {
            $keyPath = "$env:USERPROFILE\.ssh\id_rsa"
        }
        $cred = New-Object System.Management.Automation.PSCredential ($Username, (New-Object System.Security.SecureString))
    }
    
    # Create SSH session
    $sessionParams = @{
        ComputerName = $VMIPAddress
        Credential = $cred
        AcceptKey = $true
    }
    
    if ($authMethod -eq "key" -and (Test-Path $keyPath)) {
        $sessionParams.KeyFile = $keyPath
    }
    
    $session = New-SSHSession @sessionParams
    
    # Copy file
    Set-SCPItem -ComputerName $VMIPAddress -Credential $cred -Path ".\dataverse-setup.sh" -Destination "/home/$Username/" -AcceptKey
    
    # Execute script
    Write-Host "Executing setup script on VM (this will take 10-15 minutes)..." -ForegroundColor Cyan
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command "chmod +x /home/$Username/dataverse-setup.sh && bash /home/$Username/dataverse-setup.sh"
    $result.Output
    
    # Remove session
    Remove-SSHSession -SessionId $session.SessionId
} else {
    Write-Host "SSH connection methods unavailable." -ForegroundColor Red
    Write-Host "`nFor SSH key authentication:" -ForegroundColor Cyan
    Write-Host "1. Ensure your SSH key is loaded: ssh-add $env:USERPROFILE\.ssh\id_ed25519" -ForegroundColor White
    Write-Host "2. Copy script manually: scp .\dataverse-setup.sh ${Username}@${VMIPAddress}:~/" -ForegroundColor White
    Write-Host "3. Run script: ssh $Username@$VMIPAddress 'bash ~/dataverse-setup.sh'" -ForegroundColor White
    
    Write-Host "`nFor password authentication:" -ForegroundColor Cyan
    Write-Host "Install-Module -Name Posh-SSH -Force" -ForegroundColor Yellow
}