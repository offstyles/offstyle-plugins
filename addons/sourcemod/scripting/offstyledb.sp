#include <convar_class>
#include <sourcemod>
#include <keyvalues>
#include <ripext>
#include <sha1>

#undef REQUIRE_PLUGIN
#include <shavit>

#define API_BASE_URL "https://offstyles.net/api"

#pragma dynamic 104857600
#pragma newdecls required
#pragma semicolon 1

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

char      gS_BulkCode[128];
bool      gB_IsProcessingBatches = false;
int       gI_CurrentBatch = 0;
int       gI_TotalRecords = 0;
ArrayList  gA_AllRecords = null;
int       gI_BatchSize = 5000;
ConVar    gCV_ExtendedDebugging = null;
ConVar    gCV_SubmitMode = null;         // 0=WRs only, 1=all times (default)
ConVar    gCV_BulkUploadMode = null;     // -1=no times, 0=WRs only (default), 1=all times  
ConVar    gCV_ReplayMode = null;         // -1=never, 0=WRs only (default), 1=all times

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

int GetShavitMajorVersion() {
    int major = SHAVIT_VERSION_MAJOR;

    return major;
}

bool IsSubmittableFinish(int client, int track)
{
    return track == 0
        && gI_TimerVersion == TimerVersion_shavit
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && !Shavit_IsPracticeMode(client)
        && !Shavit_IsPaused(client);
}

void GetTempReplayPath(int client, char[] buffer, int maxlen)
{
    BuildPath(Path_SM, buffer, maxlen, "data/osdb_tmp/%d_%d.replay", client, GetTime());
}

bool IsTempReplayPath(const char[] path)
{
    return StrContains(path, "osdb_tmp") != -1;
}

void EnsureTempReplayDir()
{
    char sDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sDir, sizeof(sDir), "data/osdb_tmp");

    if (!DirExists(sDir))
    {
        CreateDirectory(sDir, 511);
        DebugPrint("[OSdb] Created temp replay directory: %s", sDir);
        return;
    }

    // Sweep leftover temp files from previous sessions (uploads that never completed)
    DirectoryListing dir = OpenDirectory(sDir);
    if (dir == null)
    {
        return;
    }

    char sEntry[PLATFORM_MAX_PATH];
    char sFullPath[PLATFORM_MAX_PATH];
    int  swept = 0;
    FileType type;
    while (dir.GetNext(sEntry, sizeof(sEntry), type))
    {
        if (type != FileType_File)
        {
            continue;
        }
        FormatEx(sFullPath, sizeof(sFullPath), "%s/%s", sDir, sEntry);
        if (DeleteFile(sFullPath))
        {
            swept++;
        }
    }
    delete dir;

    if (swept > 0)
    {
        DebugPrint("[OSdb] Swept %d orphan temp replays", swept);
    }
}

public Plugin myinfo =
{
    name        = "Offstyle Database",
    author      = "shavit (Modified by Jeft & Tommy)",
    description = "Provides Offstyles with a database of bhop records.",
    version     = "4.1.0",
    url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("Shavit_GetWorldRecord");
    MarkNativeAsOptional("Shavit_OnReplaySaved");
    MarkNativeAsOptional("OnTimerFinished_Post");
    MarkNativeAsOptional("Shavit_OnFinish");
    MarkNativeAsOptional("Shavit_IsPracticeMode");
    MarkNativeAsOptional("Shavit_IsPaused");
    MarkNativeAsOptional("Shavit_AddAdditionalReplayPathsHere");
    MarkNativeAsOptional("Shavit_AlsoSaveReplayTo");

    return APLRes_Success;
}

