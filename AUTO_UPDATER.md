# Auto-Updater Documentation

The Offstyle Database plugin now includes an automatic update system that can check for and install new versions from GitHub releases.

## Features

- **GitHub Release-Based Update Checking**: Checks for updates only when new releases are published on GitHub
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

1. **GitHub Release Check**: Plugin checks GitHub API for latest release version on map start
2. **Version Comparison**: Compares latest GitHub release with last checked version
3. **Update Check**: Only checks for updates if a new release is available on GitHub
4. **Version Detection**: Compares current plugin version with latest GitHub release
5. **Download**: Downloads the `.smx` file from the release assets
6. **Backup**: Creates backup of current plugin file
7. **Installation**: Replaces plugin file with new version
8. **Configuration**: Updates config file with any new ConVars
9. **Version Update**: Stores new release version for future comparisons

## Installation Process

When an update is available:

1. Plugin downloads `offstyledb.smx` from the latest GitHub release
2. Current plugin is backed up to `offstyledb_backup.smx`
3. New plugin file replaces the current one
4. New GitHub release version is stored for future comparisons
5. Configuration file is updated with missing ConVars
6. Server restart is recommended to apply changes

## GitHub Release-Based Update Detection

The auto-updater uses GitHub release monitoring to detect when new versions are available:

- On map start, queries GitHub API for the latest release
- Compares latest release version with stored version from `data/osdb_release_version.txt`
- Only performs update check if a new release is available
- Stores new release version after successful checks
- Eliminates unnecessary update processing when no new releases exist

## Error Handling

- Failed downloads are logged and reported
- Installation failures restore the backup automatically
- Network errors are handled gracefully
- Invalid releases (missing .smx file) are detected and skipped
- File hash calculation errors are logged and handled gracefully

## Logging

The auto-updater provides extensive logging:
- GitHub release version checks and comparisons
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
- Release authenticity verified through GitHub API

## Disabling Auto-Updates

To disable automatic updates:
```
OSdb_allow_auto_update 0
```

Manual update checking will still be available through admin commands.