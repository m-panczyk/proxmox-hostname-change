#!/bin/bash

###########################################
# Proxmox VE Hostname Change Script
# Compatible with: Proxmox VE 9.x
# Based on: https://pve.proxmox.com/wiki/Renaming_a_PVE_node
#
# WARNING: This script should be run on a standalone node
# or with extreme caution in a cluster environment.
# It's recommended to have no running VMs/containers.
###########################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to validate hostname format
validate_hostname() {
    local hostname=$1
    # Check if hostname is valid (FQDN format: hostname.domain.tld)
    if [[ ! $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Function to check for running VMs and containers
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

# Function to create backup
create_backup() {
    local backup_dir="/root/proxmox-hostname-backup-$(date +%Y%m%d-%H%M%S)"
    print_info "Creating backup in $backup_dir..."
    
    mkdir -p "$backup_dir"
    
    # Backup configuration files
    cp /etc/hostname "$backup_dir/hostname.bak" 2>/dev/null || true
    cp /etc/hosts "$backup_dir/hosts.bak" 2>/dev/null || true
    cp /etc/mailname "$backup_dir/mailname.bak" 2>/dev/null || true
    cp /etc/postfix/main.cf "$backup_dir/main.cf.bak" 2>/dev/null || true
    
    # Backup PVE node configuration if exists
    if [[ -d "/etc/pve/nodes/$OLD_HOSTNAME" ]]; then
        cp -r "/etc/pve/nodes/$OLD_HOSTNAME" "$backup_dir/pve-nodes-backup" 2>/dev/null || true
    fi
    
    # Backup storage configuration
    cp /etc/pve/storage.cfg "$backup_dir/storage.cfg.bak" 2>/dev/null || true
    
    print_success "Backup created at: $backup_dir"
    echo "$backup_dir" > /tmp/proxmox-hostname-backup-location
}

# Function to update system files
update_system_files() {
    print_info "Updating system configuration files..."
    
    # Update /etc/hostname
    echo "$NEW_HOSTNAME" > /etc/hostname
    print_success "Updated /etc/hostname"
    
    # Update /etc/hosts
    if [[ -f /etc/hosts ]]; then
        sed -i.bak "s/\b$OLD_HOSTNAME\b/$NEW_HOSTNAME/g" /etc/hosts
        # Ensure the short name is also updated if using FQDN
        SHORT_OLD=$(echo "$OLD_HOSTNAME" | cut -d'.' -f1)
        SHORT_NEW=$(echo "$NEW_HOSTNAME" | cut -d'.' -f1)
        if [[ "$SHORT_OLD" != "$OLD_HOSTNAME" ]] && [[ "$SHORT_NEW" != "$NEW_HOSTNAME" ]]; then
            sed -i "s/\b$SHORT_OLD\b/$SHORT_NEW/g" /etc/hosts
        fi
        print_success "Updated /etc/hosts"
    fi
    
    # Update /etc/mailname if exists
    if [[ -f /etc/mailname ]]; then
        sed -i.bak "s/$OLD_HOSTNAME/$NEW_HOSTNAME/g" /etc/mailname
        print_success "Updated /etc/mailname"
    fi
    
    # Update /etc/postfix/main.cf if exists
    if [[ -f /etc/postfix/main.cf ]]; then
        sed -i.bak "s/$OLD_HOSTNAME/$NEW_HOSTNAME/g" /etc/postfix/main.cf
        print_success "Updated /etc/postfix/main.cf"
    fi
}

# Function to update storage configuration
update_storage_config() {
    if [[ -f /etc/pve/storage.cfg ]]; then
        print_info "Updating storage configuration..."
        sed -i.bak "s/nodes $OLD_HOSTNAME/nodes $NEW_HOSTNAME/g" /etc/pve/storage.cfg
        print_success "Updated storage configuration"
    fi
}

# Function to copy RRD database files
copy_rrd_files() {
    print_info "Copying RRD database files..."
    
    # Copy pve2-node RRD files
    if [[ -d "/var/lib/rrdcached/db/pve2-node/$OLD_HOSTNAME" ]]; then
        mkdir -p "/var/lib/rrdcached/db/pve2-node/$NEW_HOSTNAME"
        cp -r "/var/lib/rrdcached/db/pve2-node/$OLD_HOSTNAME/"* "/var/lib/rrdcached/db/pve2-node/$NEW_HOSTNAME/" 2>/dev/null || true
        print_success "Copied pve2-node RRD files"
    fi
    
    # Copy pve2-storage RRD files
    if [[ -d "/var/lib/rrdcached/db/pve2-storage/$OLD_HOSTNAME" ]]; then
        mkdir -p "/var/lib/rrdcached/db/pve2-storage/$NEW_HOSTNAME"
        cp -r "/var/lib/rrdcached/db/pve2-storage/$OLD_HOSTNAME/"* "/var/lib/rrdcached/db/pve2-storage/$NEW_HOSTNAME/" 2>/dev/null || true
        print_success "Copied pve2-storage RRD files"
    fi
    
    # Copy pve2-<hostname> RRD files if they exist
    if [[ -d "/var/lib/rrdcached/db/pve2-$OLD_HOSTNAME" ]]; then
        mkdir -p "/var/lib/rrdcached/db/pve2-$NEW_HOSTNAME"
        cp -r "/var/lib/rrdcached/db/pve2-$OLD_HOSTNAME/"* "/var/lib/rrdcached/db/pve2-$NEW_HOSTNAME/" 2>/dev/null || true
        print_success "Copied pve2-hostname RRD files"
    fi
}

# Function to handle VM and container configurations
handle_vm_container_configs() {
    print_info "Handling VM and container configurations..."
    
    # Wait a moment for the new node directory to be created by pmxcfs
    sleep 2
    
    # Check if old node directory exists
    if [[ ! -d "/etc/pve/nodes/$OLD_HOSTNAME" ]]; then
        print_warning "Old node directory /etc/pve/nodes/$OLD_HOSTNAME does not exist"
        return
    fi
    
    # Create new node directories if they don't exist
    mkdir -p "/etc/pve/nodes/$NEW_HOSTNAME/qemu-server" 2>/dev/null || true
    mkdir -p "/etc/pve/nodes/$NEW_HOSTNAME/lxc" 2>/dev/null || true
    
    # Move QEMU/KVM VM configurations
    if [[ -d "/etc/pve/nodes/$OLD_HOSTNAME/qemu-server" ]]; then
        local vm_count=$(ls "/etc/pve/nodes/$OLD_HOSTNAME/qemu-server/"*.conf 2>/dev/null | wc -l)
        if [[ $vm_count -gt 0 ]]; then
            print_info "Moving $vm_count VM configuration(s)..."
            mv "/etc/pve/nodes/$OLD_HOSTNAME/qemu-server/"*.conf "/etc/pve/nodes/$NEW_HOSTNAME/qemu-server/" 2>/dev/null || true
            print_success "Moved VM configurations"
        fi
    fi
    
    # Move LXC container configurations
    if [[ -d "/etc/pve/nodes/$OLD_HOSTNAME/lxc" ]]; then
        local ct_count=$(ls "/etc/pve/nodes/$OLD_HOSTNAME/lxc/"*.conf 2>/dev/null | wc -l)
        if [[ $ct_count -gt 0 ]]; then
            print_info "Moving $ct_count container configuration(s)..."
            mv "/etc/pve/nodes/$OLD_HOSTNAME/lxc/"*.conf "/etc/pve/nodes/$NEW_HOSTNAME/lxc/" 2>/dev/null || true
            print_success "Moved container configurations"
        fi
    fi
}

# Function to cleanup old files
cleanup_old_files() {
    print_info "Cleaning up old configuration files..."
    
    # Remove old RRD directories
    rm -rf "/var/lib/rrdcached/db/pve2-node/$OLD_HOSTNAME" 2>/dev/null || true
    rm -rf "/var/lib/rrdcached/db/pve2-storage/$OLD_HOSTNAME" 2>/dev/null || true
    rm -rf "/var/lib/rrdcached/db/pve2-$OLD_HOSTNAME" 2>/dev/null || true
    
    # Remove old node directory (after ensuring configs are moved)
    if [[ -d "/etc/pve/nodes/$OLD_HOSTNAME" ]]; then
        # Check if directory is empty or only has empty subdirectories
        if [[ -z "$(find /etc/pve/nodes/$OLD_HOSTNAME -type f)" ]]; then
            rm -rf "/etc/pve/nodes/$OLD_HOSTNAME" 2>/dev/null || true
            print_success "Removed old node directory"
        else
            print_warning "Old node directory still contains files. Please verify and remove manually."
        fi
    fi
    
    print_success "Cleanup completed"
}

# Function to verify the changes
verify_changes() {
    print_info "Verifying changes..."
    
    local current_hostname=$(hostname)
    if [[ "$current_hostname" == "$NEW_HOSTNAME" ]]; then
        print_success "Hostname verification: OK"
    else
        print_warning "Hostname verification: Current hostname ($current_hostname) doesn't match expected ($NEW_HOSTNAME)"
    fi
    
    # Check if new node directory exists
    if [[ -d "/etc/pve/nodes/$NEW_HOSTNAME" ]]; then
        print_success "New node directory exists: /etc/pve/nodes/$NEW_HOSTNAME"
    else
        print_warning "New node directory not found. It may be created after reboot."
    fi
    
    # Check /etc/hosts
    if grep -q "$NEW_HOSTNAME" /etc/hosts; then
        print_success "/etc/hosts contains new hostname"
    else
        print_warning "/etc/hosts does not contain new hostname"
    fi
}

# Function to handle cluster configuration
handle_cluster_config() {
    if [[ -f /etc/pve/corosync.conf ]]; then
        print_warning "This node appears to be in a cluster!"
        print_warning "Changing hostname in a cluster is NOT recommended!"
        echo ""
        read -p "Do you want to update corosync.conf? (yes/no): " update_cluster
        if [[ "$update_cluster" == "yes" ]]; then
            print_info "Updating corosync.conf..."
            # Backup corosync.conf
            cp /etc/pve/corosync.conf /etc/pve/corosync.conf.bak
            
            # Update node name in corosync.conf
            sed -i "s/name: $OLD_HOSTNAME/name: $NEW_HOSTNAME/g" /etc/pve/corosync.conf
            
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
    echo "=========================================="
    echo ""
    
    # Check if running as root
    check_root
    
    # Get current hostname
    OLD_HOSTNAME=$(hostname -f)
    print_info "Current hostname: $OLD_HOSTNAME"
    echo ""
    
    # Get new hostname
    read -p "Enter new hostname (FQDN format recommended, e.g., pve.example.com): " NEW_HOSTNAME
    
    # Validate new hostname
    if ! validate_hostname "$NEW_HOSTNAME"; then
        print_error "Invalid hostname format"
        exit 1
    fi
    
    if [[ "$OLD_HOSTNAME" == "$NEW_HOSTNAME" ]]; then
        print_error "New hostname is the same as old hostname"
        exit 1
    fi
    
    echo ""
    print_warning "You are about to change hostname from:"
    echo "  OLD: $OLD_HOSTNAME"
    echo "  NEW: $NEW_HOSTNAME"
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
    
    # Create backup
    create_backup
    
    # Update system files
    update_system_files
    
    # Update storage configuration
    update_storage_config
    
    # Copy RRD files
    copy_rrd_files
    
    # Handle cluster if present
    handle_cluster_config
    
    echo ""
    print_success "Pre-reboot configuration completed!"
    echo ""
    print_warning "The system needs to be rebooted to complete the hostname change."
    print_info "After reboot, VM and container configurations will be moved automatically."
    echo ""
    
    read -p "Do you want to reboot now? (yes/no): " reboot_now
    if [[ "$reboot_now" == "yes" ]]; then
        print_info "System will reboot in 5 seconds..."
        sleep 5
        reboot
    else
        print_info "Please reboot manually when ready: reboot"
        echo ""
        print_info "After reboot, run this script again with '--post-reboot' flag to complete the migration"
        echo "Usage: $0 --post-reboot $OLD_HOSTNAME $NEW_HOSTNAME"
    fi
}

# Post-reboot handling
post_reboot_handler() {
    if [[ -z "$2" ]] || [[ -z "$3" ]]; then
        print_error "Usage: $0 --post-reboot <old_hostname> <new_hostname>"
        exit 1
    fi
    
    OLD_HOSTNAME="$2"
    NEW_HOSTNAME="$3"
    
    echo "=========================================="
    echo "  Post-Reboot Configuration"
    echo "=========================================="
    echo ""
    
    check_root
    
    print_info "Moving VM and container configurations..."
    handle_vm_container_configs
    
    print_info "Running final cleanup..."
    cleanup_old_files
    
    echo ""
    verify_changes
    
    echo ""
    print_success "Hostname change completed!"
    print_info "Old hostname: $OLD_HOSTNAME"
    print_info "New hostname: $NEW_HOSTNAME"
    echo ""
    print_info "Please verify that all VMs and containers are working correctly."
    print_info "You can access the Proxmox web interface at: https://$NEW_HOSTNAME:8006"
    echo ""
    
    # Show backup location
    if [[ -f /tmp/proxmox-hostname-backup-location ]]; then
        local backup_dir=$(cat /tmp/proxmox-hostname-backup-location)
        print_info "Backup files are located at: $backup_dir"
        rm /tmp/proxmox-hostname-backup-location
    fi
}

# Check for post-reboot flag
if [[ "$1" == "--post-reboot" ]]; then
    post_reboot_handler "$@"
else
    main
fi
