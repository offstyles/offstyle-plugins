# offstyle-database
modified sourcejump-database plugin by shavit

## Features

- Database integration for bhop timer records
- Bulk record submission and management
- Style mapping configuration
- **Auto-updater system** - Automatically checks for and installs plugin updates

## Auto-Updater

The plugin now includes an automatic update system that can:
- Check for new releases on GitHub automatically
- Download and install updates safely
- Manage configuration file changes
- Provide admin controls for manual updates

See [AUTO_UPDATER.md](AUTO_UPDATER.md) for detailed documentation.

### Quick Setup
- `OSdb_allow_auto_update 1` - Enable automatic updates (default)
- `osdb_check_update` - Manually check for updates
- `osdb_force_update` - Force update installation (admin only)
