#if defined _offstyledb_styles_included
 #endinput
#endif
#define _offstyledb_styles_included

#pragma newdecls required
#pragma semicolon 1

void GetStyleMapping(bool forceRefresh = false)
{
    DebugPrint("Starting style mapping request (forceRefresh: %s)", forceRefresh ? "true" : "false");

    if (!forceRefresh)
    {
        char temp[160];
        temp = gS_StyleHash;
        HashStyleConfig();

        if (strcmp(temp, gS_StyleHash) == 0)
        {
            DebugPrint("Style hash unchanged, skipping mapping request");
            return;
        }
    }
    else
    {
        DebugPrint("Force refresh requested, bypassing hash check");
    }

    DebugPrint("Style hash changed or forced refresh, requesting new mapping from server");

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
            int iSize = fFile.Position;
            fFile.Seek(0, SEEK_SET);

            char[] sFileContents = new char[iSize + 1];
            fFile.ReadString(sFileContents, iSize + 1, iSize);
            delete fFile;

            char[] sFileContentsEncoded = new char[iSize * 2];
            Crypt_Base64Encode(sFileContents, sFileContentsEncoded, iSize * 2, iSize);

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
        LogError("[OSdb] configs/shavit-styles.cfg is missing - style mapping cannot be synced. Submissions will be dropped until shavit is installed correctly.");
        delete hJSONObject;
        delete hHTTPRequest;
        return;
    }

    hHTTPRequest.Post(hJSONObject, Callback_OnStyleMapping);

    delete hJSONObject;
}

int ConvertStyle(int style)
{
    if (gM_StyleMapping == null)
    {
        LogError("[OSdb] Style mapping is null in ConvertStyle");
        DebugPrint("ConvertStyle called but style mapping is null");
        return -1;
    }

    char s[16];
    IntToString(style, s, sizeof(s));

    DebugPrint("Converting style %d (key: %s)", style, s);

    int out;
    if (gM_StyleMapping.GetValue(s, out))
    {
        DebugPrint("Style %d converted to %d", style, out);
        return out;
    }

    DebugPrint("Style %d not found in mapping, returning -1", style);
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
    DebugPrint("Style mapping callback received - Status: %d", resp.Status);

    if (resp.Status != HTTPStatus_OK || resp.Data == null)
    {
        LogError("[OSdb] Style mapping fetch failed (status=%d). Keeping any existing mapping; will retry on next map change.", resp.Status);
        // Invalidate the cached hash so the next OnMapEnd tries again even if
        // shavit-styles.cfg didn't change in between.
        gS_StyleHash[0] = '\0';
        return;
    }

    DebugPrint("Style mapping response received successfully");

    JSONObject data = view_as<JSONObject>(resp.Data);
    char       s_Data[512];
    data.GetString("data", s_Data, sizeof(s_Data));
    // dont think we need to do it here, but doing it anyway
    delete data;

    DebugPrint("Style mapping data extracted: %s", s_Data);

    // check if StringMap is still valid FUCKING INVALID HANDLE
    if (gM_StyleMapping == null)
    {
        LogError("[OSdb] Style mapping handle is null, recreating...");
        DebugPrint("Style mapping handle was null, recreating");
        gM_StyleMapping = new StringMap();
    }

    if (gM_StyleMapping.Size > 0)
    {
        DebugPrint("Clearing existing style mapping (%d entries)", gM_StyleMapping.Size);
        gM_StyleMapping.Clear();
    }

    const int MAX_STYLES = 512;    // fucking Hope people arent adding this many....
    char      parts[MAX_STYLES][8];

    int       count = ExplodeString(s_Data, ",", parts, sizeof(parts), sizeof(parts[]));

    DebugPrint("Processing style mapping with %d parts", count);

    for (int i = 0; i < count - 1; i += 2)
    {
        char key[8];
        strcopy(key, sizeof(key), parts[i]);

        int ivalue = StringToInt(parts[i + 1]);

        gM_StyleMapping.SetValue(key, ivalue);
        DebugPrint("Mapped style %s -> %d", key, ivalue);
    }

    DebugPrint("Style mapping completed with %d styles", gM_StyleMapping.Size);
}

public Action Command_ViewStyleMap(int client, int args)
{
    DebugPrint("Command_ViewStyleMap called by client %d", client);

    if (gM_StyleMapping == null || gM_StyleMapping.Size == 0)
    {
        PrintToChat(client, "[OSdb] Style map is empty or null");
        DebugPrint("Style mapping is null or empty");
        return Plugin_Handled;
    }

    StringMapSnapshot snapshot = gM_StyleMapping.Snapshot();
    int               count    = snapshot.Length;

    DebugPrint("Displaying style mapping with %d entries", count);
    PrintToChat(client, "[OSdb] Style Mapping (%d entries):", count);

    char key[16];
    int  value;
    for (int i = 0; i < count; i++)
    {
        snapshot.GetKey(i, key, sizeof(key));
        gM_StyleMapping.GetValue(key, value);

        PrintToChat(client, "[StyleMap] %s: %d", key, value);
    }

    delete snapshot;
    return Plugin_Handled;
}

public Action Command_RefreshMapping(int client, int args)
{
    if (!IsOSdbAdmin(client))
    {
        ReplyToCommand(client, "[OSdb] You are not permitted to refresh the style mapping.");
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[OSdb] Refreshing style mapping...");

    if (gM_StyleMapping == null)
    {
        gM_StyleMapping = new StringMap();
    }

    GetStyleMapping(true);
    return Plugin_Handled;
}
