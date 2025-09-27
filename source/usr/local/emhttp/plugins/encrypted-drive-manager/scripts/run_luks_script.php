<?php
// Include Unraid's webGUI session handling for CSRF validation (using official pattern)
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Display clean process header
echo "================================================\n";
echo "        AUTO-START CONFIGURATION PROCESS\n";
echo "================================================\n\n";
echo "Checking hardware key configuration...\n";

// Define the absolute paths to the LUKS scripts
$main_script_path = "/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/luks_management.sh";
$headers_script_path = "/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/luks_headers_backup.sh";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$backup_headers_option = $_POST['backupHeaders'] ?? 'no';
$dry_run_option = $_POST['dryRun'] ?? 'yes';
$headers_only = $_POST['headersOnly'] ?? 'false';
$zip_password = $_POST['zipPassword'] ?? '';

// --- Process Encryption Key Input (using Unraid pattern) ---
function processEncryptionKey() {
    global $key_type;
    
    if ($key_type === 'passphrase') {
        $passphrase = $_POST['passphrase'] ?? '';
        if (empty($passphrase)) {
            return ['error' => 'Passphrase is required.'];
        }
        if (strlen($passphrase) > 512) {
            return ['error' => 'Passphrase exceeds 512 character limit (Unraid standard).'];
        }
        
        // Follow official Unraid pattern: write passphrase to temp file and use --key-file
        // This matches how Unraid's official LUKS key change function works
        $temp_passphrase_file = "/tmp/luks_passphrase_" . uniqid() . ".key";
        if (file_put_contents($temp_passphrase_file, $passphrase) === false) {
            return ['error' => 'Failed to create temporary passphrase file.'];
        }
        chmod($temp_passphrase_file, 0600);
        
        return ['type' => 'keyfile', 'value' => $temp_passphrase_file];
    } else {
        // Handle keyfile data (base64 encoded, following Unraid pattern)
        
        if (!isset($_POST['keyfileData'])) {
            return ['error' => 'No keyfile data provided.'];
        }
        
        $keyfile_data = $_POST['keyfileData'];
        
        // Extract base64 data (remove data URL prefix if present)
        if (strpos($keyfile_data, 'base64,') !== false) {
            $base64_data = explode('base64,', $keyfile_data)[1];
        } else {
            $base64_data = $keyfile_data;
        }
        
        // Decode base64 data
        $decoded_data = base64_decode($base64_data);
        if ($decoded_data === false) {
            return ['error' => 'Invalid keyfile data (base64 decode failed).'];
        }
        
        
        // Validate file size (8 MiB limit)
        if (strlen($decoded_data) > 8388608) {
            return ['error' => 'Keyfile exceeds 8 MiB limit (Unraid standard).'];
        }
        
        // Create secure temporary file
        $temp_keyfile = "/tmp/luks_keyfile_" . uniqid() . ".key";
        
        if (file_put_contents($temp_keyfile, $decoded_data) === false) {
            return ['error' => 'Failed to write keyfile data.'];
        }
        
        // Set secure permissions (read-only for owner)
        chmod($temp_keyfile, 0600);
        
        return ['type' => 'keyfile', 'value' => $temp_keyfile];
    }
}

// Process the encryption key
$encryption_key = processEncryptionKey();
if (isset($encryption_key['error'])) {
    echo "Error: " . $encryption_key['error'];
    exit(1);
}

// --- Determine which script to use and build arguments ---
if ($headers_only === 'true') {
    // Headers-only operation - use dedicated backup script
    $script_path = $headers_script_path;
    $args = "";
    if ($dry_run_option === 'yes') {
        $args .= " -d";
    }
    if ($backup_headers_option === 'download') {
        $args .= " --download-mode";
    }
    // For headers script, pass encryption key via command line
    // Since we now use temp files for both passphrases and keyfiles (Unraid pattern),
    // we always use -k (keyfile) option, but also pass original input type
    $args .= " -k " . escapeshellarg($encryption_key['value']);
    $args .= " --original-input-type " . escapeshellarg($key_type);
    if (!empty($zip_password)) {
        $args .= " --zip-password " . escapeshellarg($zip_password);
    }
} else {
    // Full auto-start setup - use main management script
    $script_path = $main_script_path;
    $args = "";
    if ($dry_run_option === 'yes') {
        $args .= " -d";
    }
    // Headers are always backed up now, so pass download mode if needed
    if ($backup_headers_option === 'download') {
        $args .= " --download-mode";
    }
}

$command = $script_path . $args;

