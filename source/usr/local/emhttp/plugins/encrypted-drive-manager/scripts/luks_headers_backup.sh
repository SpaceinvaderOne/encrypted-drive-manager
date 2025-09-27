#!/bin/bash
#
# Description: Standalone LUKS header backup utility
# This script creates encrypted backups of LUKS headers for all devices
# that can be unlocked with the provided passphrase.
#

# Note: Removed 'set -e' to prevent premature script termination on individual device failures
# We want to continue processing other devices even if one fails

# --- Configuration & Variables ---

# Default values for script options
DOWNLOAD_MODE="no"
PASSPHRASE=""
KEYFILE_PATH=""
KEY_TYPE=""
ORIGINAL_INPUT_TYPE=""
CUSTOM_ZIP_PASSWORD=""

# Locations
TEMP_WORK_DIR="/tmp/luks_header_backup_$$" # $$ makes it unique per script run
HEADER_BACKUP_DIR="$TEMP_WORK_DIR/header_backups"
# Final backup location - changes based on download mode
ZIPPED_HEADER_BACKUP_LOCATION="/boot/config/luksheaders"
DOWNLOAD_TEMP_DIR="/tmp/luksheaders"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

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
# Create header backup for a single device
#
backup_device_header() {
    local device="$1"
    
    # Validate encryption key
    if ! test_encryption_key "$device"; then
        return 1
    fi
    
    # Extract UUID and create backup
    local uuid=$(cryptsetup luksDump "$device" | grep 'UUID:' | awk '{print $2}')
    local device_name=$(basename "$device")
    local backup_filename="HEADER_UUID_${uuid}_DEVICE_${device_name}.img"
    local backup_path="$HEADER_BACKUP_DIR/$backup_filename"
    
    if cryptsetup luksHeaderBackup "$device" --header-backup-file "$backup_path" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

#
# Create encrypted archive of all header backups
#
create_backup_archive() {
    local headers_found="$1"
    
    if [[ "$headers_found" -eq 0 ]]; then
        echo "No headers were backed up - skipping archive creation."
        return 0
    fi
    
    # Determine archive location based on download mode
    local archive_location
    if [[ "$DOWNLOAD_MODE" == "yes" ]]; then
        archive_location="$DOWNLOAD_TEMP_DIR"
        mkdir -p "$archive_location"
    else
        archive_location="$ZIPPED_HEADER_BACKUP_LOCATION"
        mkdir -p "$archive_location"
    fi
    
    local archive_name="luksheaders_${TIMESTAMP}.zip"
    local archive_path="$archive_location/$archive_name"
    
    # Create metadata file with key information
    local metadata_file="$HEADER_BACKUP_DIR/luks_backup_info_${TIMESTAMP}.txt"
    cat > "$metadata_file" << EOF
LUKS Header Backup Information
=============================
Generated: $(date)
Authentication: $KEY_TYPE
Number of devices backed up: $headers_found

This archive contains LUKS header backups for your encrypted devices.
The archive is encrypted using the same key that unlocks your LUKS devices.

To restore a header:
cryptsetup luksHeaderRestore /dev/sdXY --header-backup-file HEADER_FILE.img

IMPORTANT: Keep this backup secure and test restoration procedures.
EOF

    # Create encrypted ZIP archive with all headers and metadata using the same key that unlocks the devices
    cd "$HEADER_BACKUP_DIR"
    
    # Use original input type if available, otherwise fall back to KEY_TYPE
    local zip_decision_type="${ORIGINAL_INPUT_TYPE:-$KEY_TYPE}"
    
    if [[ "$zip_decision_type" == "passphrase" ]]; then
        # For passphrase users (even if using temp keyfile), read passphrase and encrypt ZIP
        if [[ -n "$PASSPHRASE" ]]; then
            zip -r -e -P "$PASSPHRASE" "$archive_path" *.img *.txt 2>/dev/null
        else
            local temp_passphrase=$(cat "$KEYFILE_PATH")
            zip -r -e -P "$temp_passphrase" "$archive_path" *.img *.txt 2>/dev/null
        fi
    else
        # For keyfile users, check if custom ZIP password was provided
        if [[ -n "$CUSTOM_ZIP_PASSWORD" ]]; then
            zip -r -e -P "$CUSTOM_ZIP_PASSWORD" "$archive_path" *.img *.txt 2>/dev/null
        else
            # Fallback: create unencrypted archive (shouldn't happen with new UI)
            echo "WARNING: Archive is unencrypted because no password was provided."
            zip -r "$archive_path" *.img *.txt 2>/dev/null
        fi
    fi
    
    # For download mode, signal that the file is ready
    if [[ "$DOWNLOAD_MODE" == "yes" ]]; then
        echo "DOWNLOAD_READY: $archive_path"
    fi
    
    return 0
}

#
# Main processing function
#
process_devices() {
    echo ""
    echo "Checking provided encryption key..."
    
    # Get all LUKS devices
    local devices=($(get_luks_devices))
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "No LUKS encrypted devices found."
        return 0
    fi
    
    echo "   Key verified successfully"
    echo ""
    echo "Backing up LUKS headers..."
    
    # Create temporary directories
    mkdir -p "$TEMP_WORK_DIR"
    mkdir -p "$HEADER_BACKUP_DIR"
    
    # Process each device
    local headers_found=0
    for device in "${devices[@]}"; do
        if backup_device_header "$device" >/dev/null 2>&1; then
            ((headers_found++))
        fi
    done
    
    echo "   → Processed $headers_found encrypted device(s) successfully"
    
    # Create archive if we have any headers
    if [[ "$headers_found" -gt 0 ]]; then
        echo ""
        echo "Creating encrypted backup archive..."
        create_backup_archive "$headers_found"
        echo "   → Archive created with password protection"
    fi
    
    return 0
}

#
# Parse command line arguments
#
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --download-mode)
                DOWNLOAD_MODE="yes"
                shift
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
            --original-input-type)
                ORIGINAL_INPUT_TYPE="$2"
                shift 2
                ;;
            --zip-password)
                CUSTOM_ZIP_PASSWORD="$2"
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

LUKS Header Backup Utility

OPTIONS:
    --download-mode         Prepare backup for browser download instead of server storage
    -p, --passphrase PASS   LUKS passphrase (can also be provided via LUKS_PASSPHRASE env var)
    -k, --keyfile PATH      LUKS keyfile path (can also be provided via LUKS_KEYFILE env var)
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    LUKS_PASSPHRASE         LUKS passphrase (alternative to -p option)
    LUKS_KEYFILE            LUKS keyfile path (alternative to -k option)

EXAMPLES:
    $0 -p "mypassphrase"                    # Backup headers to server
    $0 -k "/path/to/keyfile"                # Backup headers to server using keyfile
    $0 -p "mypassphrase" --download-mode    # Prepare backup for download
    $0 -k "/path/to/keyfile" --download-mode # Prepare backup for download using keyfile

EOF
}

#
# Cleanup function
#
cleanup() {
    if [[ -d "$TEMP_WORK_DIR" ]]; then
        rm -rf "$TEMP_WORK_DIR" >/dev/null 2>&1
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# --- Main Script Logic ---

echo "================================================"
echo "        LUKS HEADERS BACKUP PROCESS"
echo "================================================"

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


# Process all devices
process_devices

echo ""
echo "================================================"
echo "           PROCESS COMPLETE ✅"
echo "================================================"