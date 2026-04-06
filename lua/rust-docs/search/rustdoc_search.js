#!/usr/bin/env node
/**
 * rustdoc_search.js — Run the official rustdoc search engine in Node.js.
 *
 * Usage:
 *   node rustdoc_search.js <query> [<static_dir> [<index_dir> [<filter_crate>]]]
 *
 * If static_dir / index_dir are omitted the script auto-discovers the nightly
 * toolchain under RUSTUP_HOME (defaults to ~/.rustup).
 *
 * Output: a JSON array written to stdout, one line per item:
 *   [{"name":"Vec","path":"std::vec","kind":"struct","desc":"...","href":"std/vec/struct.Vec.html"}, ...]
 *
 * Exit codes: 0 = success, 1 = error (message on stderr).
 *
 * Design notes
 * ─────────────
 * • stringdex-*.js  exports via  module.exports.Stringdex / .RoaringBitmap
 * • search-*.js     exports via  exports.initSearch  (NOT module.exports)
 * • ALL data files (root, tree nodes, column data) MUST be loaded with eval()
 *   so that JavaScript string-literal escapes (\xe2, \", …) are preserved.
 *   Extracting the payload manually would produce wrong bytes → hash mismatch
 *   → the Promise registered by dataLoadByNameAndHash never resolves.
 * • search-*.js calls nonnull() — we provide a minimal global stub.
 * • search-*.js is NOT a browser module; it checks `typeof exports !== "undefined"`
 *   and takes the Node.js path when exports is defined.
 */

'use strict';

const fs   = require('fs');
const path = require('path');

// ──────────────────────────────────────────────────────────────────────────────
// 1. Resolve toolchain paths
// ──────────────────────────────────────────────────────────────────────────────

function findToolchain() {
  const rustupHome = process.env.RUSTUP_HOME ||
    path.join(process.env.HOME || '/root', '.rustup');
  const toolchainsDir = path.join(rustupHome, 'toolchains');

  let candidates = [];
  try {
    for (const entry of fs.readdirSync(toolchainsDir)) {
      const htmlDir = path.join(toolchainsDir, entry, 'share', 'doc', 'rust', 'html');
      const indexDir = path.join(htmlDir, 'search.index');
      if (fs.existsSync(indexDir)) {
        candidates.push({ name: entry, htmlDir, indexDir });
      }
    }
  } catch (_) {}

  candidates.sort((a, b) => {
    const score = n => n.includes('nightly') ? 0 : n.includes('beta') ? 1 : 2;
    return score(a.name) - score(b.name);
  });

  if (candidates.length === 0) {
    throw new Error('No rustup toolchain with search.index found under ' + rustupHome);
  }
  return candidates[0];
}

function findStaticFile(staticDir, prefix) {
  for (const f of fs.readdirSync(staticDir)) {
    if (f.startsWith(prefix) && f.endsWith('.js')) return path.join(staticDir, f);
  }
  throw new Error(`${prefix}*.js not found in ${staticDir}`);
}

// ──────────────────────────────────────────────────────────────────────────────
// 2. Parse CLI args
// ──────────────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
if (args.length === 0) {
  process.stderr.write('Usage: rustdoc_search.js <query> [static_dir [index_dir [filter_crate]]]\n');
  process.exit(1);
}

const query        = args[0];
const filterCrate  = args[3] || null;   // e.g. "std" or null for all crates

let staticDir, indexDir;
if (args[1] && args[2]) {
  staticDir = args[1];
  indexDir  = args[2];
} else {
  const tc = findToolchain();
  staticDir = path.join(tc.htmlDir, 'static.files');
  indexDir  = tc.indexDir;
}

// ──────────────────────────────────────────────────────────────────────────────
// 3. Provide globals required by search-*.js
// ──────────────────────────────────────────────────────────────────────────────

// search-*.js checks `typeof window !== "undefined"` for the browser path.
// We must NOT define window so it takes the `typeof exports !== "undefined"` path.
// It does call nonnull() inside getRow, so we stub that.
global.nonnull   = (x, msg) => { if (x == null) throw new Error(msg || 'unexpected null'); return x; };
global.addClass  = () => {};
global.removeClass = () => {};

// ──────────────────────────────────────────────────────────────────────────────
// 4. Load stringdex and search engines via eval()
// ──────────────────────────────────────────────────────────────────────────────

const stringdexFile = findStaticFile(staticDir, 'stringdex-');
const searchFile    = findStaticFile(staticDir, 'search-');

// Step 1: eval stringdex — exports via module.exports
const stringdexSrc = fs.readFileSync(stringdexFile, 'utf8');
// eslint-disable-next-line no-eval
eval(stringdexSrc);
const { Stringdex, RoaringBitmap } = module.exports;
if (!Stringdex || !RoaringBitmap) {
  throw new Error('stringdex eval did not export Stringdex/RoaringBitmap');
}

// Step 2: reset exports, then eval search — exports via exports.initSearch
// We must keep module.exports as a live object (search.js uses `exports.initSearch`)
// but clear any stringdex keys so they don't bleed over.
for (const k of Object.keys(module.exports)) delete module.exports[k];