public void OnPluginStart()
{
    int smv = GetShavitMajorVersion();
    if (smv < 4) {
        PrintToServer("[OSdb] smv = %d", smv);
        // DebugPrint("[OSdb] bhoptimer version <4 detected, use the v3 version here https://github.com/offstyles/offstyle-plugins/tree/v3");
        SetFailState("[OSdb] bhoptimer version <4 detected, use the v3 version here https://github.com/offstyles/offstyle-plugins/tree/v3");
    } else if (smv >= 5) {
        // probably needless but future proofing is nice ig
        DebugPrint("[OSdb] bhoptimer version >4 detected, there may be compatibility issues, check for update here https://github.com/offstyles/offstyle-plugins/releases");
        // SetFailState("[OSdb] bhoptimer version >4 detected, there may be compatibility issues, check for update here https://github.com/offstyles/offstyle-plugins/releases");
    }

    RegConsoleCmd("osdb_get_all_wrs", Command_SendAllWRs);
    RegConsoleCmd("osdb_viewmapping", Command_ViewStyleMap);
    RegConsoleCmd("osdb_batch_status", Command_BatchStatus);
    RegConsoleCmd("osdb_refresh_mapping", Command_RefreshMapping);

    gCV_ExtendedDebugging = new Convar("OSdb_extended_debugging", "0", "Use extensive debugging messages?", 0, true, 0.0, true, 1.0);
    gCV_SubmitMode = new Convar("OSdb_submit_mode", "1", "Submit only WRs (0) or all times (1)?", 0, true, 0.0, true, 1.0);
    gCV_BulkUploadMode = new Convar("OSdb_bulk_upload_mode", "0", "Bulk upload (database time sync): no times (-1), only WRs (0), or all times (1)?", 0, true, -1.0, true, 1.0);
    gCV_ReplayMode = new Convar("OSdb_replay_mode", "0", "Replay attachment: never (-1), WRs only (0), or all times (1)?", 0, true, -1.0, true, 1.0);
    gCV_PublicIP       = new Convar("OSdb_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.", 0);
    gCV_Authentication = new Convar("OSdb_private_key", "super_secret_key", "Fill in your Offstyles Database API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.", 0);

    Convar.AutoExecConfig();

    sv_cheats       = FindConVar("sv_cheats");

    gM_StyleMapping = new StringMap();

    EnsureTempReplayDir();

    DebugPrint("[OSdb] OSdb plugin started, commands registered, ConVars created");

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

    strcopy(gS_MySQLPrefix, sizeof(gS_MySQLPrefix), "");

    switch (gI_TimerVersion)
    {
        case TimerVersion_Unknown: SetFailState("[OSdb] Supported timer plugin was not found.");

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

void GetStyleMapping(bool forceRefresh = false)
{
    DebugPrint("[OSdb] Starting style mapping request (forceRefresh: %s)", forceRefresh ? "true" : "false");
    
    if (!forceRefresh)
    {
        char temp[160];
        temp = gS_StyleHash;
        HashStyleConfig();

        if (strcmp(temp, gS_StyleHash) == 0)
        {
            DebugPrint("[OSdb] Style hash unchanged, skipping mapping request");
            return;
        }
    }
    else
    {
        DebugPrint("[OSdb] Force refresh requested, bypassing hash check");
    }

    DebugPrint("[OSdb] Style hash changed or forced refresh, requesting new mapping from server");

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
            int iSize = fFile.Position;
            fFile.Seek(0, SEEK_SET);

            char[] sFileContents = new char[iSize + 1];
            fFile.ReadString(sFileContents, iSize + 1, iSize);
            delete fFile;

            char[] sFileContentsEncoded = new char[iSize * 2];
            Crypt_Base64Encode(sFileContents, sFileContentsEncoded, iSize * 2, iSize);

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
        DebugPrint("[OSdb] ConvertStyle called but style mapping is null");
        return -1;
    }
    
    char s[16];
    IntToString(style, s, sizeof(s));

    DebugPrint("[OSdb] Converting style %d (key: %s)", style, s);

    int out;
    if (gM_StyleMapping.GetValue(s, out))
    {
        DebugPrint("[OSdb] Style %d converted to %d", style, out);
        return out;
    }

    DebugPrint("[OSdb] Style %d not found in mapping, returning -1", style);
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
    DebugPrint("[OSdb] Style mapping callback received - Status: %d", resp.Status);
    
    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        LogError("[OSdb] Style Mapping failed: status = %d, data = null", resp.Status);
        DebugPrint("[OSdb] Style mapping failed with status %d", resp.Status);
        SetFailState("[OSdb] Style Mapping returned non-ok response");
        return;
    }

    DebugPrint("[OSdb] Style mapping response received successfully");

    JSONObject data = view_as<JSONObject>(resp.Data);
    char       s_Data[512];
    data.GetString("data", s_Data, sizeof(s_Data));
    // dont think we need to do it here, but doing it anyway
    delete data;

    DebugPrint("[OSdb] Style mapping data extracted: %s", s_Data);

    // check if StringMap is still valid FUCKING INVALID HANDLE
    if (gM_StyleMapping == null)
    {
        LogError("[OSdb] Style mapping handle is null, recreating...");
        DebugPrint("[OSdb] Style mapping handle was null, recreating");
        gM_StyleMapping = new StringMap();
    }

    if (gM_StyleMapping.Size > 0)
    {
        DebugPrint("[OSdb] Clearing existing style mapping (%d entries)", gM_StyleMapping.Size);
        gM_StyleMapping.Clear();
    }

    const int MAX_STYLES = 512;    // fucking Hope people arent adding this many....
    char      parts[MAX_STYLES][8];

    int       count = ExplodeString(s_Data, ",", parts, sizeof(parts), sizeof(parts[]));
    
    DebugPrint("[OSdb] Processing style mapping with %d parts", count);

    for (int i = 0; i < count - 1; i += 2)
    {
        char key[8];
        strcopy(key, sizeof(key), parts[i]);

        int ivalue = StringToInt(parts[i + 1]);

        gM_StyleMapping.SetValue(key, ivalue);
        DebugPrint("[OSdb] Mapped style %s -> %d", key, ivalue);
    }
    
    DebugPrint("[OSdb] Style mapping completed with %d styles", gM_StyleMapping.Size);
}

