#if defined _offstyledb_records_included
 #endinput
#endif
#define _offstyledb_records_included

#pragma newdecls required
#pragma semicolon 1

// A finalized submission, captured at OnFinish time. When we wait for a replay
// save (WR, or non-WR with replay_mode=1), we stash one of these per client and
// dispatch it when OnReplaySaved fires. When no wait is needed, we build one,
// dispatch it inline, and never touch gPending.
enum struct SubmissionIntent
{
    bool  pending;
    int   rawStyle;
    float time;
    float sync;
    int   strafes;
    int   jumps;
    bool  isWR;
    char  map[64];
    char  steamId[32];
    char  name[MAX_NAME_LENGTH];
}

SubmissionIntent gPending[MAXPLAYERS + 1];

bool IsSubmittableFinish(int client, int track)
{
    return track == 0
        && gI_TimerVersion == TimerVersion_shavit
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && !Shavit_IsPracticeMode(client)
        && !Shavit_IsPaused(client);
}

void Records_HandleFinish(int client, int style, float time, int jumps, int strafes, float sync, int track, float oldtime)
{
    gPending[client].pending = false;

    DebugPrint("OnFinish: client=%d style=%d time=%f oldtime=%f track=%d", client, style, time, oldtime, track);

    if (!IsSubmittableFinish(client, track))
    {
        return;
    }

    // Non-PB filter: drop runs that don't beat the player's prior PB. oldtime=0
    // means no prior PB (first-time finish on this style), which should submit.
    if (oldtime != 0.0 && time >= oldtime)
    {
        DebugPrint("Dropping non-PB (time=%f >= oldtime=%f)", time, oldtime);
        return;
    }

    float fWR  = Shavit_GetWorldRecord(style, track);
    bool  isWR = (fWR == 0.0 || time <= fWR);

    if (!isWR && gCV_SubmitMode.IntValue == 0)
    {
        DebugPrint("Skipping non-WR (submit_mode=0)");
        return;
    }

    // Decide whether to attach a replay:
    //   replay_mode=-1  -> no replay, dispatch now
    //   replay_mode= 0  -> replay only for WRs; non-WRs dispatch now
    //   replay_mode= 1  -> replay for everything, always wait for OnReplaySaved
    bool waitForReplay;
    if (gCV_ReplayMode.IntValue == -1)
    {
        waitForReplay = false;
    }
    else if (gCV_ReplayMode.IntValue == 0)
    {
        waitForReplay = isWR;
    }
    else    // replay_mode == 1
    {
        waitForReplay = true;
    }

    SubmissionIntent intent;
    BuildIntent(client, style, time, sync, strafes, jumps, isWR, intent);

    if (!waitForReplay)
    {
        DispatchSubmission(intent, "");
        return;
    }

    // TODO: overwrite race - if player A stashed an intent, disconnected,
    // player B took the slot and finished all before A's replay save fired,
    // A's replay would dispatch B's intent. Requires B to complete a full
    // map run in <100ms so practically impossible, but a steamid check
    // before dispatch would close it.
    gPending[client] = intent;
    DebugPrint("Stashed intent for client %d (isWR=%d)", client, isWR);
}

// Fills an intent from the shavit-finish params and the client's current identity.
void BuildIntent(int client, int style, float time, float sync, int strafes, int jumps, bool isWR, SubmissionIntent intent)
{
    intent.pending  = true;
    intent.rawStyle = style;
    intent.time     = time;
    intent.sync     = sync;
    intent.strafes  = strafes;
    intent.jumps    = jumps;
    intent.isWR     = isWR;

    GetCurrentMap(intent.map, sizeof(intent.map));
    GetMapDisplayName(intent.map, intent.map, sizeof(intent.map));
    GetClientAuthId(client, AuthId_Steam3, intent.steamId, sizeof(intent.steamId));
    GetClientName(client, intent.name, sizeof(intent.name));
}

// Called from the compat layer's pre-replay-save hook. Returns true if shavit
// should save a replay we'll pick up later. If shavit refuses to save
// (istoolong), OnReplaySaved won't fire either, so we dispatch the stashed
// intent now without a replay - this applies to WR intents as well, not just
// non-WR copies.
bool Records_ShouldSaveReplay(int client, bool isbestreplay, bool istoolong)
{
    if (!gPending[client].pending)
    {
        return false;
    }

    if (istoolong)
    {
        DebugPrint("Replay too long (isWR=%d), submitting without replay", gPending[client].isWR);
        DispatchSubmission(gPending[client], "");
        gPending[client].pending = false;
        return false;
    }

    // Canonical WR saves are shavit's responsibility - we don't need to ask
    // for an extra copy.
    if (isbestreplay || gPending[client].isWR)
    {
        return false;
    }

    DebugPrint("Requesting non-WR replay copy for client %d", client);
    return true;
}

