// Shared, deterministic digesting for isolated REA analyses.
//
// Used by rea-snapshot.mjs (to digest the immutable snapshot it creates) and by
// rea-provenance.mjs (to re-digest that snapshot when writing the record), so
// both agree by construction rather than by two similar implementations.
//
// Two rules matter here:
//
// 1. A digest covers names and tree structure, not only contents. Hashing just
//    the set of file digests gives two different trees the same value whenever
//    their contents match but their layout does not.
//
// 2. Anything that is not a regular file or a directory is REFUSED, not
//    recorded. A symbolic link has no content of its own: hashing the link
//    target is not the bytes that were analysed, and following it leaves the
//    declared input entirely. FIFOs, sockets and device nodes have no stable
//    content to hash at all, and reading one can block forever. Refusing is the
//    only answer that keeps a digest an honest statement about analysed bytes.

import { createHash } from "node:crypto";
import { lstatSync, readdirSync, readFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

export class UnhashableEntryError extends Error {
  constructor(path, kind) {
    super(
      `refusing to digest ${kind} at ${path}: only regular files and directories can be hashed deterministically`,
    );
    this.name = "UnhashableEntryError";
    this.path = path;
    this.kind = kind;
  }
}

const kindOf = (stats) => {
  if (stats.isSymbolicLink()) return "symbolic link";
  if (stats.isFIFO()) return "FIFO";
  if (stats.isSocket()) return "socket";
  if (stats.isBlockDevice()) return "block device";
  if (stats.isCharacterDevice()) return "character device";
  return "special file";
};

const posix = (root, path) => relative(root, path).split(sep).join("/");

export const sha256File = (path) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

/**
 * Entries under `root`, ordered by code point so the result does not depend on
 * traversal order. `lstat` is used throughout, so a symbolic link is seen as a
 * link and refused rather than silently followed.
 */
export const walk = (root) => {
  const entries = [];
  const visit = (dir) => {
    const children = readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
    );
    for (const child of children) {
      const full = join(dir, child.name);
      const path = posix(root, full);
      const stats = lstatSync(full);
      if (stats.isDirectory()) {
        entries.push({ kind: "dir", path });
        visit(full);
      } else if (stats.isFile()) {
        entries.push({ kind: "file", path, sha256: sha256File(full) });
      } else {
        throw new UnhashableEntryError(path, kindOf(stats));
      }
    }
  };
  visit(root);
  return entries;
};

/** One digest over the kind, path and content digest of every entry. */
export const treeDigest = (entries) => {
  const hash = createHash("sha256");
  for (const entry of entries)
    hash.update(`${entry.kind}\t${entry.path}\t${entry.sha256 ?? ""}\n`);
  return hash.digest("hex");
};

/**
 * Describe one analysis input. The root itself is lstat-ed, so a symlinked
 * input is refused instead of resolving to somewhere else.
 */
export const describeInput = (path) => {
  const stats = lstatSync(path);
  if (stats.isFile())
    return {
      kind: "file",
      sha256: sha256File(path),
      digest_covers: "file contents",
    };
  if (!stats.isDirectory()) throw new UnhashableEntryError(path, kindOf(stats));
  const entries = walk(path);
  return {
    kind: "directory",
    sha256: treeDigest(entries),
    digest_covers: "contents, names and tree structure",
    entry_count: entries.length,
  };
};
