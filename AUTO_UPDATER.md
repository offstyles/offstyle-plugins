# Auto-Updater Documentation

The Offstyle Database plugin now includes an automatic update system that can check for and install new versions from GitHub releases.

## Features

- **Automatic Update Checking**: Checks for updates periodically (every 30 minutes minimum)
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

1. **Version Detection**: Plugin compares current version with latest GitHub release
2. **Download**: Downloads the `.smx` file from the release assets
3. **Backup**: Creates backup of current plugin file
4. **Installation**: Replaces plugin file with new version
5. **Configuration**: Updates config file with any new ConVars
6. **Cleanup**: Removes backup file after successful installation

## Installation Process

When an update is available:

1. Plugin downloads `offstyledb.smx` from the latest GitHub release
2. Current plugin is backed up to `offstyledb_backup.smx`
3. New plugin file replaces the current one
4. Configuration file is updated with missing ConVars
5. Server restart is recommended to apply changes

## Error Handling

- Failed downloads are logged and reported
- Installation failures restore the backup automatically
- Network errors are handled gracefully
- Invalid releases (missing .smx file) are detected and skipped

## Logging

The auto-updater provides extensive logging:
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

## Disabling Auto-Updates

To disable automatic updates:
```
OSdb_allow_auto_update 0
```

Manual update checking will still be available through admin commands.