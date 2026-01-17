// enforce semicolons after each code statement
#pragma semicolon 1
#pragma newdecls required // Ensure new-style declarations are enforced

#include <sourcemod>
#include <sdktools> // Required for GetClientAbsOrigin, TeleportEntity, TR_TraceHullFilter, etc.
#include <sdkhooks>
#include <sdktools_functions.inc> // Provides GetEntPropVector, GetEntProp (used by our stock helpers)
#include <sdktools_stocks.inc>   // Contains various stock functions
#include <sdktools_trace.inc>   // Contains TR_TraceRayFilterEx, TR_DidHit etc.

// Define common constants manually as they might not be picked up by your compiler setup
#if !defined INT_MAX_DIGITS
    #define INT_MAX_DIGITS 12 // Sufficient for a 32-bit integer (-2147483648 to 2147483647)
#endif

#if !defined COLLISION_GROUP_PLAYER_MOVEMENT
    #define COLLISION_GROUP_PLAYER_MOVEMENT 5 // Common value for player movement collision group
#endif
#if !defined COLLISION_GROUP_DEBRIS_TRIGGER
    #define COLLISION_GROUP_DEBRIS_TRIGGER 14 // Corrected value for debris trigger collision group
#endif
#if !defined COLLISION_GROUP_WEAPON
    #define COLLISION_GROUP_WEAPON 13 // Common value for weapon collision group
#endif

// Define Prop_Send if it's not coming from sdktools or other includes
#if !defined Prop_Send
    #define Prop_Send 0 // This is the value for Prop_Send, usually defined in sdktools.inc or similar
#endif

// Define FFADE_* constants if they are not coming from client.inc or sdktools
#if !defined FFADE_OUT
    #define FFADE_OUT (1<<0)
#endif
#if !defined FFADE_STAYOUT
    #define FFADE_STAYOUT (1<<1)
#endif
#if !defined FFADE_PURGE
    #define FFADE_PURGE (1<<2)
#endif
#if !defined FFADE_IN
    #define FFADE_IN (1<<3)
#endif

// Define HIDEHUD_* constants if they are not coming from client.inc or sdktools
#if !defined HIDEHUD_WEAPONSELECTION
    #define HIDEHUD_WEAPONSELECTION (1<<0)
#endif
#if !defined HIDEHUD_HEALTH
    #define HIDEHUD_HEALTH (1<<1)
#endif
#if !defined HIDEHUD_CROSSHAIR
    #define HIDEHUD_CROSSHAIR (1<<2)
#endif

// Define PLATFORM_MAX_PATH if not defined (for APLRes AskPluginLoad2, though now unused)
#if !defined PLATFORM_MAX_PATH
    #define PLATFORM_MAX_PATH 260 // Common value for max path length
#endif


#undef REQUIRE_EXTENSIONS // This might be from the original plugin, keep for compatibility if needed.

#include "collisionhook" // Assumed to provide collision group definitions (many are now defined directly above)

#define PLUGIN_VERSION "1.9.2" // Updated version for trace filter logic refinement


#define KILLPROTECTION_DISABLE_BUTTONS (IN_ATTACK | IN_JUMP | IN_DUCK | IN_FORWARD | IN_BACK | IN_USE | IN_LEFT | IN_RIGHT | IN_MOVELEFT | IN_MOVERIGHT | IN_ATTACK2 | IN_RUN | IN_WALK | IN_GRENADE1 | IN_GRENADE2 )
#define SHOOT_DISABLE_BUTTONS (IN_ATTACK | IN_ATTACK2)
#define BOUNDINGBOX_INFLATION_OFFSET 3.0 // Float for consistency in calculations


/*****************************************************************


        P L U G I N   I N F O


*****************************************************************/

public Plugin myinfo = {
    name = "Spawn & Kill Protection (Standalone)", // Updated name
    author = "Berni, Chanz, ph (Stuck Fix by Dr. HyperKiLLeR / dcx2, Standalone by Gemini)", // Updated author
    description = "Spawn protection against spawnkilling, kill protection when near walls, and automatic repositioning for players who spawn stuck. No external dependencies beyond SDKHooks.", // Updated description
    version = PLUGIN_VERSION,
    url = "http://forums.alliedmods.net/showthread.php?p=901294"
}


/*****************************************************************


        G L O B A L   V A R S


*****************************************************************/

// ConVar Handles
static Handle version                           = INVALID_HANDLE;
static Handle enabled                           = INVALID_HANDLE;
static Handle walltime                          = INVALID_HANDLE;
static Handle takedamage                        = INVALID_HANDLE;
static Handle punishmode                        = INVALID_HANDLE;
static Handle notify                            = INVALID_HANDLE;
static Handle disableonmoveshoot                = INVALID_HANDLE;
static Handle disableweapondamage               = INVALID_HANDLE;
static Handle disabletime                       = INVALID_HANDLE;
static Handle disabletime_team1                 = INVALID_HANDLE;
static Handle disabletime_team2                 = INVALID_HANDLE;
static Handle keypressignoretime                = INVALID_HANDLE;
static Handle keypressignoretime_team1          = INVALID_HANDLE;
static Handle keypressignoretime_team2          = INVALID_HANDLE;
static Handle maxspawnprotection                = INVALID_HANDLE;
static Handle maxspawnprotection_team1          = INVALID_HANDLE;
static Handle maxspawnprotection_team2          = INVALID_HANDLE;
static Handle fadescreen                        = INVALID_HANDLE;
static Handle hidehud                           = INVALID_HANDLE;
static Handle player_color_r                    = INVALID_HANDLE;
static Handle player_color_g                    = INVALID_HANDLE;
static Handle player_color_b                    = INVALID_HANDLE;
static Handle player_color_a                    = INVALID_HANDLE;
static Handle noblock                           = INVALID_HANDLE;
static Handle collisiongroupcvar                = INVALID_HANDLE;
static Handle stuck_notify                      = INVALID_HANDLE; // New ConVar for stuck notification

