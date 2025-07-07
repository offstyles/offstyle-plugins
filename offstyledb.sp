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
    RegConsoleCmd("osdb_get_all_wrs", Command_SendAllWRs, "Fetches WRs to OSdb.");
    RegConsoleCmd("osdb_viewmapping", Command_ViewStyleMap, "Prints the current style mapping.");

    // gCV_ExtendedDebugging = CreateConVar("OSdb_extended_debugging", "0", "Use extensive debugging messages?", FCVAR_DONTRECORD, true, 0.0, true, 1.0);
    gCV_PublicIP       = CreateConVar("OSdb_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.");
    gCV_Authentication = CreateConVar("OSdb_private_key", "super_secret_key", "Fill in your Offstyles Database API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.");

    AutoExecConfig();

    sv_cheats       = FindConVar("sv_cheats");

    gM_StyleMapping = new StringMap();

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

    if (strlen(gS_AuthKey) == 0)
    {
        gCV_Authentication.GetString(gS_AuthKey, sizeof(gS_AuthKey));
    }
    gCV_Authentication.SetString("");

    // HTTPRequest hHTTPRequest;
    // JSONObject hJSONObject = new JSONObject();

    // hHTTPRequest = new HTTPRequest(API_BASE_URL..."/style_mapping");
    // AddHeaders(hHTTPRequest);
    // hHTTPRequest.Post(hJSONObject, Callback_OnStyleMapping);

    // delete hJSONObject;

    GetStyleMapping();
}

void GetStyleMapping()
{
    char temp[160];
    temp = gS_StyleHash;
    HashStyleConfig();

    if (strcmp(temp, gS_StyleHash) == 0)
    {
        return;
    }

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
    char s[16];
    IntToString(style, s, sizeof(s));

    int out;
    if (gM_StyleMapping.GetValue(s, out))
    {
        return out;
    }

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
    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        LogError("[OSdb] Style Mapping failed: status = %d, data = null", resp.Status);
        SetFailState("Style Mapping returned non-ok response");
        return;
    }

    JSONObject data = view_as<JSONObject>(resp.Data);
    char       s_Data[512];
    data.GetString("data", s_Data, sizeof(s_Data));
    // dont think we need to do it here, but doing it anyway
    delete data;

    if (gM_StyleMapping.Size > 0)
    {
        gM_StyleMapping.Clear();
    }

    const int MAX_STYLES = 128;    // fucking Hope people arent adding this many....
    char      parts[MAX_STYLES][8];

    int       count = ExplodeString(s_Data, ",", parts, sizeof(parts), sizeof(parts[]));

    for (int i = 0; i < count - 1; i += 2)
    {
        char key[8];
        strcopy(key, sizeof(key), parts[i]);

        int ivalue = StringToInt(parts[i + 1]);

        gM_StyleMapping.SetValue(key, ivalue);
    }
}

public void OnMapStart()
{
    gI_Tickrate = RoundToZero(1.0 / GetTickInterval());
}

public void OnMapEnd()
{
    GetStyleMapping();
}

public Action Command_SendAllWRs(int client, int args)
{
    int  iSteamID = GetSteamAccountID(client);
    bool bAllowed = false;

    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
    {
        if (iSteamID == gI_SteamIDWhitelist[i])
        {
            bAllowed = true;
            break;
        }
    }

    if (!bAllowed)
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to fetch the records list.");
        return Plugin_Handled;
    }

    // TODO: Send list of records
    ReplyToCommand(client, "[OSdb] Preparing list of records...");
    SendRecordDatabase();

    return Plugin_Handled;
}

public Action Command_ViewStyleMap(int client, int args)
{
    if (gM_StyleMapping == null || gM_StyleMapping.Size == 0)
    {
        PrintToChat(client, "[OSdb] Style map is empty or null");
        return Plugin_Handled;
    }

    StringMapSnapshot snapshot = gM_StyleMapping.Snapshot();

    int               count    = snapshot.Length;

    char              key[256], value[256];
    for (int i = 0; i < count; i++)
    {
        snapshot.GetKey(i, key, sizeof(key));
        gM_StyleMapping.GetString(key, value, sizeof(value));

        PrintToChat(client, "[StyleMap] %s: %s", key, value);
    }

    delete snapshot;
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
    if (sv_cheats.BoolValue)
    {
        LogError("[OSdb] Attempted to submit record with sv_cheats enabled. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
                 sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);

        return;
    }

    int n_Style = ConvertStyle(style);
    if (n_Style == -1)
    {
        return;
    }

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

void OnHttpDummyCallback(HTTPResponse resp, any value)
{
    if (resp.Status != HTTPStatus_OK)
    {
        return;
    }

    return;
}

void SendRecordDatabase()
{
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
                     "WHERE a.track = 0" ... "ORDER BY a.date DESC;",
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

    JSONArray hArray = new JSONArray();

    while (results.FetchRow())
    {
        JSONObject hJSON = GetTimeJsonFromResult(results);
        hArray.Push(hJSON);
        delete hJSON;
    }
    PrintToServer("[osdb] Finished parsing results, sending bulk records now...");
    HTTPRequest hHTTPRequest;
    JSONObject  hRecordsList = new JSONObject();

    hHTTPRequest             = new HTTPRequest(API_BASE_URL... "/bulk_records");
    AddHeaders(hHTTPRequest);
    hRecordsList.Set("records", hArray);

    hHTTPRequest.Post(hRecordsList, OnHttpDummyCallback);

    delete hArray;
    delete hRecordsList;
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

    char sDate[32];
    FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", results.FetchInt(7));

    JSONObject hJSON = new JSONObject();
    hJSON.SetString("map", sMap);
    hJSON.SetString("steamid", sSteamID);
    hJSON.SetString("name", sName);
    hJSON.SetFloat("time", results.FetchFloat(3));
    hJSON.SetFloat("sync", results.FetchFloat(4));
    hJSON.SetInt("strafes", results.FetchInt(5));
    hJSON.SetInt("jumps", results.FetchInt(6));
    hJSON.SetString("date", sDate);
    hJSON.SetInt("tickrate", gI_Tickrate);
    hJSON.SetInt("style", results.FetchInt(7));

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
