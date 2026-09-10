export class DuplicateJsonKeyError extends SyntaxError {
  constructor() {
    super("Duplicate JSON object key");
    this.name = "DuplicateJsonKeyError";
    this.code = "DUPLICATE_JSON_KEY";
  }
}

export class InvalidJsonError extends SyntaxError {
  constructor() {
    super("Invalid JSON");
    this.name = "InvalidJsonError";
    this.code = "INVALID_JSON";
  }
}

const WHITESPACE = new Set([" ", "\n", "\r", "\t"]);
const SIMPLE_ESCAPES = new Set(["\"", "\\", "/", "b", "f", "n", "r", "t"]);

function fail() {
  throw new InvalidJsonError();
}

export function parseJsonRejectDuplicateKeys(source) {
  if (typeof source !== "string") fail();
  let index = 0;

  function skipWhitespace() {
    while (index < source.length && WHITESPACE.has(source[index])) index += 1;
  }

  function parseString() {
    const start = index;
    if (source[index] !== '"') fail();
    index += 1;
    while (index < source.length) {
      const character = source[index];
      if (character === '"') {
        index += 1;
        try {
          return JSON.parse(source.slice(start, index));
        } catch {
          fail();
        }
      }
      if (character === "\\") {
        index += 1;
        if (index >= source.length) fail();
        const escape = source[index];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(source.slice(index + 1, index + 5))) fail();
          index += 5;
          continue;
        }
        if (!SIMPLE_ESCAPES.has(escape)) fail();
        index += 1;
        continue;
      }
      if (character.charCodeAt(0) < 0x20) fail();
      index += 1;
    }
    fail();
  }

  function parseNumber() {
    const match = source.slice(index).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (!match) fail();
    index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) fail();
    return value;
  }

  function parseArray() {
    index += 1;
    skipWhitespace();
    const result = [];
    if (source[index] === "]") {
      index += 1;
      return result;
    }
    while (true) {
      result.push(parseValue());
      skipWhitespace();
      if (source[index] === "]") {
        index += 1;
        return result;
      }
      if (source[index] !== ",") fail();
      index += 1;
      skipWhitespace();
    }
  }

  function parseObject() {
    index += 1;
    skipWhitespace();
    const result = {};
    const keys = new Set();
    if (source[index] === "}") {
      index += 1;
      return result;
    }
    while (true) {
      const key = parseString();
      if (keys.has(key)) throw new DuplicateJsonKeyError();
      keys.add(key);
      skipWhitespace();
      if (source[index] !== ":") fail();
      index += 1;
      skipWhitespace();
      result[key] = parseValue();
      skipWhitespace();
      if (source[index] === "}") {
        index += 1;
        return result;
      }
      if (source[index] !== ",") fail();
      index += 1;
      skipWhitespace();
    }
  }

  function parseValue() {
    skipWhitespace();
    const character = source[index];
    if (character === "{") return parseObject();
    if (character === "[") return parseArray();
    if (character === '"') return parseString();
    if (source.startsWith("true", index)) {
      index += 4;
      return true;
    }
    if (source.startsWith("false", index)) {
      index += 5;
      return false;
    }
    if (source.startsWith("null", index)) {
      index += 4;
      return null;
    }
    if (character === "-" || (character >= "0" && character <= "9")) return parseNumber();
    fail();
  }

  const value = parseValue();
  skipWhitespace();
  if (index !== source.length) fail();
  return value;
}
