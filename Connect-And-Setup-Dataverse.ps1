# Connect-And-Setup-Dataverse.ps1
# Quick script to connect to your existing VM and set up Dataverse

$vmIP = "13.69.216.105"
$username = "azureuser"

Write-Host "🚀 Connecting to your Dataverse VM..." -ForegroundColor Cyan
Write-Host "IP Address: $vmIP" -ForegroundColor White
Write-Host "Username: $username" -ForegroundColor White

# Test SSH connection
Write-Host "`nTesting SSH connection..." -ForegroundColor Yellow
$testConnection = ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$username@$vmIP" "echo 'Connection successful!'"

if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ SSH connection successful!" -ForegroundColor Green
    
    $installNow = Read-Host "`nInstall Dataverse prerequisites now? (Y/n)"
    if ($installNow -ne 'n') {
        Write-Host "`n📦 Installing prerequisites (this will take 10-15 minutes)..." -ForegroundColor Cyan
        
        # Run the setup commands
        ssh "$username@$vmIP" @'
#!/bin/bash
set -e

echo "Starting Dataverse prerequisites installation..."

# Update system
echo "Updating system packages..."
sudo dnf update -y

# Install required packages
echo "Installing base packages..."
sudo dnf install -y epel-release
sudo dnf install -y wget unzip curl vim git python3 python3-pip java-11-openjdk-devel ImageMagick

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

echo "✅ Prerequisites installed successfully!"
echo ""
echo "Next steps:"
echo "1. Download Dataverse: wget https://github.com/IQSS/dataverse/releases/download/v6.1/dvinstall.zip"
echo "2. Extract: unzip dvinstall.zip"
echo "3. Install: cd dvinstall && ./install.py"
'@
        
        Write-Host "`n✅ Prerequisites installed!" -ForegroundColor Green
        Write-Host "`nNow connecting you to the VM to install Dataverse..." -ForegroundColor Cyan
        ssh "$username@$vmIP"
    } else {
        Write-Host "`nConnecting to VM..." -ForegroundColor Cyan
        ssh "$username@$vmIP"
    }
} else {
    Write-Host "❌ SSH connection failed!" -ForegroundColor Red
    Write-Host "`nPossible issues:" -ForegroundColor Yellow
    Write-Host "1. VM might still be starting up (wait 1-2 minutes)" -ForegroundColor White
    Write-Host "2. SSH key might not be loaded in agent" -ForegroundColor White
    Write-Host "   Try: ssh-add $env:USERPROFILE\.ssh\id_ed25519" -ForegroundColor Cyan
    Write-Host "3. Network connectivity issues" -ForegroundColor White
    
    Write-Host "`nManual connection command:" -ForegroundColor Yellow
    Write-Host "ssh $username@$vmIP" -ForegroundColor Cyan
}

# Show VM management commands
Write-Host "`n📋 Useful Commands:" -ForegroundColor Cyan
Write-Host "Stop VM:    .\Manage-DataverseVM.ps1 -Action Stop" -ForegroundColor White
Write-Host "Start VM:   .\Manage-DataverseVM.ps1 -Action Start" -ForegroundColor White
Write-Host "Get Status: .\Manage-DataverseVM.ps1 -Action Status" -ForegroundColor White
Write-Host "Check Costs: .\Manage-DataverseVM.ps1 -Action Costs" -ForegroundColor White