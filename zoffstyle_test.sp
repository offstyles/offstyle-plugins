#include <sourcemod>
#include <ripext>

#define REMOTE_SERVER "http://127.0.0.1:8000"

#pragma dynamic 0x2000000
#pragma newdecls required
#pragma semicolon 1

native float Shavit_GetWorldRecord(int style, int track);
forward void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath);
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

int gI_DebuggingLog = 0;
ConVar gCV_ExtendedDebugging = null;
HTTPClient gH_Client = null;
int gI_Tickrate = 0;
Database gH_Database = null;
char gS_MySQLPrefix[32];
char gS_PasswordHash[64];
ConVar gCV_PublicIP = null;
char gS_AuthKey[64];
ConVar gCV_Authentication = null;
ConVar sv_cheats = null;

// SteamIDs which can fetch records from the server
int gI_SteamIDWhitelist[] =
{
    903787042 // jeft
};

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

public void OnAllPluginsLoaded()
{
	for(int i = 1; i < TimerVersion_END; i++)
	{
		if(GetFeatureStatus(FeatureType_Native, gS_TimerNatives[i]) != FeatureStatus_Unknown)
		{
			gI_TimerVersion = i;
			PrintToServer("[SourceJump] Detected timer plugin %s based on native %s", gS_TimerVersion[i], gS_TimerNatives[i]);

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
				SetFailState("SourceJump plugin startup failed. Reason: %s", sError);
			}
		}
	}

	gH_Client = new HTTPClient(REMOTE_SERVER);
	gH_Client.Get("password", Callback_OnGetPassword);
}

