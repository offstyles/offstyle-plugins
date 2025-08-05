#include <sourcemod>
#include <keyvalues>
#include <ripext>
#include <sha1>
#include <sdktools>

#define API_BASE_URL "https://offstyles.tommyy.dev/api"

#pragma dynamic 0x2000000
#pragma newdecls required
#pragma semicolon 1

native float Shavit_GetWorldRecord(int style, int track);
native bool  Shavit_IsPracticeMode(int client);
native bool  Shavit_IsPaused(int client);
native bool  Shavit_StartReplay(int style, int track, float time, int bot, const char[] path);
native void  Shavit_StopReplay(int bot);
native int   Shavit_GetReplayBot(int style, int track);

forward void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath);
forward void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp);
forward void OnTimerFinished_Post(int client, float Time, int Type, int Style, bool tas, bool NewTime, int OldPosition, int NewPosition);

enum
{
    TimerVersion_Unknown,
    TimerVersion_shavit,
    TimerVersion_END
}

int  gI_TimerVersion     = TimerVersion_Unknown;
char gS_TimerVersion[][] = {
    "Unknown Timer",
    "shavit",
};

char gS_TimerNatives[][] = {
    "<none>",
    "Shavit_ChangeClientStyle",    // shavit
};

// SteamIDs which can fetch records from the server
int gI_SteamIDWhitelist[] = {
    903787042,      // jeft
    401295170       // tommy
};

int       gI_Tickrate = 0;
Database  gH_Database = null;
char      gS_MySQLPrefix[32];
ConVar    gCV_PublicIP = null;
char      gS_AuthKey[64];
ConVar    gCV_Authentication = null;
ConVar    sv_cheats          = null;
StringMap gM_StyleMapping    = null;
char      gS_StyleHash[160];

char      gS_BulkCode[64];
bool      gB_IsProcessingBatches = false;
int       gI_CurrentBatch = 0;
int       gI_TotalRecords = 0;
ArrayList  gA_AllRecords = null;
int       gI_BatchSize = 5000;
ConVar    gCV_ExtendedDebugging = null;

// GetReplay plugin variables
ConVar    gCV_ReplayPermissionFlag = null;
ConVar    gCV_ReplayBotLooping = null;
ConVar    gCV_ReplaySpectateDelay = null;
ConVar    gCV_ReplayMaxConcurrent = null;
ArrayList gA_ActiveReplays = null;
int       gI_ReplayBot = -1;
bool      gB_IsDownloadingReplay = false;
StringMap gM_ReplayCache = null;
char      gS_CurrentMap[64];

// Helper function for debug logging
void DebugPrint(const char[] format, any ...)
{
    if (gCV_ExtendedDebugging == null || !gCV_ExtendedDebugging.BoolValue)
    {
        return;
    }
    
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);
    PrintToServer("[OSdb Debug] %s", buffer);
}

public Plugin myinfo =
{
    name        = "Offstyle Database",
    author      = "shavit (Modified by Jeft & Tommy)",
    description = "Provides Offstyles with a database of bhop records.",
    version     = "0.0.2",
    url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("Shavit_GetWorldRecord");
    MarkNativeAsOptional("Shavit_StartReplay");
    MarkNativeAsOptional("Shavit_StopReplay");
    MarkNativeAsOptional("Shavit_GetReplayBot");
    return APLRes_Success;
}

public void OnPluginStart()
{
    RegConsoleCmd("osdb_get_all_wrs", Command_SendAllWRs);
    RegConsoleCmd("osdb_viewmapping", Command_ViewStyleMap);
    RegConsoleCmd("osdb_batch_status", Command_BatchStatus);
    RegConsoleCmd("osdb_refresh_mapping", Command_RefreshMapping);
    RegConsoleCmd("getreplay", Command_GetReplay, "Download and play replays from the database");
    RegAdminCmd("osdb_stop_replays", Command_StopReplays, ADMFLAG_RCON, "Stop all active replays");

    gCV_ExtendedDebugging = CreateConVar("OSdb_extended_debugging", "0", "Use extensive debugging messages?", FCVAR_DONTRECORD, true, 0.0, true, 1.0);
    gCV_PublicIP       = CreateConVar("OSdb_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.");
    gCV_Authentication = CreateConVar("OSdb_private_key", "super_secret_key", "Fill in your Offstyles Database API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.");
    
    // GetReplay ConVars
    gCV_ReplayPermissionFlag = CreateConVar("osdb_replay_flag", "b", "Admin flag required to use getreplay command (empty for all players)", FCVAR_NONE);
    gCV_ReplayBotLooping = CreateConVar("osdb_replay_loop", "0", "Enable replay bot looping", FCVAR_NONE, true, 0.0, true, 1.0);
    gCV_ReplaySpectateDelay = CreateConVar("osdb_replay_spectate_delay", "2.5", "Delay before spectating replay bot", FCVAR_NONE, true, 0.0, true, 10.0);
    gCV_ReplayMaxConcurrent = CreateConVar("osdb_replay_max_concurrent", "1", "Maximum number of concurrent replays", FCVAR_NONE, true, 1.0, true, 5.0);

    AutoExecConfig();

    sv_cheats       = FindConVar("sv_cheats");

    gM_StyleMapping = new StringMap();
    
    // Initialize GetReplay data structures
    gA_ActiveReplays = new ArrayList(ByteCountToCells(64));
    gM_ReplayCache = new StringMap();
    GetCurrentMap(gS_CurrentMap, sizeof(gS_CurrentMap));

    DebugPrint("OSdb plugin started, commands registered, ConVars created");

    // SourceJump_DebugLog("OSdb database plugin loaded.");
}

public void OnAllPluginsLoaded()
{
    for (int i = 1; i < TimerVersion_END; i++)
    {
        if (GetFeatureStatus(FeatureType_Native, gS_TimerNatives[i]) != FeatureStatus_Unknown)
        {
            gI_TimerVersion = i;
            PrintToServer("[OSdb] Detected timer plugin %s based on native %s", gS_TimerVersion[i], gS_TimerNatives[i]);

            break;
        }
    }

    char sError[255];
    strcopy(gS_MySQLPrefix, sizeof(gS_MySQLPrefix), "");

    switch (gI_TimerVersion)
    {
        case TimerVersion_Unknown: SetFailState("Supported timer plugin was not found.");

        case TimerVersion_shavit:
        {
            gH_Database = GetTimerDatabaseHandle();
            GetTimerSQLPrefix(gS_MySQLPrefix, sizeof(gS_MySQLPrefix));
        }
    }
}

