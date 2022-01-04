local ffi = require('ffi')
local C = ffi.C

ffi.cdef([[
  typedef unsigned char char_u;
  typedef long linenr_T;
  typedef int scid_T;
  typedef void scriptitem_T;

  typedef struct {
    scid_T sc_sid;     // script ID
    int sc_seq;        // sourcing sequence number
    linenr_T sc_lnum;  // line number
  } sctx_T;

  extern sctx_T current_sctx;

  void *xmalloc(size_t size);
  scriptitem_T *new_script_item(char_u *const name, scid_T *const sid_out);
]])

local M = {}
local scripts = {}

function M._script_begin(id)
  local sid = scripts[id]
  if sid == nil then
    local name = '[nrepl'..id..']'
    local sname = C.xmalloc(#name + 1)
    ffi.copy(sname, name)
    local sid_out = ffi.new('scid_T[1]', 0)
    C.new_script_item(sname, sid_out)
    sid = sid_out[0]
    scripts[id] = sid
  end
  C.current_sctx.sc_sid = sid
end

local err = nil
function M._set_exception(exception, throwpoint)
  err = { exception = exception, throwpoint = throwpoint }
end

function M.exec(id, prg)
  err = nil

  local ok, res = pcall(vim.api.nvim_exec, string.format([[
    lua require("nrepl.vimeval")._script_begin(%d)
    try

      %s

    catch
      call luaeval('require("nrepl.vimeval")._set_exception(_A[1], _A[2])',
        \ [v:exception, v:throwpoint])
    endtry
  ]], id, prg), true)

  if not ok then
    return false, { exception = res, throwpoint = 'nvim_exec' }
  elseif err then
    return false, err
  else
    return true, res
  end
end

return M