// Misc
static bool bNoBlock                            = true;
static int defaultcollisiongroup                = view_as<int>(COLLISION_GROUP_PLAYER_MOVEMENT);
static bool isKillProtected[MAXPLAYERS+1]       = { false, ... };
static bool isSpawnKillProtected[MAXPLAYERS+1] = { false, ... };
static bool isWallKillProtected[MAXPLAYERS+1]  = { false, ... };
static Handle activeDisableTimer[MAXPLAYERS+1] = { INVALID_HANDLE, ... };
static float keyPressOnTime[MAXPLAYERS+1]       = { 0.0, ... };
static int timeLookingAtWall[MAXPLAYERS+1]      = { 0, ... };
static bool isTryingToUnStuck[MAXPLAYERS+1];
static Handle hudSynchronizer                   = INVALID_HANDLE;

/*****************************************************************
        CUSTOM STOCK HELPER FUNCTIONS (WORKAROUND FOR RUNTIME NATIVE ISSUES)
*****************************************************************/
// These functions directly access entity properties using GetEntProp/SetEntProp
// to bypass potential runtime issues with specific natives like IsValidClient,
// GetEntityHealth, SetEntityHealth, and SetEntityProp in older/custom SourceMod environments.

/**
 * @brief Helper function to check if a client is valid (in game, not a bot).
 * @param client The client index.
 * @return True if the client is valid, in-game, and not a bot; false otherwise.
 */
