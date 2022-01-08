#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>

#ifndef NREPL_NO_YIELD_CHECK
# include <luajit.h> // luajit required
# if LUAJIT_VERSION_NUM < 20100
#  include "lj_frame.h" // run make luajit-2.0
# endif
#endif

#ifndef LUA_OK
#define LUA_OK 0
#endif

#define NREPL_CURRENT "nrepl.current"
#define NREPL_THREAD "nrepl.thread"

#define MODE_STEP 0
#define MODE_NEXT 1
#define MODE_FINISH 2

typedef struct {
  int thread;
  int func;
  int currentline;
  int skipline;
  int skiplevel;
} debug_userdata;

static int getlevel(lua_State *L)
{
  lua_Debug ar;
  int level = 0;
  while (lua_getstack(L, level, &ar))
    ++level;
  return level;
}

static int canresume(lua_State *L)
{
  int status = lua_status(L);
  if (status == LUA_YIELD)
    return 1; // suspended
  if (status == LUA_OK) {
    lua_Debug ar;
    if (lua_getstack(L, 0, &ar) > 0)
      return 1; // normal. can it resume?
    if (lua_gettop(L) == 0)
      return 0; // dead
    return 1; // suspended
  }
  return 0;
}

static void hook(lua_State *L, lua_Debug *ar)
{
  if (ar->event != LUA_HOOKLINE) return;

  lua_getfield(L, LUA_REGISTRYINDEX, NREPL_CURRENT);
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, -1, NREPL_THREAD);

  // luajit ignores thread in sethook, we have to check this outselves.
  // I think this might be actually useless though, since we're resetting
  // the hook function immediately after it yields.
  // TODO: handle coroutines, somehow?
  lua_getref(L, data->thread);
  lua_State *thread = lua_tothread(L, -1);
  if (L != thread) return;
  lua_pop(L, 1);

  // save current line
  data->currentline = ar->currentline;

  // get call stack level
  int level = getlevel(L);
  if (data->skiplevel != -1 && level > data->skiplevel)
    return;

  if (ar->currentline != data->skipline) {
    // hook is called before the line is executed,
    // so to not fall into a loop, save the line
    // number and skip it next time
    // TODO: save source, because it could be a different file
    data->skipline = ar->currentline;
#ifndef NREPL_NO_YIELD_CHECK
# if LUAJIT_VERSION_NUM < 20100
    if (cframe_canyield(L->cframe))
# else
    if (lua_isyieldable(L))
# endif
#endif
      lua_yield(L, 0);
  } else {
    data->skipline = -1;
  }
}

static int debugger_hook(lua_State *L, int mode)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  lua_getref(L, data->thread);
  lua_State *thread = lua_tothread(L, -1);
  if (L == thread)
    luaL_error(L, "cannot resume main thread");
  if (!canresume(thread))
    luaL_error(L, "cannot resume dead coroutine");

  lua_pushvalue(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, NREPL_CURRENT);

  if (mode == MODE_NEXT) {
    data->skiplevel = getlevel(thread);
  } else if (mode == MODE_FINISH) {
    data->skiplevel = getlevel(thread) - 1;
    if (data->skiplevel < 0)
      data->skiplevel = 0;
  } else {
    data->skiplevel = -1;
  }

  lua_sethook(thread, hook, LUA_MASKLINE, 1);
  int status = lua_resume(thread, 0);
  lua_sethook(thread, NULL, 0, 0); // TODO: restore previous hook
  data->skiplevel = -1;

  if (status == LUA_OK) { // coroutine returned
    lua_pushboolean(L, 1);
    return 1;
  } else if (status == LUA_ERRRUN) {
    lua_pushboolean(L, 0);
    lua_xmove(thread, L, 1); // move error message
    return 2;
  } else if (status == LUA_YIELD) {
    lua_pushnumber(L, data->currentline);
    return 1;
  } else {
    luaL_error(L, "unknown resume status");
  }
  return 0; // unreachable
}

static int debugger_step(lua_State *L)
{
  return debugger_hook(L, MODE_STEP);
}

static int debugger_next(lua_State *L)
{
  return debugger_hook(L, MODE_NEXT);
}

static int debugger_finish(lua_State *L)
{
  return debugger_hook(L, MODE_FINISH);
}

