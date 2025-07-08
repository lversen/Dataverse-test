#!/bin/bash
# Complete Dataverse Prerequisites Installation Script

set -e  # Exit on error

echo "==================================="
echo "Dataverse Prerequisites Installation"
echo "==================================="

# Update system
echo "📦 Updating system packages..."
sudo dnf update -y

# Install required packages
echo "📦 Installing base packages..."
sudo dnf install -y epel-release
sudo dnf install -y wget unzip curl vim git python3 python3-pip java-11-openjdk-devel ImageMagick
sudo dnf install -y python3-devel gcc  # For building Python packages

# Mount and format data disk if not already done
echo "💾 Setting up data disk..."
if [ ! -d "/dataverse" ]; then
    # Find the data disk (usually /dev/sdc)
    DATA_DISK=$(lsblk -nd --output NAME | grep -v sda | grep -v sdb | head -1)
    if [ ! -z "$DATA_DISK" ]; then
        echo "Found data disk: /dev/${DATA_DISK}"
        if ! blkid /dev/${DATA_DISK}; then
            echo "Formatting data disk..."
            sudo mkfs.ext4 /dev/${DATA_DISK}
        fi
        sudo mkdir -p /dataverse
        sudo mount /dev/${DATA_DISK} /dataverse
        echo "/dev/${DATA_DISK} /dataverse ext4 defaults 0 0" | sudo tee -a /etc/fstab
    fi
fi

# Install PostgreSQL 13
echo "🐘 Installing PostgreSQL 13..."
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql13-server postgresql13-contrib postgresql13-devel  # Added -devel package!

# Initialize PostgreSQL if not already done
if [ ! -d "/var/lib/pgsql/13/data/base" ]; then
    echo "Initializing PostgreSQL..."
    sudo /usr/pgsql-13/bin/postgresql-13-setup initdb
fi

# Start PostgreSQL
sudo systemctl enable postgresql-13
sudo systemctl start postgresql-13

# Configure PostgreSQL
echo "Configuring PostgreSQL..."
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';" || true
sudo sed -i 's/local   all             all                                     peer/local   all             all                                     md5/' /var/lib/pgsql/13/data/pg_hba.conf
sudo sed -i 's/host    all             all             127.0.0.1\/32            ident/host    all             all             127.0.0.1\/32            md5/' /var/lib/pgsql/13/data/pg_hba.conf
sudo systemctl restart postgresql-13

# Install Payara 6
echo "🐟 Installing Payara 6..."
if [ ! -d "/usr/local/payara6" ]; then
    cd /tmp
    wget -q https://s3-eu-west-1.amazonaws.com/payara.fish/Payara+Downloads/6.2024.3/payara-6.2024.3.zip
    sudo unzip -q payara-6.2024.3.zip -d /usr/local/
    sudo mv /usr/local/payara6 /usr/local/payara6 2>/dev/null || true
    rm -f payara-6.2024.3.zip
    
    # Create payara user
    sudo useradd -s /bin/false -d /usr/local/payara6 payara || true
    sudo chown -R payara:payara /usr/local/payara6
fi

# Create Payara systemd service
echo "Creating Payara service..."
sudo tee /etc/systemd/system/payara.service > /dev/null <<'EOF'
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
sudo systemctl start payara || echo "Payara start failed - will retry"

# Install Solr 9.3.0
echo "🔍 Installing Solr 9.3.0..."
if [ ! -d "/opt/solr" ]; then
    cd /tmp
    wget -q https://archive.apache.org/dist/solr/solr/9.3.0/solr-9.3.0.tgz
    tar xzf solr-9.3.0.tgz
    cd solr-9.3.0
    sudo ./bin/install_solr_service.sh ../solr-9.3.0.tgz
    cd /tmp
    rm -rf solr-9.3.0*
fi

sudo systemctl enable solr
sudo systemctl start solr

# Wait for Solr to start
echo "Waiting for Solr to start..."
sleep 15

# Create Solr collection
echo "Creating Solr collection..."
sudo -u solr /opt/solr/bin/solr create_core -c collection1 || echo "Collection might already exist"

# Create directories
echo "📁 Creating Dataverse directories..."
sudo mkdir -p /dataverse/files /dataverse/docroot /dataverse/logs
sudo chown -R payara:payara /dataverse

# Open firewall ports
echo "🔥 Configuring firewall..."
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=8983/tcp
sudo firewall-cmd --reload

# Install Python packages for Dataverse
echo "🐍 Installing Python packages..."
export PATH=/usr/pgsql-13/bin:$PATH
pip3 install --user psycopg2-binary

# Check services
echo ""
echo "==================================="
echo "✅ Checking installed services..."
echo "==================================="
echo "PostgreSQL:" 
sudo systemctl is-active postgresql-13 || echo "NOT RUNNING"
echo "Payara:" 
sudo systemctl is-active payara || echo "NOT RUNNING - This is OK, might take time to start"
echo "Solr:" 
sudo systemctl is-active solr || echo "NOT RUNNING"

# Create summary file
cat > ~/dataverse-prerequisites-status.txt <<EOL
Dataverse Prerequisites Installation Summary
==========================================
PostgreSQL: $(sudo systemctl is-active postgresql-13)
Payara: $(sudo systemctl is-active payara)
Solr: $(sudo systemctl is-active solr)

PostgreSQL password: postgres
Payara admin: http://$(hostname -I | awk '{print $1}'):4848
Solr admin: http://$(hostname -I | awk '{print $1}'):8983

Next steps:
1. cd ~/dvinstall
2. chmod +x install.py
3. ./install.py
EOL

echo ""
echo "✅ Prerequisites installation complete!"
echo "Check ~/dataverse-prerequisites-status.txt for details"
echo ""
echo "Next steps:"
echo "1. cd ~/dvinstall"
echo "2. chmod +x install.py"
echo "3. ./install.py"