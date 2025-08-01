#include <sourcemod>
#include <keyvalues>
#include <ripext>
#include <sha1>

#define API_BASE_URL "https://offstyles.tommyy.dev/api"

#pragma dynamic 0x2000000
#pragma newdecls required
#pragma semicolon 1

native float Shavit_GetWorldRecord(int style, int track);
native bool  Shavit_IsPracticeMode(int client);
native bool  Shavit_IsPaused(int client);
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
    return APLRes_Success;
}

public void OnPluginStart()
{
    RegConsoleCmd("osdb_get_all_wrs", Command_SendAllWRs);
    RegConsoleCmd("osdb_viewmapping", Command_ViewStyleMap);
    RegConsoleCmd("osdb_batch_status", Command_BatchStatus);
    RegConsoleCmd("osdb_refresh_mapping", Command_RefreshMapping);

    gCV_ExtendedDebugging = CreateConVar("OSdb_extended_debugging", "0", "Use extensive debugging messages?", FCVAR_DONTRECORD, true, 0.0, true, 1.0);
    gCV_PublicIP       = CreateConVar("OSdb_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.");
    gCV_Authentication = CreateConVar("OSdb_private_key", "super_secret_key", "Fill in your Offstyles Database API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.");

    AutoExecConfig();

    sv_cheats       = FindConVar("sv_cheats");

    gM_StyleMapping = new StringMap();

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
