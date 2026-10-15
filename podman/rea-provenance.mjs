// Write the run-provenance record for one isolated REA analysis.
//
// This runs INSIDE the pinned analysis runtime, started from an image ID, with
// the analysis input mounted read-only and the output directory mounted
// read-write. It is invoked by podman/rea-analyze.sh after the analysis.
//
// Why node and not shell: the record is JSON, and hand-rolled shell escaping
// is where provenance records go wrong. An earlier shell implementation
// silently wrote empty `path` values because its escaper aborted inside a
// command substitution. Here JSON.stringify is correct by construction, every
// input arrives through an environment variable so nothing is parsed by a
// shell, and a failure is an exit code rather than a quietly malformed record.
//
// Digests cover names and tree structure, not just contents. Hashing only the
// set of file digests gives two different trees the same value whenever their
// contents match but their layout does not.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const INPUT = "/analysis/input";
const OUTPUT = "/analysis/output";
const MANIFEST = "rea-run-provenance.json";

const required = (name) => {
  const value = process.env[name];
  if (value === undefined)
    throw new Error(`rea-provenance: missing environment variable ${name}`);
  return value;
};

/** POSIX-style path relative to a root, so a record reads the same anywhere. */
const relativePosix = (root, path) => relative(root, path).split(sep).join("/");

const sha256File = (path) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

/**
 * Entries under `root`, ordered by code point so the result is independent of
 * traversal order. Directories are included so that a renamed or added empty
 * directory changes the tree digest. Anything that is neither a regular file
 * nor a directory is recorded by kind and never opened.
 */
const walk = (root) => {
  const entries = [];
  const visit = (dir) => {
    const children = readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
    );
    for (const child of children) {
      const full = join(dir, child.name);
      const path = relativePosix(root, full);
      if (child.isDirectory()) {
        entries.push({ kind: "dir", path });
        visit(full);
      } else if (child.isFile()) {
        entries.push({ kind: "file", path, sha256: sha256File(full) });
      } else {
        entries.push({ kind: "other", path });
      }
    }
  };
  visit(root);
  return entries;
};

/** One digest over kind, path and content digest of every entry. */
const treeDigest = (entries) => {
  const hash = createHash("sha256");
  for (const entry of entries)
    hash.update(`${entry.kind}\t${entry.path}\t${entry.sha256 ?? ""}\n`);
  return hash.digest("hex");
};

const describeInput = (path) => {
  const stats = statSync(path);
  if (stats.isFile())
    return {
      kind: "file",
      sha256: sha256File(path),
      digest_covers: "file contents",
    };
  const entries = walk(path);
  return {
    kind: "directory",
    sha256: treeDigest(entries),
    digest_covers: "contents, names and tree structure",
    entry_count: entries.length,
  };
};

const outputEntries = walk(OUTPUT)
  .filter((entry) => entry.path !== MANIFEST)
  .map(({ kind, path, sha256 }) =>
    sha256 === undefined ? { kind, path } : { kind, path, sha256 },
  );

const record = {
  operation: required("REA_PROV_OPERATION"),
  // Real argv elements, forwarded by the wrapper; never a hand-built string.
  arguments: process.argv.slice(2),
  exit_code: Number.parseInt(required("REA_PROV_EXIT"), 10),
  runtime: {
    image_ref_requested: required("REA_PROV_IMAGE_REF"),
    image_id: required("REA_PROV_IMAGE_ID"),
    started_from: "image_id",
    rea_source_sha: required("REA_PROV_SOURCE_SHA"),
    rea_source_sha_baked_in_image: readFileSync(
      "/opt/rea/.rea-source-sha",
      "utf8",
    ).trim(),
    rea_source_tree: required("REA_PROV_SOURCE_TREE"),
    base_image_digest: required("REA_PROV_BASE_DIGEST"),
    node_version: process.version,
  },
  input: {
    ...describeInput(INPUT),
    mounted_at: INPUT,
    mode: "read-only",
  },
  isolation: {
    network: "none",
    root_filesystem: "read-only",
    capabilities: "all dropped",
    no_new_privileges: true,
    podman_socket_mounted: false,
    rootless: true,
  },
  output: outputEntries,
};

if (
  record.runtime.rea_source_sha_baked_in_image !== record.runtime.rea_source_sha
)
  throw new Error(
    `rea-provenance: image label ${record.runtime.rea_source_sha} does not match baked source ${record.runtime.rea_source_sha_baked_in_image}`,
  );

writeFileSync(join(OUTPUT, MANIFEST), `${JSON.stringify(record, null, 2)}\n`);
