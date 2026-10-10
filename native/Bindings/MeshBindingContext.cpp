#include "Module/Pch.h"
#include "Bindings/MeshBindingContext.h"
#include <chrono>
#include <cmath>

namespace mcmesh::l2bridge
{
using namespace GarrysMod::Lua;
namespace
{
MeshBindingState sBindingState;
}
MeshBindingState &GetBindingState()
{
	return sBindingState;
}
double ClockMS()
{
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
BuildScope::BuildScope()
{
	l2::require(!sBindingState.mBuilding, "recursive L2 mesh build");
	sBindingState.mBuilding = true;
}
BuildScope::~BuildScope()
{
	sBindingState.mBuilding = false;
}
void SetFunction(ILuaBase *inLua, const char *inName, CFunc inFunction)
{
	inLua->PushCFunction(inFunction);
	inLua->SetField(-2, inName);
}
void SetNumber(ILuaBase *inLua, const char *inName, double inValue)
{
	inLua->PushNumber(inValue);
	inLua->SetField(-2, inName);
}
double ReadNumber(ILuaBase *inLua, int inIndex)
{
	l2::require(inLua->IsType(inIndex, Type::Number), "expected numeric L2 field");
	const double value = inLua->GetNumber(inIndex);
	l2::require(std::isfinite(value), "non-finite L2 field");
	return value;
}
double ReadItem(ILuaBase *inLua, int inTable, int inIndex)
{
	inLua->PushNumber(inIndex);
	inLua->RawGet(inTable);
	const double value = ReadNumber(inLua, -1);
	inLua->Pop();
	return value;
}
void ResetStack(ILuaBase *inLua, int inTop)
{
	if (inLua->Top() > inTop)
		inLua->Pop(inLua->Top() - inTop);
}
int Fail(ILuaBase *inLua, int inTop, const char *inReason)
{
	ResetStack(inLua, inTop);
	++GetBindingState().mFailures;
	inLua->PushNil();
	inLua->PushString(inReason);
	return 2;
}
void PushPixels(ILuaBase *inLua, const uint32_t *inValues, size_t inCount)
{
	inLua->CreateTable();
	const int table = inLua->Top();
	for (size_t i = 0; i < inCount; ++i)
	{
		inLua->PushNumber(static_cast<double>(i + 1));
		inLua->PushNumber(inValues[i]);
		inLua->RawSet(table);
	}
}
} // namespace mcmesh::l2bridge