public void OnConfigsExecuted()
{
    if (strlen(gS_AuthKey) == 0)
    {
        gCV_Authentication.GetString(gS_AuthKey, sizeof(gS_AuthKey));
    }
    gCV_Authentication.SetString("");

    GetStyleMapping();
}

public void OnMapStart()
{
    char sNewMap[64];
    GetCurrentMap(sNewMap, sizeof(sNewMap));
    
    // Clean up replay cache if map changed
    if (strcmp(gS_CurrentMap, sNewMap) != 0)
    {
        strcopy(gS_CurrentMap, sizeof(gS_CurrentMap), sNewMap);
        CleanupReplayCache();
        DebugPrint("Map changed to %s, cleaned up replay cache", sNewMap);
    }
}

void CleanupReplayCache()
{
    if (gM_ReplayCache != null)
    {
        gM_ReplayCache.Clear();
    }
    
    if (gA_ActiveReplays != null)
    {
        gA_ActiveReplays.Clear();
    }
    
    gI_ReplayBot = -1;
    gB_IsDownloadingReplay = false;
}

void GetStyleMapping(bool forceRefresh = false)
{
    DebugPrint("Starting style mapping request (forceRefresh: %s)", forceRefresh ? "true" : "false");
    
    if (!forceRefresh)
    {
        char temp[160];
        temp = gS_StyleHash;
        HashStyleConfig();

        if (strcmp(temp, gS_StyleHash) == 0)
        {
            DebugPrint("Style hash unchanged, skipping mapping request");
            return;
        }
    }
    else
    {
        DebugPrint("Force refresh requested, bypassing hash check");
    }

    DebugPrint("Style hash changed or forced refresh, requesting new mapping from server");

    HTTPRequest hHTTPRequest;
    JSONObject  hJSONObject = new JSONObject();

    hHTTPRequest            = new HTTPRequest(API_BASE_URL... "/style_mapping");
    AddHeaders(hHTTPRequest);

    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/shavit-styles.cfg");

    if (FileExists(sPath))
    {
        File fFile = OpenFile(sPath, "rb");

        if (fFile != null && fFile.Seek(0, SEEK_END))
        {
            int iSize = (fFile.Position + 1);
            fFile.Seek(0, SEEK_SET);

            char[] sFileContents = new char[iSize + 1];
            fFile.ReadString(sFileContents, (iSize + 1), iSize);
            delete fFile;

            char[] sFileContentsEncoded = new char[iSize * 2];
            Crypt_Base64Encode(sFileContents, sFileContentsEncoded, (iSize * 2), iSize);

            hJSONObject.SetString("data", sFileContentsEncoded);
        }
        else {
            delete fFile;
            delete hJSONObject;
            delete hHTTPRequest;
            return;
        }
    }
    else {
        SetFailState("Couldnt find configs/shavit-styles.cfg");
        return;
    }

    hHTTPRequest.Post(hJSONObject, Callback_OnStyleMapping);

    delete hJSONObject;
}

int ConvertStyle(int style)
{
    if (gM_StyleMapping == null)
    {
        LogError("[OSdb] Style mapping is null in ConvertStyle");
        DebugPrint("ConvertStyle called but style mapping is null");
        return -1;
    }
    
    char s[16];
    IntToString(style, s, sizeof(s));

    DebugPrint("Converting style %d (key: %s)", style, s);

    int out;
    if (gM_StyleMapping.GetValue(s, out))
    {
        DebugPrint("Style %d converted to %d", style, out);
        return out;
    }

    DebugPrint("Style %d not found in mapping, returning -1", style);
    return -1;
}

void HashStyleConfig()
{
    char sPath[PLATFORM_MAX_PATH];
    char hash[160];
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/shavit-styles.cfg");
    if (FileExists(sPath))
    {
        File fFile = OpenFile(sPath, "r");
        if (!SHA1File(fFile, hash))
        {
            LogError("Failed to hash shavit-styles.cfg");
            delete fFile;
            return;
        }

        delete fFile;
    }
    else {
        LogError("[OSdb] Failed to find shavit-styles.cfg");
        return;
    }

    gS_StyleHash = hash;
}

public void Callback_OnStyleMapping(HTTPResponse resp, any value)
{
    DebugPrint("Style mapping callback received - Status: %d", resp.Status);
    
    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        LogError("[OSdb] Style Mapping failed: status = %d, data = null", resp.Status);
        DebugPrint("Style mapping failed with status %d", resp.Status);
        SetFailState("Style Mapping returned non-ok response");
        return;
    }

    DebugPrint("Style mapping response received successfully");

    JSONObject data = view_as<JSONObject>(resp.Data);
    char       s_Data[512];
    data.GetString("data", s_Data, sizeof(s_Data));
    // dont think we need to do it here, but doing it anyway
    delete data;

    DebugPrint("Style mapping data extracted: %s", s_Data);

    // check if StringMap is still valid FUCKING INVALID HANDLE
    if (gM_StyleMapping == null)
    {
        LogError("[OSdb] Style mapping handle is null, recreating...");
        DebugPrint("Style mapping handle was null, recreating");
        gM_StyleMapping = new StringMap();
    }

    if (gM_StyleMapping.Size > 0)
    {
        DebugPrint("Clearing existing style mapping (%d entries)", gM_StyleMapping.Size);
        gM_StyleMapping.Clear();
    }

    const int MAX_STYLES = 128;    // fucking Hope people arent adding this many....
    char      parts[MAX_STYLES][8];

    int       count = ExplodeString(s_Data, ",", parts, sizeof(parts), sizeof(parts[]));
    
    DebugPrint("Processing style mapping with %d parts", count);

    for (int i = 0; i < count - 1; i += 2)
    {
        char key[8];
        strcopy(key, sizeof(key), parts[i]);

        int ivalue = StringToInt(parts[i + 1]);

        gM_StyleMapping.SetValue(key, ivalue);
        DebugPrint("Mapped style %s -> %d", key, ivalue);
    }
    
    DebugPrint("Style mapping completed with %d styles", gM_StyleMapping.Size);
}

public void OnMapStart()
{
    char sMapName[256];
    GetCurrentMap(sMapName, sizeof(sMapName));
    DebugPrint("Map started: %s", sMapName);
    
    gI_Tickrate = RoundToZero(1.0 / GetTickInterval());
    DebugPrint("Tickrate calculated: %d", gI_Tickrate);
}

