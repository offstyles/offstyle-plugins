#include <sourcemod>
#include <ripext>

#define API_BASE_URL "http://127.0.0.1:8000/api"

#pragma dynamic 0x2000000
#pragma newdecls required
#pragma semicolon 1

native float Shavit_GetWorldRecord(int style, int track);
forward void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath);
forward void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp);
forward void OnTimerFinished_Post(int client, float Time, int Type, int Style, bool tas, bool NewTime, int OldPosition, int NewPosition);
forward void FuckItHops_OnWorldRecord(int client, int style, float time, int jumps, int strafes, float sync, int track);

enum
{
	TimerVersion_Unknown,
	TimerVersion_shavit,
	TimerVersion_FuckItHops,
	TimerVersion_END
}

int gI_TimerVersion = TimerVersion_Unknown;
char gS_TimerVersion[][] =
{
	"Unknown Timer",
	"shavit",
	"FuckItHops Timer"
};

char gS_TimerNatives[][] =
{
	"<none>",
	"Shavit_ChangeClientStyle", // shavit
	"tTimer_GetTimerState" // fuckithops
};

// SteamIDs which can fetch records from the server
int gI_SteamIDWhitelist[] =
{
    903787042 // jeft
};

int gI_Tickrate = 0;
Database gH_Database = null;
char gS_MySQLPrefix[32];
ConVar gCV_PublicIP = null;
char gS_AuthKey[64];
ConVar gCV_Authentication = null;
ConVar sv_cheats = null;


public Plugin myinfo =
{
	name = "Offstyle Database",
	author = "shavit (Modified by Jeft & Tommy)",
	description = "Provides Offstyles with a database of bhop records.",
	version = "0.0.2",
	url = ""
};


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("Shavit_GetWorldRecord");
	return APLRes_Success;
}

public void OnPluginStart()
{
	RegConsoleCmd("sj_get_all_wrs", Command_SendAllWRs, "Fetches WRs to OSdb.");

	// gCV_ExtendedDebugging = CreateConVar("OSdb_extended_debugging", "0", "Use extensive debugging messages?", FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	gCV_PublicIP = CreateConVar("OSdb_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.");
	gCV_Authentication = CreateConVar("OSdb_private_key", "super_secret_key", "Fill in your Offstyles Database API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.");

	AutoExecConfig();

	sv_cheats = FindConVar("sv_cheats");

	// SourceJump_DebugLog("OSdb database plugin loaded.");
}

public void OnAllPluginsLoaded()
{
	for(int i = 1; i < TimerVersion_END; i++)
	{
		if(GetFeatureStatus(FeatureType_Native, gS_TimerNatives[i]) != FeatureStatus_Unknown)
		{
			gI_TimerVersion = i;
			PrintToServer("[OSdb] Detected timer plugin %s based on native %s", gS_TimerVersion[i], gS_TimerNatives[i]);

			break;
		}
	}

	char sError[255];
	strcopy(gS_MySQLPrefix, sizeof(gS_MySQLPrefix), "");

	switch(gI_TimerVersion)
	{
		case TimerVersion_Unknown: SetFailState("Supported timer plugin was not found.");

		case TimerVersion_shavit:
		{
			gH_Database = GetTimerDatabaseHandle();
			GetTimerSQLPrefix(gS_MySQLPrefix, sizeof(gS_MySQLPrefix));
		}

		case TimerVersion_FuckItHops:
		{
			if((gH_Database = SQL_Connect("TimerDB65", true, sError, sizeof(sError))) == null)
			{
				SetFailState("OSdb plugin startup failed. Reason: %s", sError);
			}
		}
	}

    if (strlen(gS_AuthKey) == 0) {
        gCV_Authentication.GetString(gS_AuthKey, sizeof(gS_AuthKey));
    }
    gCV_Authentication.SetString("");

    // HTTPRequest hHTTPRequest;
    // JSONObject hJSONObject = new JSONObject();

    // hHTTPRequest = new HTTPRequest(API_BASE_URL..."/style_mapping");
    // AddHeaders(hHTTPRequest);
    // hHTTPRequest.Post(hJSONObject, OnHttpDummyCallback);

    // delete hJSONObject;
}


public void Callback_OnStyleMapping(HTTPResponse resp, any value) {
	if (resp.Status != HTTPStatus_OK || resp.Data == null) {
		return;
	}


}

public void OnMapStart()
{
	gI_Tickrate = RoundToZero(1.0 / GetTickInterval());
}