static int debugger_continue(lua_State *L)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  lua_getref(L, data->thread);
  lua_State *thread = lua_tothread(L, -1);
  if (L == thread)
    luaL_error(L, "cannot resume main thread");
  if (!canresume(thread))
    luaL_error(L, "cannot resume dead coroutine");

  int status = lua_resume(thread, 0);
  if (status == LUA_OK) { // coroutine returned
    lua_pushboolean(L, 1);
    return 1;
  } else if (status == LUA_ERRRUN) {
    lua_pushboolean(L, 0);
    lua_xmove(thread, L, 1); // move error message
    return 2;
  } else if (status == LUA_YIELD) {
    lua_pushnumber(L, data->currentline);
    return 1;
  } else {
    luaL_error(L, "unknown resume status");
  }
  return 0; // unreachable
}

static int debugger_create(lua_State *L)
{
  luaL_checktype(L, 1, LUA_TFUNCTION);

  lua_State *thread = lua_newthread(L);
  lua_pushvalue(L, 1);
  lua_xmove(L, thread, 1); // move function to new thread

  debug_userdata *data = (debug_userdata *)lua_newuserdata(L, sizeof(debug_userdata));
  lua_pushvalue(L, -2); // duplicate thread and save the reference
  data->thread = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushvalue(L, 1); // duplicate function and save the reference
  data->func = luaL_ref(L, LUA_REGISTRYINDEX);
  data->currentline = -1;
  data->skipline = -1;
  data->skiplevel = -1;

  luaL_getmetatable(L, NREPL_THREAD);
  lua_setmetatable(L, -2);
  return 1;
}

static int debugger_index(lua_State *L)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  luaL_checktype(L, 2, LUA_TSTRING);

  const char *index = lua_tostring(L, 2);
  if (strcmp(index, "thread") == 0) {
    lua_getref(L, data->thread);
    return 1;
  } else if (strcmp(index, "func") == 0) {
    lua_getref(L, data->func);
    return 1;
  } else if (strcmp(index, "currentline") == 0) {
    lua_pushinteger(L, data->currentline);
    return 1;
  } else if (strcmp(index, "status") == 0) {
    lua_getref(L, data->thread);
    lua_State *thread = lua_tothread(L, -1);
    if (L == thread) {
      lua_pushliteral(L, "running");
      return 1;
    }
    int status = lua_status(thread);
    if (status == LUA_YIELD) {
      lua_pushliteral(L, "suspended");
      return 1;
    } else if (status == LUA_OK) {
      lua_Debug ar;
      if (lua_getstack(thread, 0, &ar) > 0) {
        lua_pushliteral(L, "normal");
      } else if (lua_gettop(thread) == 0) {
        lua_pushliteral(L, "dead");
      } else {
        lua_pushliteral(L, "suspended");
      }
      return 1;
    } else {
      lua_pushliteral(L, "dead");
      return 1;
    }
  } else if (strcmp(index, "next") == 0) {
    lua_pushcfunction(L, debugger_next);
    return 1;
  } else if (strcmp(index, "step") == 0) {
    lua_pushcfunction(L, debugger_step);
    return 1;
  } else if (strcmp(index, "finish") == 0) {
    lua_pushcfunction(L, debugger_finish);
    return 1;
  } else if (strcmp(index, "continue") == 0) {
    lua_pushcfunction(L, debugger_continue);
    return 1;
  }

  return 0;
}

static int debugger_gc(lua_State *L)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  luaL_unref(L, LUA_REGISTRYINDEX, data->thread);
  luaL_unref(L, LUA_REGISTRYINDEX, data->func);
  return 0;
}

static int debugger_tostring(lua_State *L)
{
  void *ptr = luaL_checkudata(L, 1, NREPL_THREAD);
  lua_pushfstring(L, "nrepl-debugger: %p", ptr);
  return 1;
}

int luaopen_nrepl_debug_debugger(lua_State *L)
{
  luaL_newmetatable(L, NREPL_THREAD);
  lua_pushcfunction(L, debugger_index);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, debugger_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, debugger_tostring);
  lua_setfield(L, -2, "__tostring");
  lua_pop(L, 1);

  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, debugger_create);
  lua_setfield(L, -2, "create");
  return 1;
}

// vim: sw=2 sts=2 et