stock bool IsClientValidHelper(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

/**
 * @brief Gets an entity's health.
 * @param entity The entity index.
 * @return The entity's current health.
 */
stock int GetEntityHealthHelper(int entity)
{
    return GetEntProp(entity, view_as<PropType>(Prop_Send), "m_iHealth");
}

/**
 * @brief Sets an entity's health.
 * @param entity The entity index.
 * @param health The new health value.
 */
stock void SetEntityHealthHelper(int entity, int health)
{
    SetEntProp(entity, view_as<PropType>(Prop_Send), "m_iHealth", health);
}

/**
 * @brief Sets an entity property.
 * @param entity The entity index.
 * @param type The property type (e.g., Prop_Send).
 * @param prop The property name.
 * @param value The value to set.
 */
stock void SetEntityPropHelper(int entity, int type, const char[] prop, any value)
{
    SetEntProp(entity, view_as<PropType>(type), prop, value);
}


/*****************************************************************


        F O R W A R D   P U B L I C S


*****************************************************************/

// Forward declarations for functions used before their definition
public Action Command_EnableKillProtection(int client, int args) {
    // Placeholder implementation to satisfy the compiler
    return Plugin_Handled;
}

// Reverted APLRes AskPluginLoad2 signature to the form that previously compiled without errors on this line
public APLRes AskPluginLoad2(Handle myself, bool late)
{
    RegPluginLibrary("sakprotection");
    CreateNative("SAKP_IsClientProtected", Native_IsClientProtected);
    return APLRes_Success;
}

public void OnPluginStart()
{
    if (!LibraryExists("sdkhooks")) {
        SetFailState("[Spawn & Kill Protection] Error: needs sdkhooks 2.* or greater");
    }

    // ConVars with sakp_ prefix
    version                              = Sakp_CreateConVar("version", PLUGIN_VERSION, "Spawn & kill protection plugin version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
    // Set it to the correct version, in case the plugin gets updated...
    SetConVarString(version, PLUGIN_VERSION);

    enabled                              = Sakp_CreateConVar("enabled", "1", "Spawn & Kill Protection enabled");
    HookConVarChange(enabled, ConVarChange_Enabled);
    walltime                             = Sakp_CreateConVar("walltime", "4", "How long a player has to look at a wall to get kill protection activated, set to -1 to disable");
    takedamage                           = Sakp_CreateConVar("takedamage", "5", "The amount of health to take from the player when shooting at protected players (when punishmode = 2)");
    punishmode                           = Sakp_CreateConVar("punishmode", "0", "0 = off, 1 = slap, 2 = decrease health 3 = slay, 4 = apply damage done to enemy");
    notify                               = Sakp_CreateConVar("notify", "4", "0 = off, 1 = HUD message, 2 = center message, 3 = chat message, 4 = auto");
    HookConVarChange(notify, ConVarChange_Notify);

    noblock                              = Sakp_CreateConVar("noblock", "1", "1 = enable noblock when protected, 0 = disabled feature");
    bNoBlock                             = GetConVarBool(noblock); // Initialize global bool from ConVar
    HookConVarChange(noblock, ConVarChange_Noblock);

    char buffer[INT_MAX_DIGITS];
    IntToString(defaultcollisiongroup, buffer, sizeof(buffer));
    collisiongroupcvar                   = Sakp_CreateConVar("collisiongroup", buffer, "Collision group players are part of. Change to match group if you are using a noblock or anti stuck plugin.");
    defaultcollisiongroup                = GetConVarInt(collisiongroupcvar);
    HookConVarChange(collisiongroupcvar, ConVarChange_CollisionGroup);

    disableonmoveshoot                   = Sakp_CreateConVar("disableonmoveshoot", "1", "0 = don't disable, 1 = disable the spawnprotection when player moves or shoots, 2 = disable the spawn protection when shooting only");
    disableweapondamage                  = Sakp_CreateConVar("disableweapondamage", "0", "0 = spawn protected players can inflict damage, 1 = spawn protected players inflict no damage");
    disabletime                          = Sakp_CreateConVar("disabletime", "0", "Time in seconds until the protection is removed after the player moved and/or shooted, 0 = immediately");
    disabletime_team1                    = Sakp_CreateConVar("disabletime_team1", "-1", "same as sakp_disabletime, but for team 2 only (overrides sakp_disabletime if not set to -1)");
    disabletime_team2                    = Sakp_CreateConVar("disabletime_team2", "-1", "same as sakp_disabletime, but for team 2 only (overrides sakp_disabletime if not set to -1)");
    keypressignoretime                   = Sakp_CreateConVar("keypressignoretime", "0.8", "The amount of time in seconds pressing any keys will not turn off spawn protection");
    keypressignoretime_team1             = Sakp_CreateConVar("keypressignoretime_team1", "-1", "same as sakp_keypressignoretime, but for team 1 only (overrides sakp_keypressignoretime if not set to -1)");
    keypressignoretime_team2             = Sakp_CreateConVar("keypressignoretime_team2", "-1", "same as sakp_keypressignoretime, but for team 1 only (overrides sakp_keypressignoretime if not set to -1)");
    maxspawnprotection                   = Sakp_CreateConVar("maxspawnprotection", "0", "max timelimit in seconds the spawnprotection stays, 0 = no limit");
    maxspawnprotection_team1             = Sakp_CreateConVar("maxspawnprotection_team1", "-1", "same as sakp_maxspawnprotection, but for team 1 only (overrides sakp_maxspawnprotection if not set to -1)");
    maxspawnprotection_team2             = Sakp_CreateConVar("maxspawnprotection_team2", "-1", "same as sakp_maxspawnprotection, but for team 2 only (overrides sakp_maxspawnprotection if not set to -1)");
    fadescreen                           = Sakp_CreateConVar("fadescreen", "1", "Fade screen to black");
    hidehud                              = Sakp_CreateConVar("hidehud", "1", "Set to 1 to hide the HUD when being protected");
    player_color_r                       = Sakp_CreateConVar("player_color_red", "255", "amount of red when a player is protected 0-255");
    player_color_g                       = Sakp_CreateConVar("player_color_green", "0", "amount of green when a player is protected 0-255");
    player_color_b                       = Sakp_CreateConVar("player_color_blue", "0", "amount of blue when a player is protected 0-255");
    player_color_a                       = Sakp_CreateConVar("player_alpha", "50", "alpha amount of a protected player 0-255");
    stuck_notify                         = Sakp_CreateConVar("stuck_notify", "2", "0=off, 1=chat, 2=client console for stuck messages"); // Default to 2 (client console)

    AutoExecConfig(true);
    LoadTranslations("spawnandkillprotection.phrases"); // Replaced File_LoadTranslations with native LoadTranslations

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_team", Event_PlayerDeath); // Reuse callback, valid for our needs

    // Hooking the existing clients in case of lateload
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientValidHelper(client) || IsFakeClient(client)) {
            continue;
        }
        SDKHook(client, SDKHook_OnTakeDamage,  Hook_OnTakeDamage);
        SDKHook(client, SDKHook_ShouldCollide, Hook_ShouldCollide);
    }

    int value = GetConVarInt(notify);

    if (value == 1 || value == 4) {
        CreateTestHudSynchronizer();
    }

    RegAdminCmd("sm_enablekillprotection", Command_EnableKillProtection, ADMFLAG_ROOT);
}

public void OnMapStart() 
{    
    CreateTimer(1.0, Timer_CheckWall, INVALID_HANDLE, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    DisableKillProtectionAll();
}

public void OnPluginEnd()
{    
    DisableKillProtectionAll();
}

public void OnClientPutInServer(int client)
{    
    isKillProtected[client] = false;
    isSpawnKillProtected[client] = false;
    isWallKillProtected[client] = false;
    keyPressOnTime[client] = 0.0;
    timeLookingAtWall[client] = 0;
    isTryingToUnStuck[client] = false;

    SDKHook(client, SDKHook_OnTakeDamage,  Hook_OnTakeDamage);
    SDKHook(client, SDKHook_ShouldCollide, Hook_ShouldCollide);
}

public void OnGameFrame() 
{
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientValidHelper(client) || IsFakeClient(client) || !IsPlayerAlive(client)) {
            continue;
        }

        if (isKillProtected[client]) {
            
            if (activeDisableTimer[client] != INVALID_HANDLE) {
                continue;
            }

            int clientButtons = GetClientButtons(client);

            if (!(clientButtons & KILLPROTECTION_DISABLE_BUTTONS)) {
                continue;
            }

            if (GetGameTime() < keyPressOnTime[client]) {
                continue;
            }
            
            if (isSpawnKillProtected[client]) {
                
                if (GetConVarInt(disableonmoveshoot) == 0) {
                    continue;
                }
                
                if (GetConVarInt(disableonmoveshoot) == 2 && !(clientButtons & SHOOT_DISABLE_BUTTONS)) {
                    continue;
                }
            }

            float disabletime_value = GetDisableTime(client);
            if (disabletime_value > 0.0) {
                activeDisableTimer[client] = CreateTimer(disabletime_value, Timer_DisableSpawnProtection,
                    GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

                if (bNoBlock || isTryingToUnStuck[client]) {
                    CheckStuck(client);
                }
            }
            else {
                DisableKillProtection(client);
            }
        }
    }
}