public void OnMapEnd()
{   
    DebugPrint("Map ending, requesting style mapping");
    GetStyleMapping();
}

public void OnPluginEnd()
{
    DebugPrint("Plugin shutting down, cleaning up resources");
    
    if (gA_AllRecords != null)
    {
        DebugPrint("Cleaning up AllRecords ArrayList");
        delete gA_AllRecords;
        gA_AllRecords = null;
    }
    
    if (gM_StyleMapping != null)
    {
        DebugPrint("Cleaning up StyleMapping StringMap");
        delete gM_StyleMapping;
        gM_StyleMapping = null;
    }
}

public void OnPluginEnd()
{
    CleanupReplayCache();
    
    if (gA_ActiveReplays != null)
    {
        delete gA_ActiveReplays;
        gA_ActiveReplays = null;
    }
    
    if (gM_ReplayCache != null)
    {
        delete gM_ReplayCache;
        gM_ReplayCache = null;
    }
}

public Action Command_SendAllWRs(int client, int args)
{
    DebugPrint("Command_SendAllWRs called by client %d", client);
    
    int  iSteamID = GetSteamAccountID(client);
    bool bAllowed = false;

    DebugPrint("Checking authorization for SteamID %d", iSteamID);

    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
    {
        if (iSteamID == gI_SteamIDWhitelist[i])
        {
            bAllowed = true;
            DebugPrint("SteamID %d found in whitelist at index %d", iSteamID, i);
            break;
        }
    }

    if (!bAllowed)
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to fetch the records list.");
        DebugPrint("SteamID %d not authorized for bulk operations", iSteamID);
        return Plugin_Handled;
    }

    if (gB_IsProcessingBatches)
    {
        ReplyToCommand(client, "[OSdb] Already processing batches. Please wait for current operation to complete.");
        DebugPrint("Bulk operation request denied - already processing batches");
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[OSdb] Requesting bulk verification...");
    DebugPrint("Starting bulk verification request");
    RequestBulkVerification();

    return Plugin_Handled;
}

public Action Command_ViewStyleMap(int client, int args)
{
    DebugPrint("Command_ViewStyleMap called by client %d", client);
    
    if (gM_StyleMapping == null || gM_StyleMapping.Size == 0)
    {
        PrintToChat(client, "[OSdb] Style map is empty or null");
        DebugPrint("Style mapping is null or empty");
        return Plugin_Handled;
    }

    StringMapSnapshot snapshot = gM_StyleMapping.Snapshot();
    int               count    = snapshot.Length;

    DebugPrint("Displaying style mapping with %d entries", count);
    PrintToChat(client, "[OSdb] Style Mapping (%d entries):", count);

    char key[16];
    int  value;
    for (int i = 0; i < count; i++)
    {
        snapshot.GetKey(i, key, sizeof(key));
        gM_StyleMapping.GetValue(key, value);

        PrintToChat(client, "[StyleMap] %s: %d", key, value);
    }

    delete snapshot;
    return Plugin_Handled;
}

public Action Command_BatchStatus(int client, int args)
{
    if (!gB_IsProcessingBatches)
    {
        ReplyToCommand(client, "[OSdb] No batch processing currently active.");
        return Plugin_Handled;
    }
    
    int totalBatches = (gI_TotalRecords + gI_BatchSize - 1) / gI_BatchSize;
    int completedBatches = gI_CurrentBatch;
    int remainingBatches = totalBatches - completedBatches;
    
    ReplyToCommand(client, "[OSdb] Batch Processing Status:");
    ReplyToCommand(client, "  Progress: %d/%d batches completed", completedBatches, totalBatches);
    ReplyToCommand(client, "  Records: %d/%d processed", completedBatches * gI_BatchSize, gI_TotalRecords);
    ReplyToCommand(client, "  Remaining: %d batches", remainingBatches);
    
    return Plugin_Handled;
}

public Action Command_RefreshMapping(int client, int args)
{
    DebugPrint("Command_RefreshMapping called by client %d", client);
    
    int  iSteamID = GetSteamAccountID(client);
    bool bAllowed = false;

    DebugPrint("Checking authorization for SteamID %d", iSteamID);

    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
    {
        if (iSteamID == gI_SteamIDWhitelist[i])
        {
            bAllowed = true;
            DebugPrint("SteamID %d found in whitelist at index %d", iSteamID, i);
            break;
        }
    }

    if (!bAllowed)
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to refresh the style mapping.");
        DebugPrint("SteamID %d not authorized for style mapping refresh", iSteamID);
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[OSdb] Refreshing style mapping...");
    DebugPrint("Starting style mapping refresh");
    
    // recreate the StringMap if it's null
    if (gM_StyleMapping == null)
    {
        gM_StyleMapping = new StringMap();
        PrintToServer("[OSdb] Recreated null StringMap handle");
        DebugPrint("Recreated null StringMap handle");
    }
    
    GetStyleMapping(true);  // Force refresh
    return Plugin_Handled;
}

public Action Command_GetReplay(int client, int args)
{
    DebugPrint("Command_GetReplay called by client %d", client);
    
    if (client == 0)
    {
        ReplyToCommand(client, "[OSdb] This command can only be used in-game.");
        return Plugin_Handled;
    }
    
    // Check permissions
    char sFlag[8];
    gCV_ReplayPermissionFlag.GetString(sFlag, sizeof(sFlag));
    
    if (strlen(sFlag) > 0 && !CheckCommandAccess(client, "osdb_getreplay", ReadFlagString(sFlag)))
    {
        ReplyToCommand(client, "[OSdb] You don't have permission to use this command.");
        DebugPrint("Client %d denied access to getreplay command", client);
        return Plugin_Handled;
    }
    
    // Check if already downloading
    if (gB_IsDownloadingReplay)
    {
        ReplyToCommand(client, "[OSdb] Already downloading a replay. Please wait.");
        return Plugin_Handled;
    }
    
    // Check max concurrent replays
    int maxConcurrent = gCV_ReplayMaxConcurrent.IntValue;
    if (gA_ActiveReplays.Length >= maxConcurrent)
    {
        ReplyToCommand(client, "[OSdb] Maximum number of replays (%d) already active.", maxConcurrent);
        return Plugin_Handled;
    }
    
    DisplayReplayStyleMenu(client);
    return Plugin_Handled;
}

