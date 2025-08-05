# GetReplay Plugin Documentation

## Overview
The GetReplay plugin allows players to download and watch replays from the Offstyles database as dynamic bots in-game, similar to how the getmap functionality works.

## Features
- Download replays for any available style from the database
- Automatic style selection menu
- Permission-based access control
- Replay caching until map change
- Dynamic bot creation with Shavit integration
- Automatic spectator switching with configurable delay
- Duplicate prevention
- Concurrent replay limiting
- Admin controls for stopping replays

## Commands
- `/getreplay` - Opens the style selection menu to download and play a replay
- `/osdb_stop_replays` - (Admin only) Stops all active replays

## ConVars
- `osdb_replay_flag "b"` - Admin flag required to use getreplay command (empty string for all players)
- `osdb_replay_loop "0"` - Enable replay bot looping (0=disabled, 1=enabled)
- `osdb_replay_spectate_delay "2.5"` - Delay in seconds before automatically spectating the replay bot
- `osdb_replay_max_concurrent "1"` - Maximum number of concurrent replays allowed

## Usage
1. Player types `/getreplay` in chat
2. Plugin checks permissions based on `osdb_replay_flag`
3. Style selection menu is displayed
4. Player selects desired style
5. Plugin downloads replay from API (with progress message)
6. Replay is cached and bot is spawned
7. Player is automatically moved to spectate the bot after the configured delay

## Permission System
- By default, requires admin flag "b" (ADMFLAG_RESERVATION)
- Set `osdb_replay_flag ""` to allow all players
- Set to any valid admin flag string (e.g., "z" for root admin)

## Caching
- Replays are cached in memory until map change
- Prevents re-downloading the same replay multiple times
- Cache is automatically cleared on map transitions

## API Integration
The plugin integrates with the Offstyles API at `https://offstyles.tommyy.dev/api/get_replay`:
- Sends POST request with map name and style
- Expects JSON response with base64-encoded replay data
- Handles errors gracefully with user feedback

## Shavit Integration
- Attempts to use Shavit's native replay system when available
- Falls back to simple bot creation if Shavit natives are not present
- Supports automatic replay bot management

## Installation
1. Place `offstyledb.smx` in `addons/sourcemod/plugins/`
2. Configure ConVars in `cfg/sourcemod/`
3. Ensure proper API authentication is configured
4. Restart server or load plugin manually

## Technical Details
- Prevents server lag during downloads with async HTTP requests
- Implements proper cleanup on map change and plugin unload
- Uses StringMap for efficient replay caching
- Includes comprehensive debug logging (enable with `OSdb_extended_debugging 1`)

## Troubleshooting
- Check that `OSdb_private_key` is properly configured
- Verify API connectivity and authentication
- Enable debug logging to diagnose issues
- Ensure Shavit timer plugin is loaded for full functionality