/****************************************************************


        C A L L B A C K   F U N C T I O N S


****************************************************************/

public void ConVarChange_Notify(Handle convar, const char[] oldValue, const char[] newValue)
{    
    if (StringToInt(oldValue) == 1) {
        CloseHandle(hudSynchronizer);
        hudSynchronizer = INVALID_HANDLE;
    }
    
    int value = StringToInt(newValue);
    if (value == 1 || value == 4) {
        CreateTestHudSynchronizer();
    }
}

public void ConVarChange_Enabled(Handle convar, const char[] oldValue, const char[] newValue)
{
    if (StringToInt(newValue) == 0) {
        DisableKillProtectionAll();
    }
}

public void ConVarChange_Noblock(Handle convar, const char[] oldValue, const char[] newValue)
{
    bNoBlock = StringToInt(newValue) != 0; // Explicit bool conversion

    if (bNoBlock != (StringToInt(oldValue) != 0)) { // Explicit bool conversion
        for (int client = 1; client <= MaxClients; client++) {
            if (!IsClientValidHelper(client)) {
                continue;
            }
            // Check the partial ShouldApplyNoBlockAgainst conditions that may allow
            // the new NoBlock value to change function's return value, for optimization
            if (isKillProtected[client] && activeDisableTimer[client] == INVALID_HANDLE && !isTryingToUnStuck[client]) {
                if (bNoBlock) {
                    SetEntityCollisionGroup(client, view_as<int>(COLLISION_GROUP_DEBRIS_TRIGGER));
                } else {
                    CheckStuck(client);
                }
            }
        }
    }
}

public void ConVarChange_CollisionGroup(Handle convar, const char[] oldValue, const char[] newValue)
{
    defaultcollisiongroup = StringToInt(newValue);
}

public Action Timer_EnableSpawnProtection(Handle timer, any userId)
{
    int client = GetClientOfUserId(userId);    
    if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client)) {
        return Plugin_Stop;
    }
    
    isSpawnKillProtected[client] = true;

    EnableKillProtection(client);
    
    return Plugin_Stop;
}

public Action Timer_DisableSpawnProtection(Handle timer, any userId)
{
    int client = GetClientOfUserId(userId);
    activeDisableTimer[client] = INVALID_HANDLE;

    if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client)) {
        return Plugin_Stop;
    }

    isSpawnKillProtected[client] = false;
    DisableKillProtection(client);
    return Plugin_Stop;
}

public Action Timer_CheckWall(Handle timer)
{
    if (!GetConVarBool(enabled) || (GetConVarInt(walltime) == -1)) {
        return Plugin_Continue;
    }

    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientValidHelper(client) || IsFakeClient(client)) {
            continue;
        }
        
        if (IsLookingAtWall(client) && !(GetClientButtons(client) & KILLPROTECTION_DISABLE_BUTTONS)) {
            if (!isWallKillProtected[client] && timeLookingAtWall[client] >= GetConVarInt(walltime)) {
                isWallKillProtected[client] = true;
                EnableKillProtection(client);
                continue;
            }
            
            timeLookingAtWall[client]++;
        }
        else {
            timeLookingAtWall[client] = 0;
        }

        if (isTryingToUnStuck[client]) {
            CheckStuck(client);
        }
    }
    
    return Plugin_Continue;
}

