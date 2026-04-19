#if defined _offstyledb_updater_included
 #endinput
#endif
#define _offstyledb_updater_included

#pragma newdecls required
#pragma semicolon 1

// Injected by CI from the git tag (e.g. tag "v5.0.1" -> "5.0.1"). Leave as
// "dev" for local/untagged builds — CI rewrites this line before compile.
#define PLUGIN_VERSION "dev"

#define UPDATER_API_URL     "https://api.github.com/repos/offstyles/offstyle-plugins/releases/latest"
#define UPDATER_CHECK_EVERY 21600.0    // 6 hours

#if defined SHAVIT_V3
 #define UPDATER_SMX_NAME "offstyledb_v3.smx"
 #define UPDATER_SM_NAME  "offstyledb_v3"
#else
 #define UPDATER_SMX_NAME "offstyledb.smx"
 #define UPDATER_SM_NAME  "offstyledb"
#endif

void Updater_OnPluginStart()
{
    gCV_AutoUpdate = new Convar("OSdb_autoupdate", "2", "Autoupdater: off (0), check + notify only (1), check + download + auto-apply (2, default).", 0, true, 0.0, true, 2.0);

    RegConsoleCmd("osdb_check_update", Command_CheckUpdate);
    RegConsoleCmd("osdb_apply_update", Command_ApplyUpdate);

    CreateTimer(UPDATER_CHECK_EVERY, Timer_CheckUpdate, _, TIMER_REPEAT);
}

void Updater_OnConfigsExecuted()
{
    Updater_CheckForUpdate(true);
}

public Action Timer_CheckUpdate(Handle timer)
{
    Updater_CheckForUpdate(true);
    return Plugin_Continue;
}

void Updater_CheckForUpdate(bool silent)
{
    if (gCV_AutoUpdate.IntValue == 0)
    {
        if (!silent)
        {
            PrintToServer("[OSdb] Autoupdater is disabled (OSdb_autoupdate 0).");
        }
        return;
    }

    if (gB_UpdateInFlight)
    {
        if (!silent)
        {
            PrintToServer("[OSdb] An update check is already in progress.");
        }
        DebugPrint("Skipping update check, one is already in flight");
        return;
    }

    DebugPrint("Checking for updates (silent=%s, current=%s)", silent ? "true" : "false", PLUGIN_VERSION);

    gB_UpdateInFlight = true;

    HTTPRequest req = new HTTPRequest(UPDATER_API_URL);
    req.SetHeader("Accept", "application/vnd.github+json");
    req.SetHeader("User-Agent", "offstyledb-updater");
    req.Get(Callback_OnLatestRelease, silent ? 1 : 0);
}

public void Callback_OnLatestRelease(HTTPResponse resp, any value)
{
    bool silent = (value == 1);

    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        DebugPrint("Update check failed: status = %d", resp.Status);
        gB_UpdateInFlight = false;
        return;
    }

    JSONObject data = view_as<JSONObject>(resp.Data);
    char       tag[32];

    if (!data.GetString("tag_name", tag, sizeof(tag)))
    {
        DebugPrint("Update check: response missing tag_name");
        delete data;
        gB_UpdateInFlight = false;
        return;
    }

    strcopy(gS_LatestTag, sizeof(gS_LatestTag), tag);

    // strip leading 'v' so "v5" compares as "5"
    int  tagOffset = (tag[0] == 'v' || tag[0] == 'V') ? 1 : 0;
    bool newer    = !StrEqual(tag[tagOffset], PLUGIN_VERSION);

    DebugPrint("Latest release tag: %s (current: %s)", tag, PLUGIN_VERSION);

    if (!newer)
    {
        if (!silent)
        {
            PrintToServer("[OSdb] Already up to date (version %s).", PLUGIN_VERSION);
        }
        delete data;
        gB_UpdateInFlight = false;
        return;
    }

    PrintToServer("[OSdb] New version available: %s (current: %s)", tag, PLUGIN_VERSION);
    LogMessage("[OSdb] New version available: %s (current: %s)", tag, PLUGIN_VERSION);

    if (gCV_AutoUpdate.IntValue < 2)
    {
        PrintToServer("[OSdb] Set OSdb_autoupdate 2 to auto-download, or update manually: https://github.com/offstyles/offstyle-plugins/releases/tag/%s", tag);
        delete data;
        gB_UpdateInFlight = false;
        return;
    }

    char      downloadUrl[256];
    downloadUrl[0]   = '\0';
    JSONArray assets = view_as<JSONArray>(data.Get("assets"));

    if (assets != null)
    {
        for (int i = 0; i < assets.Length; i++)
        {
            JSONObject asset = view_as<JSONObject>(assets.Get(i));
            char name[64];
            asset.GetString("name", name, sizeof(name));

            if (StrEqual(name, UPDATER_SMX_NAME))
            {
                asset.GetString("browser_download_url", downloadUrl, sizeof(downloadUrl));
                delete asset;
                break;
            }

            delete asset;
        }
    }
    delete assets;
    delete data;

    if (downloadUrl[0] == '\0')
    {
        DebugPrint("Update check: no %s asset in release %s", UPDATER_SMX_NAME, tag);
        gB_UpdateInFlight = false;
        return;
    }

    DebugPrint("Downloading %s from %s", UPDATER_SMX_NAME, downloadUrl);

    char stagePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, stagePath, sizeof(stagePath), "plugins/" ... UPDATER_SMX_NAME ... ".new");

    HTTPRequest dl = new HTTPRequest(downloadUrl);
    dl.SetHeader("User-Agent", "offstyledb-updater");
    dl.DownloadFile(stagePath, Callback_OnSMXDownloaded);
}

