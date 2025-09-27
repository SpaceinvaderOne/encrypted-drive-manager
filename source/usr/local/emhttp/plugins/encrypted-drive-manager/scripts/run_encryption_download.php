<?php
// Include Unraid's webGUI session handling for CSRF validation
require_once '/usr/local/emhttp/webGUI/include/Wrappers.php';

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define paths
$info_script_path = "/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/luks_info_viewer.sh";
$download_temp_dir = "/tmp/luksheaders";
$plugin_download_dir = "/usr/local/emhttp/plugins/encrypted-drive-manager/downloads";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$detail_level = $_POST['detailLevel'] ?? 'detailed';

// --- Process Encryption Key Input (same pattern as run_encryption_info.php) ---
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
        
        return ['type' => 'keyfile', 'value' => $temp_passphrase_file, 'original_type' => 'passphrase', 'zip_password' => $passphrase];
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
        
        return ['type' => 'keyfile', 'value' => $temp_keyfile, 'original_type' => 'keyfile', 'zip_password' => $decoded_data];
    }
}

// Process the encryption key
$encryption_key = processEncryptionKey();
if (isset($encryption_key['error'])) {
    echo "Error: " . $encryption_key['error'];
    exit(1);
}

// Validate detail level
if (!in_array($detail_level, ['simple', 'detailed', 'very_detailed'])) {
    echo "Error: Invalid detail level. Must be 'simple', 'detailed', or 'very_detailed'.";
    exit(1);
}

// Generate timestamp for unique filename
$timestamp = date('Ymd_His');
$analysis_filename = "luks_encryption_analysis_{$timestamp}.txt";
$temp_analysis_file = "$download_temp_dir/$analysis_filename";
$zip_filename = "luks_encryption_analysis_{$timestamp}.zip";
$temp_zip_file = "$download_temp_dir/$zip_filename";
$symlink_path = "$plugin_download_dir/$zip_filename";

echo "Generating encryption analysis report...\n";

// Create temp directory
if (!is_dir($download_temp_dir)) {
    mkdir($download_temp_dir, 0755, true);
}

// --- Execute the encryption info script to generate analysis ---
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("file", $temp_analysis_file, "w"),  // stdout to file
   2 => array("pipe", "w")   // stderr
);

$command = "$info_script_path -d " . escapeshellarg($detail_level);
// Pass the encryption key securely as an environment variable
// Since we now use temp files for both passphrases and keyfiles (Unraid pattern),
// we always use LUKS_KEYFILE
$env = array(
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin',
    'LUKS_KEYFILE' => $encryption_key['value']
);

$process = proc_open($command, $descriptorspec, $pipes, null, $env);

if (is_resource($process)) {
    // Close stdin
    fclose($pipes[0]);
    
    // Read any errors
    $errors = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    
    $return_value = proc_close($process);
    
    if ($return_value !== 0) {
        echo "Error: Failed to generate encryption analysis.\n";
        if (!empty($errors)) {
            echo "Details: $errors\n";
        }
        exit(1);
    }
} else {
    echo "Error: Failed to execute encryption analysis script.\n";
    exit(1);
}

// Check if analysis file was created
if (!file_exists($temp_analysis_file)) {
    echo "Error: Analysis file was not generated.\n";
    exit(1);
}

echo "Analysis generated successfully.\n";
echo "Creating encrypted archive...\n";

// Create encrypted ZIP archive using appropriate password
// Use the stored zip_password (which is the raw passphrase or keyfile data)
$zip_password = $encryption_key['zip_password'];

// Use a simpler zip command approach that's more reliable
$zip_command = sprintf(
    'cd %s && zip -j --password %s %s %s',
    escapeshellarg($download_temp_dir),
    escapeshellarg($zip_password),
    escapeshellarg($zip_filename),
    escapeshellarg($analysis_filename)
);

$zip_output = [];
$zip_exit_code = 0;
exec($zip_command . ' 2>&1', $zip_output, $zip_exit_code);

if ($zip_exit_code !== 0 || !file_exists($temp_zip_file)) {
    echo "Error: Failed to create encrypted archive.\n";
    echo "Command: $zip_command\n";
    echo "Exit code: $zip_exit_code\n";
    echo "Output: " . implode("\n", $zip_output) . "\n";
    exit(1);
}

echo "Encrypted archive created successfully.\n";

// Create download directory if it doesn't exist
if (!is_dir($plugin_download_dir)) {
    if (!mkdir($plugin_download_dir, 0755, true)) {
        echo "Error: Failed to create plugin download directory.\n";
        exit(1);
    }
}

// Instead of symlink, copy the file directly to avoid symlink issues
$final_download_path = "$plugin_download_dir/$zip_filename";

// Remove any existing file and copy the new one
if (file_exists($final_download_path)) {
    unlink($final_download_path);
}

if (copy($temp_zip_file, $final_download_path)) {
    echo "Final encrypted analysis archive created.\n";
    echo "Archive includes detailed encryption analysis for download.\n";
    echo "\nDOWNLOAD_READY: $final_download_path\n";
    
    // Clean up temporary files
    if (file_exists($temp_analysis_file)) {
        unlink($temp_analysis_file);
    }
    if (file_exists($temp_zip_file)) {
        unlink($temp_zip_file);
    }
    
    // Clean up temporary keyfile (both passphrases and keyfiles use temp files now)
    if (file_exists($encryption_key['value'])) {
        unlink($encryption_key['value']);
    }
} else {
    echo "Error: Could not copy file to download directory.\n";
    echo "Source: $temp_zip_file\n";
    echo "Destination: $final_download_path\n";
    
    // Clean up temporary keyfile (both passphrases and keyfiles use temp files now)
    if (file_exists($encryption_key['value'])) {
        unlink($encryption_key['value']);
    }
    exit(1);
}
?>