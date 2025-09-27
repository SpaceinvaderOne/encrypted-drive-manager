<?php
// Include Unraid's webGUI session handling for CSRF validation (using official pattern)
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Display clean process header
echo "================================================\n";
echo "        EVENT MANAGEMENT PROCESS\n";
echo "================================================\n\n";

// Define the absolute path to the event management script
$script_path = "/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/manage_events.sh";

// --- Get POST data from the UI ---
$action = $_POST['action'] ?? 'status'; // Default to 'status' if nothing is received

// Validate action parameter
$valid_actions = ['enable', 'disable', 'status', 'get_status', 'system_state', 'hardware_fingerprint', 'unlockable_devices', 'check_keys_exist', 'test_keys_work'];
if (!in_array($action, $valid_actions)) {
    echo "Error: Invalid action '$action'. Valid actions are: " . implode(', ', $valid_actions) . "\n";
    exit(1);
}

// --- Build the Shell Command ---
$command = array($script_path, $action);

// --- Execute the Command using proc_open ---
$descriptorspec = array(
    0 => array("pipe", "r"),  // stdin
    1 => array("pipe", "w"),  // stdout
    2 => array("pipe", "w"),  // stderr
);

$process = proc_open($command, $descriptorspec, $pipes);

if (is_resource($process)) {
    // Close stdin as we don't need to send input
    fclose($pipes[0]);
    
    // Read stdout and stderr
    $output = stream_get_contents($pipes[1]);
    $errors = stream_get_contents($pipes[2]);
    
    // Close pipes
    fclose($pipes[1]);
    fclose($pipes[2]);
    
    // Wait for the process to terminate and get return code
    $return_code = proc_close($process);
    
    // Handle errors from stderr
    if (!empty($errors)) {
        $output .= "\n--- SCRIPT ERRORS ---\n" . $errors;
    }
    
    // Output the results
    echo $output;
    
    // Add completion status based on return code
    if ($return_code === 0) {
        echo "\n================================================\n";
        echo "           OPERATION COMPLETED ✅\n"; 
        echo "================================================\n";
    } else {
        echo "\n================================================\n";
        echo "           OPERATION FAILED ❌\n"; 
        echo "           Exit Code: $return_code\n";
        echo "================================================\n";
    }
} else {
    echo "Error: Failed to execute the event management script.\n";
    echo "Check that the script exists at: $script_path\n";
    echo "And verify permissions are correct.\n";
    exit(1);
}
?>