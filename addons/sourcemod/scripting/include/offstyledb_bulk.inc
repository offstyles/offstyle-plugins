#if defined _offstyledb_bulk_included
 #endinput
#endif
#define _offstyledb_bulk_included

#pragma newdecls required
#pragma semicolon 1

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

    int bulkMode = gCV_BulkUploadMode.IntValue;
    DebugPrint("Bulk upload mode: %d (-1=no times, 0=WRs only, 1=all times)", bulkMode);

    if (bulkMode == -1)
    {
        PrintToServer("[OSdb] Bulk upload disabled (mode = -1), skipping record collection");
        DebugPrint("Bulk upload skipped due to mode = -1");
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
        LogError("[OSdb] SQL_GetRecords_Callback results are null, SQL error: %s", error);
        return;
    }

    if (results.RowCount == 0)
    {
        LogError("[OSdb] SQL_GetRecords_Callback rowcount is 0");
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
    DebugPrint("Created HTTP request to %s/bulk_records", API_BASE_URL);
    AddHeaders(hHTTPRequest);

    JSONObject hRecordsList = new JSONObject();
    hRecordsList.Set("records", hArray);

    DataPack pack = new DataPack();
    pack.WriteCell(gI_CurrentBatch);
    pack.WriteCell(hArray.Length);

    DebugPrint("Sending batch %d with %d records", gI_CurrentBatch + 1, hArray.Length);
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

    DebugPrint("Callback_OnBatchSent received - Status: %d", resp.Status);

    if (resp.Status != HTTPStatus_OK)
    {
        LogError("[OSdb] Batch %d failed to send: status = %d", batchNumber + 1, resp.Status);
        DebugPrint("Batch %d failed with HTTP status %d", batchNumber + 1, resp.Status);

        // Try to extract error message from response
        if (resp.Data != null)
        {
            JSONObject errorData = view_as<JSONObject>(resp.Data);
            char errorMsg[256];
            if (errorData.GetString("error", errorMsg, sizeof(errorMsg)))
            {
                DebugPrint("Server error message: %s", errorMsg);
                LogError("[OSdb] Server error: %s", errorMsg);
            }
            if (errorData.GetString("message", errorMsg, sizeof(errorMsg)))
            {
                DebugPrint("Server message: %s", errorMsg);
                LogError("[OSdb] Server message: %s", errorMsg);
            }
        }
        else
        {
            DebugPrint("No response data available");
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
        delete gA_AllRecords;
        gA_AllRecords = null;
    }

    gS_BulkCode[0] = '\0';

    DebugPrint("Batch processing state reset complete");
    PrintToServer("[OSdb] Batch processing completed.");
}
