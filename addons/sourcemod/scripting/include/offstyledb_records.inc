#if defined _offstyledb_records_included
 #endinput
#endif
#define _offstyledb_records_included

#pragma newdecls required
#pragma semicolon 1

bool IsSubmittableFinish(int client, int track)
{
    return track == 0
        && gI_TimerVersion == TimerVersion_shavit
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && !Shavit_IsPracticeMode(client)
        && !Shavit_IsPaused(client);
}

#if defined SHAVIT_V3
// v3: requests shavit to save a replay copy for non-WR PBs when replay_mode=1.
// Also submits the record directly when shavit refuses to save (istoolong),
// since OnFinish already deferred non-WR replay_mode=1 submissions to us.
public Action Shavit_ShouldSaveReplayCopy(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong)
{
    DebugPrint("[OSdb] ShouldSaveReplayCopy fired: client=%d style=%d time=%f oldtime=%f track=%d isbestreplay=%d istoolong=%d replay_mode=%d",
               client, style, time, oldtime, track, isbestreplay, istoolong, gCV_ReplayMode.IntValue);

    if (gCV_ReplayMode.IntValue != 1 || isbestreplay)
    {
        return Plugin_Continue;
    }

    if (!IsSubmittableFinish(client, track) || oldtime <= time)
    {
        return Plugin_Continue;
    }

    if (gCV_SubmitMode.IntValue == 0)
    {
        return Plugin_Continue;
    }

    float fWR = Shavit_GetWorldRecord(style, track);
    if (fWR == 0.0 || time <= fWR)
    {
        // Actually a WR - handled via shavit's canonical replay path
        return Plugin_Continue;
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
        return Plugin_Continue;
    }

    DebugPrint("[OSdb] Requesting non-WR replay copy");
    return Plugin_Handled;
}
#else
// v4: registers a temp replay path for shavit to save to (normal case), or submits
// the record directly without a replay when shavit refuses to save (istoolong).
// OnFinish already deferred. Fires between Shavit_OnFinish and Shavit_OnReplaySaved.
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
#endif

// Handles WR submissions, and non-WR submissions when replay_mode=1.
// Fires after the replay file has been written to disk.
#if defined SHAVIT_V3
public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, bool iscopy, const char[] replaypath)
#else
public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime, float perfs, float avgvel, float maxvel, int timestamp, bool isbestreplay, bool istoolong, ArrayList replaypaths, ArrayList frames, int preframes, int postframes, const char[] name)
#endif
{
    if (client == 0 || !IsSubmittableFinish(client, track))
    {
        return;
    }

    // Replays disabled: OnFinish submits everything, ignore this forward entirely
    // so shavit not firing it (e.g. replay saving disabled server-side) never
    // swallows a time.
    if (gCV_ReplayMode.IntValue == -1)
    {
        return;
    }

    float fWR = Shavit_GetWorldRecord(style, track);
    bool  isWR = (fWR == 0.0 || time <= fWR);

#if defined SHAVIT_V3
    if (iscopy)
    {
        // Non-WR replay copy we requested via Shavit_ShouldSaveReplayCopy
        if (gCV_ReplayMode.IntValue != 1 || gCV_SubmitMode.IntValue == 0 || oldtime <= time || isWR)
        {
            CleanupTempReplay(replaypath);
            return;
        }
    }
    else
    {
        // Canonical (WR) save
        if (!isbestreplay || !isWR)
        {
            return;
        }
    }
#else
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
#endif

    DebugPrint("[OSdb] OnReplaySaved submit: isWR=%d submit_mode=%d", isWR, gCV_SubmitMode.IntValue);

    char sMap[64];
    GetCurrentMap(sMap, sizeof(sMap));
    GetMapDisplayName(sMap, sMap, sizeof(sMap));

    char sSteamID[32];
    GetClientAuthId(client, AuthId_Steam3, sSteamID, sizeof(sSteamID));

    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));

    int sDate = GetTime();

#if defined SHAVIT_V3
    SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style, isWR, replaypath);
#else
    char sReplayPath[PLATFORM_MAX_PATH];
    if (replaypaths != null && replaypaths.Length > 0)
    {
        replaypaths.GetString(0, sReplayPath, sizeof(sReplayPath));
    }

    SendRecord(sMap, sSteamID, sName, sDate, time, sync, strafes, jumps, style, isWR, sReplayPath);
#endif
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

    if (isWR && gCV_ReplayMode.IntValue != -1)
    {
        // WRs are handled by Shavit_OnReplaySaved with the correct replay file.
        // When replays are disabled we submit here instead, since OnReplaySaved
        // may not fire at all.
        return;
    }

    if (!isWR && gCV_SubmitMode.IntValue == 0)
    {
        DebugPrint("[OSdb] Skipping non-WR submission due to submit mode = 0 (WRs only)");
        return;
    }

    if (!isWR && gCV_ReplayMode.IntValue == 1)
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
