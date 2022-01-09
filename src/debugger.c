#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#include <luajit.h> // luajit required
#if LUAJIT_VERSION_NUM < 20100
# include "lj_frame.h" // run make luajit-2.0
#endif


#ifndef LUA_OK
#define LUA_OK 0
#endif

#if LUAJIT_VERSION_NUM < 20100
# define CAN_YIELD(L) (cframe_canyield((L)->cframe))
#else
# define CAN_YIELD(L) (lua_isyieldable(L))
#endif

#define NREPL_CURRENT "nrepl.current"
#define NREPL_THREAD "nrepl.thread"

#define MODE_STEP 0
#define MODE_NEXT 1
#define MODE_FINISH 2


typedef struct {
  int32_t id;
  int32_t line;
  char *file;
} debug_breakpoint;

typedef struct {
  // references
  int thread;
  int func;
  // state
  int currentline;
  int skipline;
  int skiplevel;
  bool continuing;
  // breakpoints
  int32_t bpid;
  uint32_t bplen;
  debug_breakpoint *bps;
} debug_userdata;

#define DEBUG_USERDATA_INIT \
  (debug_userdata){ \
    .thread = LUA_REFNIL, \
    .func = LUA_REFNIL, \
    .currentline = -1, \
    .skipline = -1, \
    .skiplevel = -1, \
    .continuing = false, \
    .bpid = 0, \
    .bplen = 0, \
    .bps = NULL, \
  }


static int getlevel(lua_State *L)
{
  lua_Debug ar;
  int level = 0;
  while (lua_getstack(L, level, &ar))
    ++level;
  return level;
}

static bool canresume(lua_State *L)
{
  int status = lua_status(L);
  if (status == LUA_YIELD)
    return true; // suspended
  if (status == LUA_OK) {
    lua_Debug ar;
    if (lua_getstack(L, 0, &ar) > 0)
      return true; // normal. can it resume?
    if (lua_gettop(L) == 0)
      return false; // dead
    return true; // suspended
  }
  return false; // dead
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

  // breakpoints
  if (data->continuing) { // TODO: move to a separate hook function
    if (data->bplen == 0 || !CAN_YIELD(L))
      return;
    bool gotinfo = false;
    for (size_t i = 0; i < data->bplen; ++i) {
      debug_breakpoint *bp = &data->bps[i];
      // check line first, since it's cheap
      if (ar->currentline < 1 || ar->currentline != bp->line)
        return;

      // get source info if necessary, once
      if (!gotinfo) {
        if (!lua_getinfo(L, "S", ar))
          return;
        gotinfo = true;
      }

      // skip if we don't know the file
      if (*(ar->source) != '@')
        continue;

      // compare source files after the '@'
      if (strcmp(bp->file, ar->source + 1) == 0) {
        if (ar->currentline != data->skipline) {
          data->skipline = ar->currentline;
          lua_yield(L, 0);
        } else {
          data->skipline = -1;
        }
      }
    }
    return;
  }

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
    if (CAN_YIELD(L))
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

  data->continuing = false;
  lua_sethook(thread, hook, LUA_MASKLINE, 0);
  int status = lua_resume(thread, 0);
  lua_sethook(thread, NULL, 0, 0); // TODO: restore previous hook
  data->skiplevel = -1;

  lua_pushnil(L);
  lua_setfield(L, LUA_REGISTRYINDEX, NREPL_CURRENT);

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

  lua_pushvalue(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, NREPL_CURRENT);

  data->continuing = true;
  int status;
  if (data->bplen > 0) { // set hook if there are any breakpoints set
    lua_sethook(thread, hook, LUA_MASKLINE, 0);
    status = lua_resume(thread, 0);
    lua_sethook(thread, NULL, 0, 0); // TODO: restore previous hook
    data->skiplevel = -1;
  } else {
    status = lua_resume(thread, 0);
  }

  lua_pushnil(L);
  lua_setfield(L, LUA_REGISTRYINDEX, NREPL_CURRENT);

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

static int debugger_breakpoint_add(lua_State *L)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  const char *file = luaL_checkstring(L, 2);
  int line = luaL_checkinteger(L, 3);
  if (file == NULL || *file == '\0')
    luaL_error(L, "no file name");
  if (line < 1)
    luaL_error(L, "line smaller than 1");

  size_t slen = strlen(file);
  char *sfile = malloc(slen + 1);
  if (sfile == NULL)
    luaL_error(L, "malloc");
  memcpy(sfile, file, slen + 1);

  size_t nlen = data->bplen + 1;
  debug_breakpoint *nbps = realloc(data->bps, nlen * sizeof(debug_breakpoint));
  if (nbps == NULL) {
    free(sfile);
    luaL_error(L, "realloc");
  }

  uint32_t id = ++data->bpid;
  nbps[nlen - 1] = (debug_breakpoint){
    .id = id,
    .line = line,
    .file = sfile,
  };
  data->bps = nbps;
  data->bplen = nlen;
  lua_pushinteger(L, id);
  return 1;
}

static int debugger_create(lua_State *L)
{
  luaL_checktype(L, 1, LUA_TFUNCTION);

  lua_State *thread = lua_newthread(L);
  lua_pushvalue(L, 1);
  lua_xmove(L, thread, 1); // move function to the new thread

  debug_userdata *data = (debug_userdata *)lua_newuserdata(L, sizeof(debug_userdata));
  *data = DEBUG_USERDATA_INIT;
  lua_pushvalue(L, -2); // duplicate thread and save the reference
  data->thread = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushvalue(L, 1); // duplicate function and save the reference
  data->func = luaL_ref(L, LUA_REGISTRYINDEX);

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
  } else if (strcmp(index, "func") == 0) {
    lua_getref(L, data->func);
  } else if (strcmp(index, "currentline") == 0) {
    lua_pushinteger(L, data->currentline);
  } else if (strcmp(index, "status") == 0) {
    lua_getref(L, data->thread);
    lua_State *thread = lua_tothread(L, -1);
    if (L == thread) {
      lua_pushliteral(L, "running");
    } else {
      int status = lua_status(thread);
      if (status == LUA_YIELD) {
        lua_pushliteral(L, "suspended");
      } else if (status == LUA_OK) {
        lua_Debug ar;
        if (lua_getstack(thread, 0, &ar) > 0) {
          lua_pushliteral(L, "normal");
        } else if (lua_gettop(thread) == 0) {
          lua_pushliteral(L, "dead");
        } else {
          lua_pushliteral(L, "suspended");
        }
      } else {
        lua_pushliteral(L, "dead");
      }
    }
  } else if (strcmp(index, "next") == 0) {
    lua_pushcfunction(L, debugger_next);
  } else if (strcmp(index, "step") == 0) {
    lua_pushcfunction(L, debugger_step);
  } else if (strcmp(index, "finish") == 0) {
    lua_pushcfunction(L, debugger_finish);
  } else if (strcmp(index, "continue") == 0) {
    lua_pushcfunction(L, debugger_continue);
  } else if (strcmp(index, "breakpoint") == 0) {
    lua_pushcfunction(L, debugger_breakpoint_add);
  } else {
    return 0;
  }
  return 1;
}

static int debugger_gc(lua_State *L)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  luaL_unref(L, LUA_REGISTRYINDEX, data->thread);
  luaL_unref(L, LUA_REGISTRYINDEX, data->func);
  if (data->bps != NULL) {
    for (size_t i = 0; i < data->bplen; ++i)
      free(data->bps[i].file);
    free(data->bps);
  }
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
