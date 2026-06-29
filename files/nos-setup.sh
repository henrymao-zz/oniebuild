#!/bin/sh

# NOS first-time setup script, invoked by cloud-init on first boot.

echo "nos-setup: running first-time initialization..."
/usr/sbin/setcap cap_net_raw=ep /usr/bin/ping 2>/dev/null || true
echo "nos-setup: first-time initialization complete"

exit 0