const searchSrc = fs.readFileSync(searchFile, 'utf8');
// eslint-disable-next-line no-eval
eval(searchSrc);
const initSearch = module.exports.initSearch;
if (typeof initSearch !== 'function') {
  throw new Error('search eval did not export initSearch as a function');
}

// ──────────────────────────────────────────────────────────────────────────────
// 5. Find the root index file
// ──────────────────────────────────────────────────────────────────────────────

function findRootFile(indexDir) {
  for (const f of fs.readdirSync(indexDir)) {
    if (f.startsWith('root') && f.endsWith('.js')) return path.join(indexDir, f);
  }
  throw new Error('root*.js not found in ' + indexDir);
}

const rootFile = findRootFile(indexDir);

// ──────────────────────────────────────────────────────────────────────────────
// 6. Build hooks that load files via eval() with callbacks bound in scope
// ──────────────────────────────────────────────────────────────────────────────

// The key insight: ALL data files call one of rr_, rd_, rb_, rn_ with their
// payload. We must eval them with those names in scope so JS string escapes
// are applied correctly (the siphash is computed from the decoded bytes,
// not from the raw source characters).

function makeHooks(callbacks_ref) {
  return {
    // Called once with the root callbacks object; we eval root*.js in that scope.
    loadRoot(callbacks) {
      callbacks_ref.current = callbacks;
      const { rr_, err_rr_, rd_, err_rd_, rb_, err_rb_, rn_, err_rn_ } = callbacks;
      try {
        const src = fs.readFileSync(rootFile, 'utf8');
        // eslint-disable-next-line no-eval
        eval(src);
      } catch (e) {
        if (callbacks.err_rr_) callbacks.err_rr_(e.message);
      }
    },

    // Called when a tree-node file is needed (hash hex → search.index/<hash>.js)
    loadTreeByHash(hashHex) {
      const file = path.join(indexDir, hashHex + '.js');
      const { rn_, err_rn_ } = callbacks_ref.current;
      try {
        const src = fs.readFileSync(file, 'utf8');
        // eslint-disable-next-line no-eval
        eval(src);
      } catch (e) {
        err_rn_(hashHex, e.message);
      }
    },

    // Called when a column data file is needed (name + hash hex → search.index/<name>/<hash>.js)
    loadDataByNameAndHash(name, hashHex) {
      const file = path.join(indexDir, name, hashHex + '.js');
      const { rd_, err_rd_, rb_, err_rb_ } = callbacks_ref.current;
      try {
        const src = fs.readFileSync(file, 'utf8');
        // eslint-disable-next-line no-eval
        eval(src);
      } catch (e) {
        // Try err_rd_ first, fallback to err_rb_
        if (err_rd_) err_rd_(hashHex, e.message);
        else if (err_rb_) err_rb_(hashHex, e.message);
      }
    },
  };
}

// ──────────────────────────────────────────────────────────────────────────────
// 7. Run the search
// ──────────────────────────────────────────────────────────────────────────────

async function main() {
  const callbacks_ref = { current: null };
  const hooks         = makeHooks(callbacks_ref);

  // Load the database (resolves after loadRoot fires rr_)
  const database = await Stringdex.loadDatabase(hooks);

  // initSearch returns { docSearch, DocSearch } in the Node.js path
  const { docSearch, DocSearch } = await initSearch(Stringdex, RoaringBitmap, hooks);

  // parseQuery is a static method on DocSearch, not on the docSearch instance
  const parsedQuery = DocSearch.parseQuery(query);

  // execQuery returns { in_args, returned, others, query }
  // filterCrates is an array (or null); currentCrate is a string (or null)
  const results = await docSearch.execQuery(parsedQuery, filterCrate ? [filterCrate] : null, filterCrate || null);

  const items = [];
  const MAX_RESULTS = 50;

  for await (const item of results.others) {
    // item.desc is a Promise<string> (description loaded lazily from the desc column)
    const desc = typeof item.desc === 'object' && item.desc && typeof item.desc.then === 'function'
      ? await item.desc
      : (item.desc || '');

    // item.displayPath contains HTML spans; strip tags to get plain text path
    const rawPath = (item.item.modulePath || '');

    items.push({
      name: item.item.name        || '',
      path: rawPath,
      kind: item.item.ty          != null ? tyToKind(item.item.ty) : '',
      desc: (desc || '').replace(/\s+/g, ' ').trim(),
      href: item.href             || '',
    });
    if (items.length >= MAX_RESULTS) break;
  }

  process.stdout.write(JSON.stringify(items) + '\n');
}

// Map rustdoc ty integer to human-readable kind string.
// Values match search.js's itemTypes array.
const ITEM_TYPES = [
  'keyword', 'primitive', 'mod', 'externcrate', 'import',
  'struct', 'enum', 'fn', 'typedef', 'static',
  'trait', 'impl', 'tymethod', 'method', 'structfield',
  'variant', 'macro', 'associatedtype', 'constant', 'associatedconstant',
  'union', 'foreigntype', 'existential', 'attr', 'derive', 'traitalias',
  'generic',
];

function tyToKind(ty) {
  return ITEM_TYPES[ty] || String(ty);
}

main().catch(err => {
  process.stderr.write('rustdoc_search error: ' + err.stack + '\n');
  process.exit(1);
});