public void OnMapStart()
{
    char sMapName[256];
    GetCurrentMap(sMapName, sizeof(sMapName));
    DebugPrint("[OSdb] Map started: %s", sMapName);
    
    gI_Tickrate = RoundToZero(1.0 / GetTickInterval());
    DebugPrint("[OSdb] Tickrate calculated: %d", gI_Tickrate);
}

public void OnMapEnd()
{   
    DebugPrint("[OSdb] Map ending, requesting style mapping");
    GetStyleMapping();
}

public void OnPluginEnd()
{
    DebugPrint("[OSdb] Plugin shutting down, cleaning up resources");
    
    if (gA_AllRecords != null)
    {
        DebugPrint("[OSdb] Cleaning up AllRecords ArrayList");
        delete gA_AllRecords;
        gA_AllRecords = null;
    }
    
    if (gM_StyleMapping != null)
    {
        DebugPrint("[OSdb] Cleaning up StyleMapping StringMap");
        delete gM_StyleMapping;
        gM_StyleMapping = null;
    }
}

public Action Command_SendAllWRs(int client, int args)
{
    DebugPrint("[OSdb] Command_SendAllWRs called by client %d", client);
    
    int  iSteamID = GetSteamAccountID(client);
    bool bAllowed = false;

    DebugPrint("[OSdb] Checking authorization for SteamID %d", iSteamID);

    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
    {
        if (iSteamID == gI_SteamIDWhitelist[i])
        {
            bAllowed = true;
            DebugPrint("[OSdb] SteamID %d found in whitelist at index %d", iSteamID, i);
            break;
        }
    }

    if (!bAllowed)
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to fetch the records list.");
        DebugPrint("[OSdb] SteamID %d not authorized for bulk operations", iSteamID);
        return Plugin_Handled;
    }

    if (gB_IsProcessingBatches)
    {
        ReplyToCommand(client, "[OSdb] Already processing batches. Please wait for current operation to complete.");
        DebugPrint("[OSdb] Bulk operation request denied - already processing batches");
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[OSdb] Requesting bulk verification...");
    DebugPrint("[OSdb] Starting bulk verification request");
    RequestBulkVerification();

    return Plugin_Handled;
}

