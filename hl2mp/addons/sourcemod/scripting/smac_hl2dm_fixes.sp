#pragma semicolon 1
#pragma newdecls required

/* SM Includes */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac> // Assumes SMAC is installed and provides necessary definitions like SMAC_MOD_ERROR, SMAC_CheatDetected, SMAC_LogAction
#include <sdktools_functions.inc> // Added for GetEntProp functions
#include <sdktools_stocks.inc>    // Added for various stock functions
#include <sdktools_sound.inc>    // Explicitly added for AddNormalSoundHook definition
#include <float.inc>             // Included for general float functions, though SquareRoot is used for sqrt

/* Plugin Info */
public Plugin myinfo =
{
    name =          "SMAC HL2:DM Exploit Fixes",
    author =        SMAC_AUTHOR,
    description =   "Blocks general Half-Life 2: Deathmatch exploits including gravity gun toggle, RPG rapid fire, airborne duck spam, and conditionally suppresses stunstick deploy sounds (holster sounds are always suppressed) for players and bots. Now with optional duck pop fix via cvar.", // Updated description
    version =       "1.2.35.20 HL2DM (Modified)", // Updated version for mutual exclusion logic
    url =           SMAC_URL
};

/* Globals */
float g_fBlockTime[MAXPLAYERS+1]; // Time until gravity gun/weapon toggle block expires
bool g_bHasCrossbow[MAXPLAYERS+1]; // Tracks if player is holding a crossbow
float g_fLastDuckPressTime[MAXPLAYERS+1]; // Stores the last time the duck button was successfully pressed (not spammed)
bool g_bWasDucking[MAXPLAYERS+1]; // Tracks if the duck button was pressed in the previous tick

// Stunstick sound specific globals
bool g_bIsSpawning[MAXPLAYERS + 1]; // Flag to indicate if a client is currently in the spawning process
Handle g_hSpawnTimer[MAXPLAYERS + 1]; // Timer to manage the end of the spawning phase
bool g_bIsIntentionalStunstickDeploy[MAXPLAYERS + 1]; // Flag for intentional stunstick deploy
Handle g_hStunstickDeployTimer[MAXPLAYERS + 1]; // Timer for intentional stunstick deploy window
bool g_bIsIntentionalStunstickHolster[MAXPLAYERS + 1]; // Flag for intentional stunstick holster
Handle g_hStunstickHolsterTimer[MAXPLAYERS + 1]; // Timer for intentional stunstick holster window

// ConVar Handles
static Handle g_hExploitBlockTime = INVALID_HANDLE; // Handle for the configurable block time
static Handle g_hDuckSpamDelay = INVALID_HANDLE;    // Handle for the duck spam delay
static Handle g_hEnableDuckPopFix = INVALID_HANDLE; // Handle for duck pop fix toggle

// --- GLOBALS FOR DUCK POP FIX ---
// g_bPreviousDuckedState tracks the actual m_bDucked property from the previous tick (used for PostThink pop fix)
bool g_bPreviousDuckedState[MAXPLAYERS+1];
// --- END GLOBALS ---

// Constants
#define STUNSTICK_ACTION_WINDOW 0.2 // Time in seconds for an intentional deploy/holster action window
#define SPAWN_PROTECTION_TIME 0.5 // Time in seconds to consider a player "spawning" for stunstick sound suppression

// --- CONSTANTS FOR DUCK POP FIX ---
// Adjusted to 9.0 units for the velocity-based correction
#define DUCK_POP_VERTICAL_ADJUSTMENT 9.0
// --- END CONSTANTS ---

// Define INVALID_VECTOR if not already defined by includes (fallback)
#if !defined INVALID_VECTOR
    #define INVALID_VECTOR {-9999999.0, -9999999.0, -9999999.0}
#endif

// Fallback for MaxEntities if not defined by sourcemod.inc (highly unusual)
#if !defined MaxEntities
    #define MaxEntities 2048 // Common default max entities
#endif

