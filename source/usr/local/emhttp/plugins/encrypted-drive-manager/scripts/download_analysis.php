<?php
// Simple file download script for LUKS analysis reports
// This replaces the complex run_encryption_download.php with a much simpler approach

// Security: Only allow downloads from our temp file pattern
$filename = $_GET['file'] ?? '';

// Validate filename pattern (security check)
if (!preg_match('/^luks_analysis_\d{8}_\d{6}\.txt$/', $filename)) {
    http_response_code(400);
    die('Error: Invalid filename format.');
}

// Construct full path
$filepath = "/tmp/" . $filename;

// Check if file exists
if (!file_exists($filepath)) {
    http_response_code(404);
    die('Error: Analysis file not found. Please run a new analysis.');
}

// Check if file is readable
if (!is_readable($filepath)) {
    http_response_code(403);
    die('Error: Cannot read analysis file.');
}

// Get file size for Content-Length header
$filesize = filesize($filepath);
if ($filesize === false) {
    http_response_code(500);
    die('Error: Cannot determine file size.');
}

// Set headers for file download
header('Content-Type: text/plain; charset=utf-8');
header('Content-Disposition: attachment; filename="' . $filename . '"');
header('Content-Length: ' . $filesize);
header('Cache-Control: no-cache, must-revalidate');
header('Pragma: no-cache');

// Serve the file content
$content = file_get_contents($filepath);
if ($content === false) {
    http_response_code(500);
    die('Error: Failed to read analysis file.');
}

echo $content;

// Clean up the temp file after successful download to keep /tmp directory clean
unlink($filepath);
?>