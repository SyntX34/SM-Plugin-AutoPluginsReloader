#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.4"

ConVar g_cvEnabled;
ConVar g_cvEmptyTime;
ConVar g_cvPluginListFile;
ConVar g_cvDebug;
ConVar g_cvChangeMap;
ConVar g_cvLogFile;
ConVar g_cvLogToFile;

float g_fLastPlayerLeaveTime;
bool g_bServerWasEmpty;
Handle g_hReloadTimer;
bool g_bReloadInProgress;

char g_sLogFilePath[PLATFORM_MAX_PATH];

enum LogLevel
{
    LOG_DEBUG = 0,
    LOG_INFO = 1,
    LOG_WARNING = 2,
    LOG_ERROR = 3,
    LOG_ACTIVITY = 4
}

public Plugin myinfo = 
{
    name = "Auto Plugin Reloader",
    author = "+SyntX",
    description = "Reloads plugins when server was empty and new client connects",
    version = PLUGIN_VERSION,
    url = "https://steamcommunity.com/id/SyntX34 && https://github.com/SyntX34"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_autoreload_enable", "1", "Enable automatic plugin reloading when server was empty", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvEmptyTime = CreateConVar("sm_autoreload_empty_time", "600.0", "How long server must be empty before triggering reload (seconds)", FCVAR_NONE, true, 1.0);
    g_cvPluginListFile = CreateConVar("sm_autoreload_plugin_list", "configs/reloadpluginslist.txt", "Path to plugin list file (relative to sourcemod folder)");
    g_cvDebug = CreateConVar("sm_autoreload_debug", "1", "Enable debug logging (1 = enable, 0 = disable)", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvChangeMap = CreateConVar("sm_autoreload_changemap", "0", "Change to random map when server was empty and new client connects (1 = enable, 0 = disable)", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvLogFile = CreateConVar("sm_autoreload_logfile", "logs/autoreload.log", "Path to log file (relative to sourcemod folder)");
    g_cvLogToFile = CreateConVar("sm_autoreload_logtofile", "1", "Enable logging to file (1 = enable, 0 = disable)", FCVAR_NONE, true, 0.0, true, 1.0);
    
    AutoExecConfig(true);
    
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("player_connect", Event_PlayerConnect, EventHookMode_Pre);
    
    g_fLastPlayerLeaveTime = GetGameTime();
    g_bServerWasEmpty = false;
    g_bReloadInProgress = false;
    
    InitializeLogFile();
    
    AutoReloadLog("Plugin started. Initializing...", LOG_INFO);
    
    int playerCount = GetRealPlayerCount();
    AutoReloadLog("Current real player count: %d", LOG_INFO, playerCount);
    
    if (playerCount == 0)
    {
        g_bServerWasEmpty = true;
        g_fLastPlayerLeaveTime = GetGameTime();
        AutoReloadLog("Server is empty on startup. Starting empty check timer.", LOG_INFO);
        CreateEmptyCheckTimer();
    }
}

public void OnMapStart()
{
    g_fLastPlayerLeaveTime = GetGameTime();
    g_bServerWasEmpty = false;
    g_bReloadInProgress = false;
    
    if (g_hReloadTimer != INVALID_HANDLE)
    {
        KillTimer(g_hReloadTimer);
        g_hReloadTimer = INVALID_HANDLE;
        AutoReloadLog("Stopped empty check timer on map start.", LOG_INFO);
    }
    
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));
    AutoReloadLog("Map started: %s. Resetting auto-reload state.", LOG_INFO, mapName);
    
    int playerCount = GetRealPlayerCount();
    AutoReloadLog("Real player count on map start: %d", LOG_INFO, playerCount);
    
    if (playerCount == 0)
    {
        g_bServerWasEmpty = true;
        g_fLastPlayerLeaveTime = GetGameTime();
        AutoReloadLog("Server is empty on map start. Starting empty check timer.", LOG_INFO);
        CreateEmptyCheckTimer();
    }
}

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client))
    {
        AutoReloadLog("Client %d is a bot, skipping auto-reload check.", LOG_DEBUG, client);
        return;
    }
    
    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    AutoReloadLog("Client %d (%s) authorized (SteamID: %s). Checking auto-reload conditions.", LOG_INFO, client, clientName, auth);
    
    if (g_bReloadInProgress)
    {
        AutoReloadLog("Reload already in progress, skipping.", LOG_WARNING);
        return;
    }
    
    if (!g_cvEnabled.BoolValue)
    {
        AutoReloadLog("Auto-reload system is disabled.", LOG_INFO);
        return;
    }
    
    int realPlayers = GetRealPlayerCount();
    AutoReloadLog("Real player count before new client: %d", LOG_DEBUG, realPlayers);
    
    if (g_bServerWasEmpty && realPlayers == 0)
    {
        float emptyTime = GetGameTime() - g_fLastPlayerLeaveTime;
        float requiredTime = g_cvEmptyTime.FloatValue;
        
        char emptyTimeStr[64], requiredTimeStr[64];
        FormatTimeDuration(emptyTime, emptyTimeStr, sizeof(emptyTimeStr));
        FormatTimeDuration(requiredTime, requiredTimeStr, sizeof(requiredTimeStr));
        
        AutoReloadLog("Server was empty for %s. Required: %s", LOG_INFO, emptyTimeStr, requiredTimeStr);
        
        if (emptyTime >= requiredTime)
        {
            AutoReloadLog("Server was empty for sufficient time. Processing auto-reload actions.", LOG_ACTIVITY);
            g_bReloadInProgress = true;
            
            ReloadPluginsSilently();
            
            if (g_cvChangeMap.BoolValue)
            {
                ReloadMap();
            }
            
            g_bReloadInProgress = false;
            AutoReloadLog("Auto-reload process completed for client %s (%s).", LOG_ACTIVITY, clientName, auth);
        }
        else
        {
            AutoReloadLog("Server was empty but not long enough (%s < %s).", LOG_INFO, emptyTimeStr, requiredTimeStr);
        }
        
        g_bServerWasEmpty = false;
        if (g_hReloadTimer != INVALID_HANDLE)
        {
            KillTimer(g_hReloadTimer);
            g_hReloadTimer = INVALID_HANDLE;
            AutoReloadLog("Stopped empty check timer.", LOG_INFO);
        }
    }
    else
    {
        AutoReloadLog("Auto-reload conditions not met: ServerWasEmpty=%d, RealPlayers=%d", LOG_DEBUG, g_bServerWasEmpty, realPlayers);
    }
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (client > 0 && !IsFakeClient(client))
    {
        char clientName[MAX_NAME_LENGTH];
        char reason[128];
        GetClientName(client, clientName, sizeof(clientName));
        event.GetString("reason", reason, sizeof(reason));
        
        AutoReloadLog("Player %s (%d) disconnected (Reason: %s). Checking if this was the last real player.", LOG_INFO, clientName, client, reason);
        
        int realPlayersBefore = GetRealPlayerCount();
        AutoReloadLog("Real players before disconnect: %d", LOG_DEBUG, realPlayersBefore);
        
        if (realPlayersBefore == 1)
        {
            g_fLastPlayerLeaveTime = GetGameTime();
            g_bServerWasEmpty = true;
            
            char timeStr[32];
            FormatTime(timeStr, sizeof(timeStr), "%Y-%m-%d %H:%M:%S", GetTime());
            AutoReloadLog("Last real player (%s) left at %s. Server is now empty.", LOG_ACTIVITY, clientName, timeStr);
            
            CreateEmptyCheckTimer();
        }
        else
        {
            AutoReloadLog("Not the last player (%d remain). No auto-reload trigger.", LOG_DEBUG, realPlayersBefore - 1);
        }
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
    char clientName[MAX_NAME_LENGTH];
    char address[32];
    event.GetString("name", clientName, sizeof(clientName));
    event.GetString("address", address, sizeof(address));
    
    AutoReloadLog("Player connecting: %s from %s", LOG_INFO, clientName, address);
    return Plugin_Continue;
}

