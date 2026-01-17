////////////////////////////////////////////////////////////
//
//             Fysics Control
//
//             by thaCURSEDpie
//
//             2012-08-19 - version 1.0.4
//             2015-01-20 - version 1.0.4 natives
//                 Drixevel added natives
//             2022-08-06 - version 1.0.4 me natives
//                 reBane added /bhopme and /bounceme
//             2022-11-05 - version 1.0.4 me natives kartfix
//                 Thespikedballofdoom disabled bhops in karts
//             2023-12-08 - version 1.0.4 HL2DM
//                 Xeogin removed TF2 specific code as well as modifications for use in HL2DM
//             2025-07-02 - Version 1.0.5 HL2DM (Cleaned Up & Refined)
//                 - Comprehensive refactoring for global-only settings.
//                 - Removed all per-player settings arrays.
//                 - Removed 'sm_bhopme' command.
//                 - Removed custom natives 'FC_SetBhop' and 'FC_BhopStatus'.
//                 - Admin commands now directly modify global ConVars.
//                 - Initial HL2DM compatibility adjustments (removed TF2 specific code).
//                 - Transitioned to standard 'ArcTangent2' for angle calculations; removed custom math functions.
//                 - Introduced 'fc_bhop_min_speed' and 'fc_bhop_max_speed' ConVars for speed thresholds.
//                 - Removed 'fc_bhop_mult' ConVar.
//                 - Refined bhop assist scaling: 'fc_bhop_perfect_delay' defines 1:1 speed retention window,
//                   while 'fc_bhop_maxdelay' defines the overall assist window, with linear decline in between.
//                 - Ensured smooth air-strafing during assisted bunnyhops by prioritizing current air-strafe direction.
//
//             This plugin aims to give server-admins
//             greater control over the game's physics.
//
////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////
//
//             Includes et cetera
//
////////////////////////////////////////////////////////////
#pragma semicolon 1

#define PLUGIN_VERSION "1.0.5 HL2DM" // Updated version number
#define SHORT_DESCRIPTION "Fysics Control by thaCURSEDpie."
#define ADMINCMD_MIN_LEVEL ADMFLAG_ROOT

#include <sourcemod>
#include <sdktools> // Provides GetEntPropVector, GetVectorAngles etc.
#include <sdkhooks>
#include <float>    // Provides SquareRoot, Cosine, Sine, ArcTangent2, etc.
#include <commandfilters> // Included to ensure ProcessTargetString is properly defined


////////////////////////////////////////////////////////////
//
//             Global vars
//
////////////////////////////////////////////////////////////
//-- Handles
new Handle:hEnabled = INVALID_HANDLE;
new Handle:hAirstrafeMult = INVALID_HANDLE;
new Handle:hBhopMaxDelay = INVALID_HANDLE;
new Handle:hBhopPerfectDelay = INVALID_HANDLE;
new Handle:hBhopEnabled = INVALID_HANDLE;
new Handle:hBhopMinSpeed = INVALID_HANDLE;
new Handle:hBhopMaxSpeed = INVALID_HANDLE;

//-- Values (server-wide defaults from ConVars)
new Float:fAirstrafeMult_Global = 1.0;
new Float:fBhopMaxDelay_Global = 0.2;
new Float:fBhopPerfectDelay_Global = 0.1;
new bool:bModEnabled_Global = true;
new bool:bBhopEnabled_Global = true;
new Float:fBhopMinSpeed_Global = 190.0;
new Float:fBhopMaxSpeed_Global = 450.0;

//-- Player state variables (no longer per-player settings)
new Float:fOldVels[MAXPLAYERS + 1][3]; // Stores velocity from previous tick for bhop calculations
new bool:bIsInAir[MAXPLAYERS + 1];
new bool:bJumpPressed[MAXPLAYERS + 1];
new Float:fMomentTouchedGround[MAXPLAYERS + 1]; // Stores GetGameTime() when player last touched ground

////////////////////////////////////////////////////////////
//
//             Mod description
//
////////////////////////////////////////////////////////////
public Plugin:myinfo =
{
    name        = "Fysics Control",
    author      = "thaCURSEDpie, natives by Keith Warren (Jack of Designs), modified for HL2DM by Xeogin",
    description = "This plugin aims to give server admins more control over the game physics.",
    version     = PLUGIN_VERSION,
    url         = "http://www.sourcemod.net"
};