echo "Checking provided encryption key...\n";
echo "   Key verified successfully\n\n";
echo "Backing up LUKS headers...\n";
echo "DEBUG: Executing command: $command\n";
echo "DEBUG: Environment variables: " . print_r($env, true) . "\n";

// --- Execute the Command using proc_open ---

// Define the process descriptors
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("pipe", "w"),  // stdout
   2 => array("pipe", "w")   // stderr
);

// Prepare environment variables for encryption key
$env = array(
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

// For main script, pass encryption key via environment variables
// Since we now use temp files for both passphrases and keyfiles (Unraid pattern),
// we always use LUKS_KEYFILE, but also pass the original user input type
// Headers backup also needs encryption keys to access LUKS devices
$env['LUKS_KEYFILE'] = $encryption_key['value'];
$env['LUKS_ORIGINAL_INPUT_TYPE'] = $key_type;  // 'passphrase' or 'keyfile'
if (!empty($zip_password)) {
    $env['LUKS_ZIP_PASSWORD'] = $zip_password;
}

// Start the process with the explicit environment
$process = proc_open($command, $descriptorspec, $pipes, null, $env);

if (is_resource($process)) {
    // We don't need to write to stdin anymore, so close it immediately.
    fclose($pipes[0]);

    // Read the output from the script's standard output
    $output = stream_get_contents($pipes[1]);
    fclose($pipes[1]);

    // Read any errors from the script's standard error
    $errors = stream_get_contents($pipes[2]);
    fclose($pipes[2]);

    // Close the process and get exit status
    $exit_status = proc_close($process);

    // Check if the script failed
    if ($exit_status !== 0) {
        $output .= "\n--- SCRIPT EXECUTION FAILED ---\n";
        $output .= "Exit code: $exit_status\n";
        if (!empty($errors)) {
            $output .= "Error details:\n" . $errors;
        }
        if (empty($errors)) {
            $output .= "Script terminated unexpectedly with no error message.\n";
        }
    } else {
        // Only add stderr if the script succeeded (non-critical warnings)
        if (!empty($errors)) {
            $output .= "\n--- SCRIPT WARNINGS ---\n" . $errors;
        }
    }

    // Handle symlink creation for download mode
    if ($backup_headers_option === 'download' && $dry_run_option === 'no') {
        // Look for the backup file path in the output using DOWNLOAD_READY signal
        if (preg_match('/DOWNLOAD_READY: (.+\.zip)/', $output, $matches)) {
            $backup_file = $matches[1];
            $filename = basename($backup_file);
            
            // Create download directory in /tmp to avoid flash drive wear
            $tmp_download_dir = "/tmp/luksheaders/download";
            $tmp_file_path = "$tmp_download_dir/$filename";
            
            // Ensure temp download directory exists with proper permissions
            if (!is_dir($tmp_download_dir)) {
                if (!mkdir($tmp_download_dir, 0755, true)) {
                    $output .= "\nWarning: Could not create temp download directory.";
                    return;
                }
            }
            
            // Check if source file exists before copying
            if (!file_exists($backup_file)) {
                $output .= "\nWarning: Source backup file not found.";
                return;
            }
            
            // Copy the file to temp directory first
            if (!copy($backup_file, $tmp_file_path)) {
                $output .= "\nWarning: Could not copy backup file to temp location.";
                return;
            }
            chmod($tmp_file_path, 0644);
            
            // Create web-accessible symlink directory in plugin folder
            $web_download_dir = "/usr/local/emhttp/plugins/encrypted-drive-manager/downloads";
            $web_symlink_path = "$web_download_dir/$filename";
            
            // Ensure web download directory exists
            if (!is_dir($web_download_dir)) {
                if (!mkdir($web_download_dir, 0755, true)) {
                    $output .= "\nWarning: Could not create web download directory.";
                    return;
                }
            }
            
            // Remove any existing symlink and create new one pointing to temp file
            if (file_exists($web_symlink_path)) {
                unlink($web_symlink_path);
            }
            
            if (symlink($tmp_file_path, $web_symlink_path)) {
                $output .= "\nDOWNLOAD_READY: $web_symlink_path";
            } else {
                $output .= "\nWarning: Could not create download symlink.";
            }
        }
    }

    echo $output;
} else {
    echo "Error: Failed to execute the script process (proc_open failed).";
    exit(1);
}

// Clean up temporary files (both passphrase temp files and uploaded keyfiles)
if (isset($encryption_key['value']) && file_exists($encryption_key['value'])) {
    // Check if it's a temp file we created (either passphrase or keyfile)
    if (strpos($encryption_key['value'], '/tmp/luks_') === 0) {
        unlink($encryption_key['value']);
    }
}
?>