void DisplayReplayStyleMenu(int client)
{
    DebugPrint("DisplayReplayStyleMenu called for client %d", client);
    
    if (gM_StyleMapping == null || gM_StyleMapping.Size == 0)
    {
        ReplyToCommand(client, "[OSdb] Style mapping not available. Please try again later.");
        DebugPrint("Style mapping not available for replay menu");
        return;
    }
    
    Menu menu = new Menu(MenuHandler_ReplayStyle);
    menu.SetTitle("Select Replay Style");
    
    StringMapSnapshot snapshot = gM_StyleMapping.Snapshot();
    for (int i = 0; i < snapshot.Length; i++)
    {
        int keySize = snapshot.KeyBufferSize(i);
        char[] sStyle = new char[keySize];
        snapshot.GetKey(i, sStyle, keySize);
        
        int styleId;
        if (gM_StyleMapping.GetValue(sStyle, styleId))
        {
            char sDisplay[64];
            Format(sDisplay, sizeof(sDisplay), "%s (ID: %d)", sStyle, styleId);
            menu.AddItem(sStyle, sDisplay);
        }
    }
    
    delete snapshot;
    
    if (menu.ItemCount == 0)
    {
        menu.AddItem("", "No styles available", ITEMDRAW_DISABLED);
    }
    
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ReplayStyle(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char sStyle[64];
            menu.GetItem(param2, sStyle, sizeof(sStyle));
            
            DebugPrint("Client %d selected style: %s", param1, sStyle);
            DownloadReplay(param1, sStyle);
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }
    
    return 0;
}

void DownloadReplay(int client, const char[] sStyle)
{
    DebugPrint("DownloadReplay called for client %d, style %s", client, sStyle);
    
    // Check if this replay is already cached
    char sCacheKey[128];
    Format(sCacheKey, sizeof(sCacheKey), "%s_%s", gS_CurrentMap, sStyle);
    
    char sDummy[1];
    if (gM_ReplayCache.GetString(sCacheKey, sDummy, sizeof(sDummy)))
    {
        DebugPrint("Replay %s already cached, spawning bot directly", sCacheKey);
        SpawnReplayBot(client, sStyle, sCacheKey);
        return;
    }
    
    // Set downloading flag to prevent concurrent downloads
    gB_IsDownloadingReplay = true;
    
    PrintToChat(client, "[OSdb] Downloading replay for %s style...", sStyle);
    
    HTTPRequest hHTTPRequest = new HTTPRequest(API_BASE_URL ... "/get_replay");
    AddHeaders(hHTTPRequest);
    
    JSONObject hJSON = new JSONObject();
    hJSON.SetString("map", gS_CurrentMap);
    hJSON.SetString("style", sStyle);
    
    char sData[1024];
    hJSON.ToString(sData, sizeof(sData));
    hHTTPRequest.Post(hJSON, OnReplayDownloaded, GetClientUserId(client));
    
    delete hJSON;
    
    DebugPrint("Sent replay download request for map %s, style %s", gS_CurrentMap, sStyle);
}

public void OnReplayDownloaded(HTTPResponse response, int userid)
{
    gB_IsDownloadingReplay = false;
    
    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        DebugPrint("OnReplayDownloaded: Client disconnected");
        return;
    }
    
    if (response.Status != HTTPStatus_OK)
    {
        PrintToChat(client, "[OSdb] Failed to download replay (HTTP %d)", response.Status);
        DebugPrint("Replay download failed with HTTP status %d", response.Status);
        return;
    }
    
    JSONObject hJSON = view_as<JSONObject>(response.Data);
    if (hJSON == null)
    {
        PrintToChat(client, "[OSdb] Invalid response from server");
        DebugPrint("Invalid JSON response for replay download");
        return;
    }
    
    bool success = false;
    if (hJSON.HasKey("success"))
    {
        success = hJSON.GetBool("success");
    }
    
    if (!success)
    {
        char sError[256] = "Unknown error";
        if (hJSON.HasKey("error"))
        {
            hJSON.GetString("error", sError, sizeof(sError));
        }
        PrintToChat(client, "[OSdb] Failed to get replay: %s", sError);
        DebugPrint("Replay download failed: %s", sError);
        return;
    }
    
    // Get replay data
    char sReplayData[65536];
    if (!hJSON.HasKey("replay_data") || !hJSON.GetString("replay_data", sReplayData, sizeof(sReplayData)))
    {
        PrintToChat(client, "[OSdb] No replay data received");
        DebugPrint("No replay data in response");
        return;
    }
    
    char sStyle[64];
    if (!hJSON.HasKey("style") || !hJSON.GetString("style", sStyle, sizeof(sStyle)))
    {
        PrintToChat(client, "[OSdb] No style information received");
        DebugPrint("No style in response");
        return;
    }
    
    // Save replay to cache
    char sCacheKey[128];
    Format(sCacheKey, sizeof(sCacheKey), "%s_%s", gS_CurrentMap, sStyle);
    gM_ReplayCache.SetString(sCacheKey, sReplayData);
    
    DebugPrint("Replay cached with key: %s", sCacheKey);
    PrintToChat(client, "[OSdb] Replay downloaded successfully! Spawning bot...");
    
    // Spawn the replay bot
    SpawnReplayBot(client, sStyle, sCacheKey);
}

