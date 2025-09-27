<?php
// Include Unraid's webGUI session handling for CSRF validation (using official pattern)
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define the absolute path to the encryption info viewer script
$script_path = "/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/luks_info_viewer.sh";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$detail_level = $_POST['detailLevel'] ?? 'simple';

// --- Process Encryption Key Input (reusing function from run_luks_script.php) ---
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

// Validate detail level
if (!in_array($detail_level, ['simple', 'detailed', 'very_detailed'])) {
    echo "Error: Invalid detail level. Must be 'simple', 'detailed', or 'very_detailed'.";
    exit(1);
}

// --- Build the Shell Command Arguments ---
$args = "";
$args .= " -d " . escapeshellarg($detail_level);

$command = $script_path . $args;

// --- Execute the Command using proc_open ---

// Define the process descriptors
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("pipe", "w"),  // stdout
   2 => array("pipe", "w")   // stderr
);

// Pass the encryption key securely as an environment variable
// Since we now use temp files for both passphrases and keyfiles (Unraid pattern),
// we always use LUKS_KEYFILE
$env = array(
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin',
    'LUKS_KEYFILE' => $encryption_key['value']
);


// Start the process with the explicit environment
$process = proc_open($command, $descriptorspec, $pipes, null, $env);

if (is_resource($process)) {
    // We don't need to write to stdin, so close it immediately
    fclose($pipes[0]);

    // Read the output from the script's standard output
    $output = stream_get_contents($pipes[1]);
    fclose($pipes[1]);

    // Read any errors from the script's standard error
    $errors = stream_get_contents($pipes[2]);
    fclose($pipes[2]);

    // Close the process
    proc_close($process);

    // Combine output and errors for display
    if (!empty($errors)) {
        $output .= "\n--- SCRIPT ERRORS ---\n" . $errors;
    }

    // Clean up old temp files (older than 24 hours) before creating new ones
    $temp_pattern = '/tmp/luks_analysis_*.txt';
    $old_files = glob($temp_pattern);
    foreach ($old_files as $file) {
        if (is_file($file) && (time() - filemtime($file)) > 86400) { // 24 hours
            unlink($file);
        }
    }
    
    // Save output to temp file for download functionality
    $timestamp = date('Ymd_His');
    $temp_filename = "luks_analysis_{$timestamp}.txt";
    $temp_filepath = "/tmp/{$temp_filename}";
    
    if (file_put_contents($temp_filepath, $output) !== false) {
        // Include temp file info in the output for JavaScript to use
        echo $output . "\n\nTEMP_FILE_READY: {$temp_filepath}";
    } else {
        // If temp file creation fails, just return the regular output
        echo $output;
    }
} else {
    echo "Error: Failed to execute the encryption analysis script (proc_open failed).";
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