public Action Command_ViewStyleMap(int client, int args)
{
    DebugPrint("[OSdb] Command_ViewStyleMap called by client %d", client);
    
    if (gM_StyleMapping == null || gM_StyleMapping.Size == 0)
    {
        PrintToChat(client, "[OSdb] Style map is empty or null");
        DebugPrint("[OSdb] Style mapping is null or empty");
        return Plugin_Handled;
    }

    StringMapSnapshot snapshot = gM_StyleMapping.Snapshot();
    int               count    = snapshot.Length;

    DebugPrint("[OSdb] Displaying style mapping with %d entries", count);
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
    DebugPrint("[OSdb] Command_RefreshMapping called by client %d", client);
    
    int  iSteamID = GetSteamAccountID(client);
    bool bAllowed = false;

    DebugPrint("[OSdb] Checking authorization for SteamID %d", iSteamID);

    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
    {
        if (iSteamID == gI_SteamIDWhitelist[i])
        {
            bAllowed = true;
            DebugPrint("[OSdb] SteamID %d found in whitelist at index %d", iSteamID, i);
            break;
        }
    }

    if (!bAllowed)
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to refresh the style mapping.");
        DebugPrint("[OSdb] SteamID %d not authorized for style mapping refresh", iSteamID);
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[OSdb] Refreshing style mapping...");
    DebugPrint("[OSdb] Starting style mapping refresh");
    
    // recreate the StringMap if it's null
    if (gM_StyleMapping == null)
    {
        gM_StyleMapping = new StringMap();
        PrintToServer("[OSdb] Recreated null StringMap handle");
        DebugPrint("[OSdb] Recreated null StringMap handle");
    }
    
    GetStyleMapping(true);  // Force refresh
    return Plugin_Handled;
}

// Handles non-WR PB submission when replay_mode=1. Either registers a temp replay
// path for shavit to save to (normal case), or submits the record directly without
// a replay when shavit refuses to save (istoolong). OnFinish already deferred.
// Fires between Shavit_OnFinish and Shavit_OnReplaySaved for every finish.
public void Shavit_AddAdditionalReplayPathsHere(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong)
{
    if (gCV_ReplayMode.IntValue != 1 || isbestreplay)
    {
        return;
    }

    if (!IsSubmittableFinish(client, track) || oldtime <= time)
    {
        return;
    }

    if (gCV_SubmitMode.IntValue == 0)
    {
        return;
    }

    float fWR = Shavit_GetWorldRecord(style, track);
    if (fWR == 0.0 || time <= fWR)
    {
        // Actually a WR - handled via shavit's canonical replay path
        return;
    }

    if (istoolong)
    {
        // Shavit won't save a replay for this run, but OnFinish deferred the
        // submission to us. Submit the record now without a replay attachment.
        DebugPrint("[OSdb] Non-WR replay too long, submitting record without replay");

        char sMap[64];
        GetCurrentMap(sMap, sizeof(sMap));
        GetMapDisplayName(sMap, sMap, sizeof(sMap));

        char sSteamID[32];
        GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

        char sName[MAX_NAME_LENGTH];
        GetClientName(client, sName, sizeof(sName));

        SendRecord(sMap, sSteamID, sName, GetTime(), time, sync, strafes, jumps, style, false);
        return;
    }

    char sTempPath[PLATFORM_MAX_PATH];
    GetTempReplayPath(client, sTempPath, sizeof(sTempPath));
    Shavit_AlsoSaveReplayTo(sTempPath);
    DebugPrint("[OSdb] Requesting non-WR replay at %s", sTempPath);
}

