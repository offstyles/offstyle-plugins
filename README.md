# Offstyle-Database

A plugin for CS:S made to submit times to the [offstyle database](https://offstyles.net/) where they can then be viewed by anyone.

<sub>Original plugin [here](https://github.com/sourcejump/plugin-database/tree/main) made by [shavit](https://github.com/shavitush) (uploaded by eric?)</sub>

## Installation Guide
### Requirements

Before adding the plugin you obviously need a CSS server setup and running the following:
  [sourcemod](https://www.sourcemod.net/downloads.php?branch=stable) +
  [bhoptimer](https://github.com/shavitush/bhoptimer)
  
  > ⚠️ **Note:** Timers other than bhoptimer are **NOT** supported and we do not intend to support them either, your best bet is forking this repo and porting the plugin yourself, however I cannot promise a key will be given for other timers

---
### Steps

#### 1. Download the latest release

Head to [the releases page](https://github.com/offstyles/offstyle-plugins/releases) and download the latest release — it ships both bhoptimer v3 and v4 builds in the same zip.

   To check bhoptimer version quickly, type `sm plugins` in the console while connected to the server and look for plugins with [shavit] infront of their names, the version of these plugins is the bhoptimer version

#### 2. Open server files

  Go to the CSS servers directory, you should see a few folders, namely `cstrike`, along with a `srcds.exe` file in this directory

#### 3. Unzip & Drag folder

  Unzip the `offstyle-database-vX.X.X.zip` file you downloaded, drag the `addons` folder from it into the `cstrike` folder in the servers directory, it may ask you to replace things, hit yes (this shouldnt cause any issues)

#### 4. Delete the build you don't need

  Navigate to `cstrike/addons/sourcemod/plugins/` and delete the one that doesn't match your bhoptimer:
  - `v3.x.x` -> keep `offstyledb_v3.smx`, delete `offstyledb.smx`
  - `v4.x.x` -> keep `offstyledb.smx`, delete `offstyledb_v3.smx`

#### 5. Restart server & Update Config

  Restart the server and head to `cstrike/cfg/sourcemod` and open the `plugin.offstyledb.cfg` file, from here you can set the apikey and configure sending times and sending replays, after setting up the config file you should restart the server again and everything should be good to go
