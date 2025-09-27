#!/bin/bash
#
# Description: Manages LUKS auto-unlock event scripts by enabling/disabling symlinks
#
# This script handles the enable/disable of auto-unlock functionality by creating
# or removing symlinks in the Unraid event directories.

# --- Configuration ---
PERSISTENT_DIR="/boot/config/plugins/encrypted-drive-manager"
EVENT_STARTING_DIR="/usr/local/emhttp/webGui/event/starting"
EVENT_STARTED_DIR="/usr/local/emhttp/webGui/event/started"
CONFIG_FILE="$PERSISTENT_DIR/config"

# Source scripts
FETCH_KEY_SOURCE="$PERSISTENT_DIR/fetch_key"
DELETE_KEY_SOURCE="$PERSISTENT_DIR/delete_key"

# Event script targets
FETCH_KEY_EVENT="$EVENT_STARTING_DIR/fetch_key"
DELETE_KEY_EVENT="$EVENT_STARTED_DIR/delete_key"

# --- Functions ---

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

debug_log() {
    # Send debug output only to stderr to prevent contamination of function results
    echo "DEBUG: $1" >&2
}

verbose_log() {
    echo "VERBOSE: $1"
}

# Array status detection for accurate LUKS information

# Check if Unraid storage is started (arrays, pools, or both)
check_array_status() {
    debug_log "Checking Unraid storage status..."
    
    # Primary: Check if user shares are mounted (/mnt/user)
    # This works for all configurations: array-only, pools-only, or hybrid
    if mountpoint -q /mnt/user 2>/dev/null; then
        debug_log "User shares mounted at /mnt/user - storage is active"
        echo "true"
        return 0
    fi
    
    # Fallback: Check if user share service (shfs) is running
    # Confirms storage services are active even if mount check fails
    if pgrep -x shfs >/dev/null 2>&1; then
        debug_log "User share service (shfs) is running - storage is active"
        echo "true"
        return 0
    fi
    
    debug_log "No user shares mounted and no shfs process - storage not started"
    echo "false"
    return 1
}

# Hardware key detection functions for smart UX

# Check if hardware keys have been generated before
check_hardware_keys_exist() {
    # Check if we have evidence of previous key generation by looking for hardware-derived entries
    debug_log "Checking for existing hardware keys..."
    
    # Find LUKS devices to check (same method as old working plugin)
    local luks_devices=()
    mapfile -t luks_devices < <(lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}' 2>/dev/null)
    
    debug_log "Found ${#luks_devices[@]} LUKS devices: ${luks_devices[*]}"
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found"
        echo "false"
        return 1
    fi
    
    # Check first device for hardware-derived tokens (optimization: single device check)
    # Since hardware tokens are managed consistently across devices, checking one is sufficient
    local first_device="${luks_devices[0]}"
    debug_log "Checking first device: $first_device"
    
    # Check for multiple patterns that indicate hardware-derived keys
    local dump_output
    dump_output=$(cryptsetup luksDump "$first_device" 2>/dev/null)
    
    if [[ -n "$dump_output" ]]; then
        debug_log "Got luksDump output for $first_device, checking for tokens..."
        
        # Look for different possible patterns (case-insensitive)
        if echo "$dump_output" | grep -qi "unraid-derived\|hardware-derived"; then
            debug_log "Found hardware-derived token via grep on $first_device"
            echo "true"
            return 0
        fi
        
        # Check for JSON token structure
        if echo "$dump_output" | grep -q '"type".*"unraid-derived"'; then
            debug_log "Found unraid-derived JSON token on $first_device"
            echo "true"
            return 0
        fi
        
        # Use the main script's working detection logic
        local luks_script="/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/luks_management.sh"
        if [[ -f "$luks_script" ]]; then
            debug_log "Using main LUKS script to check derived slots on $first_device"
            
            # Source the find_unraid_derived_slots function from the main script
            if source "$luks_script" 2>/dev/null; then
                # Try to use the main script's detection function
                local derived_slots
                derived_slots=$(find_unraid_derived_slots "$first_device" 2>/dev/null)
                if [[ -n "$derived_slots" ]]; then
                    debug_log "Main script found derived slots on $first_device: $derived_slots"
                    echo "true"
                    return 0
                fi
            fi
        fi
        
        debug_log "No hardware-derived tokens found on $first_device"
    else
        debug_log "No luksDump output for $first_device"
    fi
    
    debug_log "No hardware-derived tokens found"
    echo "false"
    return 1
}