void CreateEmptyCheckTimer()
{
    if (g_hReloadTimer != INVALID_HANDLE)
    {
        KillTimer(g_hReloadTimer);
    }
    
    g_hReloadTimer = CreateTimer(5.0, Timer_CheckEmpty, _, TIMER_REPEAT);
    AutoReloadLog("Started empty check timer (5 second intervals).", LOG_INFO);
}

public Action Timer_CheckEmpty(Handle timer)
{
    if (!g_cvEnabled.BoolValue)
    {
        g_hReloadTimer = INVALID_HANDLE;
        AutoReloadLog("Auto-reload disabled. Stopping empty check timer.", LOG_INFO);
        return Plugin_Stop;
    }
    
    int realPlayers = GetRealPlayerCount();
    
    if (realPlayers > 0)
    {
        g_bServerWasEmpty = false;
        g_hReloadTimer = INVALID_HANDLE;
        
        char timeStr[32];
        FormatTime(timeStr, sizeof(timeStr), "%Y-%m-%d %H:%M:%S", GetTime());
        AutoReloadLog("Players returned at %s. Stopping empty check timer.", LOG_INFO, timeStr);
        
        return Plugin_Stop;
    }
    
    g_bServerWasEmpty = true;
    
    float emptyTime = GetGameTime() - g_fLastPlayerLeaveTime;
    char emptyTimeStr[64];
    FormatTimeDuration(emptyTime, emptyTimeStr, sizeof(emptyTimeStr));
    
    AutoReloadLog("Server still empty for %s. Continuing to monitor...", LOG_DEBUG, emptyTimeStr);
    
    return Plugin_Continue;
}

int GetRealPlayerCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i))
        {
            count++;
        }
    }
    return count;
}

void ReloadPluginsSilently()
{
    if (!g_cvEnabled.BoolValue)
        return;
    
    char pluginListPath[PLATFORM_MAX_PATH];
    g_cvPluginListFile.GetString(pluginListPath, sizeof(pluginListPath));
    
    char fullPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, fullPath, sizeof(fullPath), pluginListPath);
    
    if (!FileExists(fullPath))
    {
        AutoReloadLog("ERROR: Plugin list file not found: %s", LOG_ERROR, fullPath);
        return;
    }
    
    File file = OpenFile(fullPath, "r");
    if (file == null)
    {
        AutoReloadLog("ERROR: Failed to open plugin list file: %s", LOG_ERROR, fullPath);
        return;
    }
    
    char pluginName[64];
    int reloadCount = 0;
    int failCount = 0;
    
    AutoReloadLog("Starting plugin reload process from file: %s", LOG_ACTIVITY, fullPath);
    
    while (!file.EndOfFile() && file.ReadLine(pluginName, sizeof(pluginName)))
    {
        TrimString(pluginName);
        StripQuotes(pluginName);
        
        if (strlen(pluginName) == 0 || pluginName[0] == '#')
            continue;

        AutoReloadLog("Attempting to reload plugin: %s", LOG_INFO, pluginName);
        
        Handle plugin = FindPluginByFile(pluginName);
        if (plugin != INVALID_HANDLE)
        {
            ServerCommand("sm plugins reload %s", pluginName);
            reloadCount++;
            AutoReloadLog("Successfully reloaded plugin: %s", LOG_INFO, pluginName);
        }
        else
        {
            failCount++;
            AutoReloadLog("WARNING: Plugin not found or not loaded: %s", LOG_WARNING, pluginName);
        }
    }
    
    delete file;
    AutoReloadLog("Plugin reload process completed. Success: %d, Failed: %d, Total processed: %d", LOG_ACTIVITY, reloadCount, failCount, reloadCount + failCount);
}

void ReloadMap()
{
    char currentMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));
    
    AutoReloadLog("Preparing to reload current map: %s", LOG_ACTIVITY, currentMap);
    
    DataPack dp = new DataPack();
    dp.WriteString(currentMap);
    CreateTimer(1.0, Timer_ReloadMap, dp);
}

public Action Timer_ReloadMap(Handle timer, DataPack dp)
{
    dp.Reset();
    char mapName[64];
    dp.ReadString(mapName, sizeof(mapName));
    delete dp;
    
    AutoReloadLog("Executing map change to: %s", LOG_ACTIVITY, mapName);
    ServerCommand("changelevel %s", mapName);
    
    return Plugin_Stop;
}