public Action Command_SendAllWRs(int client, int args) {
    int iSteamID = GetSteamAccountID(client);
    bool bAllowed = false;

    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++) {
        if (iSteamID == gI_SteamIDWhitelist[i]) {
            bAllowed = true;
            break;
        }
    }

    if (!bAllowed) {
        ReplyToCommand(client, "[OSdb] You are not permitted to fetch the records list.");
        return Plugin_Handled;
    }

    // TODO: Send list of records
    ReplyToCommand(client, "[OSdb] Preparing list of records...");
    SendRecordDatabase();

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

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp) {
	if (track != 0 || gI_TimerVersion != TimerVersion_shavit || oldtime >= time) {
		return;
	}

	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
    GetMapDisplayName(sMap, sMap, sizeof(sMap));

    char sSteamID[32];
    GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));

    char sDate[32];
    FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", GetTime());

    SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style);
}

public void FuckItHops_OnWorldRecord(int client, int style, float time, int jumps, int strafes, float sync, int track) {
    if (track != 0 || gI_TimerVersion != TimerVersion_FuckItHops) {
        return;
    }

    char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	GetMapDisplayName(sMap, sMap, sizeof(sMap));

	char sSteamID[32];
	GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	char sDate[32];
	FormatTime(sDate, sizeof(sDate), "%Y-%m-%d %H:%M:%S", GetTime());

	SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style);
}

void SendRecord(char[] sMap, char[] sSteamID, char[] sName, char[] sDate, float time, float sync, int strafes, int jumps, int style) {
    if (sv_cheats.BoolValue) {
        LogError("[OSdb] Attempted to submit record with sv_cheats enabled. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
            sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);

        return;
    }

    HTTPRequest hHTTPRequest;
    JSONObject hJSON = new JSONObject();

    hHTTPRequest = new HTTPRequest(API_BASE_URL..."/record");
    AddHeaders(hHTTPRequest);
    hJSON.SetString("map", sMap);
    hJSON.SetString("steamid", sSteamID);
    hJSON.SetString("name", sName);
    hJSON.SetFloat("time", time);
    hJSON.SetFloat("sync", sync);
    hJSON.SetInt("strafes", strafes);
    hJSON.SetInt("jumps", jumps);
    hJSON.SetString("date", sDate);
    hJSON.SetInt("tickrate", gI_Tickrate);
    hJSON.SetInt("style", style);
    hJSON.SetNull("replayfile");

    char sPath[PLATFORM_MAX_PATH];
    switch (gI_TimerVersion) {
        case TimerVersion_shavit: {
			// TODO: i believe the /0/ is tied to the auto style or the track(main/bonus)
			// this should check for the style record instead and also be skipped if the time
			// isnt a record

            // BuildPath(Path_SM, sPath, sizeof(sPath), "data/replaybot/0/%s.replay", sMap);
        }

        case TimerVersion_FuckItHops: {
            // format: no header. read 6 cells at once. x/y/z yaw/pitch buttons. until eof
			char sSteamIDCopy[32];
			strcopy(sSteamIDCopy, sizeof(sSteamIDCopy), sSteamID);
			ReplaceString(sSteamIDCopy, sizeof(sSteamIDCopy), "[U:1:", "");
			ReplaceString(sSteamIDCopy, sizeof(sSteamIDCopy), "]", "");

			BuildPath(Path_SM, sPath, sizeof(sPath), "data/tTimer/%s/0-0-%d.rec", sMap, StringToInt(sSteamIDCopy));
        }
    }

	if(FileExists(sPath))
	{
		File fFile = OpenFile(sPath, "rb");

		if(fFile != null && fFile.Seek(0, SEEK_END))
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
	}

    hHTTPRequest.Post(hJSON, OnHttpDummyCallback);
    delete hJSON;
}

void OnHttpDummyCallback(HTTPResponse resp, any value) {
    if (resp.Status != HTTPStatus_OK) {
        return;
    }

    return;
}

