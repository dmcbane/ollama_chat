# Batch and Pattern-Based File Operations

This document describes the batch and pattern-based operations added to the MCP test server to improve efficiency when working with multiple files.

## Overview

These operations allow the LLM to perform actions on multiple files with a single tool call and user approval, significantly reducing the number of confirmations needed for bulk operations.

## Batch Operations

### delete_files

Delete multiple files at once.

**Input:**
```json
{
  "paths": ["file1.txt", "temp/file2.log", "data/old_file.dat"]
}
```

**Output:**
- Success: Lists all deleted files with ✓ marks
- Partial success: Shows both successful (✓) and failed (✗) operations
- Failure: Lists errors for each failed file

**Example:**
```
Successfully deleted 3 file(s):
  ✓ file1.txt
  ✓ temp/file2.log
  ✓ data/old_file.dat
```

### delete_directories

Delete multiple directories (recursive) at once.

**Input:**
```json
{
  "paths": ["temp", "old_logs", "backup/2023"]
}
```

**Output:**
- Success: Lists all deleted directories
- Partial success: Shows successful and failed deletions
- Handles singular/plural properly ("directory" vs "directories")

### copy_files

Copy multiple files at once with source/destination pairs.

**Input:**
```json
{
  "operations": [
    {"source": "data.txt", "destination": "backup/data.txt"},
    {"source": "config.json", "destination": "config.backup.json"}
  ]
}
```

**Output:**
- Shows source → destination for each operation
- Validates both source and destination paths
- Reports copy size in bytes on success

**Example:**
```
Successfully copied 2 file(s):
  ✓ data.txt → backup/data.txt
  ✓ config.json → config.backup.json
```

### move_files

Move/rename multiple files at once with source/destination pairs.

**Input:**
```json
{
  "operations": [
    {"source": "draft.txt", "destination": "final.txt"},
    {"source": "temp/file.dat", "destination": "archive/file.dat"}
  ]
}
```

**Output:**
- Same format as copy_files
- Uses `File.rename` which is atomic on the same filesystem
- Can move across directories within workspace

## Pattern-Based Operations

### delete_files_by_pattern

Delete all files matching a glob pattern.

**Input:**
```json
{
  "pattern": "*.tmp",
  "path": "."  // optional, defaults to workspace root
}
```

**Supported patterns:**
- `*.txt` - All .txt files
- `temp_*` - Files starting with "temp_"
- `*_backup.*` - Files containing "_backup" before extension
- `**/*.log` - All .log files recursively (if glob supports it)
- `file?.txt` - Single character wildcard (file1.txt, fileA.txt, etc)

**Output:**
- Lists all files found and deleted
- If no matches found, returns informative message
- Only operates on files (skips directories)

**Example:**
```
Deleted 3 file(s) matching '*.tmp':
  - temp_data.tmp
  - cache.tmp
  - session_12345.tmp
```

### delete_directories_by_pattern

Delete all directories matching a name pattern.

**Input:**
```json
{
  "pattern": "*_backup",
  "path": "."  // optional, defaults to workspace root
}
```

**Pattern matching:**
- `temp*` - Directories starting with "temp"
- `*_backup` - Directories ending with "_backup"  
- `cache` - Exact name match
- `node_modules` - Delete all node_modules directories
- `*test*` - Directories containing "test"

**Output:**
- Lists all directories found and deleted
- Recursive deletion (removes all contents)
- Only matches directory names (not full paths)

**Example:**
```
Deleted 2 directories matching 'temp*':
  - temp_files
  - temp_cache
```

## Error Handling

All batch operations provide detailed error information:

### Partial Success
When some operations succeed and others fail:
```
Copied 2 file(s), 1 failed:
Successful:
  ✓ file1.txt → backup/file1.txt
  ✓ file2.txt → backup/file2.txt
Failed:
  ✗ file3.txt → backup/file3.txt: permission denied
```

### Complete Failure
When all operations fail, the response includes `isError: true`:
```
Failed to delete all files:
  - file1.txt: not found
  - file2.txt: permission denied
  - file3.txt: path outside workspace
```

## Security

All operations:
- Validate paths against workspace boundaries
- Reject operations outside the workspace
- Respect file permissions
- Provide detailed error messages without exposing system internals

## Use Cases

### Cleanup temporary files
```
delete_files_by_pattern with pattern="*.tmp"
```

### Backup multiple files
```
copy_files with operations=[
  {source: "data.json", destination: "backups/data_2024.json"},
  {source: "config.json", destination: "backups/config_2024.json"}
]
```

### Remove old directories
```
delete_directories_by_pattern with pattern="*_old"
```

### Organize files
```
move_files with operations=[
  {source: "draft1.txt", destination: "drafts/draft1.txt"},
  {source: "draft2.txt", destination: "drafts/draft2.txt"},
  {source: "final.txt", destination: "published/final.txt"}
]
```

## Performance Considerations

- **Batch operations** process items sequentially but require only one approval
- **Pattern operations** first find all matches, then process them
- **Large operations** (100+ files) may take time but provide progress via detailed output
- **Partial failures** don't stop processing - all items are attempted

## Future Enhancements

Potential additions:
- `copy_directory` - recursive directory copy
- `move_directory` - move entire directory trees
- `compress_files` - create archive from multiple files
- `extract_archive` - extract archive to multiple files
- Pattern matching with regex support (beyond simple wildcards)
- Dry-run mode to preview operations before execution