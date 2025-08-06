# Auto-Updater Documentation

The Offstyle Database plugin now includes an automatic update system that can check for and install new versions from GitHub releases.

## Features

- **File Hash-Based Update Checking**: Checks for updates only when the plugin file changes
- **Safe Installation**: Creates backups before updating and restores on failure
- **Configuration Management**: Automatically adds new ConVars to configuration files
- **Admin Control**: Manual update commands for administrators
- **GitHub Integration**: Uses GitHub API to fetch latest release information

## Configuration

### ConVar
- `OSdb_allow_auto_update` (default: `1`)
  - `0` = Disabled - No automatic updates
  - `1` = Enabled - Allow automatic updates

### Admin Commands
- `osdb_check_update` - Check for available updates
- `osdb_force_update` - Force download and install latest update (admin only)

Both admin commands are restricted to whitelisted SteamIDs defined in the plugin.

## How It Works

1. **File Hash Detection**: Plugin calculates hash of current plugin file on map start
2. **Hash Comparison**: Compares current hash with stored hash from previous run
3. **Update Check**: Only checks for updates if file hash has changed (indicating file was modified)
4. **Version Detection**: Compares current version with latest GitHub release
5. **Download**: Downloads the `.smx` file from the release assets
6. **Backup**: Creates backup of current plugin file
7. **Installation**: Replaces plugin file with new version
8. **Configuration**: Updates config file with any new ConVars
9. **Hash Update**: Stores new file hash for future comparisons

## Installation Process

When an update is available:

1. Plugin downloads `offstyledb.smx` from the latest GitHub release
2. Current plugin is backed up to `offstyledb_backup.smx`
3. New plugin file replaces the current one
4. New plugin file hash is calculated and stored
5. Configuration file is updated with missing ConVars
6. Server restart is recommended to apply changes

## Hash-Based Update Detection

The auto-updater uses SHA1 file hashing to detect when the plugin file has changed:

- On first run or map start, calculates SHA1 hash of current plugin file
- Compares with stored hash from `data/osdb_plugin_hash.txt`
- Only performs update check if hash differs or file doesn't exist
- Stores new hash after successful updates
- Eliminates unnecessary API calls when plugin hasn't changed

## Error Handling

- Failed downloads are logged and reported
- Installation failures restore the backup automatically
- Network errors are handled gracefully
- Invalid releases (missing .smx file) are detected and skipped
- File hash calculation errors are logged and handled gracefully

## Logging

The auto-updater provides extensive logging:
- File hash calculations and comparisons
- Update checks and results
- Download progress and errors
- Installation success/failure
- Configuration file changes

Enable `OSdb_extended_debugging 1` for detailed debug output.

## Security

- Only downloads from the official GitHub repository
- Verifies file existence before installation
- Uses secure HTTPS connections
- Admin commands restricted to whitelisted users
- File integrity verified through SHA1 hashing

## Disabling Auto-Updates

To disable automatic updates:
```
OSdb_allow_auto_update 0
```

Manual update checking will still be available through admin commands.