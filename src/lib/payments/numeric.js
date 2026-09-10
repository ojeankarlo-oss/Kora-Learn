const JSON_NUMBER = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/;

/**
 * Canonical numeric rule for request fingerprints:
 * - preserve the exact decimal mathematical value from the JSON lexeme;
 * - remove irrelevant integer/fractional zeros;
 * - normalize exponent notation to `<significant-digits>e<base10-exponent>`;
 * - normalize every zero, including -0 and -0.0, to `0`;
 * - never use IEEE-754 conversion for the canonical representation.
 */
export const NUMERIC_CANONICALIZATION_RULE =
  "exact decimal coefficient/exponent; trailing zeros removed; negative zero is 0";

function signedExponent(value) {
  return value.startsWith("-") ? BigInt(value) : BigInt(`+${value}`);
}

export function canonicalizeNumericLexeme(lexeme) {
  if (typeof lexeme !== "string") throw new TypeError("Numeric lexeme must be a string");
  const match = lexeme.match(JSON_NUMBER);
  if (!match) throw new SyntaxError("Invalid JSON number");

  const [, sign, integerPart, fractionalPart = "", exponentPart = "0"] = match;
  let digits = `${integerPart}${fractionalPart}`;
  let decimalScale = BigInt(fractionalPart.length) - signedExponent(exponentPart);

  digits = digits.replace(/^0+/, "");
  if (digits.length === 0) return "0";

  while (digits.endsWith("0")) {
    digits = digits.slice(0, -1);
    decimalScale -= 1n;
  }

  const exponent = -decimalScale;
  return `${sign === "-" ? "-" : ""}${digits}e${exponent.toString()}`;
}
