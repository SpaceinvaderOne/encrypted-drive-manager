#!/bin/bash
#
# This script runs on system startup (from the 'go' file) to dynamically
# generate and save the LUKS keyfile before the array starts.

# --- Configuration ---
DEFAULT_KEYFILE="/root/keyfile"
DISK_CFG="/boot/config/disk.cfg"

# --- Functions ---

#
# Get Motherboard Serial Number (1st factor used to make key)
# This MUST match the logic in the main management script.
#
get_motherboard_id() {
    dmidecode -s baseboard-serial-number
}

#
# Get the MAC address of the default gateway (2nd factor used to make key)
# This MUST match the logic in the main management script.
#
get_gateway_mac() {
    local interface gateway_ip mac_address
    # Read all default routes into an array
    mapfile -t routes < <(ip route show default | awk '/default/ {print $5 " " $3}')

    if [[ ${#routes[@]} -eq 0 ]]; then
        echo "Error: No default gateway found." >&2
        return 1
    fi

    for route in "${routes[@]}"; do
        interface=$(echo "$route" | awk '{print $1}')
        gateway_ip=$(echo "$route" | awk '{print $2}')
        # Use arping to find the MAC address for the gateway IP on the correct interface
        mac_address=$(timeout 2 arping -c 1 -w 1 -I "$interface" "$gateway_ip" 2>/dev/null | grep "reply from" | awk '{print $5}' | tr -d '[]')
        if [[ -n "$mac_address" ]]; then
            echo "$mac_address"
            return 0 # Success
        fi
    done

    echo "Error: Unable to retrieve MAC address of the default gateway." >&2
    return 1
}

#
# Get the keyfile location if different from default
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

#
# Check if the server array is set to auto start
#
is_auto_start_enabled() {
    # If the config file doesn't exist, assume auto-start is off
    if [[ ! -f "$DISK_CFG" ]]; then
        return 1
    fi
    
    local start_array
    start_array=$(grep '^startArray=' "$DISK_CFG" | awk -F= '{print $2}' | tr -d '\r"')
    if [[ "$start_array" == "yes" ]]; then
        return 0  # Auto-start is enabled
    else
        return 1  # Auto-start is disabled
    fi
}

#
# Makes the LUKS keyfile from the two hardware factors
#
generate_keyfile() {
    local motherboard_id mac_address derived_key keyfile_path="$1"

    echo "Attempting to generate hardware-tied key..."
    motherboard_id=$(get_motherboard_id)
    mac_address=$(get_gateway_mac)

    # Check that both hardware identifiers were successfully retrieved
    if [[ -z "$motherboard_id" || "$motherboard_id" == "unknown" || -z "$mac_address" ]]; then
        echo "Error: Unable to generate hardware-tied key. Missing hardware data."
        exit 1
    fi

    # Generate the key (SHA256 hash of motherboard serial and gateway MAC address)
    derived_key=$(echo -n "${motherboard_id}_${mac_address}" | sha256sum | awk '{print $1}')

    # Write the key so it's ready for Unraid to start the array
    echo -n "$derived_key" > "$keyfile_path"
    echo "Keyfile generated successfully at $keyfile_path"
}

# --- Main Execution ---

# Determine the correct keyfile path
keyfile_path=$(get_keyfile_location)

# Only run if the array is set to auto-start
if is_auto_start_enabled; then
    echo "Auto-start is enabled. Proceeding with keyfile generation."
    # Generate the keyfile using the determined path
    generate_keyfile "$keyfile_path"
else
    echo "Auto-start is disabled. Keyfile generation skipped."
    exit 0
fi