void SpawnReplayBot(int client, const char[] sStyle, const char[] sCacheKey)
{
    DebugPrint("SpawnReplayBot called for client %d, style %s", client, sStyle);
    
    // Check for duplicate active replays
    for (int i = 0; i < gA_ActiveReplays.Length; i++)
    {
        char sActiveKey[128];
        gA_ActiveReplays.GetString(i, sActiveKey, sizeof(sActiveKey));
        if (strcmp(sActiveKey, sCacheKey) == 0)
        {
            PrintToChat(client, "[OSdb] This replay is already being played!");
            DebugPrint("Attempted to spawn duplicate replay: %s", sCacheKey);
            return;
        }
    }
    
    // Get replay data from cache
    char sReplayData[65536];
    if (!gM_ReplayCache.GetString(sCacheKey, sReplayData, sizeof(sReplayData)))
    {
        PrintToChat(client, "[OSdb] Replay data not found in cache");
        DebugPrint("Replay data not found for key: %s", sCacheKey);
        return;
    }
    
    // Create replay bot through Shavit system
    // Note: This would require integration with Shavit's replay system
    // For now, we'll simulate the process and show the concept
    
    PrintToChat(client, "[OSdb] Creating replay bot for %s style...", sStyle);
    
    // Save replay file temporarily for bot to use
    char sReplayPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sReplayPath, sizeof(sReplayPath), "data/replaybot/temp_%s.replay", sCacheKey);
    
    // Decode base64 replay data and save to file
    if (SaveReplayFile(sReplayPath, sReplayData))
    {
        DebugPrint("Replay file saved to: %s", sReplayPath);
        
        // Add to active replays list
        gA_ActiveReplays.PushString(sCacheKey);
        
        // Try to spawn the bot (this would require Shavit integration)
        if (CreateReplayBot(sReplayPath, sStyle))
        {
            PrintToChat(client, "[OSdb] Replay bot created successfully!");
            
            // Schedule spectator switch with delay
            float fDelay = gCV_ReplaySpectateDelay.FloatValue;
            CreateTimer(fDelay, Timer_SpectateReplayBot, GetClientUserId(client));
            
            DebugPrint("Scheduled spectator switch for client %d with %.1f second delay", client, fDelay);
        }
        else
        {
            PrintToChat(client, "[OSdb] Failed to create replay bot");
            DebugPrint("Failed to create replay bot for %s", sCacheKey);
            
            // Remove from active replays since it failed
            int index = gA_ActiveReplays.FindString(sCacheKey);
            if (index != -1)
            {
                gA_ActiveReplays.Erase(index);
            }
        }
    }
    else
    {
        PrintToChat(client, "[OSdb] Failed to save replay file");
        DebugPrint("Failed to save replay file for %s", sCacheKey);
    }
}

bool SaveReplayFile(const char[] sPath, const char[] sBase64Data)
{
    DebugPrint("SaveReplayFile called for path: %s", sPath);
    
    // Create directory if it doesn't exist
    char sDir[PLATFORM_MAX_PATH];
    strcopy(sDir, sizeof(sDir), sPath);
    int lastSlash = FindCharInString(sDir, '/', true);
    if (lastSlash != -1)
    {
        sDir[lastSlash] = '\0';
        if (!DirExists(sDir))
        {
            CreateDirectory(sDir, 755);
            DebugPrint("Created directory: %s", sDir);
        }
    }
    
    // Decode base64 data
    int decodedSize = (strlen(sBase64Data) * 3) / 4;
    char[] decodedData = new char[decodedSize];
    
    if (!DecodeBase64(sBase64Data, decodedData, decodedSize))
    {
        DebugPrint("Failed to decode base64 replay data");
        return false;
    }
    
    File hFile = OpenFile(sPath, "wb");
    if (hFile == null)
    {
        DebugPrint("Failed to create replay file: %s", sPath);
        return false;
    }
    
    // Write decoded binary data
    hFile.Write(decodedData, decodedSize, 1);
    hFile.Close();
    
    DebugPrint("Replay file saved successfully with %d bytes", decodedSize);
    return true;
}

bool DecodeBase64(const char[] sInput, char[] sOutput, int maxlen)
{
    // Simple base64 decoder - in production you'd want a more robust implementation
    int inputLen = strlen(sInput);
    if (inputLen % 4 != 0)
    {
        return false;
    }
    
    char base64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int outputLen = 0;
    
    for (int i = 0; i < inputLen; i += 4)
    {
        if (outputLen >= maxlen - 3)
        {
            break;
        }
        
        int val1 = FindCharInString(base64_table, sInput[i]);
        int val2 = FindCharInString(base64_table, sInput[i + 1]);
        int val3 = (sInput[i + 2] == '=') ? 0 : FindCharInString(base64_table, sInput[i + 2]);
        int val4 = (sInput[i + 3] == '=') ? 0 : FindCharInString(base64_table, sInput[i + 3]);
        
        if (val1 == -1 || val2 == -1 || (sInput[i + 2] != '=' && val3 == -1) || (sInput[i + 3] != '=' && val4 == -1))
        {
            return false;
        }
        
        int combined = (val1 << 18) | (val2 << 12) | (val3 << 6) | val4;
        
        sOutput[outputLen++] = (combined >> 16) & 0xFF;
        if (sInput[i + 2] != '=')
        {
            sOutput[outputLen++] = (combined >> 8) & 0xFF;
        }
        if (sInput[i + 3] != '=')
        {
            sOutput[outputLen++] = combined & 0xFF;
        }
    }
    
    return true;
}

bool CreateReplayBot(const char[] sReplayPath, const char[] sStyle)
{
    DebugPrint("CreateReplayBot called for path: %s, style: %s", sReplayPath, sStyle);
    
    // Get style ID for Shavit integration
    int styleId;
    if (!gM_StyleMapping.GetValue(sStyle, styleId))
    {
        DebugPrint("Failed to get style ID for style: %s", sStyle);
        return false;
    }
    
    // Try to use Shavit's replay system if available
    if (GetFeatureStatus(FeatureType_Native, "Shavit_StartReplay") == FeatureStatus_Available)
    {
        DebugPrint("Using Shavit_StartReplay for bot creation");
        
        // Get or create a bot for this replay
        int bot = Shavit_GetReplayBot(styleId, 0); // Track 0 for main
        if (bot == -1)
        {
            // Need to create a bot
            bot = CreateFakeClient("Replay Bot");
            if (bot == 0)
            {
                DebugPrint("Failed to create fake client for replay bot");
                return false;
            }
            
            DebugPrint("Created fake client %d for replay bot", bot);
        }
        
        // Start the replay
        if (Shavit_StartReplay(styleId, 0, 0.0, bot, sReplayPath))
        {
            gI_ReplayBot = bot;
            DebugPrint("Successfully started Shavit replay with bot %d", bot);
            return true;
        }
        else
        {
            DebugPrint("Failed to start Shavit replay");
            if (IsValidClient(bot))
            {
                KickClient(bot);
            }
            return false;
        }
    }
    else
    {
        DebugPrint("Shavit replay natives not available, using fallback method");
        
        // Fallback: create a simple bot
        int bot = CreateFakeClient("Replay Bot");
        if (bot == 0)
        {
            DebugPrint("Failed to create fake client for replay bot");
            return false;
        }
        
        gI_ReplayBot = bot;
        DebugPrint("Created fallback replay bot with client %d", bot);
        
        // In a more complete implementation, you would:
        // 1. Load and parse the replay file
        // 2. Create a timer to play back the movements
        // 3. Handle bot positioning and animation
        
        return true;
    }
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

public Action Timer_SpectateReplayBot(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        DebugPrint("Timer_SpectateReplayBot: Client disconnected");
        return Plugin_Stop;
    }
    
    if (gI_ReplayBot == -1 || !IsValidClient(gI_ReplayBot))
    {
        PrintToChat(client, "[OSdb] Replay bot not available for spectating");
        DebugPrint("No valid replay bot available for spectating");
        return Plugin_Stop;
    }
    
    // Make client spectate the replay bot
    int currentTeam = GetClientTeam(client);
    if (currentTeam != 1) // Not already spectator
    {
        ChangeClientTeam(client, 1); // Move to spectators
        DebugPrint("Moved client %d to spectator team", client);
    }
    
    // Set spectator target and mode
    SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", gI_ReplayBot);
    SetEntProp(client, Prop_Send, "m_iObserverMode", 4); // OBS_MODE_IN_EYE
    
    PrintToChat(client, "[OSdb] Now spectating the replay bot!");
    DebugPrint("Client %d switched to spectate replay bot %d", client, gI_ReplayBot);
    
    return Plugin_Stop;
}

