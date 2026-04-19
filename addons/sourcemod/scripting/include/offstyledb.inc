#if defined _offstyledb_included
 #endinput
#endif
#define _offstyledb_included

#include <convar_class>
#include <sourcemod>
#include <keyvalues>
#include <ripext>
#include <sha1>

#include <offstyledb_shavit>

// TODO: 100MB is reserved unconditionally for bulk JSON payloads. If bulk
// ever switches to streaming/paging, shrink this.
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
ConVar    gCV_ReplayMode = null;         // -1=never, 0=WRs only, 1=all times (default)
ConVar    gCV_AutoUpdate = null;         // 0=off, 1=check only, 2=check + download + auto-apply
char      gS_LatestTag[32];
bool      gB_UpdateInFlight = false;

// Helper function for debug logging
void DebugPrint(const char[] format, any ...)
{
    if (gCV_ExtendedDebugging == null || !gCV_ExtendedDebugging.BoolValue)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);
    PrintToServer("[OSdb] %s", buffer);
}

// Gate for all osdb_* admin commands. Server console (client 0) is always
// allowed; everyone else must be in gI_SteamIDWhitelist.
bool IsOSdbAdmin(int client)
{
    if (client == 0)
    {
        return true;
    }

    int iSteamID = GetSteamAccountID(client);
    for (int i = 0; i < sizeof(gI_SteamIDWhitelist); i++)
    {
        if (iSteamID == gI_SteamIDWhitelist[i])
        {
            return true;
        }
    }
    return false;
}

#include <offstyledb_http>
#include <offstyledb_styles>
#include <offstyledb_records>
#include <offstyledb_bulk>
#include <offstyledb_updater>

public Plugin myinfo =
{
    name        = "Offstyle Database",
    author      = "shavit (Modified by Jeft & Tommy)",
    description = "Provides Offstyles with a database of bhop records.",
    version     = PLUGIN_VERSION ... SHAVIT_BUILD_LABEL,
    url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    ShavitCompat_MarkOptionalNatives();
    return APLRes_Success;
}

public void OnPluginStart()
{
    ShavitCompat_OnPluginStart();

    RegConsoleCmd("osdb_get_all_wrs", Command_SendAllWRs);
    RegConsoleCmd("osdb_viewmapping", Command_ViewStyleMap);
    RegConsoleCmd("osdb_batch_status", Command_BatchStatus);
    RegConsoleCmd("osdb_refresh_mapping", Command_RefreshMapping);

    gCV_ExtendedDebugging = new Convar("OSdb_extended_debugging", "0", "Use extensive debugging messages?", 0, true, 0.0, true, 1.0);
    gCV_SubmitMode = new Convar("OSdb_submit_mode", "1", "Submit only WRs (0) or all times (1)?", 0, true, 0.0, true, 1.0);
    gCV_BulkUploadMode = new Convar("OSdb_bulk_upload_mode", "0", "Bulk upload (database time sync): no times (-1), only WRs (0), or all times (1)?", 0, true, -1.0, true, 1.0);
    gCV_ReplayMode = new Convar("OSdb_replay_mode", "1", "Replay attachment: never (-1), WRs only (0), or all times (1, default)?", 0, true, -1.0, true, 1.0);
    gCV_PublicIP       = new Convar("OSdb_public_ip", "127.0.0.1", "Input the IP:PORT of the game server here. It will be used to identify the game server.", 0);
    gCV_Authentication = new Convar("OSdb_private_key", "super_secret_key", "Fill in your Offstyles Database API access key here. This key can be used to submit records to the database using your server key - abuse will lead to removal.", 0);

    Updater_OnPluginStart();

    Convar.AutoExecConfig();

    sv_cheats       = FindConVar("sv_cheats");

    gM_StyleMapping = new StringMap();

    DebugPrint("OSdb plugin started, commands registered, ConVars created");
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
    // TODO: we read the key once and blank the ConVar so it doesn't leak via
    // sm_cvar. The strlen guard makes a plugin reload re-read correctly
    // (since we blanked the ConVar after), but the interaction is subtle -
    // worth replacing with a proper secret-loading path (env var / sealed
    // file) if one appears.
    if (strlen(gS_AuthKey) == 0)
    {
        gCV_Authentication.GetString(gS_AuthKey, sizeof(gS_AuthKey));
    }
    gCV_Authentication.SetString("");

    GetStyleMapping();
    Updater_OnConfigsExecuted();
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
