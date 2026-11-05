// Parse data only. SavedVariables must never be evaluated as Lua or JavaScript.
export function parseSavedVariables(src) {
  let i = 0;
  function fail(message) { throw new Error(`${message} at offset ${i}`); }
  function whitespace() {
    while (i < src.length) {
      if (/\s/.test(src[i])) i++;
      else if (src.startsWith('--', i)) {
        if (src.startsWith('--[', i)) fail('Long comments are not supported');
        while (i < src.length && src[i] !== '\n') i++;
      } else break;
    }
  }
  function expect(token) {
    whitespace();
    if (!src.startsWith(token, i)) fail(`Expected ${token}`);
    i += token.length;
  }
  function string() {
    const quote = src[i++];
    let out = '';
    while (i < src.length) {
      let c = src[i++];
      if (c === quote) return out;
      if (c === '\n' || c === '\r') fail('Unescaped newline in string');
      if (c === '\\') {
        if (i === src.length) fail('Unterminated escape');
        c = src[i++];
        const escapes = { n: '\n', r: '\r', t: '\t', a: '\x07', b: '\b', f: '\f', v: '\v', '\\': '\\', '"': '"', "'": "'" };
        if (Object.hasOwn(escapes, c)) out += escapes[c];
        else if (/\d/.test(c)) {
          let digits = c;
          while (digits.length < 3 && /\d/.test(src[i] || '')) digits += src[i++];
          if (Number(digits) > 255) fail('Invalid decimal escape');
          out += String.fromCharCode(Number(digits));
        } else fail('Unsupported string escape');
      } else out += c;
    }
    fail('Unterminated string');
  }
  function value(depth = 0) {
    if (depth > 100) fail('Table nesting limit exceeded');
    whitespace();
    if (src[i] === '"' || src[i] === "'") return string();
    if (src[i] === '{') {
      i++;
      const table = Object.create(null);
      let next = 1;
      whitespace();
      while (src[i] !== '}') {
        if (i >= src.length) fail('Unterminated table');
        let key;
        if (src[i] === '[') {
          i++;
          key = value(depth + 1);
          if (typeof key !== 'string' && typeof key !== 'number') fail('Invalid table key');
          expect(']');
          expect('=');
        } else {
          const named = /^([A-Za-z_]\w*)\s*=/.exec(src.slice(i));
          if (named) { key = named[1]; i += named[0].length; }
          else key = next++;
        }
        table[key] = value(depth + 1);
        whitespace();
        if (src[i] === ',' || src[i] === ';') { i++; whitespace(); }
        else if (src[i] !== '}') fail('Expected table separator');
      }
      i++;
      return table;
    }
    const number = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/.exec(src.slice(i));
    if (number) {
      i += number[0].length;
      const parsed = Number(number[0]);
      if (!Number.isFinite(parsed)) fail('Non-finite number');
      return parsed;
    }
    const literal = /^(true|false|nil)\b/.exec(src.slice(i));
    if (literal) {
      i += literal[0].length;
      return literal[1] === 'nil' ? null : literal[1] === 'true';
    }
    fail('Unsupported Lua value');
  }
  const assignments = new Map();
  whitespace();
  while (i < src.length) {
    const start = i;
    const name = /^[A-Za-z_]\w*/.exec(src.slice(i));
    if (!name) fail('Expected global assignment');
    i += name[0].length;
    expect('=');
    const parsed = value();
    if (assignments.has(name[0])) fail('Duplicate global assignment');
    assignments.set(name[0], { value: parsed, start, end: i });
    whitespace();
  }
  return assignments;
}

export function luaSequence(table) {
  if (!table || typeof table !== 'object') return [];
  if (Array.isArray(table)) return table;
  const out = [];
  for (let i = 1; Object.hasOwn(table, i); i++) out.push(table[i]);
  return out;
}

export function toLua(value) {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean') return String(value);
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('Cannot serialize non-finite number');
    return String(value);
  }
  if (typeof value === 'string') {
    return '"' + value.replace(/[\\"\x00-\x1f\x7f]/g, c => {
      if (c === '\\' || c === '"') return '\\' + c;
      return '\\' + c.charCodeAt(0).toString().padStart(3, '0');
    }) + '"';
  }
  const entries = Array.isArray(value)
    ? value.map(item => toLua(item))
    : Object.entries(value).map(([key, item]) => `[${toLua(key)}] = ${toLua(item)}`);
  return '{\n' + entries.map(entry => entry + ',').join('\n') + '\n}';
}