public Action Command_StopReplays(int client, int args)
{
    DebugPrint("Command_StopReplays called by client %d", client);
    
    int stoppedCount = 0;
    
    // Stop Shavit replays if available
    if (GetFeatureStatus(FeatureType_Native, "Shavit_StopReplay") == FeatureStatus_Available)
    {
        if (gI_ReplayBot != -1 && IsValidClient(gI_ReplayBot))
        {
            Shavit_StopReplay(gI_ReplayBot);
            DebugPrint("Stopped Shavit replay for bot %d", gI_ReplayBot);
            stoppedCount++;
        }
    }
    
    // Clean up any remaining bots
    if (gI_ReplayBot != -1 && IsValidClient(gI_ReplayBot))
    {
        KickClient(gI_ReplayBot, "Replay stopped by admin");
        DebugPrint("Kicked replay bot %d", gI_ReplayBot);
        stoppedCount++;
    }
    
    // Clear all active replays
    if (gA_ActiveReplays != null)
    {
        gA_ActiveReplays.Clear();
    }
    
    gI_ReplayBot = -1;
    
    ReplyToCommand(client, "[OSdb] Stopped %d active replay(s)", stoppedCount);
    DebugPrint("Stopped %d active replays", stoppedCount);
    
    return Plugin_Handled;
}

public void OnClientDisconnect(int client)
{
    // Clean up if this was our replay bot
    if (client == gI_ReplayBot)
    {
        DebugPrint("Replay bot %d disconnected, cleaning up", client);
        gI_ReplayBot = -1;
        
        // Remove from active replays list
        if (gA_ActiveReplays != null)
        {
            // Note: In a more complete implementation, you'd track which
            // replay this bot was associated with and remove only that one
            gA_ActiveReplays.Clear();
        }
    }
}

// for records only, useless since we want every time submitted
// public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath)
// {
//     if (track != 0 || gI_TimerVersion != TimerVersion_shavit) {
//         return;
//     }

//     // uncomment this if we want to only send records
//     // if (time > Shavit_GetWorldRecord(style, track)) {
//     //     return;
//     // }

//     char sMap[64];
//     GetCurrentMap(sMap, sizeof(sMap));
//     GetMapDisplayName(sMap, sMap, sizeof(sMap));

//     char sSteamID[32];
//     GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

//     char sName[MAX_NAME_LENGTH];
//     GetClientName(client, sName, sizeof(sName));

//     char sDate[32];
//     FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", GetTime());

//     SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style);
// }
public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
    // oldtime <= time is a filter to prevent non-pbs from being submitted
    // also means times wont submit if they never beat ur pb, like in the case
    // of a skip being removed, but thats up the to server to delete the time
    if (track != 0 || gI_TimerVersion != TimerVersion_shavit || (oldtime != 0.0 && oldtime <= time) || Shavit_IsPracticeMode(client) || Shavit_IsPaused(client))
    {
        // skipping record
        return;
    }

    bool isWR;
    if (time > Shavit_GetWorldRecord(style, track))
    {
        isWR = false;
    }
    else {
        isWR = true;
    }

    char sMap[64];
    GetCurrentMap(sMap, sizeof(sMap));
    GetMapDisplayName(sMap, sMap, sizeof(sMap));

    char sSteamID[32];
    GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));

    int sDate = GetTime();

    SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style, isWR);
}

void SendRecord(char[] sMap, char[] sSteamID, char[] sName, int sDate, float time, float sync, int strafes, int jumps, int style, bool isWR)
{
    DebugPrint("SendRecord called: Map=%s, SteamID=%s, Name=%s, Time=%.3f, Style=%d, IsWR=%s", 
               sMap, sSteamID, sName, time, style, isWR ? "true" : "false");
    
    if (sv_cheats.BoolValue)
    {
        LogError("[OSdb] Attempted to submit record with sv_cheats enabled. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
                 sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);
        DebugPrint("Record submission blocked due to sv_cheats being enabled");
        return;
    }

    int n_Style = ConvertStyle(style);
    if (n_Style == -1)
    {
        DebugPrint("Style conversion failed for style %d, aborting record submission", style);
        return;
    }

    DebugPrint("Style %d converted to %d, preparing HTTP request", style, n_Style);

    HTTPRequest hHTTPRequest;
    JSONObject  hJSON = new JSONObject();

    hHTTPRequest      = new HTTPRequest(API_BASE_URL... "/submit_record");
    AddHeaders(hHTTPRequest);
    hJSON.SetString("map", sMap);
    hJSON.SetString("steamid", sSteamID);
    hJSON.SetString("name", sName);
    hJSON.SetFloat("time", time);
    hJSON.SetFloat("sync", sync);
    hJSON.SetInt("strafes", strafes);
    hJSON.SetInt("jumps", jumps);
    hJSON.SetInt("date", sDate);
    hJSON.SetInt("tickrate", gI_Tickrate);
    hJSON.SetInt("style", n_Style);
    hJSON.SetNull("replayfile");

    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "data/replaybot/%d/%s.replay", style, sMap);

    // since we arent considering bonuses, we only have to think about track 0 (main)
    if (FileExists(sPath) && isWR)
    {
        File fFile = OpenFile(sPath, "rb");

        if (fFile != null && fFile.Seek(0, SEEK_END))
        {
            int iSize = (fFile.Position + 1);
            fFile.Seek(0, SEEK_SET);

            char[] sFileContents = new char[iSize + 1];
            fFile.ReadString(sFileContents, (iSize + 1), iSize);
            delete fFile;

            char[] sFileContentsEncoded = new char[iSize * 2];
            Crypt_Base64Encode(sFileContents, sFileContentsEncoded, (iSize * 2), iSize);

            hJSON.SetString("replayfile", sFileContentsEncoded);
        }
        delete fFile;
    }

    hHTTPRequest.Post(hJSON, OnHttpDummyCallback);
    delete hJSON;
}

