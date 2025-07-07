# Manage-DataverseVM.ps1
# Management script for Dataverse VM

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Start','Stop','Status','Restart','GetIP','Costs','Delete','Backup')]
    [string]$Action,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "dataverse-nonprod-rg",
    
    [Parameter(Mandatory=$false)]
    [string]$VMName = "dataverse-dev-vm"
)

# Ensure Azure connection
if (-not (Get-AzContext)) {
    Write-Host "Not connected to Azure. Connecting..." -ForegroundColor Yellow
    Connect-AzAccount
}

switch ($Action) {
    'Start' {
        Write-Host "Starting VM: $VMName" -ForegroundColor Green
        Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        
        # Wait for public IP
        Start-Sleep -Seconds 30
        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name "$VMName-pip" -ErrorAction SilentlyContinue
        if ($pip.IpAddress) {
            Write-Host "VM started. Public IP: $($pip.IpAddress)" -ForegroundColor Green
            Write-Host "Dataverse URL: http://$($pip.IpAddress):8080" -ForegroundColor Cyan
        }
    }
    
    'Stop' {
        Write-Host "Stopping VM: $VMName" -ForegroundColor Yellow
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
        Write-Host "VM stopped. No charges for compute while stopped!" -ForegroundColor Green
    }
    
    'Status' {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
        $status = $vm.Statuses | Where-Object {$_.Code -like "PowerState/*"} | Select-Object -ExpandProperty DisplayStatus
        
        Write-Host "VM Status: $status" -ForegroundColor Cyan
        
        if ($status -eq "VM running") {
            $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name "$VMName-pip" -ErrorAction SilentlyContinue
            if ($pip.IpAddress) {
                Write-Host "Public IP: $($pip.IpAddress)" -ForegroundColor Green
                
                # Check if SSH key exists
                $sshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
                if (-not (Test-Path $sshKeyPath)) {
                    $sshKeyPath = "$env:USERPROFILE\.ssh\id_rsa"
                }
                
                if (Test-Path $sshKeyPath) {
                    Write-Host "SSH: ssh azureuser@$($pip.IpAddress)" -ForegroundColor Yellow
                    Write-Host "Using SSH key: $sshKeyPath" -ForegroundColor Green
                } else {
                    Write-Host "SSH: ssh azureuser@$($pip.IpAddress)" -ForegroundColor Yellow
                    Write-Host "Note: Using password authentication (consider setting up SSH keys)" -ForegroundColor Yellow
                }
                
                Write-Host "Dataverse URL: http://$($pip.IpAddress):8080" -ForegroundColor Yellow
                
                # Check if services are responding
                try {
                    $response = Invoke-WebRequest -Uri "http://$($pip.IpAddress):8080" -TimeoutSec 5 -ErrorAction SilentlyContinue
                    if ($response.StatusCode -eq 200) {
                        Write-Host "Dataverse is responding!" -ForegroundColor Green
                    }
                } catch {
                    Write-Host "Dataverse not responding yet (may still be starting)" -ForegroundColor Yellow
                }
            }
        }
        
        # Show auto-shutdown status
        $schedule = Get-AzResource -ResourceId "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$VMName" -ErrorAction SilentlyContinue
        if ($schedule) {
            $shutdownTime = $schedule.Properties.dailyRecurrence.time
            $timeZone = $schedule.Properties.timeZoneId
            Write-Host "Auto-shutdown: $($schedule.Properties.status) at $shutdownTime $timeZone" -ForegroundColor Cyan
        }
    }
    
    'Restart' {
        Write-Host "Restarting VM: $VMName" -ForegroundColor Yellow
        Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        Write-Host "VM restarted successfully" -ForegroundColor Green
    }
    
    'GetIP' {
        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name "$VMName-pip" -ErrorAction SilentlyContinue
        if ($pip.IpAddress) {
            Write-Host "Public IP: $($pip.IpAddress)" -ForegroundColor Green
            
            # Show SSH command
            Write-Host "SSH Command: ssh azureuser@$($pip.IpAddress)" -ForegroundColor Yellow
            
            # Copy to clipboard if possible
            if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
                $pip.IpAddress | Set-Clipboard
                Write-Host "IP address copied to clipboard!" -ForegroundColor Cyan
            }
            
            # Check for SSH key
            if (Test-Path "$env:USERPROFILE\.ssh\id_ed25519") {
                Write-Host "✓ SSH key authentication available" -ForegroundColor Green
            }
        } else {
            Write-Host "No IP address assigned. Is the VM running?" -ForegroundColor Yellow
        }
    }
    
    'Costs' {
        Write-Host "Calculating costs for resource group: $ResourceGroupName" -ForegroundColor Cyan
        
        # Get current month costs
        $startDate = (Get-Date).ToString("yyyy-MM-01")
        $endDate = (Get-Date).ToString("yyyy-MM-dd")
        
        try {
            $costs = Get-AzConsumptionUsageDetail -StartDate $startDate -EndDate $endDate | 
                Where-Object {$_.ResourceGroup -eq $ResourceGroupName} |
                Measure-Object -Property PretaxCost -Sum
            
            Write-Host "Current month costs (up to today): €$([math]::Round($costs.Sum, 2))" -ForegroundColor Green
            
            # Estimate full month
            $daysInMonth = [DateTime]::DaysInMonth((Get-Date).Year, (Get-Date).Month)
            $daysPassed = (Get-Date).Day
            $estimatedMonthly = ($costs.Sum / $daysPassed) * $daysInMonth
            Write-Host "Estimated full month: €$([math]::Round($estimatedMonthly, 2))" -ForegroundColor Yellow
            
        } catch {
            Write-Host "Unable to retrieve cost data. This requires Cost Management Reader role." -ForegroundColor Yellow
        }
        
        # Show resource costs breakdown
        Write-Host "`nResource breakdown:" -ForegroundColor Cyan
        $resources = Get-AzResource -ResourceGroupName $ResourceGroupName
        foreach ($resource in $resources) {
            Write-Host "  - $($resource.Name) ($($resource.ResourceType))" -ForegroundColor White
        }
    }
    
    'Delete' {
        Write-Host "WARNING: This will delete the entire resource group and all resources!" -ForegroundColor Red
        $confirm = Read-Host "Type 'DELETE' to confirm deletion of $ResourceGroupName"
        
        if ($confirm -eq 'DELETE') {
            Write-Host "Deleting resource group: $ResourceGroupName" -ForegroundColor Red
            Remove-AzResourceGroup -Name $ResourceGroupName -Force
            Write-Host "Resource group deleted. All resources removed." -ForegroundColor Green
        } else {
            Write-Host "Deletion cancelled." -ForegroundColor Yellow
        }
    }
    
    'Backup' {
        Write-Host "Creating snapshot of data disk..." -ForegroundColor Cyan
        
        # Get the data disk
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        $dataDisk = $vm.StorageProfile.DataDisks | Where-Object {$_.Lun -eq 0}
        
        if ($dataDisk) {
            $snapshotName = "$VMName-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            $snapshotConfig = New-AzSnapshotConfig -SourceResourceId $dataDisk.ManagedDisk.Id -Location $vm.Location -CreateOption Copy
            
            $snapshot = New-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshotConfig
            Write-Host "Snapshot created: $snapshotName" -ForegroundColor Green
            
            # List all snapshots
            Write-Host "`nExisting snapshots:" -ForegroundColor Cyan
            Get-AzSnapshot -ResourceGroupName $ResourceGroupName | ForEach-Object {
                Write-Host "  - $($_.Name) (Created: $($_.TimeCreated))" -ForegroundColor White
            }
        } else {
            Write-Host "No data disk found to backup" -ForegroundColor Yellow
        }
    }
}

# Show quick tips
Write-Host "`n💡 Quick Tips:" -ForegroundColor Cyan
Write-Host "  - Stop VM when not in use to save costs" -ForegroundColor White
Write-Host "  - Auto-shutdown is configured for 19:00 CET" -ForegroundColor White
Write-Host "  - Use Spot VMs for up to 90% savings" -ForegroundColor White
Write-Host "  - Monitor costs regularly with: .\Manage-DataverseVM.ps1 -Action Costs" -ForegroundColor White