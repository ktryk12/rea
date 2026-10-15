// Verify that the source files inside an analysis runtime image are the files
// recorded in a declared Git commit.
//
// Why this exists: an image label and a file baked into the image both only
// state a commit. They are declarations by whoever built the image, so they
// cannot by themselves establish that the image was built from that commit's
// sources. This compares content, file by file:
//
//   expected  sha256 of every file `git archive <commit>` produces
//   actual    sha256 of every source file present in the image
//
// `git archive` is used rather than raw blobs because it applies the
// repository's `.gitattributes` text conversion, so it reproduces exactly what
// a checkout of that commit writes to disk - including `*.cmd text eol=crlf`,
// which a raw blob comparison would report as a false mismatch.
//
// Two modes:
//   --emit <root>                       walk a tree, print a JSON manifest
//   --compare <archiveDir> <manifest>   compare, exit non-zero on any difference
//
// `--emit` is what runs inside the image; `--compare` runs wherever the Git
// repository is available.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

/** Paths the image deliberately does not contain, or that it generates. */
const GENERATED_IN_IMAGE = [
  "node_modules",
  "dist",
  ".rea-source-sha",
  ".rea-source-dirty",
];

const posix = (root, path) => relative(root, path).split(sep).join("/");

const excluded = (path, entries) =>
  entries.some((entry) => path === entry || path.startsWith(`${entry}/`));

/** sha256 of every regular file under `root`, keyed by POSIX relative path. */
const manifest = (root, skip) => {
  const files = {};
  const visit = (dir) => {
    for (const child of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, child.name);
      const path = posix(root, full);
      if (excluded(path, skip)) continue;
      if (child.isDirectory()) visit(full);
      else if (child.isFile())
        files[path] = createHash("sha256")
          .update(readFileSync(full))
          .digest("hex");
    }
  };
  visit(root);
  return files;
};

/** Entries of a .containerignore, ignoring comments and blank lines. */
const ignoreEntries = (archiveDir) => {
  try {
    return readFileSync(join(archiveDir, ".containerignore"), "utf8")
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith("#"));
  } catch {
    return [];
  }
};

const compare = (archiveDirArg, imageManifestPath) => {
  const archiveDir = archiveDirArg;
  statSync(archiveDir);
  const imageFiles = JSON.parse(readFileSync(imageManifestPath, "utf8"));

  // The commit's own .containerignore decides which of its files the image is
  // expected to hold, so the rule travels with the commit rather than with
  // whoever runs this check.
  const skip = [...ignoreEntries(archiveDir), ...GENERATED_IN_IMAGE];
  const expected = manifest(archiveDir, skip);

  const missing = [];
  const modified = [];
  for (const [path, digest] of Object.entries(expected)) {
    const actual = imageFiles[path];
    if (actual === undefined) missing.push(path);
    else if (actual !== digest)
      modified.push({ path, expected: digest, actual });
  }
  const extra = Object.keys(imageFiles).filter(
    (path) => expected[path] === undefined,
  );

  const report = {
    verdict:
      missing.length === 0 && modified.length === 0 && extra.length === 0
        ? "SOURCE_BINDING_VERIFIED"
        : "SOURCE_BINDING_FAILED",
    files_expected: Object.keys(expected).length,
    files_in_image: Object.keys(imageFiles).length,
    ignored_by_commit: skip,
    missing_from_image: missing.sort(),
    modified_in_image: modified.sort((a, b) => (a.path < b.path ? -1 : 1)),
    not_in_commit: extra.sort(),
  };

  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  process.exitCode = report.verdict === "SOURCE_BINDING_VERIFIED" ? 0 : 1;
};

const [mode, first, second] = process.argv.slice(2);

if (mode === "--emit") {
  const root = first ?? "/opt/rea";
  // NEVER follow a large stdout write with process.exit(). Writes to a pipe
  // are asynchronous, so exiting immediately discards whatever has not been
  // flushed: this manifest is well over the 64 KiB pipe buffer and was
  // silently truncated to exactly 65536 bytes while still reporting exit 0.
  // Returning normally lets node drain stdout, and every path here sets
  // process.exitCode instead of calling process.exit().
  process.stdout.write(
    `${JSON.stringify(manifest(root, GENERATED_IN_IMAGE), null, 0)}\n`,
  );
} else if (
  mode === "--compare" &&
  first !== undefined &&
  second !== undefined
) {
  compare(first, second);
} else {
  process.stderr.write(
    "usage: rea-verify-source.mjs --emit <root>\n" +
      "       rea-verify-source.mjs --compare <archiveDir> <imageManifest.json>\n",
  );
  process.exitCode = 2;
}
