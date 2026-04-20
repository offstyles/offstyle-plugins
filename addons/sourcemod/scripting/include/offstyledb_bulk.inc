#if defined _offstyledb_bulk_included
 #endinput
#endif
#define _offstyledb_bulk_included

#pragma newdecls required
#pragma semicolon 1

public Action Command_SendAllWRs(int client, int args)
{
    if (!IsOSdbAdmin(client))
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to fetch the records list.");
        return Plugin_Handled;
    }

    if (gB_IsProcessingBatches)
    {
        ReplyToCommand(client, "[OSdb] Already processing batches. Please wait for current operation to complete.");
        return Plugin_Handled;
    }

    // Flag immediately so a second osdb_get_all_wrs call doesn't slip through
    // the guard while /bulk_verification and the SQL query are in flight.
    // Every failure path below clears this back to false.
    gB_IsProcessingBatches = true;

    ReplyToCommand(client, "[OSdb] Requesting bulk verification...");
    RequestBulkVerification();

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
        DebugPrint("Bulk verification failed: status = %d, data = null", resp.Status);
        gB_IsProcessingBatches = false;
        return;
    }

    JSONObject data = view_as<JSONObject>(resp.Data);

    if (!data.HasKey("key_to_send_times"))
    {
        DebugPrint("Bulk verification response missing 'key_to_send_times' field");
        delete data;
        gB_IsProcessingBatches = false;
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

    int bulkMode = gCV_BulkUploadMode.IntValue;
    DebugPrint("Bulk upload mode: %d (-1=no times, 0=WRs only, 1=all times)", bulkMode);

    if (bulkMode == -1)
    {
        PrintToServer("[OSdb] Bulk upload disabled (mode = -1), skipping record collection");
        gB_IsProcessingBatches = false;
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
        DebugPrint("SQL_GetRecords_Callback results are null, SQL error: %s", error);
        gB_IsProcessingBatches = false;
        return;
    }

    if (results.RowCount == 0)
    {
        DebugPrint("SQL_GetRecords_Callback rowcount is 0");
        gB_IsProcessingBatches = false;
        return;
    }

    gI_CurrentBatch = 0;
    gI_TotalRecords = 0;

    if (gA_AllRecords != null)
    {
        for (int i = 0; i < gA_AllRecords.Length; i++)
        {
            JSONObject hJSON = view_as<JSONObject>(gA_AllRecords.Get(i));
            delete hJSON;
        }
        delete gA_AllRecords;
    }
    gA_AllRecords = new ArrayList();

    PrintToServer("[OSdb] Collecting %d records for batch processing...", results.RowCount);

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

    PrintToServer("[OSdb] Collected %d records, starting batch processing...", gI_TotalRecords);
    ProcessNextBatch();
}

JSONObject GetTimeJsonFromResult(DBResultSet results)
{
    char sMap[64];
    results.FetchString(0, sMap, sizeof(sMap));

    char sSteamID[32];
    results.FetchString(1, sSteamID, sizeof(sSteamID));

    // Shavit stores auth as an INT account ID; API expects Steam3 form. Match the
    // casing AuthId_Steam3 uses for single submissions so both paths key identically.
    Format(sSteamID, sizeof(sSteamID), "[U:1:%s]", sSteamID);

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

void ProcessNextBatch()
{
    DebugPrint("ProcessNextBatch called - gB_IsProcessingBatches: %s, gS_BulkCode length: %d",
               gB_IsProcessingBatches ? "true" : "false", strlen(gS_BulkCode));
    DebugPrint("Current bulk code value: %s", gS_BulkCode);

    if (gA_AllRecords == null || gA_AllRecords.Length == 0)
    {
        PrintToServer("[OSdb] No more records to process, finishing batch operation.");
        FinishBatchProcessing();
        return;
    }

    int startIndex = gI_CurrentBatch * gI_BatchSize;
    int endIndex = startIndex + gI_BatchSize;

    if (startIndex >= gI_TotalRecords)
    {
        PrintToServer("[OSdb] All batches processed, finishing operation.");
        FinishBatchProcessing();
        return;
    }

    if (endIndex > gI_TotalRecords)
    {
        endIndex = gI_TotalRecords;
    }

    PrintToServer("[OSdb] Processing batch %d (%d-%d of %d records)...",
                    gI_CurrentBatch + 1, startIndex + 1, endIndex, gI_TotalRecords);

    JSONArray hArray = new JSONArray();

    for (int i = startIndex; i < endIndex; i++)
    {
        JSONObject hJSON = view_as<JSONObject>(gA_AllRecords.Get(i));
        hArray.Push(hJSON);
    }

    DebugPrint("Created JSON array with %d records", hArray.Length);

    HTTPRequest hHTTPRequest = new HTTPRequest(API_BASE_URL... "/bulk_records");
    AddHeaders(hHTTPRequest);
    hHTTPRequest.SetHeader("bulk_verify", gS_BulkCode);

    DataPack pack = new DataPack();
    pack.WriteCell(gI_CurrentBatch);
    pack.WriteCell(hArray.Length);

    // /bulk_records is Json<Vec<RecordForm>>, i.e. a bare array - don't wrap.
    DebugPrint("Sending batch %d with %d records", gI_CurrentBatch + 1, hArray.Length);
    hHTTPRequest.Post(hArray, Callback_OnBatchSent, pack);

    delete hArray;
}

public void Callback_OnBatchSent(HTTPResponse resp, any value)
{
    DataPack pack = view_as<DataPack>(value);
    pack.Reset();
    int batchNumber = pack.ReadCell();
    int batchSize = pack.ReadCell();
    delete pack;

    DebugPrint("Callback_OnBatchSent received - Status: %d", resp.Status);

    if (resp.Status != HTTPStatus_OK)
    {
        DebugPrint("Batch %d failed with HTTP status %d", batchNumber + 1, resp.Status);

        if (resp.Data != null)
        {
            JSONObject errorData = view_as<JSONObject>(resp.Data);
            char errorMsg[256];
            if (errorData.GetString("error", errorMsg, sizeof(errorMsg)))
            {
                DebugPrint("Server error message: %s", errorMsg);
            }
            if (errorData.GetString("message", errorMsg, sizeof(errorMsg)))
            {
                DebugPrint("Server message: %s", errorMsg);
            }
        }

        PrintToServer("[OSdb] Batch %d failed, stopping batch processing.", batchNumber + 1);
        FinishBatchProcessing();
        return;
    }

    PrintToServer("[OSdb] Batch %d (%d records) sent successfully.", batchNumber + 1, batchSize);
    DebugPrint("Batch %d completed successfully", batchNumber + 1);

    gI_CurrentBatch++;
    ProcessNextBatch();
}

void FinishBatchProcessing()
{
    DebugPrint("FinishBatchProcessing called - clearing bulk code: %s", gS_BulkCode);

    gB_IsProcessingBatches = false;
    gI_CurrentBatch = 0;
    gI_TotalRecords = 0;

    if (gA_AllRecords != null)
    {
        DebugPrint("Cleaning up %d records from ArrayList", gA_AllRecords.Length);
        // ArrayList stores the handle values; deleting the list doesn't close
        // the per-row JSONObjects, so walk and delete them first.
        for (int i = 0; i < gA_AllRecords.Length; i++)
        {
            JSONObject hJSON = view_as<JSONObject>(gA_AllRecords.Get(i));
            delete hJSON;
        }
        delete gA_AllRecords;
        gA_AllRecords = null;
    }

    gS_BulkCode[0] = '\0';

    DebugPrint("Batch processing state reset complete");
    PrintToServer("[OSdb] Batch processing completed.");
}