void ProcessNextBatch()
{
    if (gA_AllRecords == null || gA_AllRecords.Length == 0)
    {
        PrintToServer("[osdb] No more records to process, finishing batch operation.");
        FinishBatchProcessing();
        return;
    }
    
    int startIndex = gI_CurrentBatch * gI_BatchSize;
    int endIndex = startIndex + gI_BatchSize;
    
    if (startIndex >= gI_TotalRecords)
    {
        PrintToServer("[osdb] All batches processed, finishing operation.");
        FinishBatchProcessing();
        return;
    }
    
    if (endIndex > gI_TotalRecords)
    {
        endIndex = gI_TotalRecords;
    }
    
    PrintToServer("[osdb] Processing batch %d (%d-%d of %d records)...", 
                    gI_CurrentBatch + 1, startIndex + 1, endIndex, gI_TotalRecords);
    
    JSONArray hArray = new JSONArray();
    
    for (int i = startIndex; i < endIndex; i++)
    {
        JSONObject hJSON = view_as<JSONObject>(gA_AllRecords.Get(i));
        hArray.Push(hJSON);
    }
    
    HTTPRequest hHTTPRequest = new HTTPRequest(API_BASE_URL... "/bulk_records");
    AddHeaders(hHTTPRequest);
    
    JSONObject hRecordsList = new JSONObject();
    hRecordsList.Set("records", hArray);
    
    DataPack pack = new DataPack();
    pack.WriteCell(gI_CurrentBatch);
    pack.WriteCell(hArray.Length);
    
    hHTTPRequest.Post(hRecordsList, Callback_OnBatchSent, pack);
    
    delete hRecordsList;
}

public void Callback_OnBatchSent(HTTPResponse resp, any value)
{
    DataPack pack = view_as<DataPack>(value);
    pack.Reset();
    int batchNumber = pack.ReadCell();
    int batchSize = pack.ReadCell();
    delete pack;
    
    if (resp.Status != HTTPStatus_OK)
    {
        LogError("[osdb] Batch %d failed to send: status = %d", batchNumber + 1, resp.Status);
        PrintToServer("[osdb] Batch %d failed, stopping batch processing.", batchNumber + 1);
        FinishBatchProcessing();
        return;
    }
    
    PrintToServer("[osdb] Batch %d (%d records) sent successfully.", batchNumber + 1, batchSize);
    
    gI_CurrentBatch++;
    ProcessNextBatch();
}

void FinishBatchProcessing()
{
    gB_IsProcessingBatches = false;
    gI_CurrentBatch = 0;
    gI_TotalRecords = 0;
    
    if (gA_AllRecords != null)
    {
        delete gA_AllRecords;
        gA_AllRecords = null;
    }
    
    gS_BulkCode[0] = '\0';
    
    PrintToServer("[osdb] Batch processing completed.");
}

void OnHttpDummyCallback(HTTPResponse resp, any value)
{
    if (resp.Status != HTTPStatus_OK)
    {
        return;
    }

    return;
}

void RequestBulkVerification()
{
    DebugPrint("Starting bulk verification request");
    
    HTTPRequest hHTTPRequest = new HTTPRequest(API_BASE_URL... "/bulk_verification");
    AddHeaders(hHTTPRequest);

    JSONObject hVerificationBody = new JSONObject();
    
    DebugPrint("Sending bulk verification request to server");
    hHTTPRequest.Post(hVerificationBody, Callback_OnBulkVerification);

    delete hVerificationBody;
    hVerificationBody = null;
}

public void Callback_OnBulkVerification(HTTPResponse resp, any value)
{
    DebugPrint("Bulk verification callback received - Status: %d", resp.Status);
    
    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        LogError("[OSdb] Bulk verification failed: status = %d, data = null", resp.Status);
        DebugPrint("Bulk verification failed with status %d", resp.Status);
        return;
    }

    DebugPrint("Bulk verification response received successfully");

    JSONObject data = view_as<JSONObject>(resp.Data);
    
    if (!data.HasKey("key_to_send_times"))
    {
        LogError("[OSdb] Bulk verification response missing 'key_to_send_times' field");
        DebugPrint("Bulk verification response missing required field");
        delete data;
        return;
    }
    
    data.GetString("key_to_send_times", gS_BulkCode, sizeof(gS_BulkCode));
    delete data;
    
    DebugPrint("Bulk code received: %s", gS_BulkCode);
    
    PrintToServer("[OSdb] Bulk verification successful, starting record collection...");
    SendRecordDatabase();
}

