<?php
// Security check - only allow access from local server
if (!in_array($_SERVER['REMOTE_ADDR'], ['127.0.0.1', '::1', $_SERVER['SERVER_ADDR']])) {
    http_response_code(403);
    exit('Access denied');
}

// Get the filename from POST data
$filename = $_POST['filename'] ?? '';

if (empty($filename)) {
    http_response_code(400);
    exit('No filename provided');
}

// Validate filename for security
if (strpos($filename, '/') !== false || strpos($filename, '..') !== false) {
    http_response_code(400);
    exit('Invalid filename');
}

// Clean up both the symlink and the original temp file
$plugin_download_dir = "/usr/local/emhttp/plugins/encrypted-drive-manager/downloads";
$symlink_path = "$plugin_download_dir/$filename";
$temp_file_path = "/tmp/luksheaders/$filename";

$cleaned = array();

// Remove symlink
if (file_exists($symlink_path)) {
    if (unlink($symlink_path)) {
        $cleaned[] = "symlink";
    }
}

// Remove original temp file
if (file_exists($temp_file_path)) {
    if (unlink($temp_file_path)) {
        $cleaned[] = "temp file";
    }
}

// Try to remove temp directory if empty
if (is_dir("/tmp/luksheaders")) {
    $files = array_diff(scandir("/tmp/luksheaders"), array('.', '..'));
    if (empty($files)) {
        rmdir("/tmp/luksheaders");
        $cleaned[] = "temp directory";
    }
}

// Return success response
header('Content-Type: application/json');
echo json_encode(array(
    'success' => true,
    'cleaned' => $cleaned,
    'message' => 'Cleanup completed'
));
?>