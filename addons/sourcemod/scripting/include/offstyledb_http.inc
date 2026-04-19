#if defined _offstyledb_http_included
 #endinput
#endif
#define _offstyledb_http_included

#pragma newdecls required
#pragma semicolon 1

#define API_BASE_URL "https://offstyles.net/api"

void AddHeaders(HTTPRequest req)
{
    char sPublicIP[32];
    gCV_PublicIP.GetString(sPublicIP, sizeof(sPublicIP));

    char sHostname[128];
    FindConVar("hostname").GetString(sHostname, sizeof(sHostname));

    req.SetHeader("public_ip", sPublicIP);
    req.SetHeader("hostname", sHostname);
    req.SetHeader("auth", gS_AuthKey);
    req.SetHeader("timer_plugin", gS_TimerVersion[gI_TimerVersion]);

    if (gB_IsProcessingBatches && strlen(gS_BulkCode) > 0)
    {
        DebugPrint("[OSdb] Adding bulk_verify header: %s", gS_BulkCode);
        req.SetHeader("bulk_verify", gS_BulkCode);
    }
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
    char base64_sTable[]  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int  base64_cFillChar = '=';

    int  nLength;
    int  resPos;

    if (sourcelen > 0)
    {
        nLength = sourcelen;
    }
    else
    {
        nLength = strlen(sString);
    }

    for (int nPos = 0; nPos < nLength; nPos++)
    {
        int cCode;

        cCode = (sString[nPos] >> 2) & 0x3f;
        resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);
        cCode = (sString[nPos] << 4) & 0x3f;

        if (++nPos < nLength)
        {
            cCode |= (sString[nPos] >> 4) & 0x0f;
        }

        resPos += FormatEx(sResult[resPos], len - resPos, "%c", base64_sTable[cCode]);

        if (nPos < nLength)
        {
            cCode = (sString[nPos] << 2) & 0x3f;

            if (++nPos < nLength)
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

        if (nPos < nLength)
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