/* Plugin Functions */
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    // Ensure the plugin only loads for Half-Life 2: Deathmatch
    if (GetEngineVersion() != Engine_HL2DM)
    {
        strcopy(error, err_max, SMAC_MOD_ERROR);
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    if (!LibraryExists("sdkhooks")) {
        SetFailState("[SMAC HL2:DM Exploit Fixes] Error: needs sdkhooks 2.* or greater");
    }

    // Create ConVars
    g_hExploitBlockTime = CreateConVar(
        "smac_exploit_block_time",
        "0.1", // Default to 0.1 seconds (100ms)
        "Time in seconds to block gravity gun/weapon toggles after a shot.",
        FCVAR_NOTIFY, // Notify clients of changes
        true, 0.001 // Minimum value of 1ms
    );
    g_hDuckSpamDelay = CreateConVar(
        "smac_exploit_duck_spam_delay",
        "0.05", // Default to 0.05 seconds (50ms)
        "Minimum time in seconds between duck presses while airborne to prevent hitbox exploits.",
        FCVAR_NOTIFY,
        true, 0.01 // Minimum value of 10ms
    );
    
    // ConVar to enable/disable the duck pop fix
    g_hEnableDuckPopFix = CreateConVar(
        "smac_enable_duckpop_fix",
        "0", // Defaults to OFF as requested
        "Enable or disable the experimental duck pop fix. (0=Disabled, 1=Enabled)",
        FCVAR_NONE, // No specific flags needed for a simple toggle
        true, 0.0, // Minimum value 0
        true, 1.0  // Maximum value 1
    );

    // Hooks for weapon fire and player actions.
    AddTempEntHook("Shotgun Shot", Hook_FireBullets); // Detects shotgun fire
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre); // Detects team changes
    HookEvent("player_spawn", Event_PlayerSpawn); // Hook player spawn event

    // Hook for all normal sounds emitted in the game
    AddNormalSoundHook(Hook_OnEmitSound);
}

public void OnClientPutInServer(int client)
{
    // Initialize client-specific globals
    g_fBlockTime[client] = 0.0;
    g_bHasCrossbow[client] = false;
    g_fLastDuckPressTime[client] = 0.0; // Initialize last duck press time
    g_bWasDucking[client] = false; // Initialize previous duck state
    g_bIsSpawning[client] = true; // Set spawning flag to true when client first joins
    g_bIsIntentionalStunstickDeploy[client] = false; // Initialize deploy flag
    g_hStunstickDeployTimer[client] = INVALID_HANDLE; // Initialize deploy timer handle
    g_bIsIntentionalStunstickHolster[client] = false; // Initialize holster flag
    g_hStunstickHolsterTimer[client] = INVALID_HANDLE; // Initialize holster timer handle

    // --- GLOBALS INITIALIZATION FOR DUCK POP FIX ---
    g_bPreviousDuckedState[client] = false; // Initialize actual ducked state
    // --- END GLOBALS INITIALIZATION ---

    // SDK Hooks for weapon interactions for this specific client
    SDKHook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);
    SDKHook(client, SDKHook_WeaponSwitchPost, Hook_WeaponSwitchPost);
    SDKHook(client, SDKHook_PostThink, Hook_PostThink); // Hook PostThink, now with cvar-controlled duck pop fix logic
}

public void OnClientDisconnect(int client)
{
    // Ensure any pending spawn timer is killed on disconnect
    if (g_hSpawnTimer[client] != INVALID_HANDLE)
    {
        KillTimer(g_hSpawnTimer[client]);
        g_hSpawnTimer[client] = INVALID_HANDLE;
    }
    // Ensure any pending stunstick deploy timer is killed on disconnect
    if (g_hStunstickDeployTimer[client] != INVALID_HANDLE)
    {
        KillTimer(g_hStunstickDeployTimer[client]);
        g_hStunstickDeployTimer[client] = INVALID_HANDLE;
    }
    // Ensure any pending stunstick holster timer is killed on disconnect
    if (g_hStunstickHolsterTimer[client] != INVALID_HANDLE)
    {
        KillTimer(g_hStunstickHolsterTimer[client]);
        g_hStunstickHolsterTimer[client] = INVALID_HANDLE;
    }

    // --- GLOBALS CLEANUP FOR DUCK POP FIX ---
    g_bPreviousDuckedState[client] = false;
    // --- END GLOBALS CLEANUP ---
}

