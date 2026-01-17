////////////////////////////////////////////////////////////
//
//			Fysics Control
//
//			by thaCURSEDpie
//
//			2012-08-19 - version 1.0.4
//			2015-01-20 - version 1.0.4 natives
//				Drixevel added natives
//			2022-08-06 - version 1.0.4 me natives
//				reBane added /bhopme and /bounceme
//			2022-11-05 - version 1.0.4 me natives kartfix
//				Thespikedballofdoom disabled bhops in karts
//			2023-12-08 - version 1.0.4 HL2DM
//				Xeogin removed TF2 specific code as well as modifications for use in HL2DM
//
//			This plugin aims to give server-admins
//			greater control over the game's physics.
//
////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////
//
//			Includes et cetera
//
////////////////////////////////////////////////////////////
#pragma semicolon 1

#define PLUGIN_VERSION "1.0.4 HL2DM"
#define SHORT_DESCRIPTION "Fysics Control by thaCURSEDpie."
#define ADMINCMD_MIN_LEVEL ADMFLAG_ROOT

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>


////////////////////////////////////////////////////////////
//
//			Global vars
//
////////////////////////////////////////////////////////////
//-- Constants
static Float:Pi = 3.1415926535898;

//-- Handles
new Handle:hEnabled = INVALID_HANDLE;
new Handle:hAirstrafeMult = INVALID_HANDLE;
new Handle:hBhopMult = INVALID_HANDLE;
new Handle:hBhopMaxDelay = INVALID_HANDLE;
new Handle:hBhopAngleRatio = INVALID_HANDLE;
new Handle:hBhopEnabled = INVALID_HANDLE;

//-- Values
new Float:fAirstrafeMult = 1.0;
new Float:fBhopMult = 1.0;
new Float:fBhopMaxDelay = 0.2;
new Float:fBhopAngleRatio = 0.5;
new bool:bModEnabled = true;
new bool:bBhopEnabled = true;

//-- Player properties
new Float:fAirstrafeMults[MAXPLAYERS];
new Float:fBhopMults[MAXPLAYERS];
new Float:fOldVels[MAXPLAYERS][3];
new Float:fBhopAngleRatios[MAXPLAYERS];
new bool:bIsInAir[MAXPLAYERS];
new bool:bJumpPressed[MAXPLAYERS];
new Float:fMomentTouchedGround[MAXPLAYERS];
new Float:fBhopMaxDelays[MAXPLAYERS];
new bool:bIsAllowedToBhop[MAXPLAYERS];

////////////////////////////////////////////////////////////
//
//			Mod description
//
////////////////////////////////////////////////////////////
public Plugin:myinfo =
{
	name		 	= "Fysics Control",
	author		   	= "thaCURSEDpie, natives by Keith Warren (Jack of Designs), modified for HL2DM by Xeogin",
	description	 	= "This plugin aims to give server admins more control over the game physics.",
	version		  	= PLUGIN_VERSION,
	url			  	= "http://www.sourcemod.net"
};


////////////////////////////////////////////////////////////
//
//			OnPluginStart
//
////////////////////////////////////////////////////////////
public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("FC_SetBhop", Native_SetBhop);
	CreateNative("FC_BhopStatus", Native_BhopStatus);
	
	RegPluginLibrary("fc");
	
	return APLRes_Success;
}