void SendRecordDatabase() {
    char sQuery[1024];
    switch (gI_TimerVersion) {
        case TimerVersion_shavit: {

            // Original, incase we fuck it up somehow
            // FormatEx(sQuery, sizeof(sQuery),
			// 	"SELECT a.map, u.auth AS steamid, u.name, a.time, a.sync, a.strafes, a.jumps, a.date, a.style FROM %splayertimes a " ...
			// 	"JOIN (SELECT MIN(time) time, map, style, track FROM %splayertimes GROUP by map, style, track) b " ...
			// 	"JOIN %susers u ON a.time = b.time AND a.auth = u.auth AND a.map = b.map AND a.style = b.style AND a.track = b.track " ...
			// 	// "WHERE a.style = 0 AND a.track = 0 " ...
			// 	"WHERE a.track = 0" ...
			// 	"ORDER BY a.date DESC;", gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);
		
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT a.map, u.auth AS steamid, u.name, a.time, a.sync, a.strafes, a.jumps, a.date, a.style FROM %splayertimes a " ...
				"JOIN (SELECT MIN(time) time, map, style, track FROM %splayertimes GROUP by map, style, track) b " ...
				"JOIN %susers u ON a.time = b.time AND a.auth = u.auth AND a.map = b.map AND a.style = b.style AND a.track = b.track " ...
				// "WHERE a.style = 0 AND a.track = 0 " ...
				"WHERE a.track = 0" ...
				"ORDER BY a.date DESC;", gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);
        }

		case TimerVersion_FuckItHops:
		{
            // Original, incase we fuck it up somehow
            // strcopy(sQuery, sizeof(sQuery),
			// 	"SELECT a.MapName, a.SteamID AS steamid, a.Name, a.Time, a.Sync, a.Strafes, a.Jumps, a.Date FROM timelist a " ...
			// 	"JOIN (SELECT MIN(Time) Time, MapName FROM timelist WHERE Type = 0 AND Style = 0 GROUP by MapName, Style, Type) b " ...
			// 	"ON a.Time = b.Time AND a.MapName = b.MapName " ...
			// 	"WHERE a.Type = 0 AND a.Style = 0 " ...
			// 	"ORDER BY Date DESC;");

			strcopy(sQuery, sizeof(sQuery),
				"SELECT a.MapName, a.SteamID AS steamid, a.Name, a.Time, a.Sync, a.Strafes, a.Jumps, a.Date FROM timelist a " ...
				"JOIN (SELECT MIN(Time) Time, MapName FROM timelist WHERE Type = 0 GROUP by MapName, Style, Type) b " ...
				"ON a.Time = b.Time AND a.MapName = b.MapName " ...
				"WHERE a.Type = 0" ...
				"ORDER BY Date DESC;");
		}
    }

    gH_Database.Query(SQL_GetRecords_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_GetRecords_Callback(Database db, DBResultSet results, const char[] error, any data) {
    if (results == null || results.RowCount == 0) {
        // no records found in selection
        
        return;
    }

    JSONArray hArray = new JSONArray();

    while (results.FetchRow()) {
        JSONObject hJSON = GetTimeJsonFromResult(results);
        hArray.Push(hJSON);
        delete hJSON;
    }

    HTTPRequest hHTTPRequest;
    JSONObject hRecordsList = new JSONObject();

    hHTTPRequest = new HTTPRequest(API_BASE_URL..."/bulk_records");
    AddHeaders(hHTTPRequest);
    hRecordsList.Set("records", hArray);

    hHTTPRequest.Post(hRecordsList, OnHttpDummyCallback);

    delete hArray;
    delete hRecordsList;
}

JSONObject GetTimeJsonFromResult(DBResultSet results) {
    char sMap[64];
    results.FetchString(0, sMap, sizeof(sMap));

    char sSteamID[32];
    results.FetchString(1, sSteamID, sizeof(sSteamID));

    switch (gI_TimerVersion) {
        // we dont Really need to do this switch case shit anymore, but whatever
        case TimerVersion_shavit, TimerVersion_FuckItHops: 
		{
            if (StrContains(sSteamID, "[U:1:]", false) == -1) {
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
	char sError[255];

	if(SQL_CheckConfig("shavit"))
	{
		if((db = SQL_Connect("shavit", true, sError, sizeof(sError))) == null)
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

	if(fFile == null)
	{
		SetFailState("Cannot open \"configs/shavit-prefix.txt\". Make sure this file exists and that the server has read permissions to it.");
	}

	char sLine[PLATFORM_MAX_PATH * 2];

	if(fFile.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		strcopy(buffer, maxlen, sLine);
	}

	delete fFile;
}

void AddHeaders(HTTPRequest req) {
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
	char base64_sTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	int base64_cFillChar = '=';

	int nLength;
	int resPos;

	if(sourcelen > 0)
	{
		nLength = sourcelen;
	}
	else
	{
		nLength = strlen(sString);
	}

	for(int nPos = 0; nPos < nLength; nPos++)
	{
		int cCode;

		cCode = (sString[nPos] >> 2) & 0x3f;
		resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);
		cCode = (sString[nPos] << 4) & 0x3f;

		if(++nPos < nLength)
		{
			cCode |= (sString[nPos] >> 4) & 0x0f;
		}

		resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);

		if(nPos < nLength)
		{
			cCode = (sString[nPos] << 2) & 0x3f;

			if(++nPos < nLength)
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

		if(nPos < nLength)
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
