#!/bin/bash
# Remove leftover official Wacom LaunchAgents/Daemons (not used by native IntuosDriver).
set -euo pipefail

echo "Unloading Wacom launch items..."
UID_NUM="$(id -u)"

sudo launchctl bootout "gui/${UID_NUM}" /Library/LaunchAgents/com.wacom.DataStoreMgr.plist 2>/dev/null || true
sudo launchctl bootout "gui/${UID_NUM}" /Library/LaunchAgents/com.wacom.IOManager.plist 2>/dev/null || true
sudo launchctl bootout "gui/${UID_NUM}" /Library/LaunchAgents/com.wacom.wacomtablet.plist 2>/dev/null || true
sudo launchctl bootout system /Library/LaunchDaemons/com.wacom.displayhelper.plist 2>/dev/null || true
sudo launchctl bootout system /Library/LaunchDaemons/com.wacom.UpdateHelper.plist 2>/dev/null || true

echo "Stopping any leftover Wacom processes..."
sudo killall WacomTabletDriver TabletDriver WacomTouchDriver \
  com.wacom.IOManager com.wacom.DataStoreMgr com.wacom.UpdateHelper 2>/dev/null || true

echo "Removing plists..."
sudo rm -f \
  /Library/LaunchAgents/com.wacom.DataStoreMgr.plist \
  /Library/LaunchAgents/com.wacom.IOManager.plist \
  /Library/LaunchAgents/com.wacom.wacomtablet.plist \
  /Library/LaunchDaemons/com.wacom.displayhelper.plist \
  /Library/LaunchDaemons/com.wacom.UpdateHelper.plist

echo "Forgetting installer receipt (if present)..."
sudo pkgutil --forget com.wacom.TabletInstaller 2>/dev/null || true

echo
echo "=== Verify ==="
if ls /Library/LaunchAgents/com.wacom* /Library/LaunchDaemons/com.wacom* 2>/dev/null; then
  echo "WARNING: some com.wacom plists still exist"
  exit 1
else
  echo "No com.wacom LaunchAgents/Daemons left."
fi

if pgrep -lf -i wacom >/dev/null 2>&1; then
  echo "WARNING: wacom processes still running:"
  pgrep -lf -i wacom
  exit 1
else
  echo "No wacom processes."
fi

if pkgutil --pkgs 2>/dev/null | grep -qi wacom; then
  echo "Remaining pkg receipts:"
  pkgutil --pkgs | grep -i wacom
else
  echo "No wacom pkg receipts."
fi

echo "Done."
