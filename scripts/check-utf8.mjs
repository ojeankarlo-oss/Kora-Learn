import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { extname } from "node:path";

const extensoesBinarias = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".svgz",
  ".woff", ".woff2", ".ttf", ".otf", ".eot", ".mp3", ".mp4", ".pdf",
]);
const extensoesTexto = new Set([
  ".css", ".html", ".js", ".jsx", ".json", ".md", ".mjs", ".sql",
  ".ts", ".tsx", ".txt", ".yml", ".yaml",
]);

const arquivos = execFileSync("git", ["ls-files", "-z"], { encoding: "buffer" })
  .toString("utf8")
  .split("\0")
  .filter(Boolean)
  .filter((arquivo) => !extensoesBinarias.has(extname(arquivo).toLowerCase()))
  .filter((arquivo) => extensoesTexto.has(extname(arquivo).toLowerCase()));

const decoder = new TextDecoder("utf-8", { fatal: true });
const falhas = [];

for (const arquivo of arquivos) {
  if (arquivo === "scripts/check-utf8.mjs") continue;
  const conteudo = readFileSync(arquivo);
  try {
    const texto = decoder.decode(conteudo);
    const escapesUnicode = [...texto.matchAll(/\\u[0-9a-fA-F]{4}/g)];
    const escapeDeTexto = escapesUnicode.some((match) => {
      const inicio = match.index ?? 0;
      const anterior = texto[inicio - 1];
      const proximo = texto[inicio + 6];
      // Permite intervalos legítimos como \\u0300-\\u036f em regex de normalização.
      return anterior !== "-" && proximo !== "-";
    });
    if (escapeDeTexto) {
      falhas.push(`${arquivo}: contém escape Unicode; use caracteres UTF-8 reais.`);
    }
  } catch {
    falhas.push(`${arquivo}: não está codificado como UTF-8 válido.`);
  }
}

if (falhas.length > 0) {
  console.error(falhas.join("\n"));
  process.exit(1);
}

console.log(`UTF-8 válido: ${arquivos.length} arquivos de texto verificados.`);
