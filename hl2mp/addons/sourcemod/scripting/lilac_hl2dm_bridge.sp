#include <sourcemod>

#define CHEAT_AIMBOT 0

// ConVar Handles
ConVar cvFixMelee;
ConVar cvFixProjectiles;
ConVar cvLogBlocks;

char g_sLastKillWeapon[MAXPLAYERS + 1][64];

public Plugin myinfo = 
{
    name = "LILAC HL2DM Bridge",
    author = "Gemini",
    description = "Configurable LILAC exclusions for HL2DM projectiles and physics",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    // Create ConVars
    cvFixMelee = CreateConVar("lilac_fix_throwable_melee", "1", "Block aimbot checks for crowbar/stunstick (Use if throwable plugin is active)");
    cvFixProjectiles = CreateConVar("lilac_fix_projectiles", "1", "Block aimbot checks for HL2DM projectiles (Grenades, RPG, Orbs, Props)");
    cvLogBlocks = CreateConVar("lilac_fix_log", "0", "Print a message to server console whenever a detection is blocked");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    
    // Creates /cfg/sourcemod/lilac_hl2dm_bridge.cfg
    AutoExecConfig(true, "lilac_hl2dm_bridge");
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    
    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
    {
        event.GetString("weapon", g_sLastKillWeapon[attacker], sizeof(g_sLastKillWeapon[]));
    }
}

public Action lilac_allow_cheat_detection(int client, int cheat)
{
    if (cheat == CHEAT_AIMBOT)
    {
        char sWep[64];
        strcopy(sWep, sizeof(sWep), g_sLastKillWeapon[client]);

        bool bBlock = false;

        // 1. Throwable Melee Logic
        if (cvFixMelee.BoolValue)
        {
            if (StrContains(sWep, "crowbar", false) != -1 || StrContains(sWep, "stun", false) != -1)
            {
                bBlock = true;
            }
        }

        // 2. Standard HL2DM Projectile/Physics Logic
        if (!bBlock && cvFixProjectiles.BoolValue)
        {
            if (StrContains(sWep, "frag", false) != -1 || 
                StrContains(sWep, "bolt", false) != -1 || 
                StrContains(sWep, "rpg", false) != -1 || 
                StrContains(sWep, "ball", false) != -1 || 
                StrContains(sWep, "ar2", false) != -1 || 
                StrEqual(sWep, "env_explosion", false) ||
                StrEqual(sWep, "prop_physics", false) ||
                StrEqual(sWep, "weapon_physcannon", false))
            {
                bBlock = true;
            }
        }

        if (bBlock)
        {
            if (cvLogBlocks.BoolValue)
            {
                PrintToServer("[Lilac-Bridge] Blocked aimbot check for %N (Weapon: %s)", client, sWep);
            }
            return Plugin_Stop;
        }
    }
    
    return Plugin_Continue;
}