#!/bin/bash
#
# This script runs after the array has started to securely clear the
# contents of the LUKS keyfile, removing it from the disk.

# --- Configuration ---
DEFAULT_KEYFILE="/root/keyfile"
DISK_CFG="/boot/config/disk.cfg"

# --- Functions ---

#
# Get the keyfile location if different from default.
# This MUST match the logic in the autostart script.
#
get_keyfile_location() {
    local keyfile_location
    # Check if the disk.cfg file exists before trying to read it
    if [[ -f "$DISK_CFG" ]]; then
        keyfile_location=$(grep '^luksKeyfile=' "$DISK_CFG" | awk -F= '{print $2}' | tr -d '\r"')
    fi
    
    if [[ -n "$keyfile_location" ]]; then
        echo "Keyfile location found in disk.cfg: $keyfile_location" >&2
    else
        echo "Keyfile location not found in disk.cfg. Falling back to default: $DEFAULT_KEYFILE" >&2
    fi
    # Return the custom path or the default if not found
    echo "${keyfile_location:-$DEFAULT_KEYFILE}"
}

# --- Main Execution ---

# Determine the correct keyfile path
keyfile_path=$(get_keyfile_location)

# Check if the file actually exists before trying to clear it
if [[ -f "$keyfile_path" ]]; then
    # Truncate the file to 0 bytes, effectively clearing its contents
    # This is a secure and standard way to empty a file.
    > "$keyfile_path"
    echo "Keyfile at $keyfile_path has been securely cleared."
else
    echo "No keyfile found at $keyfile_path. Nothing to clear."
fi

exit 0
