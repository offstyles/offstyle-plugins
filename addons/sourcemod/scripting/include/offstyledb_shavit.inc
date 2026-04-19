#if defined _offstyledb_shavit_included
 #endinput
#endif
#define _offstyledb_shavit_included

#pragma newdecls required
#pragma semicolon 1

#if defined SHAVIT_V3
// Manual shavit v3 declarations (no v3 shavit include is shipped in CI)
native float  Shavit_GetWorldRecord(int style, int track);
native bool   Shavit_IsPracticeMode(int client);
native bool   Shavit_IsPaused(int client);
// v4-only native. Declared here so the build-mismatch detector can probe its
// availability via GetFeatureStatus. Never actually called from the v3 build.
native void   Shavit_AlsoSaveReplayTo(const char[] path);
forward void   Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath);
forward void   Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp);
forward Action Shavit_ShouldSaveReplayCopy(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong);

// stocks from shavit.inc (v3 doesn't ship the helpers we use)
stock Database GetTimerDatabaseHandle()
{
    Database db = null;
    char     sError[255];

    if (SQL_CheckConfig("shavit"))
    {
        if ((db = SQL_Connect("shavit", true, sError, sizeof(sError))) == null)
        {
            SetFailState("[OSdb] OSdb plugin startup failed. Reason: %s", sError);
        }
    }
    else
    {
        db = SQLite_UseDatabase("shavit", sError, sizeof(sError));
    }

    return db;
}

stock void GetTimerSQLPrefix(char[] buffer, int maxlen)
{
    char sFile[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sFile, sizeof(sFile), "configs/shavit-prefix.txt");

    File fFile = OpenFile(sFile, "r");

    if (fFile == null)
    {
        delete fFile;
        SetFailState("[OSdb] Cannot open \"configs/shavit-prefix.txt\". Make sure this file exists and that the server has read permissions to it.");
    }

    char sLine[PLATFORM_MAX_PATH * 2];

    if (fFile.ReadLine(sLine, sizeof(sLine)))
    {
        TrimString(sLine);
        strcopy(buffer, maxlen, sLine);
    }

    delete fFile;
}

 #define SHAVIT_BUILD_LABEL " (shavit v3)"
#else
#undef REQUIRE_PLUGIN
#include <shavit>
 #define SHAVIT_BUILD_LABEL " (shavit v4)"
#endif

// v4 writes its non-WR replay copies to a temp path we manage; v3 lets shavit
// write them to its own "/copy/" subfolder under the replay dir.
bool IsTempReplayPath(const char[] path)
{
#if defined SHAVIT_V3
    return StrContains(path, "/copy/") != -1;
#else
    return StrContains(path, "osdb_tmp") != -1;
#endif
}

#if !defined SHAVIT_V3
void GetTempReplayPath(int client, char[] buffer, int maxlen)
{
    BuildPath(Path_SM, buffer, maxlen, "data/osdb_tmp/%d_%d.replay", client, GetTime());
}

void EnsureTempReplayDir()
{
    char sDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sDir, sizeof(sDir), "data/osdb_tmp");

    if (!DirExists(sDir))
    {
        CreateDirectory(sDir, 511);
        DebugPrint("Created temp replay directory: %s", sDir);
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
        DebugPrint("Swept %d orphan temp replays", swept);
    }
}
#endif

// --- Compat helpers called from offstyledb.inc's plugin lifecycle hooks ---

void ShavitCompat_MarkOptionalNatives()
{
    MarkNativeAsOptional("Shavit_GetWorldRecord");
    MarkNativeAsOptional("Shavit_OnReplaySaved");
    MarkNativeAsOptional("Shavit_OnFinish");
    MarkNativeAsOptional("Shavit_IsPracticeMode");
    MarkNativeAsOptional("Shavit_IsPaused");
    // Shavit_AlsoSaveReplayTo is v4-only. Marked optional in both builds so
    // the v3 build can probe its availability for build-mismatch detection
    // without the plugin refusing to load when the native is absent.
    MarkNativeAsOptional("Shavit_AlsoSaveReplayTo");
#if defined SHAVIT_V3
    MarkNativeAsOptional("Shavit_ShouldSaveReplayCopy");
#else
    MarkNativeAsOptional("Shavit_AddAdditionalReplayPathsHere");
#endif
}

void ShavitCompat_OnPluginStart()
{
#if !defined SHAVIT_V3
    EnsureTempReplayDir();
#endif
}

// Which shavit major version this .smx was compiled for. Compile-time constant,
// not a runtime query.
int ShavitCompat_BuildVersion()
{
#if defined SHAVIT_V3
    return 3;
#else
    return 4;
#endif
}

// Runtime detection of the shavit major version actually loaded on the server.
// Keyed on Shavit_AlsoSaveReplayTo, which is a v4-only native.
int ShavitCompat_DetectRunningVersion()
{
    if (GetFeatureStatus(FeatureType_Native, "Shavit_AlsoSaveReplayTo") == FeatureStatus_Available)
    {
        return 4;
    }
    return 3;
}

// --- Shavit forwards: thin adapters delegating to the records layer ---

public void Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp)
{
    Records_HandleFinish(client, style, time, jumps, strafes, sync, track, oldtime);
}

#if defined SHAVIT_V3
// v3: we return Plugin_Handled to ask shavit to save a /copy/ of the replay.
public Action Shavit_ShouldSaveReplayCopy(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong)
{
    return Records_ShouldSaveReplay(client, isbestreplay, istoolong) ? Plugin_Handled : Plugin_Continue;
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath)
{
    // Ignore saves that are neither our requested copy nor shavit's canonical save.
    if (!iscopy && !isbestreplay)
    {
        return;
    }

    Records_HandleReplaySaved(client, isbestreplay, replaypath, iscopy);
}
#else
// v4: we register a temp path via Shavit_AlsoSaveReplayTo, and shavit calls us back
// with the saved file in Shavit_OnReplaySaved.
public void Shavit_AddAdditionalReplayPathsHere(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong)
{
    if (!Records_ShouldSaveReplay(client, isbestreplay, istoolong))
    {
        return;
    }

    char sTempPath[PLATFORM_MAX_PATH];
    GetTempReplayPath(client, sTempPath, sizeof(sTempPath));
    Shavit_AlsoSaveReplayTo(sTempPath);
    DebugPrint("Requesting non-WR replay at %s", sTempPath);
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
{
    char replayPath[PLATFORM_MAX_PATH];
    if (replaypaths != null && replaypaths.Length > 0)
    {
        replaypaths.GetString(0, replayPath, sizeof(replayPath));
    }

    // A non-canonical save (isbestreplay=false) is ours only if the path lives in
    // our temp dir - other plugins may register their own extra replay paths too.
    bool isOurCopy = !isbestreplay && replayPath[0] != '\0' && IsTempReplayPath(replayPath);

    if (!isbestreplay && !isOurCopy)
    {
        return;
    }

    Records_HandleReplaySaved(client, isbestreplay, replayPath, isOurCopy);
}
#endif
