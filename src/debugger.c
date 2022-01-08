#include <lua.h>
#include <lauxlib.h>
#ifndef NREPL_NO_YIELD_CHECK
# include <luajit.h> // luajit required
#endif
#include <stdio.h>

#ifndef NREPL_NO_YIELD_CHECK
# if LUAJIT_VERSION_NUM < 20100
#  include "lj_frame.h" // run make luajit-2.0
# endif
#endif

#ifndef LUA_OK
#define LUA_OK 0
#endif

#define REGKEY_LINE "nrepl-current"

#define MODE_STEP 0
#define MODE_NEXT 1
#define MODE_FINISH 2

// TODO: store in registry
static lua_State *currentthread = NULL;
static int skipline = -1;
static int skiplevel = -1;

static int getlevel(lua_State *L)
{
  lua_Debug ar;
  int level = 0;
  while (lua_getstack(L, level, &ar))
    ++level;
  return level;
}

static void hook(lua_State *L, lua_Debug *ar)
{
  // luajit ignores thread in sethook, we have to check this outselves
  // TODO: handle coroutines, somehow?
  if (L != currentthread || ar->event != LUA_HOOKLINE)
    return;

  // get call stack level
  int level = getlevel(L);
  if (skiplevel != -1 && level > skiplevel)
    return;

  if (ar->currentline != skipline) {
    // printf("[debug] %d line %d\n", level, ar->currentline);
    // hook is called before the line is executed,
    // so to not fall into a loop, save the line
    // number and skip it next time
    // TODO: save source, because it could be a different file
    skipline = ar->currentline;
    lua_pushnumber(L, ar->currentline);
    lua_setfield(L, LUA_REGISTRYINDEX, REGKEY_LINE);
#ifndef NREPL_NO_YIELD_CHECK
# if LUAJIT_VERSION_NUM < 20100
    if (cframe_canyield(L->cframe))
# else
    if (lua_isyieldable(L))
# endif
#endif
      lua_yield(L, 0);
  } else {
    skipline = -1;
  }
}

static int resume(lua_State *L, int mode)
{
  luaL_checktype(L, 1, LUA_TTHREAD);
  lua_State *T = lua_tothread(L, 1);
  if (L == T)
    luaL_error(L, "cannot resume debugger thread");
  if (lua_status(L) == LUA_OK && lua_gettop(L) == 0)
    luaL_error(L, "cannot resume dead coroutine");

  currentthread = T;
  if (mode == MODE_NEXT) {
    skiplevel = getlevel(T);
  } else if (mode == MODE_FINISH) {
    skiplevel = getlevel(T) - 1;
    if (skiplevel < 0)
      skiplevel = 0;
  } else {
    skiplevel = -1;
  }

  lua_sethook(T, hook, LUA_MASKLINE, 1);
  int status = lua_resume(T, 0);
  lua_sethook(T, NULL, 0, 0); // TODO: restore previous hook
  skiplevel = -1;

  if (status == LUA_OK) { // coroutine returned
    lua_pushboolean(L, 1);
    return 1;
  } else if (status == LUA_ERRRUN) {
    lua_pushboolean(L, 0);
    lua_xmove(T, L, 1); // move error message
    return 2;
  } else if (status == LUA_YIELD) {
    lua_getfield(T, LUA_REGISTRYINDEX, REGKEY_LINE);
    int nres = lua_gettop(T);
    lua_xmove(T, L, nres);
    return nres;
  } else {
    luaL_error(L, "unknown resume status");
  }
  return 1;
}

static int step(lua_State *L)
{
  return resume(L, MODE_STEP);
}

static int next(lua_State *L)
{
  return resume(L, MODE_NEXT);
}

static int finish(lua_State *L)
{
  return resume(L, MODE_FINISH);
}

int luaopen_nrepl_debug_debugger(lua_State *L)
{
  lua_createtable(L, 0, 3);
  lua_pushcfunction(L, step);
  lua_setfield(L, -2, "step");
  lua_pushcfunction(L, next);
  lua_setfield(L, -2, "next");
  lua_pushcfunction(L, finish);
  lua_setfield(L, -2, "finish");
  return 1;
}

// vim: sw=2 sts=2 et
