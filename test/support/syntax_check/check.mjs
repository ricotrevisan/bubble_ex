// Parses generated schema files with real parsers (WTF-408) and prints one
// JSON line per file: {"file", "errors", "names"}. `.dbml` files go through
// @dbml/core; `.ts` files through the TypeScript compiler's parser (syntax
// only: imports are not resolved, nothing is type-checked). `names` are what
// the parser read, so a caller can check that escaped names round-trip:
// DBML `schema.table` and `schema.table.field`, TypeScript object-literal
// property names.
//
//     node check.mjs a.dbml b.ts ...
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { Parser } = require('@dbml/core');
const ts = require('typescript');

function dbml(source) {
  try {
    const database = new Parser().parse(source, 'dbmlv2');
    const names = [];
    for (const schema of database.schemas) {
      for (const table of schema.tables) {
        names.push(`${schema.name}.${table.name}`);
        for (const field of table.fields) names.push(`${schema.name}.${table.name}.${field.name}`);
      }
    }
    return { errors: [], names };
  } catch (error) {
    const diags = error.diags ?? [{ message: String(error) }];
    return { errors: diags.map((d) => d.message), names: [] };
  }
}

function typescript(file, source) {
  const sourceFile = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const errors = sourceFile.parseDiagnostics.map((d) => ts.flattenDiagnosticMessageText(d.messageText, '\n'));
  const names = [];

  const visit = (node) => {
    if (ts.isObjectLiteralElementLike(node) && node.name && ts.isObjectLiteralExpression(node.parent)) {
      names.push(ts.isIdentifier(node.name) || ts.isStringLiteral(node.name) ? node.name.text : node.name.getText());
    }
    ts.forEachChild(node, visit);
  };

  visit(sourceFile);
  return { errors, names };
}

for (const file of process.argv.slice(2)) {
  const source = readFileSync(file, 'utf8');
  const result = file.endsWith('.dbml') ? dbml(source) : typescript(file, source);
  process.stdout.write(JSON.stringify({ file, ...result }) + '\n');
}