public void Callback_OnSMXDownloaded(HTTPStatus status, any value)
{
    gB_UpdateInFlight = false;

    if (status != HTTPStatus_OK)
    {
        DebugPrint("Update download failed with status %d", status);
        gS_LatestTag[0] = '\0';
        return;
    }

    PrintToServer("[OSdb] Update %s downloaded, applying...", gS_LatestTag);
    Updater_ApplyStaged();
}

// Renames the staged .smx.new over the live .smx and reloads the plugin.
// Returns true if the rename succeeded (the reload runs asynchronously after
// this frame). Leaves the staged file in place on failure so it can be retried.
bool Updater_ApplyStaged()
{
    char livePath[PLATFORM_MAX_PATH];
    char stagePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, livePath,  sizeof(livePath),  "plugins/" ... UPDATER_SMX_NAME);
    BuildPath(Path_SM, stagePath, sizeof(stagePath), "plugins/" ... UPDATER_SMX_NAME ... ".new");

    if (!FileExists(stagePath))
    {
        LogMessage("[OSdb] Apply update: staged file %s is missing", stagePath);
        return false;
    }

    if (FileExists(livePath) && !DeleteFile(livePath))
    {
        LogMessage("[OSdb] Apply update failed: could not delete %s", livePath);
        return false;
    }

    if (!RenameFile(livePath, stagePath))
    {
        LogMessage("[OSdb] Apply update failed: RenameFile %s -> %s", stagePath, livePath);
        return false;
    }

    LogMessage("[OSdb] Applied update to version %s, reloading plugin.", gS_LatestTag);
    PrintToServer("[OSdb] Update %s applied, reloading plugin...", gS_LatestTag);

    ServerCommand("sm plugins reload " ... UPDATER_SM_NAME);
    return true;
}

public Action Command_CheckUpdate(int client, int args)
{
    if (!IsOSdbAdmin(client))
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to run update commands.");
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[OSdb] Checking for updates...");
    Updater_CheckForUpdate(false);
    return Plugin_Handled;
}

public Action Command_ApplyUpdate(int client, int args)
{
    if (!IsOSdbAdmin(client))
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to run update commands.");
        return Plugin_Handled;
    }

    if (Updater_ApplyStaged())
    {
        ReplyToCommand(client, "[OSdb] Update applied. Reloading plugin...");
    }
    else
    {
        ReplyToCommand(client, "[OSdb] No staged update available, or apply failed. Check logs.");
    }
    return Plugin_Handled;
}

// Called from OnAllPluginsLoaded once shavit natives have been resolved.
// Detects mismatch between this build and the running shavit version, and
// triggers a build switch when OSdb_autoupdate is 2.
void Updater_CheckBuildMatch()
{
    int running = ShavitCompat_DetectRunningVersion();
    int built   = ShavitCompat_BuildVersion();

    PrintToServer("[OSdb] Build-match check: installed=v%d build, running=shavit v%d", built, running);

    if (running == built)
    {
        return;
    }

    gB_BuildMismatch = true;
    LogMessage("[OSdb] This is the shavit v%d build but the server is running shavit v%d. Records will not submit until the correct build is installed.", built, running);

    int mode = gCV_AutoUpdate.IntValue;
    if (mode == 0)
    {
        PrintToServer("[OSdb] OSdb_autoupdate is 0 - install offstyledb%s.smx manually, or set OSdb_autoupdate 2 to auto-correct.", running == 3 ? "_v3" : "");
        return;
    }
    if (mode < 2)
    {
        PrintToServer("[OSdb] Set OSdb_autoupdate 2 to auto-download the correct build, or manually install offstyledb%s.smx.", running == 3 ? "_v3" : "");
        return;
    }

    PrintToServer("[OSdb] Auto-switching to offstyledb%s.smx...", running == 3 ? "_v3" : "");
    Updater_SwitchToBuild(running);
}

