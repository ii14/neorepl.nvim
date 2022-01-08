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

#ifndef NREPL_NO_YIELD_CHECK
# if LUAJIT_VERSION_NUM < 20100
#  define CAN_YIELD(L) (cframe_canyield((L)->cframe))
# else
#  define CAN_YIELD(L) (lua_isyieldable(L))
# endif
#else
# define CAN_YIELD(L) (1)
#endif

typedef struct {
  int line;
  char *file;
} debug_breakpoint;

typedef struct {
  int thread;
  int func;
  int currentline;
  int skipline;
  int skiplevel;
  int continuing;
  size_t bplen;
  debug_breakpoint *bps;
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

  // breakpoints
  if (data->continuing) { // TODO: move to a separate hook function
    if (data->bplen == 0 || !CAN_YIELD(L))
      return;
    int gotinfo = 0;
    for (size_t i = 0; i < data->bplen; ++i) {
      debug_breakpoint *bp = &data->bps[i];
      // check line first, since it's cheap
      if (ar->currentline != bp->line)
        return;

      // get source info if necessary, once
      if (!gotinfo) {
        if (!lua_getinfo(L, "S", ar))
          return;
        gotinfo = 1;
      }

      // skip if we don't know the file
      if (*(ar->source) != '@')
        continue;

      // yield if everything checks out
      if (strcmp(bp->file, ar->short_src) == 0) {
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

  data->continuing = 0;
  lua_sethook(thread, hook, LUA_MASKLINE, 0);
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

  lua_pushvalue(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, NREPL_CURRENT);

  data->continuing = 1;
  int status;
  if (data->bplen > 0) { // set hook if there are any breakpoints set
    lua_sethook(thread, hook, LUA_MASKLINE, 0);
    status = lua_resume(thread, 0);
    lua_sethook(thread, NULL, 0, 0); // TODO: restore previous hook
    data->skiplevel = -1;
  } else {
    status = lua_resume(thread, 0);
  }

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

static int debugger_breakpoint(lua_State *L)
{
  debug_userdata *data = (debug_userdata *)luaL_checkudata(L, 1, NREPL_THREAD);
  const char *file = luaL_checkstring(L, 2);
  int line = luaL_checkinteger(L, 3);
  if (file == NULL || *file == '\0')
    luaL_error(L, "no file name");
  if (line <= 0)
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

  nbps[nlen - 1] = (debug_breakpoint){ .line = line, .file = sfile };
  data->bps = nbps;
  data->bplen = nlen;
  lua_pushinteger(L, nlen);
  return 1;
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
  data->continuing = 0;
  data->bplen = 0;
  data->bps = NULL;

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
  } else if (strcmp(index, "breakpoint") == 0) {
    lua_pushcfunction(L, debugger_breakpoint);
    return 1;
  }

  return 0;
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