public void OnPluginStart()
{
	RegConsoleCmd("sj_get_all_wrs", Command_GetAllWRs, "Fetches WRs to SourceJump.");

	gCV_ExtendedDebugging = CreateConVar("sourcejump_extended_debugging", "0", "Use extensive debugging messages?", FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	gCV_PublicIP = CreateConVar("sourcejump_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.");
	gCV_Authentication = CreateConVar("sourcejump_private_key", "super_secret_key", "Fill in your SourceJump API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.");

	AutoExecConfig();

	sv_cheats = FindConVar("sv_cheats");

	SourceJump_DebugLog("SourceJump database plugin loaded.");
}

public void OnMapStart()
{
	gI_Tickrate = RoundToZero(1.0 / GetTickInterval());
}

public Action Command_GetAllWRs(int client, int args)
{
	int iSteamID = GetSteamAccountID(client);
	bool bAllowed = false;

	for(int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
	{
		if(iSteamID == gI_SteamIDWhitelist[i])
		{
			bAllowed = true;

			break;
		}
	}

	if(!bAllowed)
	{
		ReplyToCommand(client, "[SourceJump] You are not permitted to fetch the world records list.");

		return Plugin_Handled;
	}

	SendListOfRecords();
	ReplyToCommand(client, "[SourceJump] Preparing list of records...");

	return Plugin_Handled;
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath)
{
	if(track != 0 || gI_TimerVersion != TimerVersion_shavit)
	{
		return;
	}

	if(time > Shavit_GetWorldRecord(style, track))
	{
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

	SendCurrentWR(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style);
}

public void FuckItHops_OnWorldRecord(int client, int style, float time, int jumps, int strafes, float sync, int track)
{
	if( track != 0 || gI_TimerVersion != TimerVersion_FuckItHops)
	{
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

	SendCurrentWR(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style);
}


public void Callback_SendNewWR(HTTPResponse response, any value)
{
    // this also returns 201 created, but it makes more sense here, changing it anyway because it seems useless
	if(response.Status != HTTPStatus_OK || response.Data == null)
	{
		LogError("[SourceJump] Could not send WR to the SJ database. Response status: %d | Data: %d", response.Status, response.Data);

		return;
	}

	SourceJump_DebugLog("Callback_SendNewWR: Successfully submitted record to SJ database.");
}

void SendCurrentWR(char[] sMap, char[] sSteamID, char[] sName, char[] sDate, float time, float sync, int strafes, int jumps, int style)
{
	if(!IsPasswordFetched())
	{
		LogError("[SourceJump] Attempted to submit world record without initial server check. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
			sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);

		return;
	}

	if(sv_cheats.BoolValue)
	{
		LogError("[SourceJump] Attempted to submit world record with sv_cheats enabled. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
			sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);

		return;
	}

	SourceJump_DebugLog("SendCurrentWR: Submitting record to SJ database. Record data: %s | %s | %s | %s | %f | %f | %d | %d",
			sMap, sSteamID, sName, sDate, time, sync, strafes, jumps);

	JSONObject hJSON = new JSONObject();
	AddServerToJson(hJSON);
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

	switch(gI_TimerVersion)
	{
		case TimerVersion_shavit:
		{
			BuildPath(Path_SM, sPath, sizeof(sPath), "data/replaybot/0/%s.replay", sMap);
		}

		case TimerVersion_FuckItHops:
		{
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

	gH_Client.Post("records", hJSON, Callback_SendNewWR);
	delete hJSON;
}

void AddServerToJson(JSONObject data)
{
	// Read from configs but remove it instantly from cvar memory so sm_cvar won't see the original value.
	if(strlen(gS_AuthKey) == 0)
	{
		gCV_Authentication.GetString(gS_AuthKey, sizeof(gS_AuthKey));
	}

	gCV_Authentication.SetString("");

	char sPublicIP[32];
	gCV_PublicIP.GetString(sPublicIP, sizeof(sPublicIP));

	char sHostname[128];
	FindConVar("hostname").GetString(sHostname, sizeof(sHostname));

	data.SetString("public_ip", sPublicIP);
	data.SetString("private_key", gS_AuthKey);
	data.SetString("hostname", sHostname);
	data.SetString("timer_plugin", gS_TimerVersion[gI_TimerVersion]);
}

bool IsPasswordFetched()
{
	return (strlen(gS_PasswordHash) > 20);
}

public void Callback_OnGetPassword(HTTPResponse response, any value)
{
	if(response.Status != HTTPStatus_OK || response.Data == null)
	{
		LogError("[SourceJump] Could not get password from remote server. Response status: %d | Data: %d", response.Status, response.Data);

		return;
	}

	view_as<JSONObject>(response.Data).GetString("password", gS_PasswordHash, sizeof(gS_PasswordHash));

	if(!IsPasswordFetched())
	{
        SourceJump_DebugLog("!IsPasswordFetched() returned true: %s", gS_PasswordHash);
		return;
	}

	SourceJump_DebugLog("Callback_OnGetPassword: Obtained checksum from remote server: %s", gS_PasswordHash);

	JSONObject hContact = new JSONObject();
	AddServerToJson(hContact);
	gH_Client.Post("install_check", hContact, Callback_OnContact);
	delete hContact;
}

public void Callback_OnContact(HTTPResponse response, any value)
{
    // for some reason this originally expects a 201 Created response, but doesnt use the location or anything created?
	if(response.Status != HTTPStatus_OK || response.Data == null)
	{
		LogError("[SourceJump] Failed contacting SJ server for initial contact. Response status: %d | Data: %d", response.Status, response.Data);

		return;
	}

	char sBuffer[255];
	view_as<JSON>(response.Data).ToString(sBuffer, sizeof(sBuffer));

	bool bWhitelisted = view_as<JSONObject>(response.Data).GetBool("whitelisted");

	if(!bWhitelisted)
	{
		SourceJump_Log("Server is not whitelisted. Contact a database admin.");

		return;
	}

	bool bSendRecordList = view_as<JSONObject>(response.Data).GetBool("send_list");

	if(bSendRecordList)
	{
		SourceJump_DebugLog("Callback_OnContact: Sending list of records to SJ server!");
		SendListOfRecords();
	}
	else
	{
		SourceJump_DebugLog("Callback_OnContact: Server does not want a list of records from us.");
	}
}

void SendListOfRecords()
{
	char sQuery[1024];

	switch(gI_TimerVersion)
	{
		case TimerVersion_shavit:
		{
			// TODO: Modify the other timers to submit style time
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
			strcopy(sQuery, sizeof(sQuery),
				"SELECT a.MapName, a.SteamID AS steamid, a.Name, a.Time, a.Sync, a.Strafes, a.Jumps, a.Date FROM timelist a " ...
				"JOIN (SELECT MIN(Time) Time, MapName FROM timelist WHERE Type = 0 AND Style = 0 GROUP by MapName, Style, Type) b " ...
				"ON a.Time = b.Time AND a.MapName = b.MapName " ...
				"WHERE a.Type = 0 AND a.Style = 0 " ...
				"ORDER BY Date DESC;");
		}
	}

	gH_Database.Query(SQL_GetList_Callback, sQuery, 0, DBPrio_Low);
}

// this was used for btimes, but i nuked that so its unused now, will keep incase its useful (never)
void SteamID2To3(const char[] steam2, char[] buffer, int maxlen)
{
	strcopy(buffer, maxlen, steam2);
	ReplaceString(buffer, maxlen, "STEAM_0:", "");
	ReplaceString(buffer, maxlen, "STEAM_1:", "");

	char sExploded[2][16];
	ExplodeString(buffer, ":", sExploded, sizeof(sExploded), sizeof(sExploded[]), false);

	int iPrefix = StringToInt(sExploded[0]);
	int iSteamID = StringToInt(sExploded[1]);

	FormatEx(buffer, maxlen, "[U:1:%d]", ((iSteamID * 2) + iPrefix));
}

JSONObject GetTimeJsonFromResult(DBResultSet results)
{
	char sMap[64];
	results.FetchString(0, sMap, sizeof(sMap));

	char sSteamID[32];
	results.FetchString(1, sSteamID, sizeof(sSteamID));

	switch(gI_TimerVersion)
	{
		case TimerVersion_shavit, TimerVersion_FuckItHops:
		{
			if(StrContains(sSteamID, "[U:1:", false) == -1)
			{
				Format(sSteamID, sizeof(sSteamID), "[U:1:%s]", sSteamID);
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

public void SQL_GetList_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null || results.RowCount == 0 || !IsPasswordFetched())
	{
		SourceJump_DebugLog("SQL_GetList_Callback: No results from record selection query.");

		return;
	}

	SourceJump_DebugLog("SQL_GetList_Callback: Collected %d records, preparing to send them over to SJ database.", results.RowCount);

	JSONArray hArray = new JSONArray();

	while(results.FetchRow())
	{
		JSONObject hJSON = GetTimeJsonFromResult(results);
		hArray.Push(hJSON);
		delete hJSON;
	}

	JSONObject hRecordsList = new JSONObject();
	AddServerToJson(hRecordsList);
	hRecordsList.Set("records", hArray);
	gH_Client.Post("bulk_records", hRecordsList, Callback_OnRecordsList, results.RowCount);

	delete hArray;
	delete hRecordsList;
}

public void Callback_OnRecordsList(HTTPResponse response, any value)
{
	if(response.Status != HTTPStatus_OK || response.Data == null)
	{
		LogError("[SourceJump] Could not submit list of world records to SJ remote server. Response status: %d | Data: %d", response.Status, response.Data);

		return;
	}

	SourceJump_DebugLog("Callback_OnRecordsList: Successfully submitted %d records to SJ database!", value);
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
			SetFailState("SourceJump plugin startup failed. Reason: %s", sError);
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

void SourceJump_DebugLog(const char[] format, any ...)
{
	if(!gCV_ExtendedDebugging.BoolValue)
	{
		return;
	}

	char sBuffer[300];
	VFormat(sBuffer, sizeof(sBuffer), format, 2);
	LogMessage("[SourceJump] %d | %s", ++gI_DebuggingLog, sBuffer);
}

void SourceJump_Log(const char[] format, any ...)
{
	char sBuffer[300];
	VFormat(sBuffer, sizeof(sBuffer), format, 2);
	LogMessage("[SourceJump] %d | %s", ++gI_DebuggingLog, sBuffer);
}