// Called from the compat layer's Shavit_OnReplaySaved handler.
// isOurCopy: the replay was saved at a path we asked for (v3: iscopy; v4:
// non-canonical path under our temp dir). Shavit's canonical WR saves arrive
// with isbestreplay=true and isOurCopy=false.
void Records_HandleReplaySaved(int client, bool isbestreplay, const char[] replayPath, bool isOurCopy)
{
    if (client == 0)
    {
        return;
    }

    // Replay uploads disabled: OnFinish already submitted everything.
    if (gCV_ReplayMode.IntValue == -1)
    {
        return;
    }

    if (!gPending[client].pending)
    {
        // Save arrived for a finish we dropped (e.g. bad style, cheats, submit_mode=0).
        // Clean up if it's our orphan; leave canonical saves alone.
        if (isOurCopy)
        {
            CleanupTempReplay(replayPath);
        }
        return;
    }

    // Match the save type to the intent type. Anything else is an early fire
    // for a save we're still waiting for, or a stray save we didn't request.
    if (gPending[client].isWR && !isbestreplay)
    {
        return;
    }
    if (!gPending[client].isWR && !isOurCopy)
    {
        return;
    }

    DebugPrint("Dispatching pending submission for client %d (isWR=%d)", client, gPending[client].isWR);
    DispatchSubmission(gPending[client], replayPath);
    gPending[client].pending = false;
}

// POSTs the finalized submission to /submit_record_nr. On success, the callback
// may chain a replay upload.
void DispatchSubmission(SubmissionIntent intent, const char[] replayPath)
{
    DebugPrint("Dispatch: map=%s steamid=%s name=%s time=%.3f style=%d isWR=%s replay=%s",
               intent.map, intent.steamId, intent.name, intent.time, intent.rawStyle,
               intent.isWR ? "true" : "false", replayPath);

    if (sv_cheats.BoolValue)
    {
        LogError("[OSdb] Attempted to submit record with sv_cheats enabled. map=%s steamid=%s time=%f",
                 intent.map, intent.steamId, intent.time);
        CleanupTempReplay(replayPath);
        return;
    }

    int mappedStyle = ConvertStyle(intent.rawStyle);
    if (mappedStyle == -1)
    {
        LogError("[OSdb] Style %d has no remote mapping - submission dropped for %s on %s (time=%f). Check the style mapping on the API server.",
                 intent.rawStyle, intent.steamId, intent.map, intent.time);
        CleanupTempReplay(replayPath);
        return;
    }

    HTTPRequest req  = new HTTPRequest(API_BASE_URL... "/submit_record_nr");
    AddHeaders(req);

    JSONObject json = new JSONObject();
    json.SetString("map", intent.map);
    json.SetString("steamid", intent.steamId);
    json.SetString("name", intent.name);
    json.SetFloat("time", intent.time);
    json.SetFloat("sync", intent.sync);
    json.SetInt("strafes", intent.strafes);
    json.SetInt("jumps", intent.jumps);
    json.SetInt("date", GetTime());
    json.SetInt("tickrate", gI_Tickrate);
    json.SetInt("style", mappedStyle);

    DataPack pack = new DataPack();
    pack.WriteString(replayPath);

    req.Post(json, OnRecordSubmitted, pack);
    delete json;
}

void UploadReplay(const char[] replayKey, const char[] replayPath)
{
    if (replayKey[0] == '\0' || replayPath[0] == '\0' || !FileExists(replayPath))
    {
        return;
    }

    DebugPrint("Uploading replay: key=%s path=%s", replayKey, replayPath);

    HTTPRequest request = new HTTPRequest(API_BASE_URL... "/upload_replay");
    AddHeaders(request);
    request.SetHeader("replay_key", replayKey);

    DataPack cleanupPack = new DataPack();
    cleanupPack.WriteString(replayPath);

    request.UploadFile(replayPath, OnReplayUploaded, cleanupPack);
}

void CleanupTempReplay(const char[] replayPath)
{
    if (replayPath[0] == '\0' || !IsTempReplayPath(replayPath) || !FileExists(replayPath))
    {
        return;
    }
    DeleteFile(replayPath);
    DebugPrint("Deleted temp replay: %s", replayPath);
}

public void OnRecordSubmitted(HTTPResponse resp, any value, const char[] error)
{
    DataPack pack = view_as<DataPack>(value);
    pack.Reset();

    char replayPath[PLATFORM_MAX_PATH];
    pack.ReadString(replayPath, sizeof(replayPath));
    delete pack;

    if (gCV_ReplayMode.IntValue == -1)
    {
        DebugPrint("Replay mode -1, not uploading replay");
        CleanupTempReplay(replayPath);
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[OSdb] Record submission failed: %s", error);
        CleanupTempReplay(replayPath);
        return;
    }

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

    if (hasReplayKey && replayKey[0] != '\0' && replayPath[0] != '\0')
    {
        DebugPrint("Got replay_key=%s, uploading %s", replayKey, replayPath);
        UploadReplay(replayKey, replayPath);
    }
    else
    {
        DebugPrint("No replay upload (hasKey=%d, pathEmpty=%d)", hasReplayKey, replayPath[0] == '\0');
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
