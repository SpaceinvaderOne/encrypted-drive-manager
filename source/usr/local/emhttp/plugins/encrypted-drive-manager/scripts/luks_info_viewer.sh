#!/bin/bash
#
# Description: LUKS Encryption Information Viewer
# This script provides detailed analysis of LUKS encrypted drives and slot configurations
# It's designed for read-only inspection and requires passphrase validation
#

# Exit on any error
set -e

# --- Configuration & Variables ---

# Default values for script options
DETAIL_LEVEL="simple"
PASSPHRASE=""
KEY_TYPE=""
KEYFILE_PATH=""

# Temporary working directory
TEMP_WORK_DIR="/tmp/luks_info_viewer_$$"

# --- Functions ---

#
# Get LUKS version for a device
#
get_luks_version() {
    local device="$1"
    cryptsetup luksDump "$device" | grep 'Version:' | awk '{print $2}'
}

#
# Find all LUKS encrypted devices in the system
#
get_luks_devices() {
    # Use the same proven method as the main script
    lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}' | sort
}

#
# Test encryption key (passphrase or keyfile) against a LUKS device
#
test_encryption_key() {
    local device="$1"
    
    if [[ "$KEY_TYPE" == "passphrase" ]]; then
        echo "$PASSPHRASE" | cryptsetup luksOpen --test-passphrase "$device" --stdin 2>/dev/null
    elif [[ "$KEY_TYPE" == "keyfile" ]]; then
        cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE_PATH" "$device" 2>/dev/null
    else
        echo "Error: Unknown key type '$KEY_TYPE'" >&2
        return 1
    fi
}

#
# Validate that a passphrase can unlock a LUKS device (legacy function, kept for backward compatibility)
#
validate_passphrase() {
    local device="$1"
    local passphrase="$2"
    
    # Use cryptsetup luksOpen --test-passphrase to validate
    echo "$passphrase" | cryptsetup luksOpen --test-passphrase "$device" 2>/dev/null
}

#
# Get used slot numbers for a device
#
get_used_slots() {
    local device="$1"
    local dump_output=$(cryptsetup luksDump "$device")
    local luks_version=$(echo "$dump_output" | grep 'Version:' | awk '{print $2}')
    
    if [[ "$luks_version" == "1" ]]; then
        # LUKS1: Look for enabled slots
        echo "$dump_output" | grep 'Key Slot [0-7]: ENABLED' | sed 's/Key Slot \([0-7]\): ENABLED/\1/' | sort -n
    else
        # LUKS2: Look for active keyslots
        echo "$dump_output" | grep -E '^[[:space:]]+[0-9]+: luks2' | sed 's/^[[:space:]]*\([0-9]\+\):.*/\1/' | sort -n
    fi
}

#
# Get slot usage warning level
#
get_slot_warning() {
    local used_count="$1"
    local total_slots=32
    
    if [[ $used_count -ge 29 ]]; then
        echo "CRITICAL: $used_count/$total_slots slots used (90%+ full)"
    elif [[ $used_count -ge 25 ]]; then
        echo "WARNING: $used_count/$total_slots slots used (80%+ full)"
    else
        echo "✅ Healthy: $used_count/$total_slots slots used"
    fi
}

#
# Classify device type (Array, Pool, Standalone)
#
classify_device() {
    local device="$1"
    local device_name=$(basename "$device")
    
    # Check if it's an array device (mdX pattern)
    if [[ "$device_name" =~ ^md[0-9]+p?[0-9]*$ ]]; then
        echo "Array Device"
    # Check if it's likely a pool device (single disk with partition)
    elif [[ "$device_name" =~ ^sd[a-z]+[0-9]+$ ]]; then
        echo "Pool Device"
    else
        echo "Standalone Device"
    fi
}

#
# Get token information for LUKS2 devices
#
get_token_info() {
    local device="$1"
    local slot="$2"
    
    # Only works with LUKS2
    local luks_version=$(get_luks_version "$device")
    if [[ "$luks_version" != "2" ]]; then
        echo "N/A (LUKS1)"
        return
    fi
    
    # First, find which token ID corresponds to this slot by checking luksDump
    local dump_info=$(cryptsetup luksDump "$device" 2>/dev/null)
    
    # Extract tokens section (from "Tokens:" until "Digests:" section)
    local tokens_section=$(echo "$dump_info" | awk '/^Tokens:$/,/^Digests:$/' | grep -v "^Tokens:$" | grep -v "^Digests:$")
    
    # Look for tokens that reference this keyslot
    local token_id=""
    local current_token_id=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*(.*) ]]; then
            current_token_id="${BASH_REMATCH[1]}"
            token_type="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*Keyslot:[[:space:]]*([0-9]+) ]]; then
            keyslot_num="${BASH_REMATCH[1]}"
            if [[ "$keyslot_num" == "$slot" ]]; then
                token_id="$current_token_id"
                break
            fi
        fi
    done <<< "$tokens_section"
    
    # If no token found for this slot
    if [[ -z "$token_id" ]]; then
        echo "Standard slot"
        return
    fi
    
    # Export the token using the found token ID
    local token_json=$(cryptsetup token export --token-id "$token_id" "$device" 2>/dev/null)
    
    if [[ -z "$token_json" ]] || [[ "$token_json" == *"No token with"* ]]; then
        echo "Token present (export failed)"
        return
    fi
    
    # Parse the JSON to check if it's our unraid-derived type
    local token_type=$(echo "$token_json" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)
    
    if [[ "$token_type" == "unraid-derived" ]]; then
        # Extract generation time from metadata
        local gen_time=$(echo "$token_json" | grep -o '"generation_time":"[^"]*"' | cut -d'"' -f4)
        
        if [[ -n "$gen_time" ]]; then
            echo "⭐ Hardware-derived ($gen_time)"
        else
            echo "⭐ Hardware-derived"
        fi
    else
        echo "Token present ($token_type)"
    fi
}