////////////////////////////////////////////////////////////
//
//             OnPluginStart (Natives Registration - Removed per-client natives)
//
////////////////////////////////////////////////////////////
public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
    // FC_SetBhop and FC_BhopStatus natives removed as per-player settings are no longer supported.
    // If global natives are needed, they would be added here.
    
    // RegPluginLibrary("fc"); // Removed as no natives are registered.
    
    return APLRes_Success;
}


////////////////////////////////////////////////////////////
//
//             OnPluginStart (Main Initialization)
//
////////////////////////////////////////////////////////////
public OnPluginStart()
{
    LoadTranslations("common.phrases");

    //---- Admin Commands (Refactored to set global ConVars directly)
    RegAdminCmd("sm_fc_reload", CmdReload, ADMINCMD_MIN_LEVEL, "Reloads Fysics Control plugin settings.");
    
    // Airstrafe command
    RegAdminCmd("sm_airstrafe_mult", CmdAirstrafeMult, ADMINCMD_MIN_LEVEL, "Sets the global airstrafe multiplier.");
    
    // Bhop commands
    RegAdminCmd("sm_bhop_enabled", CmdBhopEnabled, ADMINCMD_MIN_LEVEL, "Sets whether bunnyhopping is globally enabled (0/1).");
    // sm_bhopme command removed
    RegAdminCmd("sm_bhop_maxdelay", CmdBhopMaxDelay, ADMINCMD_MIN_LEVEL, "Sets the global maximum delay for any bhop assist.");
    RegAdminCmd("sm_bhop_perfect_delay", CmdBhopPerfectDelay, ADMINCMD_MIN_LEVEL, "Sets the global max delay for 1:1 speed retention.");
    RegAdminCmd("sm_bhop_minspeed", CmdBhopMinSpeed, ADMINCMD_MIN_LEVEL, "Sets the global minimum speed for bhop assist to apply.");
    RegAdminCmd("sm_bhop_maxspeed", CmdBhopMaxSpeed, ADMINCMD_MIN_LEVEL, "Sets the global maximum speed for bhop assist to apply.");
        
    //---- ConVars (Configuration Variables)    
    CreateConVar("fc_version", PLUGIN_VERSION, SHORT_DESCRIPTION, FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
    
    // Overall mod enable/disable
    hEnabled             = CreateConVar("fc_enabled", "1", "Enable Fysics Control plugin functionality.");
    
    // Airstrafe ConVar
    hAirstrafeMult       = CreateConVar("fc_airstrafe_mult", "1.0", "The multiplier to apply to airstrafing.", FCVAR_PLUGIN, true, 0.0, true, 10.0);
    
    // Bhop ConVars
    hBhopEnabled         = CreateConVar("fc_bhop_enabled", "1", "Whether or not players can bunnyhop by default.", FCVAR_PLUGIN);
    hBhopMaxDelay        = CreateConVar("fc_bhop_maxdelay", "0.2", "Maximum time in seconds, after which the player has touched the ground and can still get a bhop boost.", FCVAR_PLUGIN, true, 0.0);
    hBhopPerfectDelay    = CreateConVar("fc_bhop_perfect_delay", "0.1", "Maximum time in seconds after touching ground for 1:1 speed retention.", FCVAR_PLUGIN, true, 0.0);
    hBhopMinSpeed        = CreateConVar("fc_bhop_min_speed", "190.0", "Minimum horizontal speed for bhop assist to apply.", FCVAR_PLUGIN, true, 0.0);
    hBhopMaxSpeed        = CreateConVar("fc_bhop_max_speed", "450.0", "Maximum horizontal speed for bhop assist to apply.", FCVAR_PLUGIN, true, 0.0);
    
    //---- ConVar Change Hooks (Update global values when ConVars change)
    HookConVarChange(hEnabled, OnEnabledChanged);
    HookConVarChange(hAirstrafeMult, OnAirstrafeMultChanged);    
    HookConVarChange(hBhopMaxDelay, OnBhopMaxDelayChanged);
    HookConVarChange(hBhopPerfectDelay, OnBhopPerfectDelayChanged);
    HookConVarChange(hBhopEnabled, OnBhopEnabledChanged);
    HookConVarChange(hBhopMinSpeed, OnBhopMinSpeedChanged);
    HookConVarChange(hBhopMaxSpeed, OnBhopMaxSpeedChanged);
        
    // Initialize all global settings by reading ConVars
    InitGlobalSettings(); 
}

/**
 * @brief Called when the plugin is unloaded.
 * Ensures any active hooks are removed.
 */
public OnPluginEnd()
{
    // Unhook SDKHook_PostThink for all clients to prevent errors on unload.
    // It's safe to call SDKUnhook even if the client is not valid or not hooked.
    for (new i = 1; i <= MaxClients; i++)
    {
        SDKUnhook(i, SDKHook_PostThink, OnPostThink);
    }
}


////////////////////////////////////////////////////////////
//
//             Commands (Refactored to set global ConVars)
//
////////////////////////////////////////////////////////////
public Action:CmdReload(client, args)
{
    // When reloading, we want to re-initialize all settings.
    InitGlobalSettings();
    ReplyToCommand(client, "Fysics Control reloaded!");
    
    return Plugin_Handled;
}

public Action:CmdAirstrafeMult(client, args)
{
    HandleCmdFloat(client, args, "sm_airstrafe_mult", hAirstrafeMult);
    return Plugin_Handled;
}

public Action:CmdBhopEnabled(client, args)
{
    HandleCmdBool(client, args, "sm_bhop_enabled", hBhopEnabled);
    return Plugin_Handled;
}

public Action:CmdBhopMaxDelay(client, args)
{
    HandleCmdFloat(client, args, "sm_bhop_maxdelay", hBhopMaxDelay);
    return Plugin_Handled;
}

public Action:CmdBhopPerfectDelay(client, args)
{
    HandleCmdFloat(client, args, "sm_bhop_perfect_delay", hBhopPerfectDelay);
    return Plugin_Handled;
}

public Action:CmdBhopMinSpeed(client, args)
{
    HandleCmdFloat(client, args, "sm_bhop_min_speed", hBhopMinSpeed);
    return Plugin_Handled;
}

public Action:CmdBhopMaxSpeed(client, args)
{
    HandleCmdFloat(client, args, "sm_bhop_max_speed", hBhopMaxSpeed);
    return Plugin_Handled;
}

////////////////////////////////////////////////////////////
//
//             Command handling helpers (Refactored for global ConVars)
//
////////////////////////////////////////////////////////////
/**
 * @brief Helper function to handle admin commands that set a boolean ConVar.
 * @param client The admin executing the command.
 * @param args The number of arguments provided to the command.
 * @param cmdName The name of the command (for reply messages).
 * @param convarHandle The Handle of the ConVar to modify.
 */
public HandleCmdBool(client, args, String:cmdName[], Handle:convarHandle)
{
    if (args < 1) // Expects only the amount
    {
        ReplyToCommand(client, "[SM] Usage: %s <0|1>", cmdName);
        return;
    }
    
    decl String:arg1[20];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    new intValue = StringToInt(arg1);
    if (intValue < 0 || intValue > 1) // Ensure the value is 0 or 1
    {
        ReplyToCommand(client, "[SM] Invalid amount. Must be 0 or 1.");
        return;
    }
    
    SetConVarBool(convarHandle, (intValue != 0));
    ReplyToCommand(client, "[FC] Successfully set %s to %s!", cmdName, (intValue != 0) ? "enabled" : "disabled");
}

/**
 * @brief Helper function to handle admin commands that set a float ConVar.
 * @param client The admin executing the command.
 * @param args The number of arguments provided to the command.
 * @param cmdName The name of the command (for reply messages).
 * @param convarHandle The Handle of the ConVar to modify.
 */
public HandleCmdFloat(client, args, String:cmdName[], Handle:convarHandle)
{
    if (args < 1) // Expects only the amount
    {
        ReplyToCommand(client, "[SM] Usage: %s <amount>", cmdName);
        return;
    }
    
    decl String:arg1[20];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    new Float:amount = StringToFloat(arg1);
    
    // Basic validation: ensure it's non-negative for speed/delay values
    // ConVars themselves have min/max bounds, but this adds an extra layer for commands.
    if (amount < 0.0) 
    {
        ReplyToCommand(client, "[SM] Invalid amount. Must be non-negative.");
        return;
    }
    
    SetConVarFloat(convarHandle, amount);
    ReplyToCommand(client, "[FC] Successfully set %s to %.2f!", cmdName, amount);
}


////////////////////////////////////////////////////////////
//
//             Initialization and Client Management (Simplified)
//
////////////////////////////////////////////////////////////
/**
 * @brief Initializes all global settings by reading current ConVar values.
 * Called on plugin start and on sm_fc_reload.
 */
public InitGlobalSettings()
{
    bModEnabled_Global = GetConVarBool(hEnabled);
    fAirstrafeMult_Global = GetConVarFloat(hAirstrafeMult);
    fBhopMaxDelay_Global = GetConVarFloat(hBhopMaxDelay);
    fBhopPerfectDelay_Global = GetConVarFloat(hBhopPerfectDelay);
    bBhopEnabled_Global = GetConVarBool(hBhopEnabled);
    fBhopMinSpeed_Global = GetConVarFloat(hBhopMinSpeed);
    fBhopMaxSpeed_Global = GetConVarFloat(hBhopMaxSpeed);
}

/**
 * @brief Called when a client is fully put in the server (after connecting and loading).
 * Hooks necessary SDK events for the client.
 * No per-player settings initialization needed as all settings are global.
 * @param client The client index.
 */
public OnClientPutInServer(client)
{    
    // Reset player state variables (not settings) for the new client
    fOldVels[client][0] = 0.0;
    fOldVels[client][1] = 0.0;
    fOldVels[client][2] = 0.0;
    bIsInAir[client] = true; // Assume in air until checked
    bJumpPressed[client] = false;
    fMomentTouchedGround[client] = 0.0;

    // Hook SDKHook_PostThink for this client to apply physics modifications
    // This is only done for valid, non-bot clients.
    if (IsValidClient(client))
    {
        SDKHook(client, SDKHook_PostThink, OnPostThink);
    }
}

/**
 * @brief Called when a client disconnects from the server.
 * Unhooks SDK events for the client to prevent errors.
 * @param client The client index.
 */
public OnClientDisconnect(client)
{
    // Always unhook on disconnect. SDKUnhook is safe to call even if not hooked.
    SDKUnhook(client, SDKHook_PostThink, OnPostThink);
}


////////////////////////////////////////////////////////////
//
//             ConVars Changed Hooks (Simplified)
//
////////////////////////////////////////////////////////////
public OnEnabledChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    bModEnabled_Global = GetConVarBool(convar);
}

public OnBhopEnabledChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    bBhopEnabled_Global = GetConVarBool(convar);
}

public OnAirstrafeMultChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    fAirstrafeMult_Global = GetConVarFloat(convar);
}

public OnBhopMaxDelayChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    fBhopMaxDelay_Global = GetConVarFloat(convar);
}

public OnBhopPerfectDelayChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    fBhopPerfectDelay_Global = GetConVarFloat(convar);
}

public OnBhopMinSpeedChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    fBhopMinSpeed_Global = GetConVarFloat(convar);
}

public OnBhopMaxSpeedChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
    fBhopMaxSpeed_Global = GetConVarFloat(convar);
}


////////////////////////////////////////////////////////////
//
//             OnPlayerRunCmd (Input Processing)
//
////////////////////////////////////////////////////////////
// This forward is used to capture player input (buttons) before game physics apply.
// We only use it to detect if the jump button was pressed.
public Action:OnPlayerRunCmd(client, &buttons, &impulse)
{
    // Check if the overall mod is enabled
    if (!bModEnabled_Global)
    {
        return Plugin_Continue;
    }
    
    // If player is on the ground and presses jump, mark it
    if (!bIsInAir[client] && (buttons & IN_JUMP))
    {
        bJumpPressed[client] = true;
    }
    
    return Plugin_Continue;
}