/**
 * @brief Timer callback to set the spawning flag to false after a delay.
 * @param timer Handle to the timer.
 * @param client_id User ID of the client.
 */
public Action Timer_EndSpawning(Handle timer, int client_id)
{
    int client = GetClientOfUserId(client_id);
    if (client > 0 && client <= MaxClients)
    {
        g_bIsSpawning[client] = false;
    }
    g_hSpawnTimer[client] = INVALID_HANDLE; // Clear timer handle
    return Plugin_Stop;
}

/**
 * @brief Timer callback to set the intentional stunstick DEPLOY flag to false after a delay.
 * @param timer Handle to the timer.
 * @param client_id User ID of the client.
 */
public Action Timer_EndStunstickDeploy(Handle timer, int client_id)
{
    int client = GetClientOfUserId(client_id);
    if (client > 0 && client <= MaxClients)
    {
        g_bIsIntentionalStunstickDeploy[client] = false;
    }
    g_hStunstickDeployTimer[client] = INVALID_HANDLE; // Clear timer handle
    return Plugin_Stop;
}

/**
 * @brief NEW: Timer callback to set the intentional stunstick HOLSTER flag to false after a delay.
 * @param timer Handle to the timer.
 * @param client_id User ID of the client.
 */
public Action Timer_EndStunstickHolster(Handle timer, int client_id)
{
    int client = GetClientOfUserId(client_id);
    if (client > 0 && client <= MaxClients)
    {
        g_bIsIntentionalStunstickHolster[client] = false;
    }
    g_hStunstickHolsterTimer[client] = INVALID_HANDLE; // Clear timer handle
    return Plugin_Stop;
}

/**
 * @brief Event hook for "player_spawn" event.
 * Used to reset the spawning flag after a player has fully spawned.
 * @param event The event handle.
 * @param name The name of the event.
 * @param broadcast Whether the event should be broadcast (not used here).
 */
