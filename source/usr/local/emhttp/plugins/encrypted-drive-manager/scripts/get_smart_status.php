<?php
// Include Unraid's webGUI session handling for CSRF validation
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set content type to JSON
header('Content-Type: application/json');

// Define the absolute path to the event management script
$script_path = "/usr/local/emhttp/plugins/encrypted-drive-manager/scripts/manage_events.sh";

// Function to execute command and get result
function executeCommand($action) {
    global $script_path;
    
    $command = array($script_path, $action);
    
    $descriptorspec = array(
        0 => array("pipe", "r"),  // stdin
        1 => array("pipe", "w"),  // stdout
        2 => array("pipe", "w"),  // stderr
    );
    
    $process = proc_open($command, $descriptorspec, $pipes);
    
    if (is_resource($process)) {
        fclose($pipes[0]);
        
        $output = trim(stream_get_contents($pipes[1]));
        $errors = trim(stream_get_contents($pipes[2]));
        
        fclose($pipes[1]);
        fclose($pipes[2]);
        
        $return_code = proc_close($process);
        
        // Log debug information
        error_log("LUKS Debug: Command: " . implode(' ', $command));
        error_log("LUKS Debug: Return code: " . $return_code);
        error_log("LUKS Debug: Output: " . $output);
        if (!empty($errors)) {
            error_log("LUKS Debug: Errors: " . $errors);
        }
        
        if ($return_code === 0) {
            return $output;
        } else {
            return false;
        }
    }
    
    return false;
}

// Get all status information
$status = array();

// Get system state (includes array status and key testing internally)
$system_state = executeCommand('system_state');
$status['system_state'] = $system_state ?: 'unknown';

// Get auto-unlock enabled status
$auto_unlock_status = executeCommand('get_status');
$status['auto_unlock_enabled'] = ($auto_unlock_status === 'enabled');

// Derive array status from system state (optimization: eliminate redundant call)
$status['array_running'] = ($system_state !== 'array_stopped');

// Hardware fingerprint removed for security reasons

// Get unlockable devices (optimization: skip if no encrypted disks)
if ($system_state === 'no_encrypted_disks') {
    $status['unlockable_devices'] = 'none';
    $status['keys_exist'] = false;
} else {
    $unlockable_devices = executeCommand('unlockable_devices');
    $status['unlockable_devices'] = $unlockable_devices ?: 'none';
    
    // Check if keys exist
    $keys_exist = executeCommand('check_keys_exist');
    $status['keys_exist'] = ($keys_exist === 'true');
}

// Derive keys work status from system state (optimization: eliminate redundant call)
// Note: 'no_encrypted_disks' means keys_work is not applicable (false)
$status['keys_work'] = ($system_state === 'ready_enabled' || $system_state === 'ready_disabled');

// Add debug information
$status['debug'] = array(
    'keys_exist_raw' => ($system_state === 'no_encrypted_disks') ? 'skipped_no_devices' : $keys_exist,
    'keys_work_derived' => ($system_state === 'ready_enabled' || $system_state === 'ready_disabled') ? 'true' : 'false',
    'system_state_raw' => $system_state,
    'auto_unlock_raw' => $auto_unlock_status,
    'optimizations' => 'Single device testing + eliminated redundant calls + no_encrypted_disks detection'
);

// Add timestamp
$status['timestamp'] = date('Y-m-d H:i:s');

// Return JSON response
echo json_encode($status, JSON_PRETTY_PRINT);
?>