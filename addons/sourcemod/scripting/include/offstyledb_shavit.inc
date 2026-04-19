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
forward void   Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath);
forward void   Shavit_OnFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp);
forward Action Shavit_ShouldSaveReplayCopy(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong);
forward void   OnTimerFinished_Post(int client, float Time, int Type, int Style, bool tas, bool NewTime, int OldPosition, int NewPosition);

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
#else
#undef REQUIRE_PLUGIN
#include <shavit>
#endif

#if !defined SHAVIT_V3
int GetShavitMajorVersion()
{
    int major = SHAVIT_VERSION_MAJOR;

    return major;
}
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
#endif