////////////////////////////////////////////////////////////
//
//			OnPluginStart
//
////////////////////////////////////////////////////////////
public OnPluginStart()
{
	LoadTranslations("common.phrases");

	//---- Cmds
	RegAdminCmd("sm_fc_reload", CmdReload, ADMINCMD_MIN_LEVEL, "Reloads Fysics Control");
	
	// Airstrafe
	RegAdminCmd("sm_airstrafe_mult", CmdAirstrafeMult, ADMINCMD_MIN_LEVEL, "Change an individual user's airstrafe multiplier");
	
	// Bhop
	RegAdminCmd("sm_bhop_mult", CmdBhopMult, ADMINCMD_MIN_LEVEL, "Change an individual users's horizontal bhop multiplier (-1 disables bhop)");
	RegAdminCmd("sm_bhop_enabled", CmdBhopEnabled, ADMINCMD_MIN_LEVEL, "Change whether or not an individual user can bunnyhop");
	RegAdminCmd("sm_bhopme", CmdBhopEnableMe, ADMINCMD_MIN_LEVEL, "Self-Controlled BHop Settings: 0 off, 1 normal, no value to toggle");
		
	//---- Convars	
	CreateConVar("fc_version", PLUGIN_VERSION, SHORT_DESCRIPTION, FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
	
	// Overall mod
	hEnabled 			= CreateConVar("fc_enabled", "1", "Enable Fysics Control");
	
	// Airstrafe
	hAirstrafeMult 		= CreateConVar("fc_airstrafe_mult", "1.0", "The multiplier to apply to airstrafing", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	
	// Bhop
	hBhopEnabled 		= CreateConVar("fc_bhop_enabled", "1", "Whether or not players can bunnyhop", FCVAR_PLUGIN);
	hBhopMult 			= CreateConVar("fc_bhop_mult", "1.0", "Horizontal boost to apply to bunnyhopping", FCVAR_PLUGIN, true, 0.0);
	hBhopMaxDelay		= CreateConVar("fc_bhop_maxdelay", "0.2", "Maximum time in seconds, after which the player has touched the ground and can still get a bhop boost.", FCVAR_PLUGIN);
	hBhopAngleRatio 	= CreateConVar("fc_bhop_angleratio", "0.5", "Ratio between old and new velocity to be used with bunnyhopping", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	
	//---- Convar changed hooks
	// Overall mod
	HookConVarChange(hEnabled, OnEnabledChanged);
	
	// Airstrafe
	HookConVarChange(hAirstrafeMult, OnAirstrafeMultChanged);	
	
	// Bhop
	HookConVarChange(hBhopMult, OnBhopMultChanged);
	HookConVarChange(hBhopMaxDelay, OnBhopMaxDelayChanged);
	HookConVarChange(hBhopAngleRatio, OnBhopAngleRatioChanged);
	HookConVarChange(hBhopEnabled, OnBhopEnabledChanged);
	
	Init();
}


////////////////////////////////////////////////////////////
//
//			Commands
//
////////////////////////////////////////////////////////////
public Action:CmdReload(client, args)
{
	Init();
	ReplyToCommand(client, "Fysics Control reloaded!");
	
	return Plugin_Handled;
}

public Action:CmdBhopMult(client, args)
{
	HandleCmdMult(client, args, "sm_bhop_mult", fBhopMults);
	
	return Plugin_Handled;
}

public Action:CmdAirstrafeMult(client, args)
{
	HandleCmdMult(client, args, "sm_airstrafe_mult", fAirstrafeMults);
	
	return Plugin_Handled;
}

public Action:CmdBhopEnabled(client, args)
{
	HandleCmdBool(client, args, "sm_bhop_enabled", bIsAllowedToBhop);
	
	return Plugin_Handled;
}

public Action:CmdBhopEnableMe(client, args)
{
	if (args < 1) {
		bIsAllowedToBhop[client] =! bIsAllowedToBhop[client];
		ReplyToCommand(client, "[SM] You toggled BHop %s", bIsAllowedToBhop[client] ? "on" : "off");
	} else {
		new String:arg[4];
		GetCmdArg(1,arg,sizeof(arg));
		new val = StringToInt(arg);
		bIsAllowedToBhop[client] = val != 0;
	}
	
	return Plugin_Handled;
}

////////////////////////////////////////////////////////////
//
//			Command handling
//
////////////////////////////////////////////////////////////
public HandleCmdBool(client, args, String:cmdName[], bool:targetArray[])
{
	if (args < 2)
	{
		new String:buf[300] = "[SM] Usage: ";
		StrCat(buf, sizeof(buf), cmdName);
		StrCat(buf, sizeof(buf), " <#userid|name> [amount]");
		
		ReplyToCommand(client, buf);
		
		return;
	}
	
	decl clients[MAXPLAYERS], nTargets;
	decl String:targetName[MAX_TARGET_LENGTH];
	
	if (GetTargetedClients(client, clients, nTargets, targetName) == 1)
	{
		return;
	}
	
	new bool:amount = false;
	
	decl String:arg2[20];
	GetCmdArg(2, arg2, sizeof(arg2));
	
	if (StringToIntEx(arg2, amount) == 0 || amount < 0)		// This line will cause a tag mismatch warning. As bools are represented as either "1" or "0" in-game, there is nothing wrong with this method (as far as I know).
	{
		ReplyToCommand(client, "[SM] %t", "Invalid Amount");
		
		return;
	}
	
	for (new i = 0; i < nTargets; i++)
	{
		targetArray[clients[i]] = amount;
	}
	
	ReplyToCommand(client, "[FC] Successfully applied cmd %s with value %b to %s!", cmdName, amount, targetName);
}

public HandleCmdMult(client, args, String:cmdName[], Float:targetArray[])
{
	if (args < 2)
	{
		new String:buf[300] = "[SM] Usage: ";
		StrCat(buf, sizeof(buf), cmdName);
		StrCat(buf, sizeof(buf), " <#userid|name> [amount]");
		
		ReplyToCommand(client, buf);
		
		return;
	}
	
	decl clients[MAXPLAYERS];
	new nTargets = 0;
	
	decl String:targetName[MAX_TARGET_LENGTH];
	
	if (GetTargetedClients(client, clients, nTargets, targetName) == 1)
	{
		return;
	}
	
	new Float:amount = 0.0;
	
	decl String:arg2[20];
	GetCmdArg(2, arg2, sizeof(arg2));
	
	if (StringToFloatEx(arg2, amount) == 0 || amount < 0)
	{
		ReplyToCommand(client, "[SM] %t", "Invalid Amount");
		
		return;
	}
	
	for (new i = 0; i < nTargets; i++)
	{
		targetArray[clients[i]] = amount;
	}
	
	ReplyToCommand(client, "[FC] Successfully applied cmd %s with value %f to %s!", cmdName, amount, targetName);
}

// Gets the clients the admin wants to target
// 		I got this somewhere from the SourceMod wiki, can't remember where :-(
public GetTargetedClients(admin, clients[MAXPLAYERS], &targetCount, String:targetName[])
{
	decl String:arg[65];
	GetCmdArg(1, arg, sizeof(arg));

	decl bool:tn_is_ml;
	
	if ((targetCount = ProcessTargetString(arg, admin, clients, MAXPLAYERS,COMMAND_FILTER_ALIVE, targetName, MAX_TARGET_LENGTH, tn_is_ml)) <= 0)
	{
		ReplyToTargetError(admin, targetCount);
		
		return 1;
	}
	
	return 0;
}


////////////////////////////////////////////////////////////
//
//			Init
//
////////////////////////////////////////////////////////////
public Init()
{
	//-- Init some arrays and values
	for (new i = 1; i < MAXPLAYERS; i++)
	{
		SetConVarFloat(hAirstrafeMult, fAirstrafeMult);
		SetConVarFloat(hBhopMult, fBhopMult);
		SetConVarFloat(hBhopMaxDelay, fBhopMaxDelay);
		SetConVarFloat(hBhopAngleRatio, fBhopAngleRatio);
		SetConVarBool(hBhopEnabled, bBhopEnabled);
		
		fAirstrafeMults[i] = fAirstrafeMult;
		fBhopMults[i] = fBhopMult;
		fBhopMaxDelays[i] = fBhopMaxDelay;
		fBhopAngleRatios[i] = fBhopAngleRatio;
		bIsAllowedToBhop[i] = bBhopEnabled;
		
		if (IsValidClient(i))
		{
			OnClientPutInServer(i);
		}
	}
}


////////////////////////////////////////////////////////////
//
//			OnClientPutInServer
//
////////////////////////////////////////////////////////////
public OnClientPutInServer(client)
{	
	SDKHook(client, SDKHook_PostThink, OnPostThink);
}


////////////////////////////////////////////////////////////
//
//			Convars Changed Hooks
//
////////////////////////////////////////////////////////////
public OnEnabledChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	bModEnabled = GetConVarBool(convar);
}

public OnBhopEnabledChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	bBhopEnabled = GetConVarBool(convar);
	
	for (new i = 0; i < MAXPLAYERS; i++)
	{
		bIsAllowedToBhop[i] = bBhopEnabled;
	}
}

public OnAirstrafeMultChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	fAirstrafeMult = GetConVarFloat(convar);
	
	for (new i = 0; i < MAXPLAYERS; i++)
	{
		fAirstrafeMults[i] = fAirstrafeMult;
	}
}

public OnBhopMultChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{	
	fBhopMult = GetConVarFloat(convar);
	
	for (new i = 0; i < MAXPLAYERS; i++)
	{
		fBhopMults[i] = fBhopMult;
	}
}

public OnBhopAngleRatioChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{	
	fBhopAngleRatio = GetConVarFloat(convar);
	
	for (new i = 0; i < MAXPLAYERS; i++)
	{
		fBhopAngleRatios[i] = fBhopAngleRatio;
	}
}

public OnBhopMaxDelayChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new Float:oldMult = fBhopMaxDelay;
	
	fBhopMaxDelay = GetConVarFloat(convar);
	
	for (new i = 0; i < MAXPLAYERS; i++)
	{
		if (fBhopMaxDelays[i] == oldMult)
		{
			fBhopMaxDelays[i] = fBhopMaxDelay;
		}
	}
}


////////////////////////////////////////////////////////////
//
//			OnPlayerRunCmd
//
////////////////////////////////////////////////////////////
public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!bModEnabled)
	{
		return Plugin_Continue;
	}
	
	if (bIsInAir[client])
	{			
		vel[0] *= fAirstrafeMults[client];
		vel[1] *= fAirstrafeMults[client];
	}
	else
	{	
		if (buttons & IN_JUMP)
		{
			bJumpPressed[client] = true;
		}
	}
	
	return Plugin_Continue;
}

