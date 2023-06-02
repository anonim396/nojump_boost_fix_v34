#include <sourcemod>
#include <sdktools>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "No-Jump Boost Fix",
	author = "rio",
	description = "Changes StepMove behavior that generates free Z velocity when moving up an incline",
	version = "1.0.0",
	url = "https://github.com/jason-e/nojump-boost-fix"
};

float NON_JUMP_VELOCITY;

int MOVEDATA_VELOCITY;
int MOVEDATA_OUTSTEPHEIGHT;
int MOVEDATA_ORIGIN;

ConVar g_cvEnabled;

// StepMove call state
Address g_mv;

bool g_bInStepMove = false;
int g_iTPMCalls = 0;

float g_vecStartPos[3];
float g_flStartStepHeight;

float g_vecDownPos[3];
float g_vecDownVel[3];

float g_vecUpVel[3];

DHookSetup g_TryPlayerMove = null;
DHookSetup g_StepMove = null;

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("nojump_boost_fix", "1", "Enable NoJump Boost Fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig();

	Handle gc = LoadGameConfigFile("nojumpboostfix.games");
	if (gc == null)
	{
		SetFailState("Failed to load nojumpboostfix gamedata");
	}

	char njv[16];
	if (!GameConfGetKeyValue(gc, "NON_JUMP_VELOCITY", njv, sizeof(njv)))
	{
		SetFailState("Failed to get NON_JUMP_VELOCITY");
	}
	NON_JUMP_VELOCITY		 = StringToFloat(njv);

	MOVEDATA_VELOCITY 		 = GetRequiredOffset(gc, "CMoveData::m_vecVelocity");
	MOVEDATA_OUTSTEPHEIGHT 	 = GetRequiredOffset(gc, "CMoveData::m_outStepHeight");
	MOVEDATA_ORIGIN 		 = GetRequiredOffset(gc, "CMoveData::m_vecAbsOrigin");

	g_TryPlayerMove = DHookCreateFromConf(gc, "CGameMovement::TryPlayerMove");
	if(g_TryPlayerMove == null)
		SetFailState("Failed to create detour \"CGameMovement::TryPlayerMove\"");
	
	g_StepMove = DHookCreateFromConf(gc, "CGameMovement::StepMove");
	if(g_StepMove == null)
		SetFailState("Failed to create detour \"CGameMovement::StepMove\"");

	if(!DHookEnableDetour(g_TryPlayerMove, true, Detour_TryPlayerMovePost))
		SetFailState("Error enabling detour \"CGameMovement::TryPlayerMove\"");
	
	if(!DHookEnableDetour(g_StepMove, true, Detour_StepMovePost))
		SetFailState("Error enabling detour \"CGameMovement::StepMove\"");
	
	if(!DHookEnableDetour(g_StepMove, false, Detour_StepMovePostPre))
		SetFailState("Error enabling detour \"CGameMovement::StepMove\"");
	
	delete gc;
}

int GetRequiredOffset(Handle gc, const char[] key)
{
	int offset = GameConfGetOffset(gc, key);
	if (offset == -1) SetFailState("Failed to get %s offset", key);

	return offset;
}

any GetMoveData(int offset)
{
	return LoadFromAddress(g_mv + view_as<Address>(offset), NumberType_Int32);
}

void GetMoveDataVector(int offset, float vector[3])
{
	for (int i = 0; i < 3; i++)
	{
		vector[i] = GetMoveData(offset + i*4);
	}
}

void SetMoveData(int offset, any value)
{
	StoreToAddress(g_mv + view_as<Address>(offset), value, NumberType_Int32);
}

void SetMoveDataVector(int offset, const float vector[3])
{
	for (int i = 0; i < 3; i++)
	{
		SetMoveData(offset + i*4, vector[i]);
	}
}

public MRESReturn Detour_StepMovePostPre(Address pThis, DHookParam hParams)
{
	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	g_bInStepMove = true;
	g_iTPMCalls = 0;
	g_mv = view_as<Address>(LoadFromAddress(pThis + view_as<Address>(0x04), NumberType_Int32));

	GetMoveDataVector(MOVEDATA_ORIGIN, g_vecStartPos);
	g_flStartStepHeight = view_as<float>(GetMoveData(MOVEDATA_OUTSTEPHEIGHT));

	return MRES_Handled;
}

public MRESReturn Detour_StepMovePost(Address pThis, DHookParam hParams)
{
	g_bInStepMove = false;

	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	float vecFinalPos[3];
	GetMoveDataVector(MOVEDATA_ORIGIN, vecFinalPos);

	if (g_iTPMCalls == 2 && GetVectorDistance(vecFinalPos, g_vecDownPos, true) != 0.0)
	{
		// StepMove chose the "up" result, which means it also used just the Z-velocity
		// from the "down" result. We don't want to do that because it can lead to the
		// player getting to keep all of their horizontal velocity, but also getting some
		// Z-velocity for free. Instead, we want to use one entire result or the other.

		if (g_vecDownVel[2] > NON_JUMP_VELOCITY)
		{
			// In this case, the "down" result gave the player enough Z-velocity to start sliding up.
			// The "up" result went farther, but we actually really want to keep the "down" result's
			// Z-velocity because sliding is the more important outcome -- so use the "down" result.
			SetMoveDataVector(MOVEDATA_ORIGIN, g_vecDownPos);
			SetMoveDataVector(MOVEDATA_VELOCITY, g_vecDownVel);

			float flStepDist = g_vecDownPos[2] - g_vecStartPos[2];
			if (flStepDist > 0.0)
			{
				SetMoveData(MOVEDATA_OUTSTEPHEIGHT, g_flStartStepHeight + flStepDist);
			}
		}
		else
		{
			// The "up" result is fine, but use the "up" result's actual velocity without combining it.
			// Doing this probably doesn't matter because we know the "down" Z-velocity is not more than
			// NON_JUMP_VELOCITY, which means the player will still be on the ground after CategorizePostion
			// and their Z-velocity will be reset to zero -- but let's do this anyway to be totally sure.
			SetMoveDataVector(MOVEDATA_VELOCITY, g_vecUpVel);
		}
	}

	return MRES_Handled;
}

public MRESReturn Detour_TryPlayerMovePost(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (!g_bInStepMove)
		return MRES_Ignored;

	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	g_iTPMCalls++;

	switch (g_iTPMCalls)
	{
		case 1:
		{
			// This was the call for the "down" move.
			GetMoveDataVector(MOVEDATA_ORIGIN, g_vecDownPos);
			GetMoveDataVector(MOVEDATA_VELOCITY, g_vecDownVel);
		}
		case 2:
		{
			// This was the call for the "up" move.
			// At this time, the origin doesn't include the step down, but we don't need it anyway.
			GetMoveDataVector(MOVEDATA_VELOCITY, g_vecUpVel);
		}
		default:
		{
			SetFailState("TryPlayerMove ran more than two times in one StepMove call?");
		}
	}

	return MRES_Handled;
}