#
# Get detailed slot information for a device
#
get_detailed_slot_info() {
    local device="$1"
    
    echo "    Detailed Slot Analysis:"
    
    local used_slots=($(get_used_slots "$device"))
    
    for slot in "${used_slots[@]}"; do
        local token_info=$(get_token_info "$device" "$slot")
        
        if [[ "$slot" == "0" ]]; then
            echo "    ├─ Slot $slot: Original encryption key"
        else
            echo "    ├─ Slot $slot: $token_info"
        fi
    done
}

#
# Analyze a single device
#
analyze_device() {
    local device="$1"
    local detail_level="$2"
    
    # Basic device info
    local luks_version=$(get_luks_version "$device")
    local device_type=$(classify_device "$device")
    local used_slots=($(get_used_slots "$device"))
    local slot_count=${#used_slots[@]}
    local slot_warning=$(get_slot_warning "$slot_count")
    
    echo "Device: $device ($device_type)"
    echo "    LUKS Version: $luks_version"
    echo "    Slot Usage: $slot_warning"
    
    # Test encryption key
    if test_encryption_key "$device"; then
        if [[ "$KEY_TYPE" == "passphrase" ]]; then
            echo "    Passphrase: ✅ Valid"
        else
            echo "    Keyfile: ✅ Valid"
        fi
        
        if [[ "$detail_level" == "detailed" ]] || [[ "$detail_level" == "very_detailed" ]]; then
            get_detailed_slot_info "$device"
        fi
    else
        if [[ "$KEY_TYPE" == "passphrase" ]]; then
            echo "    Passphrase: Invalid for this device"
        else
            echo "    Keyfile: Invalid for this device"
        fi
    fi
    
    echo ""
}

#
# Group devices by slot configuration pattern  
#
group_devices_by_pattern() {
    local devices=("$@")
    
    declare -A patterns
    declare -A pattern_devices
    
    # First pass: identify patterns
    for device in "${devices[@]}"; do
        if test_encryption_key "$device"; then
            local used_slots=($(get_used_slots "$device"))
            local pattern=$(IFS=','; echo "${used_slots[*]}")
            local luks_version=$(get_luks_version "$device")
            local slot_count=${#used_slots[@]}
            
            local full_pattern="${luks_version}:${pattern}:${slot_count}"
            patterns["$full_pattern"]+="$device "
            pattern_devices["$full_pattern"]="$pattern"
        fi
    done
    
    # Second pass: display grouped results
    for pattern in "${!patterns[@]}"; do
        local devices_in_pattern=(${patterns[$pattern]})
        local slot_pattern="${pattern_devices[$pattern]}"
        
        IFS=':' read -r luks_version slots slot_count <<< "$pattern"
        
        # Classify the group
        local first_device="${devices_in_pattern[0]}"
        local group_type=$(classify_device "$first_device")
        
        if [[ ${#devices_in_pattern[@]} -gt 1 ]]; then
            echo "${group_type}s (${#devices_in_pattern[@]} devices):"
            echo "    Devices: ${devices_in_pattern[*]}"
        else
            echo "${group_type} (1 device):"
            echo "    Device: ${devices_in_pattern[*]}"
        fi
        
        echo "    LUKS Version: $luks_version"
        local slot_warning=$(get_slot_warning "$slot_count")
        echo "    Slot Usage: $slot_warning"
        
        if [[ "$DETAIL_LEVEL" == "detailed" ]]; then
            echo "    Slot Configuration:"
            local slots_array=(${slots//,/ })
            for slot in "${slots_array[@]}"; do
                local token_info=$(get_token_info "$first_device" "$slot")
                
                if [[ "$slot" == "0" ]]; then
                    echo "    ├─ Slot $slot: Original encryption key"
                else
                    echo "    ├─ Slot $slot: $token_info"
                fi
            done
        fi
        
        echo ""
    done
}

#
# Main analysis function
#
analyze_encryption() {
    local detail_level="$1"
    
    echo "=================================================="
    echo "---         LUKS Encryption Analysis          ---"
    echo "=================================================="
    echo ""
    echo "Analysis Mode: $(echo "$detail_level" | tr '[:lower:]' '[:upper:]')"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Get all LUKS devices
    local devices=($(get_luks_devices))
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "No LUKS encrypted devices found on this system."
        return 0
    fi
    
    echo "Found ${#devices[@]} LUKS encrypted device(s)"
    echo ""
    
    if [[ "$detail_level" == "simple" ]]; then
        echo "--- Simple Device List ---"
        for device in "${devices[@]}"; do
            local device_type=$(classify_device "$device")
            if test_encryption_key "$device"; then
                if [[ "$KEY_TYPE" == "passphrase" ]]; then
                    echo "✅ $device ($device_type) - Passphrase valid"
                else
                    echo "✅ $device ($device_type) - Keyfile valid"
                fi
            else
                if [[ "$KEY_TYPE" == "passphrase" ]]; then
                    echo "❌ $device ($device_type) - Passphrase invalid"
                else
                    echo "❌ $device ($device_type) - Keyfile invalid"
                fi
            fi
        done
    elif [[ "$detail_level" == "very_detailed" ]]; then
        echo "--- Very Detailed Analysis (Individual Devices) ---"
        for device in "${devices[@]}"; do
            analyze_device "$device" "$detail_level"
        done
    else
        echo "--- Detailed Analysis with Smart Grouping ---"
        group_devices_by_pattern "${devices[@]}"
    fi
    
    echo ""
    echo "=================================================="
    echo "---            Analysis Complete               ---"
    echo "=================================================="
    
    return 0
}

#
# Parse command line arguments
#
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--detail-level)
                DETAIL_LEVEL="$2"
                shift 2
                ;;
            -p|--passphrase)
                PASSPHRASE="$2"
                KEY_TYPE="passphrase"
                shift 2
                ;;
            -k|--keyfile)
                KEYFILE_PATH="$2"
                KEY_TYPE="keyfile"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
        esac
    done
}

#
# Show usage information
#
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

LUKS Encryption Information Viewer

OPTIONS:
    -d, --detail-level LEVEL   Analysis detail level: simple, detailed, or very_detailed (default: simple)
    -p, --passphrase PASS      LUKS passphrase (can also be provided via LUKS_PASSPHRASE env var)
    -k, --keyfile PATH         LUKS keyfile path (can also be provided via LUKS_KEYFILE env var)
    -h, --help                 Show this help message

DETAIL LEVELS:
    simple                     Simple device listing with key validation
    detailed                   Smart grouping with slot configuration analysis
    very_detailed              Individual device analysis (no smart grouping)

ENVIRONMENT VARIABLES:
    LUKS_PASSPHRASE           LUKS passphrase (alternative to -p option)
    LUKS_KEYFILE              LUKS keyfile path (alternative to -k option)

EXAMPLES:
    $0 -p "mypassphrase"                          # Simple device listing with passphrase
    $0 -k "/path/to/keyfile"                      # Simple device listing with keyfile
    $0 -p "mypassphrase" -d detailed              # Detailed analysis with smart grouping
    $0 -k "/path/to/keyfile" -d very_detailed     # Individual device analysis with keyfile
    LUKS_PASSPHRASE="pass" $0 -d very_detailed   # Using environment variable for passphrase
    LUKS_KEYFILE="/path/key" $0 -d detailed      # Using environment variable for keyfile

EOF
}

#
# Cleanup function
#
cleanup() {
    if [[ -d "$TEMP_WORK_DIR" ]]; then
        rm -rf "$TEMP_WORK_DIR"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# --- Main Script Logic ---

# Parse command line arguments
parse_args "$@"

# Get encryption key from environment if not provided via command line
if [[ -z "$KEY_TYPE" ]]; then
    if [[ -n "$LUKS_PASSPHRASE" ]]; then
        PASSPHRASE="$LUKS_PASSPHRASE"
        KEY_TYPE="passphrase"
    elif [[ -n "$LUKS_KEYFILE" ]]; then
        KEYFILE_PATH="$LUKS_KEYFILE"
        KEY_TYPE="keyfile"
    fi
fi

# Validate that we have an encryption key
if [[ -z "$KEY_TYPE" ]]; then
    echo "Error: No encryption key provided. Use -p/-k option or LUKS_PASSPHRASE/LUKS_KEYFILE environment variable." >&2
    exit 1
fi

# Validate keyfile exists if using keyfile authentication
if [[ "$KEY_TYPE" == "keyfile" ]]; then
    if [[ ! -f "$KEYFILE_PATH" ]]; then
        echo "Error: Keyfile not found at $KEYFILE_PATH" >&2
        exit 1
    fi
    if [[ ! -r "$KEYFILE_PATH" ]]; then
        echo "Error: Keyfile not readable at $KEYFILE_PATH" >&2
        exit 1
    fi
fi

# Create temporary directory if needed
mkdir -p "$TEMP_WORK_DIR"

# Run the analysis
analyze_encryption "$DETAIL_LEVEL"