////////////////////////////////////////////////////////////
//
//			OnPostThink
//
////////////////////////////////////////////////////////////
public OnPostThink(client)
{
	if (!bModEnabled || !IsValidEntity(client) || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}	
	
	if (bJumpPressed[client])
	{			
		bJumpPressed[client] = false;
		
		if (bBhopEnabled && bIsAllowedToBhop[client] && GetTickedTime() - fMomentTouchedGround[client] <= fBhopMaxDelays[client])
		{			
			new Float:fNewVel[3];
			
			GetEntPropVector(client, Prop_Data, "m_vecVelocity", fNewVel);
			
			new Float:fAngle = GetVectorAngle(fNewVel[0], fNewVel[1]);
			new Float:fOldAngle = GetVectorAngle(fOldVels[client][0], fOldVels[client][1]);
			
			new Float:fSpeed = SquareRoot(fOldVels[client][0] * fOldVels[client][0] + fOldVels[client][1] * fOldVels[client][1]);
			new Float:fNewSpeed = SquareRoot(fNewVel[0] * fNewVel[0] + fNewVel[1] * fNewVel[1]);
			fSpeed *= fBhopMults[client];

			if (fSpeed > fNewSpeed)
			{
				new Float:fNewAngle = (fAngle * fBhopAngleRatios[client] + fOldAngle) / (fBhopAngleRatios[client] + 1);

				// There are some strange instances we need to filter out, else the player sometimes gets propelled backwards
				if ((fOldAngle < 0) && (fNewAngle >= 0))
				{
					fNewAngle = fAngle;
				}
				else if ((fNewAngle < 0) && (fOldAngle >= 0) )
				{
					fNewAngle = fAngle;
				}		

				fNewVel[0] = fSpeed * Cosine(fAngle);
				fNewVel[1] = fSpeed * Sine(fAngle);

				TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fNewVel);
			}
		}
	}
	
	// Find out if the player is on the ground or in the air
	new iGroundEntity = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
	if (iGroundEntity == -1)
	{					
		// Air	
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", fOldVels[client]);
		bIsInAir[client] = true;
	}
	else
	{		
		// Ground or entity
		if (bIsInAir[client])
		{
			fMomentTouchedGround[client] = GetTickedTime();
			bIsInAir[client] = false;
		}
	}
}


/////////////////////////////////////////////////////////
//
//		 GetVectorAngle
//
//		 Notes:
//		  Get the angle for the respective vector
//		  
/////////////////////////////////////////////////////////
Float:GetVectorAngle(Float:x, Float:y)
{
	// set this to an arbitrary value, which we can use for error-checking
	new Float:theta=1337.00;
	
	// some math :)
	if (x>0)
	{
		theta = ArcTangent(y/x);
	}
	else if ((x<0) && (y>=0))
	{
		theta = ArcTangent(y/x) + Pi;
	}
	else if ((x<0) && (y<0))
	{
		theta = ArcTangent(y/x) - Pi;
	}
	else if ((x==0) && (y>0))
	{
		theta = 0.5 * Pi;
	}
	else if ((x==0) && (y<0))
	{
		theta = -0.5 * Pi;
	}
	
	// let's return the value
	return theta;		
}

////////////////////////////////////////////////////////////
//
//			Natives
//
////////////////////////////////////////////////////////////
public Native_SetBhop(Handle:plugin, numParams)
{
	if (!hEnabled || !hBhopEnabled) ThrowNativeError(SP_ERROR_INDEX, "Native is currently disabled.");
	
	new client = GetNativeCell(1);
	
	if (!IsValidClient(client))
	{
		ThrowNativeError(SP_ERROR_INDEX, "Client is invalid.");
	}
	
	bIsAllowedToBhop[client] = bool:GetNativeCell(2);
	fBhopMults[client] = Float:GetNativeCell(3);
}

public Native_BhopStatus(Handle:plugin, numParams)
{
	if (!hEnabled || !hBhopEnabled) ThrowNativeError(SP_ERROR_INDEX, "Native is currently disabled.");
	
	new client = GetNativeCell(1);
	
	if (!IsValidClient(client))
	{
		ThrowNativeError(SP_ERROR_INDEX, "Client is invalid.");
	}
	
	return bIsAllowedToBhop[client];
}

bool:IsValidClient(client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	return false;
	return true;
}