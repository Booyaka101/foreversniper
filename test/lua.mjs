import assert from 'node:assert/strict';
import fs from 'node:fs';
import fengari from 'fengari';

export const source = fs.readFileSync(new URL('../ForeverSniper.lua', import.meta.url), 'utf8').replace(/\r\n/g, '\n');

export function section(start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first + start.length);
  assert.ok(first >= 0 && last > first, `Missing test boundary: ${start}`);
  return source.slice(first, last);
}

export function run(code) {
  const L = fengari.lauxlib.luaL_newstate();
  fengari.lualib.luaL_openlibs(L);
  try {
    const status = fengari.lauxlib.luaL_dostring(L, fengari.to_luastring(code));
    const error = status === fengari.lua.LUA_OK ? '' : fengari.to_jsstring(fengari.lua.lua_tostring(L, -1));
    assert.equal(status, fengari.lua.LUA_OK, error);
  } finally {
    fengari.lua.lua_close(L);
  }
}
