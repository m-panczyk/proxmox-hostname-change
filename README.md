# Proxmox VE Hostname Change Script

A comprehensive bash script for safely changing the hostname of a Proxmox VE 9.x node, with automatic handling of VM and container configurations.

## ⚠️ Important Warnings

1. **This script is designed for Proxmox VE 9.x** - compatibility with other versions is not guaranteed
2. **Stop all VMs and containers before running** - the official Proxmox documentation recommends performing this operation on an empty node
3. **Not recommended for clustered nodes** - changing hostname in a cluster can cause issues
4. **Always create backups** - the script creates automatic backups, but additional backups are recommended
5. **Test in a non-production environment first**

## 🔍 What This Script Does

The script automates the official Proxmox hostname change process as documented at:
https://pve.proxmox.com/wiki/Renaming_a_PVE_node

### Changes Made:

1. **System Configuration:**
   - Updates `/etc/hostname`
   - Updates `/etc/hosts` (both FQDN and short name)
   - Updates `/etc/mailname` (if exists)
   - Updates `/etc/postfix/main.cf` (if exists)

2. **Proxmox Configuration:**
   - Updates `/etc/pve/storage.cfg` to reference new hostname
   - Copies RRD database files from old to new hostname directories:
     - `/var/lib/rrdcached/db/pve2-node/`
     - `/var/lib/rrdcached/db/pve2-storage/`
     - `/var/lib/rrdcached/db/pve2-<hostname>/`

3. **VM/Container Configuration:**
   - Moves QEMU/KVM VM configurations from `/etc/pve/nodes/<old>/qemu-server/` to new location
   - Moves LXC container configurations from `/etc/pve/nodes/<old>/lxc/` to new location

4. **Cluster Handling (optional):**
   - Can update `/etc/pve/corosync.conf` if node is in a cluster
   - Increments config_version appropriately

## 📋 Prerequisites

- Proxmox VE 9.x installed
- Root access
- All VMs and containers stopped (strongly recommended)
- Not part of a cluster (or understand the risks)

## 🚀 Usage

### Method 1: Interactive Mode (Recommended)

```bash
# Download the script
wget https://raw.githubusercontent.com/m-panczyk/proxmox-hostname-change/refs/heads/main/proxmox-hostname-change.sh

# Make it executable
chmod +x proxmox-hostname-change.sh

# Run the script
./proxmox-hostname-change.sh
```

The script will:
1. Display current hostname
2. Prompt for new hostname
3. Check for running VMs/containers
4. Create automatic backup
5. Update all configuration files
6. Prompt for reboot

### Method 2: Two-Step Process

If you prefer not to reboot immediately:

**Step 1: Pre-reboot configuration**
```bash
./proxmox-hostname-change.sh
# Answer "no" when prompted to reboot
```

**Step 2: After manual reboot**
```bash
./proxmox-hostname-change.sh --post-reboot <old_hostname> <new_hostname>
```

Example:
```bash
./proxmox-hostname-change.sh --post-reboot pve1.old.local pve1.new.local
```

## 📁 Backup Location

The script creates automatic backups in:
```
/root/proxmox-hostname-backup-YYYYMMDD-HHMMSS/
```

Backed up files include:
- `/etc/hostname`
- `/etc/hosts`
- `/etc/mailname`
- `/etc/postfix/main.cf`
- `/etc/pve/storage.cfg`
- `/etc/pve/nodes/<old_hostname>/` (entire directory)

## ✅ Verification Steps

After running the script and rebooting:

1. **Check hostname:**
   ```bash
   hostname -f
   ```

2. **Check web interface:**
   ```bash
   systemctl status pveproxy
   systemctl status pvedaemon
   ```

3. **Verify node in web UI:**
   - Access https://your-new-hostname:8006
   - Check that node appears with new name
   - Verify no old node appears

4. **Check VMs and containers:**
   ```bash
   qm list
   pct list
   ```

5. **Verify configurations moved:**
   ```bash
   ls /etc/pve/nodes/
   # Should only show new hostname
   ```

6. **Check for errors:**
   ```bash
   journalctl -xe | grep -i error
   systemctl status pve-cluster
   ```

## 🔧 Troubleshooting

### Issue: Web interface shows "Connection Failed"

**Solution:**
```bash
# Check if hostname resolution is correct
grep $(hostname) /etc/hosts

# Ensure both FQDN and short name are present
# Example: 192.168.1.100 pve1.domain.com pve1

# Restart services
systemctl restart pveproxy
systemctl restart pvedaemon
systemctl restart pve-cluster
```

### Issue: Old hostname still appears in web UI

**Solution:**
```bash
# Clear browser cache completely
# Wait 5-10 minutes for cluster filesystem to sync
# Check if old node directory was removed
ls /etc/pve/nodes/

# If old directory still exists and is empty:
rm -rf /etc/pve/nodes/<old_hostname>
```