// Handles WR submissions, and non-WR submissions when replay_mode=1.
// Fires after the replay file has been written to disk.
public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
    if (client == 0 || !IsSubmittableFinish(client, track))
    {
        return;
    }

    float fWR = Shavit_GetWorldRecord(style, track);
    bool  isWR = (fWR == 0.0 || time <= fWR);

    if (isWR != isbestreplay)
    {
        // Our registered temp path also triggers this forward with isbestreplay=false;
        // only proceed when this invocation's WR status matches isbestreplay.
        return;
    }

    if (!isWR)
    {
        if (gCV_ReplayMode.IntValue != 1 || gCV_SubmitMode.IntValue == 0 || oldtime <= time)
        {
            return;
        }
    }

    DebugPrint("[OSdb] OnReplaySaved submit: isWR=%d submit_mode=%d", isWR, gCV_SubmitMode.IntValue);

    char sMap[64];
    GetCurrentMap(sMap, sizeof(sMap));
    GetMapDisplayName(sMap, sMap, sizeof(sMap));

    char sSteamID[32];
    GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));

    int sDate = GetTime();

    char sReplayPath[PLATFORM_MAX_PATH];
    if (replaypaths != null && replaypaths.Length > 0)
    {
        replaypaths.GetString(0, sReplayPath, sizeof(sReplayPath));
    }

    SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style, isWR, sReplayPath);
}

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
    DebugPrint("[OSdb] oldtime = %f newtime = %f", oldtime, time);
    // oldtime <= time is a filter to prevent non-pbs from being submitted
    // also means times wont submit if they never beat ur pb, like in the case
    // of a skip being removed, but thats up the to server to delete the time
    if (!IsSubmittableFinish(client, track) || oldtime <= time)
    {
        return;
    }

    float fWR = Shavit_GetWorldRecord(style, track);
    bool  isWR = (fWR == 0.0 || time <= fWR);

    if (isWR)
    {
        // WRs are handled by Shavit_OnReplaySaved with the correct replay file
        return;
    }

    if (gCV_SubmitMode.IntValue == 0)
    {
        DebugPrint("[OSdb] Skipping non-WR submission due to submit mode = 0 (WRs only)");
        return;
    }

    if (gCV_ReplayMode.IntValue == 1)
    {
        // Non-WR with replay attachment: submitted from Shavit_OnReplaySaved so the replay is attached
        DebugPrint("[OSdb] Deferring non-WR submit to OnReplaySaved (replay_mode=1)");
        return;
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

void SendRecord(char[] sMap, char[] sSteamID, char[] sName, int sDate, float time, float sync, int strafes, int jumps, int style, bool isWR, const char[] replayPath = "")
{
    DebugPrint("[OSdb] SendRecord called: Map=%s, SteamID=%s, Name=%s, Time=%.3f, Style=%d, IsWR=%s", 
               sMap, sSteamID, sName, time, style, isWR ? "true" : "false");
    
    if (sv_cheats.BoolValue)
    {
        LogError("[OSdb] Attempted to submit record with sv_cheats enabled. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
                 sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);
        DebugPrint("[OSdb] Record submission blocked due to sv_cheats being enabled");
        CleanupTempReplay(replayPath);
        return;
    }

    int n_Style = ConvertStyle(style);
    if (n_Style == -1)
    {
        DebugPrint("[OSdb] Style conversion failed for style %d, aborting record submission", style);
        CleanupTempReplay(replayPath);
        return;
    }

    DebugPrint("[OSdb] Style %d converted to %d, preparing HTTP request", style, n_Style);

    HTTPRequest hHTTPRequest;
    JSONObject  hJSON = new JSONObject();

    hHTTPRequest      = new HTTPRequest(API_BASE_URL... "/submit_record_nr");
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

    DataPack pack = new DataPack();
    pack.WriteString(replayPath);

    hHTTPRequest.Post(hJSON, OnRecordSubmitted, pack);
    delete hJSON;
}

void UploadReplay(const char[] replayKey, const char[] replayPath)
{
    if (replayKey[0] == '\0' || replayPath[0] == '\0' || !FileExists(replayPath))
    {
        return;
    }

    DebugPrint("[OSdb] Uploading replay with key: %s, path: %s", replayKey, replayPath);

    HTTPRequest request = new HTTPRequest(API_BASE_URL... "/upload_replay");
    AddHeaders(request);
    request.SetHeader("replay_key", replayKey);

    DataPack cleanupPack = new DataPack();
    cleanupPack.WriteString(replayPath);

    DebugPrint("[OSdb] Headers set, calling UploadFile");
    request.UploadFile(replayPath, OnReplayUploaded, cleanupPack);
}

void CleanupTempReplay(const char[] replayPath)
{
    if (replayPath[0] == '\0' || !IsTempReplayPath(replayPath) || !FileExists(replayPath))
    {
        return;
    }
    DeleteFile(replayPath);
    DebugPrint("[OSdb] Deleted temp replay: %s", replayPath);
}

public void OnRecordSubmitted(HTTPResponse resp, any value, const char[] error)
{
    DebugPrint("[OSdb] OnRecordSubmitted callback fired");

    DataPack pack = view_as<DataPack>(value);
    pack.Reset();

    char replayPath[PLATFORM_MAX_PATH];
    pack.ReadString(replayPath, sizeof(replayPath));
    delete pack;

    if (gCV_ReplayMode.IntValue == -1) {
        DebugPrint("[OSdb] Replay mode is -1, skipping replay upload");
        CleanupTempReplay(replayPath);
        return;
    }

    DebugPrint("[OSdb] Replay mode = %d, replayPath = '%s'", gCV_ReplayMode.IntValue, replayPath);

    if (error[0] != '\0')
    {
        LogError("[OSdb] Record submission failed: %s", error);
        CleanupTempReplay(replayPath);
        return;
    }

    DebugPrint("[OSdb] HTTP response status: %d", resp.Status);

    if (resp.Status != HTTPStatus_OK && resp.Status != HTTPStatus_Created)
    {
        LogError("[OSdb] Record submission failed with status %d", resp.Status);
        CleanupTempReplay(replayPath);
        return;
    }

    char replayKey[128];
    bool hasReplayKey = false;
    if (resp.Data != null)
    {
        JSONObject data = view_as<JSONObject>(resp.Data);
        hasReplayKey = data.GetString("replay_key", replayKey, sizeof(replayKey));
    }
    else
    {
        DebugPrint("[OSdb] Record submitted but resp.Data is null, no replay key in response");
    }

    DebugPrint("[OSdb] Has replay_key in response: %s, value: '%s', replayPath: '%s'",
               hasReplayKey ? "true" : "false", replayKey, replayPath);

    if (hasReplayKey && replayKey[0] != '\0' && replayPath[0] != '\0')
    {
        DebugPrint("[OSdb] Got replay key from response: %s, calling UploadReplay", replayKey);
        UploadReplay(replayKey, replayPath);
    }
    else {
        DebugPrint("[OSdb] Skipping replay upload - replayKey empty: %d, replayPath empty: %d",
                   replayKey[0] == '\0', replayPath[0] == '\0');
        CleanupTempReplay(replayPath);
    }
}

public void OnReplayUploaded(HTTPStatus status, any value)
{
    DataPack pack = view_as<DataPack>(value);
    pack.Reset();
    char replayPath[PLATFORM_MAX_PATH];
    pack.ReadString(replayPath, sizeof(replayPath));
    delete pack;

    if (status != HTTPStatus_OK)
    {
        LogError("[OSdb] Replay upload failed with status %d", status);
    }

    CleanupTempReplay(replayPath);
}

void ProcessNextBatch()
{
    DebugPrint("[OSdb] ProcessNextBatch called - gB_IsProcessingBatches: %s, gS_BulkCode length: %d", 
               gB_IsProcessingBatches ? "true" : "false", strlen(gS_BulkCode));
    DebugPrint("[OSdb] Current bulk code value: %s", gS_BulkCode);
    
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
    
    DebugPrint("[OSdb] Created JSON array with %d records", hArray.Length);
    
    HTTPRequest hHTTPRequest = new HTTPRequest(API_BASE_URL... "/bulk_records");
    DebugPrint("[OSdb] Created HTTP request to %s/bulk_records", API_BASE_URL);
    AddHeaders(hHTTPRequest);
    
    JSONObject hRecordsList = new JSONObject();
    hRecordsList.Set("records", hArray);
    
    DataPack pack = new DataPack();
    pack.WriteCell(gI_CurrentBatch);
    pack.WriteCell(hArray.Length);
    
    DebugPrint("[OSdb] Sending batch %d with %d records", gI_CurrentBatch + 1, hArray.Length);
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
    
    DebugPrint("[OSdb] Callback_OnBatchSent received - Status: %d", resp.Status);
    
    if (resp.Status != HTTPStatus_OK)
    {
        LogError("[osdb] Batch %d failed to send: status = %d", batchNumber + 1, resp.Status);
        DebugPrint("[OSdb] Batch %d failed with HTTP status %d", batchNumber + 1, resp.Status);
        
        // Try to extract error message from response
        if (resp.Data != null)
        {
            JSONObject errorData = view_as<JSONObject>(resp.Data);
            char errorMsg[256];
            if (errorData.GetString("error", errorMsg, sizeof(errorMsg)))
            {
                DebugPrint("[OSdb] Server error message: %s", errorMsg);
                LogError("[osdb] Server error: %s", errorMsg);
            }
            if (errorData.GetString("message", errorMsg, sizeof(errorMsg)))
            {
                DebugPrint("[OSdb] Server message: %s", errorMsg);
                LogError("[osdb] Server message: %s", errorMsg);
            }
        }
        else
        {
            DebugPrint("[OSdb] No response data available");
        }
        
        PrintToServer("[osdb] Batch %d failed, stopping batch processing.", batchNumber + 1);
        FinishBatchProcessing();
        return;
    }
    
    PrintToServer("[osdb] Batch %d (%d records) sent successfully.", batchNumber + 1, batchSize);
    DebugPrint("[OSdb] Batch %d completed successfully", batchNumber + 1);
    
    gI_CurrentBatch++;
    ProcessNextBatch();
}

void FinishBatchProcessing()
{
    DebugPrint("[OSdb] FinishBatchProcessing called - clearing bulk code: %s", gS_BulkCode);
    
    gB_IsProcessingBatches = false;
    gI_CurrentBatch = 0;
    gI_TotalRecords = 0;
    
    if (gA_AllRecords != null)
    {
        DebugPrint("[OSdb] Cleaning up %d records from ArrayList", gA_AllRecords.Length);
        delete gA_AllRecords;
        gA_AllRecords = null;
    }
    
    gS_BulkCode[0] = '\0';
    
    DebugPrint("[OSdb] Batch processing state reset complete");
    PrintToServer("[osdb] Batch processing completed.");
}

void RequestBulkVerification()
{
    DebugPrint("[OSdb] Starting bulk verification request");
    
    HTTPRequest hHTTPRequest = new HTTPRequest(API_BASE_URL... "/bulk_verification");
    AddHeaders(hHTTPRequest);

    JSONObject hVerificationBody = new JSONObject();
    
    DebugPrint("[OSdb] Sending bulk verification request to server");
    hHTTPRequest.Post(hVerificationBody, Callback_OnBulkVerification);

    delete hVerificationBody;
    hVerificationBody = null;
}

public void Callback_OnBulkVerification(HTTPResponse resp, any value)
{
    DebugPrint("[OSdb] Bulk verification callback received - Status: %d", resp.Status);
    
    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        LogError("[OSdb] Bulk verification failed: status = %d, data = null", resp.Status);
        DebugPrint("[OSdb] Bulk verification failed with status %d", resp.Status);
        return;
    }

    DebugPrint("[OSdb] Bulk verification response received successfully");

    JSONObject data = view_as<JSONObject>(resp.Data);
    
    if (!data.HasKey("key_to_send_times"))
    {
        LogError("[OSdb] Bulk verification response missing 'key_to_send_times' field");
        DebugPrint("[OSdb] Bulk verification response missing required field");
        delete data;
        return;
    }
    
    data.GetString("key_to_send_times", gS_BulkCode, sizeof(gS_BulkCode));
    delete data;
    
    DebugPrint("[OSdb] Bulk code received: %s", gS_BulkCode);
    
    PrintToServer("[OSdb] Bulk verification successful, starting record collection...");
    SendRecordDatabase();
}

