// Copy one analysis input into an immutable snapshot, then digest it.
//
// Why a snapshot: the analysis and the provenance record are two separate
// container runs. If both read the caller's live input directory, the bytes
// could change in between, and the manifest would attest a digest that is not
// what was analysed. The snapshot is written once here, into a volume that
// every later run mounts READ-ONLY, so the digest recorded in the manifest and
// the bytes the analysis read are the same bytes.
//
// What this does not claim: the caller's input could still change while this
// copy is running. The manifest therefore attests the snapshot - what was
// actually analysed - and never claims the host path was stable.
//
// Symbolic links and other special files are refused rather than copied. A
// symlink in the source would otherwise either escape the declared input or be
// stored as a dangling path with no content to attest.

import { copyFileSync, lstatSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { describeInput, UnhashableEntryError } from "./rea-digest.mjs";

const SOURCE = process.env.REA_SNAPSHOT_SOURCE ?? "/src";
const TARGET = process.env.REA_SNAPSHOT_TARGET ?? "/snapshot/input";

const kindOf = (stats) => {
  if (stats.isSymbolicLink()) return "symbolic link";
  if (stats.isFIFO()) return "FIFO";
  if (stats.isSocket()) return "socket";
  if (stats.isBlockDevice()) return "block device";
  if (stats.isCharacterDevice()) return "character device";
  return "special file";
};

const copyTree = (from, to) => {
  mkdirSync(to, { recursive: true });
  for (const child of readdirSync(from, { withFileTypes: true })) {
    const source = join(from, child.name);
    const target = join(to, child.name);
    const stats = lstatSync(source);
    if (stats.isDirectory()) copyTree(source, target);
    else if (stats.isFile()) copyFileSync(source, target);
    else throw new UnhashableEntryError(source, kindOf(stats));
  }
};

try {
  const stats = lstatSync(SOURCE);
  if (stats.isFile()) copyFileSync(SOURCE, TARGET);
  else if (stats.isDirectory()) copyTree(SOURCE, TARGET);
  else throw new UnhashableEntryError(SOURCE, kindOf(stats));

  // Digest the snapshot, not the source, so the value describes the bytes that
  // later runs will read.
  process.stdout.write(`${describeInput(TARGET).sha256}\n`);
} catch (cause) {
  if (cause instanceof UnhashableEntryError) {
    process.stderr.write(`rea-snapshot: ${cause.message}\n`);
    process.exit(5);
  }
  throw cause;
}