public void Event_PlayerSpawn(Handle event, const char[] name, bool broadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client > 0 && client <= MaxClients)
    {
        // Set spawning flag to true for this spawn event.
        g_bIsSpawning[client] = true;

        // Kill any existing spawn timer for this client to prevent conflicts
        if (g_hSpawnTimer[client] != INVALID_HANDLE)
        {
            KillTimer(g_hSpawnTimer[client]);
            g_hSpawnTimer[client] = INVALID_HANDLE;
        }

        // Create a new timer to end the spawning phase after a short delay.
        g_hSpawnTimer[client] = CreateTimer(SPAWN_PROTECTION_TIME, Timer_EndSpawning, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

/**
 * @brief Hook called when a weapon attempts to switch. This fires BEFORE the switch.
 * @param client The client attempting to switch weapons.
 * @param weapon The entity index of the weapon being switched to.
 * @return Plugin_Handled to block the switch, Plugin_Continue otherwise.
 */
public Action Hook_WeaponCanSwitchTo(int client, int weapon)
{
    char sWeapon[32];

    // Validate weapon entity and get its classname.
    if (!IsValidEdict(weapon) || !GetEdictClassname(weapon, sWeapon, sizeof(sWeapon)))
    {
        return Plugin_Continue;
    }
    
    // Block gravity gun toggle if exploit block time is active.
    // This prevents rapid switching to/from gravity gun after certain shots.
    if (g_fBlockTime[client] > GetGameTime() && StrEqual(sWeapon, "weapon_physcannon"))
    {
        return Plugin_Handled;
    }

    // If not in spawning phase, detect if this switch involves a stunstick.
    if (!g_bIsSpawning[client])
    {
        // Check if we are switching TO a stunstick
        if (StrEqual(sWeapon, "weapon_stunstick"))
        {
            g_bIsIntentionalStunstickDeploy[client] = true;

            // Kill any existing deploy timer for this client to prevent conflicts
            if (g_hStunstickDeployTimer[client] != INVALID_HANDLE)
            {
                KillTimer(g_hStunstickDeployTimer[client]);
                g_hStunstickDeployTimer[client] = INVALID_HANDLE;
            }
            // Create a new timer to clear the deploy flag after a short window
            g_hStunstickDeployTimer[client] = CreateTimer(STUNSTICK_ACTION_WINDOW, Timer_EndStunstickDeploy, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }
        
        // Check if we are switching AWAY FROM a stunstick (current active weapon is stunstick)
        int iCurrentWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
        char sCurrentWeapon[32];
        if (IsValidEdict(iCurrentWeapon) && GetEdictClassname(iCurrentWeapon, sCurrentWeapon, sizeof(sCurrentWeapon)) && StrEqual(sCurrentWeapon, "weapon_stunstick"))
        {
            g_bIsIntentionalStunstickHolster[client] = true; // Set holster flag

            // Kill any existing holster timer for this client to prevent conflicts
            if (g_hStunstickHolsterTimer[client] != INVALID_HANDLE)
            {
                    KillTimer(g_hStunstickHolsterTimer[client]);
                g_hStunstickHolsterTimer[client] = INVALID_HANDLE;
            }
            // Create a new timer to clear the holster flag after a short window
            g_hStunstickHolsterTimer[client] = CreateTimer(STUNSTICK_ACTION_WINDOW, Timer_EndStunstickHolster, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    
    return Plugin_Continue;
}

/**
 * @brief Hook called after a weapon switch has occurred.
 * This hook is mainly used for tracking weapon states like crossbow status.
 * Stunstick intentionality flags are now handled in Hook_WeaponCanSwitchTo.
 * @param client The client who switched weapons.
 * @param weapon The entity index of the weapon that was just switched to.
 * @return Plugin_Continue.
 */
public Action Hook_WeaponSwitchPost(int client, int weapon)
{
    char sWeapon[32];

    // Monitor if the player has a crossbow equipped.
    g_bHasCrossbow[client] = IsValidEdict(weapon) && 
                             GetEdictClassname(weapon, sWeapon, sizeof(sWeapon)) && 
                             StrEqual(sWeapon, "weapon_crossbow");

    return Plugin_Continue;
}

/**
 * @brief TempEnt hook for "Shotgun Shot" (triggered when a shotgun bullet is fired).
 * Used to set the exploit block time for gravity gun/weapon toggles.
 * @param te_name The name of the TempEnt.
 * @param Players Array of clients involved (not used here).
 * @param numClients Number of clients in Players array (not used here).
 * @param delay Delay of the TempEnt (not used here).
 * @return Plugin_Continue.
 */
public Action Hook_FireBullets(const char[] te_name, const int[] Players, int numClients, float delay)
{
    // Read the player index from the TempEnt data.
    int client = TE_ReadNum("m_iPlayer");

    // Ensure it's a valid client
    if (IsValidClient(client)) // Using the helper function now
    {
        // Set the block time based on the ConVar value.
        g_fBlockTime[client] = GetGameTime() + GetConVarFloat(g_hExploitBlockTime);
    }

    return Plugin_Continue;
}

/**
 * @brief Event hook for "player_team" event.
 * Slay players who attempt to change teams while actively using a gravity gun.
 * @param event The event handle.
 * @param name The name of the event.
 * @param dontBroadcast Whether the event should not be broadcast (not used here).
 * @return Plugin_Continue.
 */
public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    // Get the client from the event's userid.
    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    // Ensure the client is valid, in-game, and alive.
    if (IsValidClient(client) && IsPlayerAlive(client)) // Using the helper function now
    {
        char sWeapon[32];
        int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

        // Check if the player is holding an active gravity gun.
        if (IsValidEdict(weapon) && 
            GetEdictClassname(weapon, sWeapon, sizeof(sWeapon)) && 
            StrEqual(sWeapon, "weapon_physcannon") && 
            GetEntProp(weapon, Prop_Send, "m_bActive", 1))
        {
            // If cheat detected and SMAC allows continuation (i.e., not blocked by another module)
            if (SMAC_CheatDetected(client, Detection_GravityGunExploit, INVALID_HANDLE) == Plugin_Continue)
            {
                SMAC_LogAction(client, "was slayed for attempting to exploit the gravity gun (team change).");
                ForcePlayerSuicide(client);
            }
        }
    }

    return Plugin_Continue;
}

/**
 * @brief SDK hook called before a player's command is processed.
 * Used for detecting crossbow shots, blocking crouch exploits, sprint for dead players,
 * general weapon/flashlight toggles, RPG rapid fire, and airborne duck spam.
 * @param client The client executing the command.
 * @param buttons Bitmask of buttons pressed.
 * @param impulse Impulse command.
 * @param vel Player's velocity (not used here).
 * @param angles Player's view angles (not used here).
 * @param weapon Weapon entity index (not used here).
 * @param subtype Weapon subtype (not used here).
 * @param cmdnum Command number (not used here).
 * @param tickcount Tick count (not used here).
 * @param seed Random seed (not used here).
 * @param mouse Mouse movement (not used here).
 * @return Plugin_Continue.
 */
public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
    // Get the active weapon for the client.
    int iActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

    // Detecting a crossbow shot to set block time.
    if (((buttons & IN_ATTACK) != 0) && g_bHasCrossbow[client])
    {
        if (IsValidEdict(iActiveWeapon) && GetEntPropFloat(iActiveWeapon, Prop_Send, "m_flNextPrimaryAttack") < GetGameTime())
        {
            // Set the block time based on the ConVar value.
            g_fBlockTime[client] = GetGameTime() + GetConVarFloat(g_hExploitBlockTime);
        }
    }

    // Rocket Launcher Rapid Fire Detection (Now uses m_flNextPrimaryAttack directly)
    // Check if player is trying to fire and is holding an RPG.
    if (((buttons & IN_ATTACK) != 0) && IsValidEdict(iActiveWeapon))
    {
        char sWeaponClassname[32];
        GetEdictClassname(iActiveWeapon, sWeaponClassname, sizeof(sWeaponClassname));

        if (StrEqual(sWeaponClassname, "weapon_rpg"))
        {
            // Check if the RPG's internal next primary attack time is in the future.
            // If it is, the weapon is not ready to fire, so block the button.
            if (GetEntPropFloat(iActiveWeapon, Prop_Send, "m_flNextPrimaryAttack") > GetGameTime())
            {
                buttons &= ~IN_ATTACK; // Block the attack button
            }
        }
    }

    // --- Airborne Duck Spam Fix for Hitbox Displacement (Conditional based on duck pop fix cvar) ---
    // This code is only active IF the duck pop fix is DISABLED.
    if (GetConVarInt(g_hEnableDuckPopFix) == 0)
    {
        bool bIsDuckingThisTick = ((buttons & IN_DUCK) != 0);
        if (bIsDuckingThisTick && !g_bWasDucking[client]) // Duck button was just pressed (transition from off to on)
        {
            // Check if player is in the air
            int iGroundEntity = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
            if (iGroundEntity == -1) // Player is in the air (m_hGroundEntity == -1 means no ground entity)
            {
                float fCurrentTime = GetGameTime();
                float fDuckSpamDelay = GetConVarFloat(g_hDuckSpamDelay);

                if (fCurrentTime < g_fLastDuckPressTime[client] + fDuckSpamDelay)
                {
                    // Block the duck button if spamming in air
                    buttons &= ~IN_DUCK;
                    // Optionally, log this as a cheat attempt (uncomment if SMAC_CheatDetected is desired)
                    // if (SMAC_CheatDetected(client, Detection_DuckSpam, INVALID_HANDLE) == Plugin_Continue)
                    // {
                    //    SMAC_LogAction(client, "attempted to duck spam in air.");
                    // }
                }
                else
                {
                    // Update the last duck press time only if it was a valid, non-spam press
                    g_fLastDuckPressTime[client] = fCurrentTime;
                }
            }
            else // Player is on the ground, allow duck press, reset timer for next airborne check
            {
                g_fLastDuckPressTime[client] = GetGameTime();
            }
        }
        // Update g_bWasDucking for the next tick's comparison
        g_bWasDucking[client] = bIsDuckingThisTick;
    }
    // --- End Airborne Duck Spam Fix ---


    // Existing: Don't let the player crouch if they are in the process of standing up (camera displacement exploit).
    // This logic relies on m_bDucked and m_bDucking properties.
    if (((buttons & IN_DUCK) != 0) && GetEntProp(client, Prop_Send, "m_bDucked", 1) && GetEntProp(client, Prop_Send, "m_bDucking", 1))
    {
        buttons ^= IN_DUCK; // Remove the IN_DUCK button
    }

    // Only allow sprint if the player is alive.
    if (((buttons & IN_SPEED) != 0) && !IsPlayerAlive(client))
    {
        buttons ^= IN_SPEED; // Remove the IN_SPEED button
    }

    // Block flashlight/weapon toggle after a bullet has fired (using g_fBlockTime).
    // Impulse 51 is flashlight, Impulse 100 is weapon toggle (next weapon).
    if ((impulse == 51) || (impulse == 100 && g_fBlockTime[client] > GetGameTime()))
    {
        impulse = 0; // Clear the impulse command
    }
    
    // Block switching to gravity gun via weapon slot if g_fBlockTime is active.
    // 'weapon' parameter here refers to the weapon slot selected, not the entity.
    if (weapon && IsValidEdict(iActiveWeapon) && g_fBlockTime[client] > GetGameTime())
    {
        char sWeapon[32];
        GetEdictClassname(iActiveWeapon, sWeapon, sizeof(sWeapon));

        if (StrEqual(sWeapon, "weapon_physcannon"))
        {
            weapon = 0; // Block the weapon switch
        }
    }

    return Plugin_Continue;
}

/**
 * @brief Helper function to check if a client index is valid, in-game, and not a bot.
 * @param client The client index.
 * @return True if valid, false otherwise.
 */
stock bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

/**
 * @brief SDK hook called after a player's movement and physics have been processed for the current tick.
 * Contains the duck pop fix logic, now controlled by a cvar.
 * @param client The client entity index.
 */
public void Hook_PostThink(int client)
{
    // Basic checks to ensure client is valid and in-game
    if (!IsValidClient(client) || !IsPlayerAlive(client))
    {
        return;
    }

    // Only apply the duck pop fix if the cvar is enabled
    if (GetConVarInt(g_hEnableDuckPopFix) == 1)
    {
        int currentFlags = GetEntProp(client, Prop_Send, "m_fFlags");
        bool bOnGround = ((currentFlags & FL_ONGROUND) != 0);
        bool bCurrentlyDucked = (GetEntProp(client, Prop_Send, "m_bDucked", 1) != 0);

        // --- DUCK POP FIX LOGIC (AIRBORNE ONLY) ---
        // Only apply this fix if the player is truly airborne.
        if (!bOnGround)
        {
            float fVelocity[3];
            GetEntPropVector(client, Prop_Send, "m_vecVelocity", fVelocity);
            float fFrameTime = GetGameFrameTime();

            // Transition from not ducked to ducked (player visually pops UP -> need to move Z DOWN)
            if (!g_bPreviousDuckedState[client] && bCurrentlyDucked)
            {
                // Apply a downward impulse to Z velocity
                if (fFrameTime > 0.0) // Avoid division by zero
                {
                    fVelocity[2] -= (DUCK_POP_VERTICAL_ADJUSTMENT / fFrameTime);
                    SetEntPropVector(client, Prop_Send, "m_vecVelocity", fVelocity);
                }
                // Debugging (can be removed after verification)
                // PrintToServer("[SMAC] DEBUG: Airborne DUCK pop fix for %N: applied downward velocity.", client);
            }
            // Transition from ducked to not ducked (player visually pops DOWN -> need to move Z UP)
            else if (g_bPreviousDuckedState[client] && !bCurrentlyDucked)
            {
                // Apply an upward impulse to Z velocity
                if (fFrameTime > 0.0) // Avoid division by zero
                {
                    fVelocity[2] += (DUCK_POP_VERTICAL_ADJUSTMENT / fFrameTime);
                    SetEntPropVector(client, Prop_Send, "m_vecVelocity", fVelocity);
                }
                // Debugging (can be removed after verification)
                // PrintToServer("[SMAC] DEBUG: Airborne UNDUCK pop fix for %N: applied upward velocity.", client);
            }
        }
    }

    // Update previous ducked state for the next tick's comparison for PostThink logic, regardless of cvar state
    bool bCurrentlyDucked = (GetEntProp(client, Prop_Send, "m_bDucked", 1) != 0);
    g_bPreviousDuckedState[client] = bCurrentlyDucked;
}

/**
 * @brief Hook called when a normal sound is about to be emitted to one or more clients.
 * Used to conditionally suppress the stunstick deploy sound.
 * @param clients Array of client indexes who would hear the sound.
 * @param numClients Number of clients in the array (can be modified to suppress).
 * @param sample The name/path of the sound sample.
 * @param entity_idx The entity emitting the sound.
 * @param channel The sound channel.
 * @param volume The sound volume.
 * @param level The sound level.
 * @param pitch Sound pitch.
 * @param flags Sound flags.
 * @param soundEntry Game sound entry name (used in newer engines).
 * @param seed Sound seed (used in newer engines).
 * @return Plugin_Changed to apply modifications, Plugin_Continue to allow, Plugin_Stop to block entirely.
 */
public Action Hook_OnEmitSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH],
                                 int &entity_idx, int &channel, float &volume, int &level, int &pitch, int &flags,
                                 char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
    // Check if the emitted sound is any of the stunstick spark sounds.
    if (StrContains(sample, "weapons/stunstick/spark", false) != -1) // Generic check for "spark"
    {
        // Get the owner of the entity emitting the sound.
        // For weapon sounds, the entity_idx is the weapon itself, so we need its owner (the player).
        int owner_client = GetEntPropEnt(entity_idx, Prop_Data, "m_hOwnerEntity");

        // Ensure the owner is a valid client (player or bot).
        if (owner_client > 0 && owner_client <= MaxClients && IsClientInGame(owner_client))
        {
            // If the client is currently in the spawning process, unconditionally suppress the sound.
            if (g_bIsSpawning[owner_client])
            {
                numClients = 0; // Suppress for all clients
                PrintToServer("[SMAC] Suppressing stunstick sound '%s' during spawn for player %N (ID: %d).", sample, owner_client, GetClientUserId(owner_client));
                return Plugin_Changed;
            }
            // If an intentional stunstick DEPLOY action was recently detected, allow the sound.
            else if (g_bIsIntentionalStunstickDeploy[owner_client])
            {
                // No log for allowing intentional sounds, as per user request for minimal logging.
                return Plugin_Continue;
            }
            // If an intentional stunstick HOLSTER action was recently detected, suppress silently.
            else if (g_bIsIntentionalStunstickHolster[owner_client])
            {
                numClients = 0; // Suppress for all clients
                // No log for suppressing holster sounds, as per user request.
                return Plugin_Changed;
            }

            // If we reach here, it's a stunstick spark sound from a non-spawning player,
            // and no recent intentional *deploy* or *holster* action was flagged.
            // This means it's a truly unintentional passive refresh.
            
            char sWeaponClassname[32];
            // Verify that the emitting entity is indeed a stunstick
            if (GetEdictClassname(entity_idx, sWeaponClassname, sizeof(sWeaponClassname)) && StrEqual(sWeaponClassname, "weapon_stunstick"))
            {
                numClients = 0; // Suppress for all clients
                PrintToServer("[SMAC] Suppressing unintentional stunstick sound '%s' for player %N (ID: %d).", sample, owner_client, GetClientUserId(owner_client));
                return Plugin_Changed; // Return Plugin_Changed to apply the modification (numClients = 0)
            }
            // If it's a spark sound but not from a stunstick weapon entity (e.g., a prop), allow it.
            else
            {
                return Plugin_Continue;
            }
        }
        // If the owner is not a valid client (e.g., world entity playing a sound that happens to contain "spark"), allow it.
        else
        {
            return Plugin_Continue;
        }
    }
    // If it's not the target stunstick sound, allow it to pass through.
    return Plugin_Continue; // Allow other sounds to play
}