# Test if current hardware keys can unlock LUKS devices
test_hardware_keys_work() {
    debug_log "Testing if current hardware keys work..."
    
    # First check if keys exist at all
    if [[ "$(check_hardware_keys_exist)" == "false" ]]; then
        debug_log "No hardware keys exist to test"
        echo "false"
        return 1
    fi
    
    # Use the main LUKS script to test - it has working logic
    local luks_script="/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/luks_management.sh"
    if [[ ! -f "$luks_script" ]]; then
        debug_log "LUKS management script not found"
        echo "false"
        return 1
    fi
    
    # Generate current hardware key using same method as fetch_key.sh
    debug_log "Generating hardware key using same method as fetch_key.sh"
    
    # Get hardware components (EXACT same method as old working plugin)
    local motherboard_id mac_address
    motherboard_id=$(dmidecode -s baseboard-serial-number 2>/dev/null)
    
    # Use original gateway MAC detection method (arping-based)
    local interface gateway_ip
    mapfile -t routes < <(ip route show default | awk '/default/ {print $5 " " $3}')
    
    if [[ ${#routes[@]} -eq 0 ]]; then
        debug_log "No default gateway found"
        mac_address=""
    else
        for route in "${routes[@]}"; do
            interface=$(echo "$route" | awk '{print $1}')
            gateway_ip=$(echo "$route" | awk '{print $2}')
            # Use arping to find the MAC address with timeout (optimization: prevent network delays)
            mac_address=$(timeout 2 arping -c 1 -w 1 -I "$interface" "$gateway_ip" 2>/dev/null | grep "reply from" | awk '{print $5}' | tr -d '[]')
            if [[ -n "$mac_address" ]]; then
                break
            fi
        done
    fi
    
    if [[ -z "$motherboard_id" ]] || [[ "$motherboard_id" == "unknown" ]] || [[ -z "$mac_address" ]]; then
        debug_log "Failed to get hardware components: MB='$motherboard_id' MAC='$mac_address'"
        echo "false"
        return 1
    fi
    
    # Generate the key (same method as fetch_key.sh line 103)
    local current_key
    current_key=$(echo -n "${motherboard_id}_${mac_address}" | sha256sum | awk '{print $1}')
    debug_log "Generated hardware key from MB:${motherboard_id} / MAC:${mac_address}"
    
    # Find LUKS devices to test (same method as old working plugin)
    local luks_devices=()
    mapfile -t luks_devices < <(lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}' 2>/dev/null)
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found"
        echo "false"
        return 1
    fi
    
    # Create temporary file for key testing (same method as old plugin)
    local temp_keyfile="/tmp/luks_test_key_$$"
    debug_log "Creating temporary keyfile: $temp_keyfile"
    
    # Write key to file with no newline (same as old plugin: echo -n)
    echo -n "$current_key" > "$temp_keyfile"
    
    # Test if current key works on first LUKS device (optimization: single device test)
    # Since hardware keys are device-independent, testing one device is sufficient
    local first_device="${luks_devices[0]}"
    debug_log "Testing hardware key on first device: $first_device using file method"
    
    # Test the key using --key-file method (same as old plugin)
    if cryptsetup luksOpen --test-passphrase --key-file="$temp_keyfile" "$first_device" &>/dev/null; then
        debug_log "Hardware key works on $first_device"
        # Clean up temp file
        rm -f "$temp_keyfile"
        echo "true"
        return 0
    fi
    
    # Clean up temp file
    rm -f "$temp_keyfile"
    
    debug_log "Hardware key doesn't work on any device"
    echo "false"
    return 1
}


# Get list of LUKS devices that can be unlocked
get_unlockable_devices() {
    debug_log "Getting list of unlockable LUKS devices..."
    
    # Find all LUKS devices (same method as old working plugin)
    local luks_devices=()
    mapfile -t luks_devices < <(lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}' 2>/dev/null)
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found"
        echo "none"
        return 1
    fi
    
    # Count all LUKS devices (not just ones with existing hardware keys)
    # This represents the total number of devices that can potentially be unlocked
    local unlockable_count=${#luks_devices[@]}
    local device_list=""
    
    for device in "${luks_devices[@]}"; do
        if [[ -n "$device_list" ]]; then
            device_list="$device_list, "
        fi
        device_list="$device_list$(basename "$device")"
    done
    
    if [[ $unlockable_count -gt 0 ]]; then
        echo "$unlockable_count device(s): $device_list"
    else
        echo "none"
    fi
}

# Determine overall system state for smart UX (4-state logic with array detection)
get_system_state() {
    local array_running luks_devices keys_work auto_unlock_enabled
    
    # First check if array is running
    array_running=$(check_array_status)
    
    if [[ "$array_running" == "false" ]]; then
        echo "array_stopped"
        return 0
    fi
    
    # Array is running, now check for LUKS devices (optimization: scan once, reuse result)
    debug_log "Scanning for LUKS devices..."
    mapfile -t luks_devices < <(lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}' 2>/dev/null)
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found - plugin not applicable"
        save_encrypted_disks_flag "false"
        echo "no_encrypted_disks"
        return 0
    fi
    
    debug_log "Found ${#luks_devices[@]} LUKS devices, checking key status..."
    save_encrypted_disks_flag "true"
    
    # LUKS devices exist, now check key status
    keys_work=$(test_hardware_keys_work)
    
    if [[ "$keys_work" == "false" ]]; then
        echo "setup_required"
        return 0
    fi
    
    # Keys work, now check if auto-unlock is enabled
    load_config
    if [[ "$AUTO_UNLOCK_ENABLED" == "true" ]]; then
        echo "ready_enabled"
    else
        echo "ready_disabled"
    fi
}

# Load plugin configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        # Create default config if missing
        echo "AUTO_UNLOCK_ENABLED=false" > "$CONFIG_FILE"
        echo "ENCRYPTED_DISKS_AVAILABLE=true" >> "$CONFIG_FILE"
        AUTO_UNLOCK_ENABLED="false"
        ENCRYPTED_DISKS_AVAILABLE="true"
        debug_log "Created default config file"
    fi
    
    # Set defaults for missing values
    [[ -z "$AUTO_UNLOCK_ENABLED" ]] && AUTO_UNLOCK_ENABLED="false"
    [[ -z "$ENCRYPTED_DISKS_AVAILABLE" ]] && ENCRYPTED_DISKS_AVAILABLE="true"
    
    debug_log "Current auto-unlock status: $AUTO_UNLOCK_ENABLED"
    debug_log "Current encrypted disks status: $ENCRYPTED_DISKS_AVAILABLE"
}

# Save plugin configuration
save_config() {
    local enabled="$1"
    # Load current config to preserve other settings
    load_config
    # Save both settings
    echo "AUTO_UNLOCK_ENABLED=$enabled" > "$CONFIG_FILE"
    echo "ENCRYPTED_DISKS_AVAILABLE=$ENCRYPTED_DISKS_AVAILABLE" >> "$CONFIG_FILE"
    debug_log "Saved config: AUTO_UNLOCK_ENABLED=$enabled, ENCRYPTED_DISKS_AVAILABLE=$ENCRYPTED_DISKS_AVAILABLE"
}

# Save encrypted disks availability flag
save_encrypted_disks_flag() {
    local available="$1"
    # Load current config to preserve other settings
    load_config
    # Save both settings
    echo "AUTO_UNLOCK_ENABLED=$AUTO_UNLOCK_ENABLED" > "$CONFIG_FILE"
    echo "ENCRYPTED_DISKS_AVAILABLE=$available" >> "$CONFIG_FILE"
    ENCRYPTED_DISKS_AVAILABLE="$available"
    debug_log "Saved encrypted disks flag: ENCRYPTED_DISKS_AVAILABLE=$available"
}

# Verify required directories and files exist
verify_prerequisites() {
    # Check event directories
    if [[ ! -d "$EVENT_STARTING_DIR" ]]; then
        mkdir -p "$EVENT_STARTING_DIR"
        debug_log "Created event starting directory"
    fi
    
    if [[ ! -d "$EVENT_STARTED_DIR" ]]; then
        mkdir -p "$EVENT_STARTED_DIR"
        debug_log "Created event started directory"
    fi
    
    # Check source scripts
    if [[ ! -f "$FETCH_KEY_SOURCE" ]]; then
        error_exit "fetch_key source script not found at $FETCH_KEY_SOURCE"
    fi
    
    if [[ ! -f "$DELETE_KEY_SOURCE" ]]; then
        error_exit "delete_key source script not found at $DELETE_KEY_SOURCE"
    fi
    
    # Ensure source scripts are executable
    chmod +x "$FETCH_KEY_SOURCE" "$DELETE_KEY_SOURCE"
    debug_log "Verified source scripts are executable"
}

# Check current auto-unlock status by examining actual files
get_current_status() {
    if [[ -f "$FETCH_KEY_EVENT" ]] && [[ -f "$DELETE_KEY_EVENT" ]]; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Enable auto-unlock by saving config (files created automatically at boot)
enable_auto_unlock() {
    echo "Enabling LUKS auto-unlock..."
    
    verbose_log "Starting enable_auto_unlock process"
    
    # Verify prerequisites exist
    verify_prerequisites
    
    # Save config as enabled
    save_config "true"
    verbose_log "Config saved: AUTO_UNLOCK_ENABLED=true"
    
    # Create event files immediately for current session
    verbose_log "Creating event files for immediate effect..."
    
    # Create event directories if they don't exist
    mkdir -p "$EVENT_STARTING_DIR"
    mkdir -p "$EVENT_STARTED_DIR"
    
    # Copy files to event directories (same method as .plg file)
    if [[ -f "$FETCH_KEY_SOURCE" ]] && cp "$FETCH_KEY_SOURCE" "$FETCH_KEY_EVENT" 2>/dev/null; then
        chmod +x "$FETCH_KEY_EVENT"
        echo "   → Created fetch_key event handler"
        verbose_log "Created fetch_key event file"
    else
        verbose_log "Warning: Could not create fetch_key event file - source: $FETCH_KEY_SOURCE"
        echo "   → Warning: fetch_key source script not found or copy failed"
    fi
    
    if [[ -f "$DELETE_KEY_SOURCE" ]] && cp "$DELETE_KEY_SOURCE" "$DELETE_KEY_EVENT" 2>/dev/null; then
        chmod +x "$DELETE_KEY_EVENT"
        echo "   → Created delete_key event handler"
        verbose_log "Created delete_key event file"
    else
        verbose_log "Warning: Could not create delete_key event file - source: $DELETE_KEY_SOURCE"
        echo "   → Warning: delete_key source script not found or copy failed"
    fi
    
    echo "   → Auto-unlock enabled successfully"
    echo "   → Event files will be recreated automatically on every boot"
    echo "   → Hardware keys will be applied at next boot"
    verbose_log "Enable operation completed successfully"
}

# Disable auto-unlock by saving config and removing current files
disable_auto_unlock() {
    echo "Disabling LUKS auto-unlock..."
    
    # Save config as disabled
    save_config "false"
    verbose_log "Config saved: AUTO_UNLOCK_ENABLED=false"
    
    local changes_made=false
    
    # Remove current session files
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        rm "$FETCH_KEY_EVENT"
        echo "   → Removed fetch_key event handler"
        verbose_log "Removed file: $FETCH_KEY_EVENT"
        changes_made=true
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        rm "$DELETE_KEY_EVENT"
        echo "   → Removed delete_key event handler"
        verbose_log "Removed file: $DELETE_KEY_EVENT"
        changes_made=true
    fi
    
    if [[ "$changes_made" == "true" ]]; then
        echo "   → Auto-unlock disabled successfully"
    else
        echo "   → Auto-unlock was already disabled"
    fi
    
    echo "   → Event files will not be recreated on next boot"
    verbose_log "Disable operation completed successfully"
}

# Get detailed status information
get_status() {
    echo "LUKS Auto-Unlock Status:"
    echo ""
    
    # Load current config
    load_config
    
    echo "Config file setting: $AUTO_UNLOCK_ENABLED"
    
    # Check actual symlink status
    local actual_status=$(get_current_status)
    echo "Event scripts status: $actual_status"
    
    # Check individual files
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        echo "fetch_key event: enabled (file present)"
    else
        echo "fetch_key event: disabled"
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        echo "delete_key event: enabled (file present)"
    else
        echo "delete_key event: disabled"
    fi
    
    # Check for inconsistencies
    if [[ "$AUTO_UNLOCK_ENABLED" != "$actual_status" ]]; then
        echo ""
        echo "WARNING: Config setting and actual status don't match!"
        echo "This may indicate a configuration issue."
    fi
}

# Main execution
main() {
    local operation="$1"
    
    case "$operation" in
        "enable")
            enable_auto_unlock
            ;;
        "disable")
            disable_auto_unlock
            ;;
        "status")
            get_status
            ;;
        "get_status")
            # Simple status for programmatic use
            get_current_status
            ;;
        "system_state")
            # Get overall system state for smart UX
            get_system_state
            ;;
        "unlockable_devices")
            # Get list of unlockable LUKS devices
            get_unlockable_devices
            ;;
        "check_keys_exist")
            # Check if hardware keys exist
            check_hardware_keys_exist
            ;;
        "test_keys_work")
            # Test if hardware keys work
            test_hardware_keys_work
            ;;
        "check_array_status")
            # Check if Unraid array is running
            check_array_status
            ;;
        *)
            echo "Usage: $0 {enable|disable|status|get_status|system_state|unlockable_devices|check_keys_exist|test_keys_work|check_array_status}"
            echo ""
            echo "Commands:"
            echo "  enable              - Enable LUKS auto-unlock"
            echo "  disable             - Disable LUKS auto-unlock"
            echo "  status              - Show detailed auto-unlock status"
            echo "  get_status          - Get simple status (enabled/disabled)"
            echo "  system_state        - Get system state (array_stopped/setup_required/ready_disabled/ready_enabled)"
            echo "  unlockable_devices  - Get list of unlockable LUKS devices"
            echo "  check_keys_exist    - Check if hardware keys have been generated"
            echo "  test_keys_work      - Test if hardware keys work with current system"
            echo "  check_array_status  - Check if Unraid array is running"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"