### Issue: VMs or containers don't appear

**Solution:**
```bash
# Check if configs exist in new location
ls /etc/pve/nodes/<new_hostname>/qemu-server/
ls /etc/pve/nodes/<new_hostname>/lxc/

# If configs are in old location, move them manually:
mv /etc/pve/nodes/<old>/qemu-server/*.conf /etc/pve/nodes/<new>/qemu-server/
mv /etc/pve/nodes/<old>/lxc/*.conf /etc/pve/nodes/<new>/lxc/
```

### Issue: SSL certificate errors

**Solution:**
```bash
# Regenerate SSL certificates
pvecm updatecerts
systemctl restart pveproxy
```

## 🔐 Security Considerations

1. The script requires root privileges
2. Creates backups with sensitive configuration data
3. Modifies critical system files
4. SSL certificates are tied to hostname (may need regeneration)

## 📚 Reference Documentation

- [Official Proxmox Wiki - Renaming a PVE Node](https://pve.proxmox.com/wiki/Renaming_a_PVE_node)
- [Proxmox VE Administration Guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.html)
- [Proxmox Forum Discussions on Hostname Changes](https://forum.proxmox.com/tags/hostname/)

## 🐛 Known Limitations

1. **Cluster Support:** While the script can update corosync.conf, changing hostnames in a cluster is generally not recommended
2. **HA Groups:** May require manual reconfiguration after hostname change
3. **External References:** Any external systems referencing the old hostname will need manual updates
4. **Backup Jobs:** Backup job configurations may need to be updated manually

## 🆘 Recovery

If something goes wrong:

1. **Revert hostname immediately:**
   ```bash
   OLD_HOSTNAME="your-old-hostname.domain"
   echo "$OLD_HOSTNAME" > /etc/hostname
   # Edit /etc/hosts manually to restore old hostname
   reboot
   ```

2. **Restore from backup:**
   ```bash
   # Find your backup directory
   ls /root/proxmox-hostname-backup-*
   
   # Restore files
   BACKUP_DIR="/root/proxmox-hostname-backup-YYYYMMDD-HHMMSS"
   cp $BACKUP_DIR/hostname.bak /etc/hostname
   cp $BACKUP_DIR/hosts.bak /etc/hosts
   cp $BACKUP_DIR/mailname.bak /etc/mailname 2>/dev/null || true
   cp $BACKUP_DIR/main.cf.bak /etc/postfix/main.cf 2>/dev/null || true
   cp $BACKUP_DIR/storage.cfg.bak /etc/pve/storage.cfg 2>/dev/null || true
   
   reboot
   ```

## 📝 Example Output

```
==========================================
  Proxmox VE Hostname Change Script
  Compatible with: Proxmox VE 9.x
==========================================

[INFO] Current hostname: pve1.old.local

Enter new hostname (FQDN format recommended, e.g., pve.example.com): pve1.new.local

[WARNING] You are about to change hostname from:
  OLD: pve1.old.local
  NEW: pve1.new.local

[INFO] Checking for running VMs and containers...
[SUCCESS] No running VMs or containers found

Do you want to proceed with the hostname change? (yes/no): yes

[INFO] Starting hostname change process...

[INFO] Creating backup in /root/proxmox-hostname-backup-20241015-143022...
[SUCCESS] Backup created at: /root/proxmox-hostname-backup-20241015-143022
[INFO] Updating system configuration files...
[SUCCESS] Updated /etc/hostname
[SUCCESS] Updated /etc/hosts
[SUCCESS] Updated /etc/mailname
[INFO] Updating storage configuration...
[SUCCESS] Updated storage configuration
[INFO] Copying RRD database files...
[SUCCESS] Copied pve2-node RRD files
[SUCCESS] Copied pve2-storage RRD files

[SUCCESS] Pre-reboot configuration completed!

[WARNING] The system needs to be rebooted to complete the hostname change.
[INFO] After reboot, VM and container configurations will be moved automatically.

Do you want to reboot now? (yes/no): 
```

## 🤝 Contributing

Contributions are welcome! Please:
1. Test thoroughly in a lab environment
2. Follow bash best practices
3. Update documentation for any changes

## 📄 License

This script is provided as-is without warranty. Use at your own risk.

## ⚠️ Disclaimer

This script is based on official Proxmox documentation but is not officially supported by Proxmox Server Solutions GmbH. Always refer to the official documentation and test in a non-production environment first.

## 🔗 Related Resources

- **Existing Tools Found:**
  - [badsmoke/proxmox-auto-hostname](https://github.com/badsmoke/proxmox-auto-hostname) - Automatically sets VM hostname to match VM name
  - Note: No comprehensive official tool was found for node hostname changes in Proxmox 9

- **Community Discussions:**
  - Multiple forum threads discuss hostname changes but no widely-adopted automated solution exists
  - Manual process is still the recommended approach per official documentation