// Fetches the latest release and downloads the OTHER build's .smx asset, then
// loads it and unloads self.
void Updater_SwitchToBuild(int targetVersion)
{
    if (gB_UpdateInFlight)
    {
        return;
    }
    gB_UpdateInFlight = true;

    HTTPRequest req = new HTTPRequest(UPDATER_API_URL);
    req.SetHeader("Accept", "application/vnd.github+json");
    req.SetHeader("User-Agent", "offstyledb-updater");
    req.Get(Callback_OnSwitchReleaseInfo, targetVersion);
}

public void Callback_OnSwitchReleaseInfo(HTTPResponse resp, any value)
{
    int targetVersion = value;

    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        DebugPrint("Build-switch: GitHub API failed (status=%d)", resp.Status);
        gB_UpdateInFlight = false;
        return;
    }

    char targetSmx[64];
    BuildSmxNameForVersion(targetVersion, targetSmx, sizeof(targetSmx));

    JSONObject data     = view_as<JSONObject>(resp.Data);
    JSONArray  assets   = view_as<JSONArray>(data.Get("assets"));
    char       downloadUrl[256];
    downloadUrl[0] = '\0';

    if (assets != null)
    {
        for (int i = 0; i < assets.Length; i++)
        {
            JSONObject asset = view_as<JSONObject>(assets.Get(i));
            char name[64];
            asset.GetString("name", name, sizeof(name));

            if (StrEqual(name, targetSmx))
            {
                asset.GetString("browser_download_url", downloadUrl, sizeof(downloadUrl));
                delete asset;
                break;
            }

            delete asset;
        }
    }
    delete assets;
    delete data;

    if (downloadUrl[0] == '\0')
    {
        DebugPrint("Build-switch: no %s asset in the latest release", targetSmx);
        gB_UpdateInFlight = false;
        return;
    }

    char stagePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, stagePath, sizeof(stagePath), "plugins/%s.new", targetSmx);

    HTTPRequest dl = new HTTPRequest(downloadUrl);
    dl.SetHeader("User-Agent", "offstyledb-updater");
    dl.DownloadFile(stagePath, Callback_OnSwitchDownloaded, targetVersion);
}

public void Callback_OnSwitchDownloaded(HTTPStatus status, any value)
{
    int targetVersion = value;
    gB_UpdateInFlight = false;

    if (status != HTTPStatus_OK)
    {
        DebugPrint("Build-switch download failed (status=%d)", status);
        return;
    }

    char targetSmx[64];
    char targetSmName[32];
    BuildSmxNameForVersion(targetVersion, targetSmx, sizeof(targetSmx));
    BuildSmNameForVersion(targetVersion, targetSmName, sizeof(targetSmName));

    char livePath[PLATFORM_MAX_PATH];
    char stagePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, livePath,  sizeof(livePath),  "plugins/%s",     targetSmx);
    BuildPath(Path_SM, stagePath, sizeof(stagePath), "plugins/%s.new", targetSmx);

    if (FileExists(livePath) && !DeleteFile(livePath))
    {
        LogMessage("[OSdb] Build-switch: could not delete %s - install manually.", livePath);
        return;
    }

    if (!RenameFile(livePath, stagePath))
    {
        LogMessage("[OSdb] Build-switch: rename %s -> %s failed.", stagePath, livePath);
        return;
    }

    LogMessage("[OSdb] Build-switch: installed %s for shavit v%d.", targetSmx, targetVersion);
    PrintToServer("[OSdb] Installed correct build %s, loading and unloading self.", targetSmx);

    // Remove our own .smx so the wrong build doesn't re-load on next restart.
    // On Windows this may fail while the plugin is loaded; admin will see the
    // log and can clean up manually.
    char ownPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, ownPath, sizeof(ownPath), "plugins/" ... UPDATER_SMX_NAME);
    if (FileExists(ownPath) && !DeleteFile(ownPath))
    {
        LogMessage("[OSdb] Build-switch: could not delete own .smx at %s - please remove manually.", ownPath);
    }

    char cmd[128];
    FormatEx(cmd, sizeof(cmd), "sm plugins load %s", targetSmName);
    ServerCommand(cmd);
    ServerCommand("sm plugins unload " ... UPDATER_SM_NAME);
}

void BuildSmxNameForVersion(int version, char[] buf, int maxlen)
{
    if (version == 3)
    {
        strcopy(buf, maxlen, "offstyledb_v3.smx");
    }
    else
    {
        strcopy(buf, maxlen, "offstyledb.smx");
    }
}

void BuildSmNameForVersion(int version, char[] buf, int maxlen)
{
    if (version == 3)
    {
        strcopy(buf, maxlen, "offstyledb_v3");
    }
    else
    {
        strcopy(buf, maxlen, "offstyledb");
    }
}

