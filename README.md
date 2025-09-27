# Encrypted Drive Manager

**A comprehensive Unraid plugin for managing encrypted drives with hardware-bound auto-unlock, LUKS header management, and encryption analysis.**

![Plugin Interface](https://img.shields.io/badge/Platform-Unraid-orange?style=flat-square)
![License](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)
![Version](https://img.shields.io/badge/Version-2025.09.27-green?style=flat-square)

## Installation

**Install via Unraid Community Applications:**

1. Open your Unraid web interface
2. Go to **Apps** tab (Community Applications)
3. Search for **"Encrypted Drive Manager"**
4. Click **Install** on the plugin by SpaceInvaderOne
5. The plugin will appear in **Settings → Utilities**

**Requirements:**
- Unraid 6.11.0 or higher
- LUKS-encrypted drives
- Network access during setup (for hardware fingerprinting)

## Security Architecture

### Hardware-Bound Key Generation

The plugin creates a **hardware-derived secondary key** that enables automatic unlocking while maintaining security:

**Hardware Fingerprinting Components:**
- **Motherboard Serial Number**: Unique identifier from the system's baseboard
- **Default Gateway MAC Address**: MAC address of your router/gateway device

**Key Generation Process:**
```
Hardware Key = SHA256(motherboard_serial + "_" + gateway_mac)
```

### Motivation and Security Benefits

Many users store their LUKS keyfiles on the Unraid server itself and reference them in the go file for automatic array startup. This approach has a critical security flaw: if the server is stolen, it will simply download and use the same keyfile, providing no theft protection.

This plugin solves this problem by creating hardware-bound keys that are tied to the physical location and hardware of your server, making automatic unlock fail if the server is moved to a different environment.

**Why this approach is secure:**

**Theft Protection**: If your Unraid server is physically stolen and moved to a different location/network, the auto-unlock will **fail** because:
- The gateway MAC address will be different (different router)
- The hardware fingerprint no longer matches
- Manual intervention with your original passphrase/keyfile is required

**Dual Authentication**: Your original LUKS passphrase or keyfile remains **completely unchanged** and functional:
- **Slot 0**: Your original passphrase/keyfile (untouched)
- **Slot 31**: Hardware-derived key (last slot of 32 available slots 0-31)

**Zero Storage**: Hardware keys are **never stored on disk** - they're derived in real-time during boot

### LUKS Slot Management

**LUKS2 Slot Architecture:**
- **32 Total Slots**: Numbered 0-31 (LUKS2 standard)
- **Slot 0**: Reserved for your original passphrase/keyfile
- **Slot 31**: Used for the hardware-derived key (last slot)
- **Slots 1-30**: Available for additional user keys

**Non-Destructive Design:**
- Original authentication methods remain fully functional
- You can always unlock manually with your passphrase/keyfile
- Hardware key adds convenience without removing security options
- Automatic cleanup of old hardware keys when hardware changes

## Plugin Interface

### Three Main Sections:

#### 1. **Auto Start Tab**
- **Hardware Key Generation**: Create hardware-bound keys for your encrypted drives
- **Event System Management**: Enable/disable automatic unlocking at boot
- **Status Monitoring**: Real-time feedback on auto-unlock configuration
- **Smart Detection**: Automatically finds LUKS devices and manages key lifecycle

#### 2. **LUKS Headers Tab** 
- **Header Backup**: Create encrypted ZIP backups of LUKS headers
- **Hardware Key Metadata**: Includes generation timestamp and hardware fingerprint
- **ZIP Encryption**: 
  - **Passphrase users**: ZIP encrypted with same passphrase
  - **Keyfile users**: Custom password input for ZIP encryption
- **Download Management**: Secure temporary file handling

#### 3. **Encryption Info Tab**
- **Device Analysis**: Comprehensive encryption information for all drives
- **Slot Information**: View occupied LUKS key slots and metadata
- **SMART Status**: Drive health information integrated with encryption data
- **Export Options**: Download detailed encryption analysis reports

## Technical Implementation

### Multi-Language Architecture
- **Shell Scripts**: Core LUKS operations and hardware fingerprinting
- **PHP Backends**: Web interface processing and security validation  
- **JavaScript Frontend**: Real-time UI updates and form validation
- **Event System Integration**: Native Unraid boot event management

### Theme Compatibility
- **Responsive Design**: Works on desktop, tablet, and mobile
- **Theme Support**: Seamlessly adapts to Unraid's light and dark modes
- **Professional Styling**: Orange accent colors with theme-neutral backgrounds

### Security Features
- **CSRF Protection**: Uses Unraid's official security patterns
- **Input Validation**: Multi-layer validation (frontend, PHP, shell)
- **Temporary File Security**: Secure file handling with automatic cleanup
- **Slot Protection**: Will never remove any slot other than slot 31 (the hardware key slot). Includes security verification that ensures the passphrase or keyfile being used can actually unlock the slot before any removal operation, preventing user lockout

## Usage Workflow

### Initial Setup
1. **Navigate to Settings → Utilities → Encrypted Drive Manager**
2. **Auto Start Tab**: Click "Generate Hardware Key" 
3. **Enter your current LUKS passphrase or select keyfile**
4. **Enable auto-unlock** for boot automation
5. **Test the configuration** by rebooting your server

### Backup Management
1. **LUKS Headers Tab**: Create encrypted backups of your LUKS headers
2. **Download backups** to your PC for safekeeping
3. **Store in a secure location** (separate from your server)

### Monitoring & Analysis
1. **Encryption Info Tab**: View detailed encryption status
2. **Download analysis reports** for documentation
3. **Monitor SMART status** alongside encryption information

## How Auto-Unlock Works

### Boot Sequence
1. **Unraid starts** and reaches the encrypted drive detection phase
2. **Hardware fingerprinting** runs automatically via event system
3. **Key derivation** generates the hardware key from current environment
4. **LUKS unlock** attempts using the derived key on slot 31
5. **Enables automatic boot and array start** for the Unraid server if unlock succeeds

### Failure Scenarios
- **Hardware change**: New motherboard requires key regeneration
- **Network change**: Different router/gateway requires key regeneration  
- **Drive transplant**: Moving drives to different server requires manual unlock
- **Slot conflicts**: Plugin manages slot cleanup automatically

## Important Security Notes

### What This Plugin Does NOT Do
- **Does not weaken your encryption** - original keys remain unchanged
- **Does not store keys on disk** - all keys derived dynamically
- **Does not work after theft** - different network = no auto-unlock
- **Does not bypass LUKS security** - uses standard LUKS key slots

### What This Plugin DOES Do  
- **Adds convenience** without sacrificing security
- **Enables automatic boot and array start** for the Unraid server
- **Maintains theft protection** through hardware binding
- **Provides escape hatches** via original authentication methods

## Troubleshooting

### Common Issues

**Auto-unlock not working after hardware change:**
- Regenerate the hardware key from the Auto Start tab
- Plugin automatically detects hardware changes

**Array won't start automatically:**
- Check that auto-unlock is enabled in the Auto Start tab
- Make sure that auto-start of the Unraid array is enabled in disk settings
- Verify your original passphrase/keyfile works manually
- Review system logs for LUKS unlock attempts

### Getting Help
- **Unraid Forums**: Search for "Encrypted Drive Manager" 
- **GitHub Issues**: Report bugs or request features

## Credits

**Author**: SpaceInvaderOne  
**License**: GPL-3.0  
**Platform**: Unraid 6.11.0+

**Special Thanks:**
- Unraid community for testing and feedback
- LUKS/cryptsetup developers for the underlying encryption technology
- Contributors to the responsive web GUI framework

---

*This plugin is designed for defensive security purposes only. It enhances convenience while maintaining the security properties of LUKS encryption.*