void SendRecordDatabase()
{
    DebugPrint("[OSdb] Starting record database query");
    
    int bulkMode = gCV_BulkUploadMode.IntValue;
    DebugPrint("[OSdb] Bulk upload mode: %d (-1=no times, 0=WRs only, 1=all times)", bulkMode);
    
    if (bulkMode == -1)
    {
        PrintToServer("[OSdb] Bulk upload disabled (mode = -1), skipping record collection");
        DebugPrint("[OSdb] Bulk upload skipped due to mode = -1");
        return;
    }
    
    char sQuery[1024];
    switch (gI_TimerVersion)
    {
        case TimerVersion_shavit:
        {
            if (bulkMode == 0)
            {
                // Only WRs (default behavior) - use MIN(time) join to get only best times
                FormatEx(sQuery, sizeof(sQuery),
                         "SELECT a.map, u.auth AS steamid, u.name, a.time, a.sync, a.strafes, a.jumps, a.date, a.style FROM %splayertimes a " ... "JOIN (SELECT MIN(time) time, map, style, track FROM %splayertimes GROUP by map, style, track) b " ... "JOIN %susers u ON a.time = b.time AND a.auth = u.auth AND a.map = b.map AND a.style = b.style AND a.track = b.track " ...
                         "WHERE a.track = 0 " ... "ORDER BY a.date DESC;",
                         gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);
            }
            else if (bulkMode == 1)
            {
                // All times - don't use MIN(time) join, get all personal best times
                FormatEx(sQuery, sizeof(sQuery),
                         "SELECT a.map, u.auth AS steamid, u.name, a.time, a.sync, a.strafes, a.jumps, a.date, a.style FROM %splayertimes a " ...
                         "JOIN %susers u ON a.auth = u.auth " ...
                         "WHERE a.track = 0 " ... "ORDER BY a.date DESC;",
                         gS_MySQLPrefix, gS_MySQLPrefix);
            }
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
        DebugPrint("[OSdb] Adding bulk_verify header: %s", gS_BulkCode);
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