void SendRecordDatabase()
{
    DebugPrint("Starting record database query");
    
    char sQuery[1024];
    switch (gI_TimerVersion)
    {
        case TimerVersion_shavit:
        {
            // Original, incase we fuck it up somehow
            // FormatEx(sQuery, sizeof(sQuery),
            // 	"SELECT a.map, u.auth AS steamid, u.name, a.time, a.sync, a.strafes, a.jumps, a.date, a.style FROM %splayertimes a " ...
            // 	"JOIN (SELECT MIN(time) time, map, style, track FROM %splayertimes GROUP by map, style, track) b " ...
            // 	"JOIN %susers u ON a.time = b.time AND a.auth = u.auth AND a.map = b.map AND a.style = b.style AND a.track = b.track " ...
            // 	// "WHERE a.style = 0 AND a.track = 0 " ...
            // 	"WHERE a.track = 0" ...
            // 	"ORDER BY a.date DESC;", gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);

            FormatEx(sQuery, sizeof(sQuery),
                     "SELECT a.map, u.auth AS steamid, u.name, a.time, a.sync, a.strafes, a.jumps, a.date, a.style FROM %splayertimes a " ... "JOIN (SELECT MIN(time) time, map, style, track FROM %splayertimes GROUP by map, style, track) b " ... "JOIN %susers u ON a.time = b.time AND a.auth = u.auth AND a.map = b.map AND a.style = b.style AND a.track = b.track " ...
                     // "WHERE a.style = 0 AND a.track = 0 " ...
                     "WHERE a.track = 0 " ... "ORDER BY a.date DESC;",
                     gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);
        }
    }

    gH_Database.Query(SQL_GetRecords_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_GetRecords_Callback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("[osdb] SQL_GetRecords_Callback results are null, SQL error: %s", error);
        return;
    }

    if (results.RowCount == 0)
    {
        LogError("[osdb] SQL_GetRecords_Callback rowcount is 0");
        return;
    }

    gB_IsProcessingBatches = true;
    gI_CurrentBatch = 0;
    gI_TotalRecords = 0;
    
    if (gA_AllRecords != null)
    {
        delete gA_AllRecords;
    }
    gA_AllRecords = new ArrayList();

    PrintToServer("[osdb] Collecting %d records for batch processing...", results.RowCount);

    while (results.FetchRow())
    {
        JSONObject hJSON = GetTimeJsonFromResult(results);
        if (hJSON.GetInt("style") != -1) {
            gA_AllRecords.Push(hJSON);
            gI_TotalRecords++;
        }
        else {
            delete hJSON;
        }
    }
    
    PrintToServer("[osdb] Collected %d records, starting batch processing...", gI_TotalRecords);
    ProcessNextBatch();
}

JSONObject GetTimeJsonFromResult(DBResultSet results)
{
    char sMap[64];
    results.FetchString(0, sMap, sizeof(sMap));

    char sSteamID[32];
    results.FetchString(1, sSteamID, sizeof(sSteamID));

    switch (gI_TimerVersion)
    {
        // we dont Really need to do this switch case shit anymore, but whatever
        case TimerVersion_shavit:
        {
            if (StrContains(sSteamID, "[U:1:]", false) == -1)
            {
                Format(sSteamID, sizeof(sSteamID), "[u:1:%s]", sSteamID);
            }
        }
    }

    char sName[MAX_NAME_LENGTH];
    results.FetchString(2, sName, MAX_NAME_LENGTH);

    JSONObject hJSON = new JSONObject();
    hJSON.SetString("map", sMap);
    hJSON.SetString("steamid", sSteamID);
    hJSON.SetString("name", sName);
    hJSON.SetFloat("time", results.FetchFloat(3));
    hJSON.SetFloat("sync", results.FetchFloat(4));
    hJSON.SetInt("strafes", results.FetchInt(5));
    hJSON.SetInt("jumps", results.FetchInt(6));
    hJSON.SetInt("date", results.FetchInt(7));
    hJSON.SetInt("tickrate", gI_Tickrate);
    hJSON.SetInt("style", ConvertStyle(results.FetchInt(8)));

    return hJSON;
}

// stocks from shavit.inc
// connects synchronously to the bhoptimer database
// calls errors if needed
Database GetTimerDatabaseHandle()
{
    Database db = null;
    char     sError[255];

    if (SQL_CheckConfig("shavit"))
    {
        if ((db = SQL_Connect("shavit", true, sError, sizeof(sError))) == null)
        {
            SetFailState("OSdb plugin startup failed. Reason: %s", sError);
        }
    }
    else
    {
        db = SQLite_UseDatabase("shavit", sError, sizeof(sError));
    }

    return db;
}

// retrieves the table prefix defined in configs/shavit-prefix.txt
void GetTimerSQLPrefix(char[] buffer, int maxlen)
{
    char sFile[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sFile, sizeof(sFile), "configs/shavit-prefix.txt");

    File fFile = OpenFile(sFile, "r");

    if (fFile == null)
    {
        delete fFile;
        SetFailState("Cannot open \"configs/shavit-prefix.txt\". Make sure this file exists and that the server has read permissions to it.");
    }

    char sLine[PLATFORM_MAX_PATH * 2];

    if (fFile.ReadLine(sLine, sizeof(sLine)))
    {
        TrimString(sLine);
        strcopy(buffer, maxlen, sLine);
    }

    delete fFile;
}

void AddHeaders(HTTPRequest req)
{
    char sPublicIP[32];
    gCV_PublicIP.GetString(sPublicIP, sizeof(sPublicIP));

    char sHostname[128];
    FindConVar("hostname").GetString(sHostname, sizeof(sHostname));

    req.SetHeader("public_ip", sPublicIP);
    req.SetHeader("hostname", sHostname);
    req.SetHeader("auth", gS_AuthKey);
    req.SetHeader("timer_plugin", gS_TimerVersion[gI_TimerVersion]);
    
    if (gB_IsProcessingBatches && strlen(gS_BulkCode) > 0)
    {
        req.SetHeader("bulk_verify", gS_BulkCode);
    }
}

// from smlib
/*
 * Encodes a string or binary data into Base64
 *
 * @param sString		The input string or binary data to be encoded.
 * @param sResult		The storage buffer for the Base64-encoded result.
 * @param len			The maximum length of the storage buffer, in characters/bytes.
 * @param sourcelen 	(optional): The number of characters or length in bytes to be read from the input source.
 *						This is not needed for a text string, but is important for binary data since there is no end-of-line character.
 * @return				The length of the written Base64 string, in bytes.
 */
int Crypt_Base64Encode(const char[] sString, char[] sResult, int len, int sourcelen = 0)
{
    char base64_sTable[]  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int  base64_cFillChar = '=';

    int  nLength;
    int  resPos;

    if (sourcelen > 0)
    {
        nLength = sourcelen;
    }
    else
    {
        nLength = strlen(sString);
    }

    for (int nPos = 0; nPos < nLength; nPos++)
    {
        int cCode;

        cCode = (sString[nPos] >> 2) & 0x3f;
        resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);
        cCode = (sString[nPos] << 4) & 0x3f;

        if (++nPos < nLength)
        {
            cCode |= (sString[nPos] >> 4) & 0x0f;
        }

        resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);

        if (nPos < nLength)
        {
            cCode = (sString[nPos] << 2) & 0x3f;

            if (++nPos < nLength)
            {
                cCode |= (sString[nPos] >> 6) & 0x03;
            }

            resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);
        }
        else
        {
            nPos++;
            resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_cFillChar);
        }

        if (nPos < nLength)
        {
            cCode = sString[nPos] & 0x3f;
            resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);
        }
        else
        {
            resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_cFillChar);
        }
    }

    return resPos;
}