void FormatTimeDuration(float seconds, char[] buffer, int maxlength)
{
    int totalSeconds = RoundToFloor(seconds);
    
    if (totalSeconds < 60)
    {
        Format(buffer, maxlength, "%d seconds", totalSeconds);
    }
    else if (totalSeconds < 3600)
    {
        int minutes = totalSeconds / 60;
        int secs = totalSeconds % 60;
        Format(buffer, maxlength, "%d minute%s %d second%s", minutes, minutes == 1 ? "" : "s", secs, secs == 1 ? "" : "s");
    }
    else if (totalSeconds < 86400)
    {
        int hours = totalSeconds / 3600;
        int minutes = (totalSeconds % 3600) / 60;
        Format(buffer, maxlength, "%d hour%s %d minute%s", hours, hours == 1 ? "" : "s", minutes, minutes == 1 ? "" : "s");
    }
    else
    {
        int days = totalSeconds / 86400;
        int hours = (totalSeconds % 86400) / 3600;
        Format(buffer, maxlength, "%d day%s %d hour%s", days, days == 1 ? "" : "s", hours, hours == 1 ? "" : "s");
    }
}

void InitializeLogFile()
{
    char logPath[PLATFORM_MAX_PATH];
    g_cvLogFile.GetString(logPath, sizeof(logPath));
    BuildPath(Path_SM, g_sLogFilePath, sizeof(g_sLogFilePath), logPath);
    
    char logDir[PLATFORM_MAX_PATH];
    strcopy(logDir, sizeof(logDir), g_sLogFilePath);
    int lastSlash = FindCharInString(logDir, '/', true);
    if (lastSlash != -1)
    {
        logDir[lastSlash] = '\0';
        if (!DirExists(logDir))
        {
            CreateDirectory(logDir, 777);
        }
    }
    
    WriteToLogFile("=== AUTO PLUGIN RELOADER STARTED ===", LOG_ACTIVITY);
    
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));
    WriteToLogFile("Server Map: %s", LOG_INFO, mapName);
    
    int maxPlayers = GetMaxHumanPlayers();
    WriteToLogFile("Max Players: %d", LOG_INFO, maxPlayers);
}

void WriteToLogFile(const char[] format, LogLevel level = LOG_INFO, any ...)
{
    if (!g_cvLogToFile.BoolValue)
        return;
    
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 3);
    
    File logFile = OpenFile(g_sLogFilePath, "a");
    if (logFile == null)
    {
        PrintToServer("[AUTO-RELOAD] ERROR: Could not open log file: %s", g_sLogFilePath);
        return;
    }
    
    char timestamp[32];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", GetTime());
    
    char levelStr[16];
    GetLogLevelString(level, levelStr, sizeof(levelStr));
    
    logFile.WriteLine("[%s] [%s] %s", timestamp, levelStr, buffer);
    logFile.Flush();
    delete logFile;
}

void GetLogLevelString(LogLevel level, char[] buffer, int maxlength)
{
    switch (level)
    {
        case LOG_DEBUG: strcopy(buffer, maxlength, "DEBUG");
        case LOG_INFO: strcopy(buffer, maxlength, "INFO");
        case LOG_WARNING: strcopy(buffer, maxlength, "WARN");
        case LOG_ERROR: strcopy(buffer, maxlength, "ERROR");
        case LOG_ACTIVITY: strcopy(buffer, maxlength, "ACTIVITY");
        default: strcopy(buffer, maxlength, "UNKNOWN");
    }
}

void AutoReloadLog(const char[] format, LogLevel level = LOG_INFO, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 3);
    
    if (g_cvDebug.BoolValue)
    {
        char timestamp[32];
        FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", GetTime());
        char levelStr[16];
        GetLogLevelString(level, levelStr, sizeof(levelStr));
        PrintToServer("[AUTO-RELOAD %s] %s", timestamp, buffer);
    }
    
    if (level == LOG_INFO || level == LOG_ACTIVITY || level == LOG_ERROR)
    {
        WriteToLogFile(buffer, level);
    }
}

public void OnPluginEnd()
{
    if (g_hReloadTimer != INVALID_HANDLE)
    {
        KillTimer(g_hReloadTimer);
        g_hReloadTimer = INVALID_HANDLE;
        AutoReloadLog("Plugin unloaded. Stopped empty check timer.", LOG_INFO);
    }
    
    AutoReloadLog("Auto Plugin Reloader shutting down.", LOG_ACTIVITY);
    WriteToLogFile("=== AUTO PLUGIN RELOADER STOPPED ===", LOG_ACTIVITY);
}