public void Event_PlayerSpawn(Handle event, const char[] name, bool broadcast)
{
    if (!GetConVarBool(enabled)) {
        return;
    }

    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    if (IsFakeClient(client)) {
        return;
    }

    // --- NEW SPAWN STUCK CHECK LOGIC ---
    float currentSpawnPos[3];
    GetClientAbsOrigin(client, currentSpawnPos); // Get the player's initial spawn origin

    float finalSpawnPos[3];
    // Store initial position for nudging if needed
    float initialSpawnX = currentSpawnPos[0];
    float initialSpawnY = currentSpawnPos[1];
    float initialSpawnZ = currentSpawnPos[2];

    // Try to find a safe position
    bool foundSafePosition = FindSafeSpawnPosition(client, currentSpawnPos, finalSpawnPos);

    // Only teleport if a safe position was found AND it's different from the current one
    if (foundSafePosition && (initialSpawnX != finalSpawnPos[0] ||
                              initialSpawnY != finalSpawnPos[1] ||
                              initialSpawnZ != finalSpawnPos[2]))
    {
        TeleportEntity(client, finalSpawnPos, NULL_VECTOR, NULL_VECTOR);
        
        int notify_mode = GetConVarInt(stuck_notify);
        if (notify_mode == 1) { // Chat
            PrintToChat(client, "\x04[SAKP] \x01You were moved to avoid being stuck at spawn.");
        } else if (notify_mode == 2) { // Client Console
            PrintToConsole(client, "[SAKP] You were moved to avoid being stuck at spawn.");
        }
    }
    else // If no safe position could be found after all attempts
    {
        // Notify the player they are stuck, but do NOT auto-slay.
        // This avoids score penalties when direct death count manipulation is not possible.
        int notify_mode = GetConVarInt(stuck_notify);
        if (notify_mode == 1) { // Chat
            PrintToChat(client, "\x04[SAKP] \x01You spawned stuck and could not be moved. Try typing !kill or !unstuck.");
        } else if (notify_mode == 2) { // Client Console
            PrintToConsole(client, "[SAKP] You spawned stuck and could not be moved. Try typing !kill or !unstuck.");
        }
    }
    // --- END NEW SPAWN STUCK CHECK LOGIC ---

    isSpawnKillProtected[client] = true;
    CreateTimer(0.1, Timer_EnableSpawnProtection, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    float maxspawnprotection_value = GetMaxSpawnProtectionTime(client);

    if (maxspawnprotection_value > 0.0) {
        CreateTimer(maxspawnprotection_value, Timer_DisableSpawnProtection, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void Event_PlayerDeath(Handle event, const char[] name, bool broadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    if (IsFakeClient(client)) {
        return;
    }

    if (isKillProtected[client]) {
        DisableKillProtection(client);
    }
}

public Action Hook_OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype, int& weapon,
                                 float damageForce[3], float damagePosition[3], int damagecustom)
{    
    if (isKillProtected[victim]) {
        ProtectedPlayerHurted(inflictor, RoundToFloor(damage));
    }
    else if (!GetConVarBool(disableweapondamage) || attacker > MaxClients || !IsClientValidHelper(attacker)) {
        return Plugin_Continue;
    }

    damage = 0.0;
    return Plugin_Changed;
}

public bool Hook_ShouldCollide(int client, int collisiongroup, int contentsmask, bool originalResult)
{
    return (ShouldApplyNoBlockAgainst(client) ? false : originalResult);
}

public Action CH_PassFilter(int entity, int other, bool& result)
{
    return CH_ShouldCollide(EntRefToEntIndex(entity), EntRefToEntIndex(other), result);
}

public Action CH_ShouldCollide(int entity, int other, bool& result)
{
    if ((entity <= MaxClients && ShouldApplyNoBlockAgainst(entity))
        || (other <= MaxClients && ShouldApplyNoBlockAgainst(other))) {
        result = false;
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

bool ShouldApplyNoBlockAgainst(int client)
{
    // Accept if the client is protected (along with the NoBlock setting enabled) and not triggering delayed unprotection
    // from pressed buttons (so that client won't be able to pass through objects not initially colliding with during it),
    // or if de-protection was requested and client is currently stuck
    return (bNoBlock && isKillProtected[client] && activeDisableTimer[client] == INVALID_HANDLE
        || isTryingToUnStuck[client]);
}

/*****************************************************************


        P L U G I N   F U N C T I O N S


*****************************************************************/

float GetMaxSpawnProtectionTime(int client)
{
    float maxspawnprotection_value = 0.0;

    switch (GetClientTeam(client)) {
        case 0: { // Unassigned/Spectator
            maxspawnprotection_value = -1.0;
        }
        case 2: { // Team 1
            maxspawnprotection_value = GetConVarFloat(maxspawnprotection_team1);        
        }
        case 3: { // Team 2
            maxspawnprotection_value = GetConVarFloat(maxspawnprotection_team2);
        }
    }

    if (maxspawnprotection_value < 0.0) {
        maxspawnprotection_value = GetConVarFloat(maxspawnprotection);
    }

    return maxspawnprotection_value;
}

float GetDisableTime(int client)
{
    float disabletime_value = 0.0;

    switch (GetClientTeam(client)) {
        case 0: { // Unassigned/Spectator
            disabletime_value = -1.0;
        }
        case 2: { // Team 1
            disabletime_value = GetConVarFloat(disabletime_team1);        
        }
        case 3: { // Team 2
            disabletime_value = GetConVarFloat(disabletime_team2);
        }
    }
    
    if (disabletime_value < 0.0) {
        disabletime_value = GetConVarFloat(disabletime);
    }
    return disabletime_value;
}

float GetKeyPressIgnoreTime(int client)
{
    float keypressignoretime_value = 0.0;

    switch (GetClientTeam(client)) {
        case 0: { // Unassigned/Spectator
            keypressignoretime_value = -1.1;
        }
        case 2: { // Team 1
            keypressignoretime_value = GetConVarFloat(keypressignoretime_team1);        
        }
        case 3: { // Team 2
            keypressignoretime_value = GetConVarFloat(keypressignoretime_team2);
        }
    }
    
    if (keypressignoretime_value < 0.0) {
        keypressignoretime_value = GetConVarFloat(keypressignoretime);
    }
    
    return keypressignoretime_value;
}

public int Native_IsClientProtected(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    SetNativeCellRef(2, isWallKillProtected[client]);
    return isKillProtected[client];
}

void CreateTestHudSynchronizer()
{    
    hudSynchronizer = CreateHudSynchronizer();
    
    if (hudSynchronizer == INVALID_HANDLE) {
        PrintToServer("[Spawn & Kill Protection] %t", "server_warning_notify");
        SetConVarInt(notify, 3);
    }
    else {
        SetConVarInt(notify, 1);
    }
}

stock void ProtectedPlayerHurted(int inflictor, int damage)
{    
    if (!IsClientValidHelper(inflictor)) {
        return;
    }

    int punishmode_value = GetConVarInt(punishmode);

    if (punishmode_value) {

        switch (punishmode_value) {

            case 2: { // Decrease Health
                SetEntityHealthHelper(inflictor, GetEntityHealthHelper(inflictor) - damage);
            }
            case 3: { // Slay
                ForcePlayerSuicide(inflictor);
            }
            case 4: { // Damage done to enemy
                SetEntityHealthHelper(inflictor, GetEntityHealthHelper(inflictor) - damage);
            }
            case 1: { //case 1: Slap
                SlapPlayer(inflictor, GetConVarInt(takedamage));
            }
        }
    }
}

void EnableKillProtection(int client)
{    
    if (!IsPlayerAlive(client)) {
        return;
    }

    isKillProtected[client] = true;
    keyPressOnTime[client] = GetGameTime() + GetKeyPressIgnoreTime(client);
    SetEntityRenderMode(client, RENDER_TRANSCOLOR);
    SetEntityRenderColor(client, GetConVarInt(player_color_r), GetConVarInt(player_color_g), GetConVarInt(player_color_b), GetConVarInt(player_color_a));

    if (GetConVarBool(hidehud)) {
        SetEntityPropHelper(client, Prop_Send, "m_iHideHUD", HIDEHUD_WEAPONSELECTION | HIDEHUD_HEALTH | HIDEHUD_CROSSHAIR);
    }
        
    if (GetConVarBool(fadescreen)) {
        FakeClientCommand(client, "fade %f %d %d %d %d %d", 0.0, FFADE_OUT | FFADE_STAYOUT | FFADE_PURGE, 0, 0, 0, 240);
    }

    if (bNoBlock) {
        if (!isTryingToUnStuck[client]) {
            SetEntityCollisionGroup(client, view_as<int>(COLLISION_GROUP_DEBRIS_TRIGGER));
        }

        isTryingToUnStuck[client] = false;
    }

    NotifyClientEnableProtection(client);
}

void DisableKillProtection(int client)
{    
    if (!isKillProtected[client]) {
        return;
    }

    NotifyClientDisableProtection(client);

    isKillProtected[client] =  false;
    isSpawnKillProtected[client] = false;
    isWallKillProtected[client] = false;
    timeLookingAtWall[client] = 0;
    keyPressOnTime[client] = 0.0;

    if (IsPlayerAlive(client)) {
        SetEntityRenderColor(client, 255, 255, 255, 255);
        
        if (GetConVarBool(hidehud)) {
            SetEntityPropHelper(client, Prop_Send, "m_iHideHUD", 0); // 0 to show all HUD elements
        }
    }
    
    if (GetConVarBool(fadescreen)) {
        FakeClientCommand(client, "fade %f %d %d %d %d %d", 0.0, FFADE_IN | FFADE_PURGE, 0, 0, 0, 0);
    }

    if (bNoBlock || isTryingToUnStuck[client]) {
        CheckStuck(client);
    }
}

void CheckStuck(int client)
{
    float origin[3], mins[3], maxs[3];
    GetClientAbsOrigin(client, origin);
    GetEntPropVector(client, view_as<PropType>(Prop_Send), "m_vecMins", mins); // Explicit cast
    GetEntPropVector(client, view_as<PropType>(Prop_Send), "m_vecMaxs", maxs); // Explicit cast
    TR_TraceHullFilter(origin, origin, mins, maxs, MASK_PLAYERSOLID, StuckTraceFilter, client);
    isTryingToUnStuck[client] = TR_DidHit();
    SetEntityCollisionGroup(client, isTryingToUnStuck[client] ?
        (view_as<int>(COLLISION_GROUP_DEBRIS_TRIGGER)) : defaultcollisiongroup);
}

/**
 * @brief Trace filter function for general traces, excluding all players and common weapon entities.
 * @param entity The entity index being checked by the trace.
 * @param contentsMask The contents mask of the trace (not directly used here).
 * @return True if the entity should be considered for collision (i.e., it's not a player or weapon), false otherwise.
 */
public bool TraceEntityFilterPlayer(int entity, int contentsMask)
{
    // If the entity is a valid client (player), filter it out (return false).
    // This ensures general traces pass through players.
    if (IsClientValidHelper(entity))
    {
        return false;
    }

    // If it's not a player, check if it's a weapon by classname.
    char classname[64];
    if (GetEntityClassname(entity, classname, sizeof(classname)))
    {
        // Check for common weapon prefixes
        if (StrContains(classname, "weapon_", false) == 0 || StrContains(classname, "item_weapon_", false) == 0)
        {
            return false; // It's a weapon, don't collide
        }
    }

    // If it's not a player and not a recognized weapon, consider it for collision (return true).
    return true;
}

/**
 * @brief Trace filter function specifically for stuck checks, excluding the originating client and weapon entities.
 * @param entity The entity index being checked by the trace.
 * @param contentsMask The contents mask of the trace (not directly used here).
 * @param client_data The client ID that initiated this specific stuck trace.
 * @return True if the entity should be considered for collision, false otherwise.
 */
public bool StuckTraceFilter(int entity, int contentsMask, any client_data)
{
    int client = client_data; // Cast the any data back to int

    // If the entity is the client whose stuck status we are checking, ignore it.
    if (entity == client)
    {
        return false;
    }

    // If it's not the client, check if it's a weapon by classname (as m_nCollisionGroup is problematic).
    char classname[64];
    if (GetEntityClassname(entity, classname, sizeof(classname)))
    {
        if (StrContains(classname, "weapon_", false) == 0 || StrContains(classname, "item_weapon_", false) == 0)
        {
            return false; // It's a weapon, don't collide
        }
    }
    
    // For all other entities (not the client, not a weapon), consider them for collision.
    return true;
}

void DisableKillProtectionAll()
{
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientValidHelper(client) || !IsPlayerAlive(client)) {
            continue;
        }

        if (!isKillProtected[client]) {
            continue;
        }

        DisableKillProtection(client);
    }
}

void NotifyClientEnableProtection(int client)
{
    int notify_value = GetConVarInt(notify);

    if (!notify_value) {
        return;
    }
    
    if (isSpawnKillProtected[client]) {

        switch (notify_value) {
            
            case 2: {
                PrintCenterText(client, "%t", "Spawnprotection Enabled");
            }
            case 3: {
                PrintToChat(client, "\x04[SAKP] \x01%t", "Spawnprotection Enabled");
            }
            default: { // case 1
                SetHudTextParams(-1.0, -1.0, 99999999.0, 255, 0, 0, 255, 0, 6.0, 0.1, 0.2);
                ShowSyncHudText(client, hudSynchronizer, "%t", "Spawnprotection Enabled");
            }
        }
    }
    else {

        switch (notify_value) {
            
            case 2: {
                PrintCenterText(client, "%t", "Killprotection Enabled");
            }
            case 3: {
                PrintToChat(client, "\x04[SAKP] \x01%t", "Killprotection Enabled");
            }
            default: { // case 1
                SetHudTextParams(-1.0, -1.0, 99999999.0, 255, 0, 0, 255, 0, 6.0, 0.1, 0.2);
                ShowSyncHudText(client, hudSynchronizer, "%t", "Killprotection Enabled");
            }
        }
    }

}

void NotifyClientDisableProtection(int client)
{    
    int notify_value = GetConVarInt(notify);
    
    if (isSpawnKillProtected[client]) {
        
        switch (notify_value) {
            
            case 2: {
                PrintCenterText(client, "%t", "Spawnprotection Disabled");
            }
            case 3: {
                PrintToChat(client, "\x04[SAKP] \x01%t", "Spawnprotection Disabled");
            }
        }
    }
    else {
        
        switch (notify_value) {
            
            case 2: {
                PrintCenterText(client, "%t", "Killprotection Disabled");
            }
            case 3: {
                PrintToChat(client, "\x04[SAKP] \x01%t", "Killprotection Disabled");
            }
        }
    }
    
    if(hudSynchronizer != INVALID_HANDLE) {
        ClearSyncHud(client, hudSynchronizer);
    }
}

Handle Sakp_CreateConVar(
        const char[] name,
        const char[] defaultValue,
        const char[] description="",
        int flags=0,
        bool hasMin=false, float min=0.0, bool hasMax=false, float max=0.0)
{
    char newName[64];
    char newDescription[256];

    Format(newName, sizeof(newName), "sakp_%s", name);
    Format(newDescription, sizeof(newDescription), "Sourcemod Spawn & kill protection plugin:\n%s", description);

    return CreateConVar(newName, defaultValue, newDescription, flags, hasMin, min, hasMax, max);
}

/**
 * @brief Performs a ray trace forward from the client's eye position to determine if they are looking at a wall.
 * This is a basic implementation to replace Client_IsLookingAtWall from smlib.
 *
 * @param client The client to check.
 * @return True if the client is looking at a solid surface within a short distance, false otherwise.
 */
stock bool IsLookingAtWall(int client)
{
    float vOrigin[3], vAngles[3], vForward[3];
    GetClientEyePosition(client, vOrigin);
    GetClientEyeAngles(client, vAngles);
    GetAngleVectors(vAngles, vForward, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(vForward, vForward);
    ScaleVector(vForward, 50.0); // Check 50 units forward (adjustable)

    float vEnd[3];
    AddVectors(vOrigin, vForward, vEnd);

    // Trace from eye position to 50 units forward, hitting solid objects
    // Use the general TraceEntityFilterPlayer, which excludes all players and weapons.
    Handle trace = TR_TraceRayFilterEx(vOrigin, vEnd, MASK_SOLID, RayType_EndPoint, TraceEntityFilterPlayer);
    bool hit = TR_DidHit(trace);
    CloseHandle(trace);
    return hit;
}


// --- START NEW STUCK CHECK UTILITY FUNCTIONS ---

/**
 * @brief Checks if a given position is both not stuck in geometry and on solid ground.
 * This is crucial for preventing players from being teleported into the void or out of map bounds.
 *
 * @param pos[3] The position to check.
 * @param client The client whose bounding box should be used for the check.
 * @return True if the position is safe and grounded, false otherwise.
 */
stock bool IsPositionSafeAndGrounded(float pos[3], int client)
{
    // First, check if the player would be stuck in solid geometry at this position
    // Use StuckTraceFilter to correctly exclude the specific client being checked.
    if (IsPlayerStuck(pos, client))
    {
        return false; // Still stuck in a wall/ceiling
    }

    // Now, check if there's solid ground beneath the player
    float traceStart[3];
    traceStart[0] = pos[0];
    traceStart[1] = pos[1];
    traceStart[2] = pos[2] + 1.0; // Start trace slightly above the position

    float traceEnd[3];
    traceEnd[0] = pos[0];
    traceEnd[1] = pos[1];
    traceEnd[2] = pos[2] - 1000.0; // Trace a significant distance downwards

    // Use MASK_PLAYERSOLID to check for ground a player can stand on
    // Use the general TraceEntityFilterPlayer, which excludes all players and weapons.
    TR_TraceRayFilterEx(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayer); // Call directly
    bool hitGround = TR_DidHit(); // Check global state of last trace

    // If it hit something, then it's considered safe.
    return hitGround;
}


/**
 * @brief Finds a safe spawn position for a player, moving upwards and then trying horizontal nudges if needed.
 * This version also ensures the final position is on solid ground and not in the void.
 *
 * @param client The client to check.
 * @param startPos[3] The initial desired spawn position.
 * @param safePos[3] Output: The found safe position.
 * @return True if a safe position was found (which might be changed from startPos), false if no safe position was found within limits.
 */
stock bool FindSafeSpawnPosition(int client, float startPos[3], float safePos[3])
{
    // Copy initial position
    safePos[0] = startPos[0];
    safePos[1] = startPos[1];
    safePos[2] = startPos[2];

    int maxVerticalAttempts = 75; // Increased iterations to move up
    float moveUpAmount = 10.0; // Increased how much to move up each step

    // First, try moving straight up and check if it's safe and grounded
    for (int i = 0; i < maxVerticalAttempts; i++)
    {
        if (IsPositionSafeAndGrounded(safePos, client))
        {
            return true; // Found a safe spot
        }
        safePos[2] += moveUpAmount; // Move up
    }

    // If still stuck after vertical attempts, try a few horizontal nudges combined with vertical
    int maxNudgeAttempts = 10; // Increased number of horizontal nudge attempts
    float nudgeAmount = 30.0; // Increased how much to nudge horizontally

    float originalX = startPos[0];
    float originalY = startPos[1];
    // Keep original Z for relative nudging, but start from the highest point reached by vertical attempts
    float highestZReached = safePos[2]; 

    for (int i = 0; i < maxNudgeAttempts; i++)
    {
        // Reset to original X/Y, but start vertical search from the highest Z previously reached
        safePos[0] = originalX;
        safePos[1] = originalY;
        safePos[2] = highestZReached; 

        // Apply a small random horizontal nudge
        safePos[0] += GetRandomFloat(-nudgeAmount, nudgeAmount);
        safePos[1] += GetRandomFloat(-nudgeAmount, nudgeAmount);

        // Try moving up again from the new horizontal position and check if it's safe and grounded
        maxVerticalAttempts = 75; // Reset vertical attempts for the nudge
        for (int j = 0; j < maxVerticalAttempts; j++)
        {
            if (IsPositionSafeAndGrounded(safePos, client))
            {
                return true; // Found a safe spot after a nudge
            }
            safePos[2] += moveUpAmount;
        }
    }

    // If after all attempts, no safe and grounded position was found,
    // the player will remain at their original (potentially stuck) spawn position.
    // We return false to indicate that no *new* safe position was found.
    return false;
}   

/**
 * @brief Checks to see if a player would collide with MASK_PLAYERSOLID at a given position.
 * This is done by performing a trace hull with the player's bounding box.
 * The player's bounding box is slightly inflated to provide better protection against getting stuck.
 *
 * @param pos[3] The position to check for stuck status.
 * @param client The client whose bounding box should be used for the check.
 * @return True if the player would be stuck (colliding with solid geometry), false otherwise.
 */
stock bool IsPlayerStuck(float pos[3], int client)
{
    float mins[3];
    float maxs[3];

    GetEntPropVector(client, view_as<PropType>(Prop_Send), "m_vecMins", mins); // Explicit cast
    GetEntPropVector(client, view_as<PropType>(Prop_Send), "m_vecMaxs", maxs); // Explicit cast
    
    // Inflate the bounding box slightly for a more robust check.
    // This helps prevent clipping into geometry even if the exact point is clear.
    for (int i=0; i<3; i++)
    {
        mins[i] -= BOUNDINGBOX_INFLATION_OFFSET;
        maxs[i] += BOUNDINGBOX_INFLATION_OFFSET;
    }

    // Perform a trace hull from the check position using the inflated bounding box.
    // MASK_PLAYERSOLID ensures we only check against solid world geometry for player collision.
    // Use StuckTraceFilter to correctly exclude the specific client being checked.
    TR_TraceHullFilter(pos, pos, mins, maxs, MASK_PLAYERSOLID, StuckTraceFilter, client); // Call directly

    bool stuck = TR_DidHit(); // Check global state of last trace
    return stuck; // Return true if the hull hit anything solid
}   

// --- END NEW STUCK CHECK UTILITY FUNCTIONS ---
