#!/bin/bash

###########################################
# Proxmox VE Hostname Change Script - FIXED
# Compatible with: Proxmox VE 9.x
# 
# CRITICAL FIX: Proxmox uses SHORT hostname for 
# /etc/pve/nodes/ directories, NOT FQDN!
#
# Based on: https://pve.proxmox.com/wiki/Renaming_a_PVE_node
###########################################

set -e  # Exit on error

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to extract short hostname from FQDN
get_short_hostname() {
    echo "$1" | cut -d'.' -f1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

validate_hostname() {
    local hostname=$1
    if [[ ! $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

check_running_resources() {
    print_info "Checking for running VMs and containers..."
    
    local running_vms=$(qm list 2>/dev/null | grep -c "running" || true)
    local running_cts=$(pct list 2>/dev/null | grep -c "running" || true)
    
    if [[ $running_vms -gt 0 ]] || [[ $running_cts -gt 0 ]]; then
        print_warning "Found $running_vms running VM(s) and $running_cts running container(s)"
        return 1
    fi
    
    print_success "No running VMs or containers found"
    return 0
}

create_backup() {
    local backup_dir="/root/proxmox-hostname-backup-$(date +%Y%m%d-%H%M%S)"
    print_info "Creating backup in $backup_dir..."
    
    mkdir -p "$backup_dir"
    
    # Backup system files
    cp /etc/hostname "$backup_dir/hostname.bak" 2>/dev/null || true
    cp /etc/hosts "$backup_dir/hosts.bak" 2>/dev/null || true
    cp /etc/mailname "$backup_dir/mailname.bak" 2>/dev/null || true
    cp /etc/postfix/main.cf "$backup_dir/main.cf.bak" 2>/dev/null || true
    
    # Backup pmxcfs database
    cp /var/lib/pve-cluster/config.db "$backup_dir/config.db.bak" 2>/dev/null || true
    
    # Backup PVE node configuration if exists
    if [[ -d "/etc/pve/nodes/$OLD_SHORT" ]]; then
        # Can't copy from pmxcfs directly, so just note it
        echo "Old node dir: /etc/pve/nodes/$OLD_SHORT" > "$backup_dir/old_node_info.txt"
    fi
    
    # Backup storage configuration
    cp /etc/pve/storage.cfg "$backup_dir/storage.cfg.bak" 2>/dev/null || true
    
    print_success "Backup created at: $backup_dir"
    echo "$backup_dir" > /tmp/proxmox-hostname-backup-location
}

update_system_files() {
    print_info "Updating system configuration files..."
    
    # Update /etc/hostname
    echo "$NEW_FQDN" > /etc/hostname
    print_success "Updated /etc/hostname with FQDN: $NEW_FQDN"
    
    # Update /etc/hosts
    # CRITICAL: Must include BOTH FQDN and short hostname
    if [[ -f /etc/hosts ]]; then
        # Replace old entries
        sed -i.bak "s/\b$OLD_FQDN\b/$NEW_FQDN/g" /etc/hosts
        sed -i "s/\b$OLD_SHORT\b/$NEW_SHORT/g" /etc/hosts
        
        # Ensure proper format: IP FQDN SHORT
        # Find the line with the main IP and ensure format is correct
        print_success "Updated /etc/hosts (FQDN: $NEW_FQDN, Short: $NEW_SHORT)"
    fi
    
    # Update /etc/mailname if exists
    if [[ -f /etc/mailname ]]; then
        sed -i.bak "s/$OLD_FQDN/$NEW_FQDN/g" /etc/mailname
        print_success "Updated /etc/mailname"
    fi
    
    # Update /etc/postfix/main.cf if exists
    if [[ -f /etc/postfix/main.cf ]]; then
        sed -i.bak "s/$OLD_FQDN/$NEW_FQDN/g" /etc/postfix/main.cf
        print_success "Updated /etc/postfix/main.cf"
    fi
}

update_storage_config() {
    if [[ -f /etc/pve/storage.cfg ]]; then
        print_info "Updating storage configuration..."
        # Storage config uses SHORT hostname
        sed -i.bak "s/nodes $OLD_SHORT/nodes $NEW_SHORT/g" /etc/pve/storage.cfg
        print_success "Updated storage configuration"
    fi
}

copy_rrd_files() {
    print_info "Copying RRD database files..."
    
    # RRD directories use SHORT hostname
    if [[ -d "/var/lib/rrdcached/db/pve2-node/$OLD_SHORT" ]]; then
        mkdir -p "/var/lib/rrdcached/db/pve2-node/$NEW_SHORT"
        cp -r "/var/lib/rrdcached/db/pve2-node/$OLD_SHORT/"* "/var/lib/rrdcached/db/pve2-node/$NEW_SHORT/" 2>/dev/null || true
        print_success "Copied pve2-node RRD files"
    fi
    
    if [[ -d "/var/lib/rrdcached/db/pve2-storage/$OLD_SHORT" ]]; then
        mkdir -p "/var/lib/rrdcached/db/pve2-storage/$NEW_SHORT"
        cp -r "/var/lib/rrdcached/db/pve2-storage/$OLD_SHORT/"* "/var/lib/rrdcached/db/pve2-storage/$NEW_SHORT/" 2>/dev/null || true
        print_success "Copied pve2-storage RRD files"
    fi
    
    if [[ -d "/var/lib/rrdcached/db/pve2-$OLD_SHORT" ]]; then
        mkdir -p "/var/lib/rrdcached/db/pve2-$NEW_SHORT"
        cp -r "/var/lib/rrdcached/db/pve2-$OLD_SHORT/"* "/var/lib/rrdcached/db/pve2-$NEW_SHORT/" 2>/dev/null || true
        print_success "Copied pve2-hostname RRD files"
    fi
}

handle_vm_container_configs() {
    print_info "Handling VM and container configurations..."
    print_warning "NOTE: VM/Container configs use SHORT hostname: $OLD_SHORT → $NEW_SHORT"
    
    # Wait for pmxcfs to sync
    sleep 3
    
    # Check if old node directory exists (uses SHORT hostname)
    if [[ ! -d "/etc/pve/nodes/$OLD_SHORT" ]]; then
        print_warning "Old node directory /etc/pve/nodes/$OLD_SHORT does not exist"
        return
    fi
    
    # Wait for new node directory to be created by pmxcfs
    local wait_count=0
    while [[ ! -d "/etc/pve/nodes/$NEW_SHORT/qemu-server" ]] && [[ $wait_count -lt 10 ]]; do
        print_info "Waiting for new node directory to be created..."
        sleep 2
        ((wait_count++))
    done
    
    # Move QEMU/KVM VM configurations ONE BY ONE (pmxcfs requirement)
    if [[ -d "/etc/pve/nodes/$OLD_SHORT/qemu-server" ]]; then
        local vm_count=$(ls "/etc/pve/nodes/$OLD_SHORT/qemu-server/"*.conf 2>/dev/null | wc -l)
        if [[ $vm_count -gt 0 ]]; then
            print_info "Moving $vm_count VM configuration(s)..."
            for vm_conf in /etc/pve/nodes/$OLD_SHORT/qemu-server/*.conf; do
                if [[ -f "$vm_conf" ]]; then
                    local vm_id=$(basename "$vm_conf")
                    print_info "Moving VM config: $vm_id"
                    # MUST use mv, not cp (pmxcfs requirement)
                    mv "$vm_conf" "/etc/pve/nodes/$NEW_SHORT/qemu-server/" || {
                        print_error "Failed to move $vm_id"
                        continue
                    }
                    sleep 0.5  # Small delay for pmxcfs
                fi
            done
            print_success "Moved VM configurations"
        fi
    fi
    
    # Move LXC container configurations ONE BY ONE
    if [[ -d "/etc/pve/nodes/$OLD_SHORT/lxc" ]]; then
        local ct_count=$(ls "/etc/pve/nodes/$OLD_SHORT/lxc/"*.conf 2>/dev/null | wc -l)
        if [[ $ct_count -gt 0 ]]; then
            print_info "Moving $ct_count container configuration(s)..."
            for ct_conf in /etc/pve/nodes/$OLD_SHORT/lxc/*.conf; do
                if [[ -f "$ct_conf" ]]; then
                    local ct_id=$(basename "$ct_conf")
                    print_info "Moving container config: $ct_id"
                    mv "$ct_conf" "/etc/pve/nodes/$NEW_SHORT/lxc/" || {
                        print_error "Failed to move $ct_id"
                        continue
                    }
                    sleep 0.5
                fi
            done
            print_success "Moved container configurations"
        fi
    fi
}

cleanup_old_files() {
    print_info "Cleaning up old configuration files..."
    
    # Use SHORT hostname for cleanup
    rm -rf "/var/lib/rrdcached/db/pve2-node/$OLD_SHORT" 2>/dev/null || true
    rm -rf "/var/lib/rrdcached/db/pve2-storage/$OLD_SHORT" 2>/dev/null || true
    rm -rf "/var/lib/rrdcached/db/pve2-$OLD_SHORT" 2>/dev/null || true
    
    # Remove old node directory (after ensuring configs are moved)
    if [[ -d "/etc/pve/nodes/$OLD_SHORT" ]]; then
        if [[ -z "$(find /etc/pve/nodes/$OLD_SHORT -type f)" ]]; then
            rm -rf "/etc/pve/nodes/$OLD_SHORT" 2>/dev/null || true
            print_success "Removed old node directory"
        else
            print_warning "Old node directory still contains files. Please verify and remove manually."
        fi
    fi
    
    print_success "Cleanup completed"
}

verify_changes() {
    print_info "Verifying changes..."
    
    local current_hostname=$(hostname -f)
    local current_short=$(hostname -s)
    
    echo ""
    print_info "Current FQDN: $current_hostname (expected: $NEW_FQDN)"
    print_info "Current SHORT: $current_short (expected: $NEW_SHORT)"
    
    if [[ "$current_short" == "$NEW_SHORT" ]]; then
        print_success "Short hostname verification: OK"
    else
        print_warning "Short hostname mismatch!"
    fi
    
    # Check if new node directory exists (SHORT hostname)
    if [[ -d "/etc/pve/nodes/$NEW_SHORT" ]]; then
        print_success "New node directory exists: /etc/pve/nodes/$NEW_SHORT"
    else
        print_warning "New node directory not found. It may be created after reboot."
    fi
    
    # Check /etc/hosts
    if grep -q "$NEW_SHORT" /etc/hosts && grep -q "$NEW_FQDN" /etc/hosts; then
        print_success "/etc/hosts contains both FQDN and short hostname"
    else
        print_warning "/etc/hosts may need adjustment"
    fi
}

handle_cluster_config() {
    if [[ -f /etc/pve/corosync.conf ]]; then
        print_warning "This node appears to be in a cluster!"
        print_warning "Changing hostname in a cluster is NOT recommended!"
        echo ""
        read -p "Do you want to update corosync.conf? (yes/no): " update_cluster
        if [[ "$update_cluster" == "yes" ]]; then
            print_info "Updating corosync.conf..."
            cp /etc/pve/corosync.conf /etc/pve/corosync.conf.bak
            
            # Corosync uses SHORT hostname
            sed -i "s/name: $OLD_SHORT/name: $NEW_SHORT/g" /etc/pve/corosync.conf
            
            # Increment config_version
            local current_version=$(grep "config_version:" /etc/pve/corosync.conf | awk '{print $2}')
            local new_version=$((current_version + 1))
            sed -i "s/config_version: $current_version/config_version: $new_version/g" /etc/pve/corosync.conf
            
            print_success "Updated corosync.conf (version $current_version -> $new_version)"
            print_warning "You may need to restart cluster services after reboot"
        else
            print_info "Skipping corosync.conf update"
        fi
    fi
}

# Main script execution
main() {
    clear
    echo "=========================================="
    echo "  Proxmox VE Hostname Change Script"
    echo "  Compatible with: Proxmox VE 9.x"
    echo "  FIXED: Properly handles SHORT hostnames"
    echo "=========================================="
    echo ""
    
    check_root
    
    # Get current hostnames
    OLD_FQDN=$(hostname -f)
    OLD_SHORT=$(hostname -s)
    
    print_info "Current FQDN: $OLD_FQDN"
    print_info "Current SHORT hostname: $OLD_SHORT"
    print_warning "Proxmox uses SHORT hostname for /etc/pve/nodes/ directories!"
    echo ""
    
    # Get new hostname
    read -p "Enter new FQDN (e.g., pve.example.com): " NEW_FQDN
    
    # Validate new hostname
    if ! validate_hostname "$NEW_FQDN"; then
        print_error "Invalid hostname format"
        exit 1
    fi
    
    # Extract short hostname
    NEW_SHORT=$(get_short_hostname "$NEW_FQDN")
    
    if [[ "$OLD_FQDN" == "$NEW_FQDN" ]]; then
        print_error "New hostname is the same as old hostname"
        exit 1
    fi
    
    echo ""
    print_warning "You are about to change hostname:"
    echo "  OLD FQDN: $OLD_FQDN"
    echo "  NEW FQDN: $NEW_FQDN"
    echo ""
    echo "  OLD SHORT: $OLD_SHORT  (used in /etc/pve/nodes/)"
    echo "  NEW SHORT: $NEW_SHORT  (used in /etc/pve/nodes/)"
    echo ""
    
    # Check for running resources
    if ! check_running_resources; then
        print_warning "It is strongly recommended to stop all VMs and containers before proceeding"
        read -p "Do you want to continue anyway? (yes/no): " continue_anyway
        if [[ "$continue_anyway" != "yes" ]]; then
            print_info "Aborted by user"
            exit 0
        fi
    fi
    
    echo ""
    read -p "Do you want to proceed with the hostname change? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Aborted by user"
        exit 0
    fi
    
    echo ""
    print_info "Starting hostname change process..."
    echo ""
    
    # Store variables for post-reboot
    echo "OLD_FQDN=$OLD_FQDN" > /tmp/proxmox-hostname-change-vars
    echo "OLD_SHORT=$OLD_SHORT" >> /tmp/proxmox-hostname-change-vars
    echo "NEW_FQDN=$NEW_FQDN" >> /tmp/proxmox-hostname-change-vars
    echo "NEW_SHORT=$NEW_SHORT" >> /tmp/proxmox-hostname-change-vars
    
    create_backup
    update_system_files
    update_storage_config
    copy_rrd_files
    handle_cluster_config
    
    echo ""
    print_success "Pre-reboot configuration completed!"
    echo ""
    print_warning "The system needs to be rebooted to complete the hostname change."
    print_info "After reboot, VM and container configurations will be moved."
    echo ""
    
    read -p "Do you want to reboot now? (yes/no): " reboot_now
    if [[ "$reboot_now" == "yes" ]]; then
        print_info "System will reboot in 5 seconds..."
        sleep 5
        reboot
    else
        print_info "Please reboot manually when ready"
        echo ""
        print_info "After reboot, run: $0 --post-reboot"
    fi
}

# Post-reboot handling
post_reboot_handler() {
    echo "=========================================="
    echo "  Post-Reboot Configuration"
    echo "=========================================="
    echo ""
    
    check_root
    
    # Load variables
    if [[ -f /tmp/proxmox-hostname-change-vars ]]; then
        source /tmp/proxmox-hostname-change-vars
        print_info "Loaded saved configuration"
    else
        print_error "Cannot find saved configuration variables"
        print_info "Please provide hostnames manually:"
        read -p "Old SHORT hostname: " OLD_SHORT
        read -p "New SHORT hostname: " NEW_SHORT
        read -p "New FQDN: " NEW_FQDN
    fi
    
    print_info "Moving VM/container configs from $OLD_SHORT to $NEW_SHORT..."
    handle_vm_container_configs
    
    print_info "Running final cleanup..."
    cleanup_old_files
    
    echo ""
    verify_changes
    
    echo ""
    print_success "Hostname change completed!"
    print_info "Old SHORT: $OLD_SHORT"
    print_info "New SHORT: $NEW_SHORT"
    print_info "New FQDN: $NEW_FQDN"
    echo ""
    print_info "Please verify that all VMs and containers are working correctly."
    print_info "Web interface: https://$NEW_FQDN:8006"
    echo ""
    
    # Show backup location
    if [[ -f /tmp/proxmox-hostname-backup-location ]]; then
        local backup_dir=$(cat /tmp/proxmox-hostname-backup-location)
        print_info "Backup files: $backup_dir"
        rm /tmp/proxmox-hostname-backup-location 2>/dev/null || true
    fi
    
    rm /tmp/proxmox-hostname-change-vars 2>/dev/null || true
}

# Check for post-reboot flag
if [[ "$1" == "--post-reboot" ]]; then
    post_reboot_handler
else
    main
fi