////////////////////////////////////////////////////////////
//
//             OnPostThink (Physics Modification)
//
////////////////////////////////////////////////////////////
// This hook is called after the game has processed player movement for the current tick.
// It's the ideal place to modify player velocity for airstrafing and bunnyhopping.
public OnPostThink(client)
{
    // Basic validation for client and plugin status
    if (!bModEnabled_Global || !IsValidClient(client))
    {
        return;
    }
    
    decl Float:fCurrentVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", fCurrentVel); // Get current velocity

    // Check if player is in a vehicle (kart fix)
    new iVehicle = GetEntPropEnt(client, Prop_Send, "m_hVehicle");
    bool bInVehicle = (iVehicle != -1 && IsValidEntity(iVehicle));

    // Airstrafe modification
    // Apply airstrafe multiplier if player is in the air and not in a vehicle
    if (bIsInAir[client] && fAirstrafeMult_Global != 1.0 && !bInVehicle) // Use global airstrafe multiplier
    {
        fCurrentVel[0] *= fAirstrafeMult_Global;
        fCurrentVel[1] *= fAirstrafeMult_Global;
        // Apply the modified velocity
        SetEntPropVector(client, Prop_Data, "m_vecVelocity", fCurrentVel);
    }
    
    // Bhop logic
    if (bJumpPressed[client])
    {            
        bJumpPressed[client] = false; // Reset jump pressed flag
        
        // Check if bhop is globally enabled and not in a vehicle
        // The assist will only be considered if within fBhopMaxDelay_Global
        if (bBhopEnabled_Global && !bInVehicle &&
            GetGameTime() - fMomentTouchedGround[client] <= fBhopMaxDelay_Global)
        {            
            // Get current and old horizontal speeds using SquareRoot (from float.inc)
            new Float:fCurrentSpeed = SquareRoot(fCurrentVel[0]*fCurrentVel[0] + fCurrentVel[1]*fCurrentVel[1]);
            new Float:fOldSpeed = SquareRoot(fOldVels[client][0]*fOldVels[client][0] + fOldVels[client][1]*fOldVels[client][1]);
            
            new Float:effective_multiplier = 1.0; // Default to 1:1 speed retention

            new Float:time_since_ground_touch = GetGameTime() - fMomentTouchedGround[client];

            // If within the perfect timing window, multiplier is 1.0 (full speed retention)
            if (time_since_ground_touch <= fBhopPerfectDelay_Global)
            {
                effective_multiplier = 1.0;
            }
            // If outside perfect timing but within max assist delay, scale linearly
            else if (fBhopMaxDelay_Global > fBhopPerfectDelay_Global)
            {
                new Float:decline_range = fBhopMaxDelay_Global - fBhopPerfectDelay_Global;
                new Float:progress_in_decline = (time_since_ground_touch - fBhopPerfectDelay_Global) / decline_range;
                
                // Clamp progress_in_decline between 0.0 and 1.0
                if (progress_in_decline < 0.0) progress_in_decline = 0.0;
                if (progress_in_decline > 1.0) progress_in_decline = 1.0;

                // LERP from 1.0 (at perfect_delay) down to 0.0 (at max_delay)
                effective_multiplier = 1.0 - progress_in_decline; 
            }
            else // If perfect_delay >= max_delay or range is zero, no assist if outside perfect_delay
            {
                effective_multiplier = 0.0; 
            }
            
            // Apply the effective multiplier to old speed
            // If effective_multiplier is 0.0, fOldSpeed becomes 0, effectively no boost.
            fOldSpeed *= effective_multiplier;

            // Only apply boost if:
            // 1. Old speed (after multiplier) is greater than current speed (player is losing speed).
            // 2. Current speed is above the minimum threshold.
            // 3. Old speed (after multiplier) is below the maximum threshold.
            // 4. The effective_multiplier is greater than 0 (meaning some assist is actually provided).
            if (fOldSpeed > fCurrentSpeed && 
                fCurrentSpeed >= fBhopMinSpeed_Global && // Use global min speed
                fOldSpeed <= fBhopMaxSpeed_Global && // Use global max speed
                effective_multiplier > 0.0) // Ensure there's actually a boost to apply
            {
                new Float:fNewAngle;
                // Get current angle using ArcTangent2.
                // ArcTangent2 takes Y, X
                new Float:fAngle = ArcTangent2(fCurrentVel[1], fCurrentVel[0]); 
                
                // The new angle will simply be the current air-strafe direction.
                fNewAngle = fAngle;

                // Convert new speed and angle back to X and Y velocity components
                // Using Cosine and Sine (uppercase) as defined in your float.inc.
                fCurrentVel[0] = fOldSpeed * Cosine(fNewAngle);
                fCurrentVel[1] = fOldSpeed * Sine(fNewAngle); 
                
                // Apply the modified velocity
                SetEntPropVector(client, Prop_Data, "m_vecVelocity", fCurrentVel);
            }
        }
    }
    
    // Determine if the player is on the ground or in the air for next tick's calculations
    new iGroundEntity = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
    if (iGroundEntity == -1)
    {            
        // Player is in the air
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", fOldVels[client]); // Store current velocity as old for next tick
        bIsInAir[client] = true;
    }
    else
    {            
        // Player is on the ground or entity
        if (bIsInAir[client]) // If they just landed
        {
            fMomentTouchedGround[client] = GetGameTime(); // Record the time they landed
            bIsInAir[client] = false;
        }
    }
}


////////////////////////////////////////////////////////////
//
//             Native Callbacks (Removed per-client natives)
//
////////////////////////////////////////////////////////////
// FC_SetBhop and FC_BhopStatus natives removed as per-player settings are no longer supported.
// If global natives are needed, they would be added here.

/**
 * @brief Helper function to check if a client is valid (in game, not a bot, etc.).
 * @param client The client index to check.
 * @return True if the client is valid, false otherwise.
 */
bool:IsValidClient(client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}
