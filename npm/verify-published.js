#!/usr/bin/env node
"use strict";

// Bước 4 của trình tự phát hành (HUONG-DAN-PHAT-HANH-CLI.md §5.9.6) — CỬA QUAN TRỌNG NHẤT.
//
// Tải LẠI 6 gói nền tảng TỪ KHO GÓI, băm lại binary bên trong, so với bảng mã băm
// trong gói bọc CHƯA publish. Bắt được hai thứ mà không bước nào khác bắt được:
// binary bị đổi ở phía kho gói, và sai sót trong chính lúc build/tải lên.
//
//   node npm/verify-published.js [--registry <url>]
//
// Cố ý KHÔNG so với dist/ trên máy: dist/ chính là thứ vừa tải lên, nên so nó với
// chính nó thì không chứng minh được gì. Nguồn duy nhất có giá trị ở bước này là
// thứ kho gói trả về cho một người dùng thật.

const { spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const CLI = "hellopay";
const root = path.resolve(__dirname, "..");
const wrapper = JSON.parse(
  fs.readFileSync(path.join(root, "dist", "npm", CLI, "package.json"), "utf8")
);

const i = process.argv.indexOf("--registry");
const registry = i !== -1 ? process.argv[i + 1] : null;

const version = wrapper.version;
const hashes = (wrapper.hellopay && wrapper.hellopay.binaryHashes) || {};
const names = Object.keys(wrapper.optionalDependencies || {});

if (names.length !== 6) {
  process.stderr.write("Error: wrapper does not declare 6 platform packages.\n");
  process.exit(1);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "hellopay-verify-"));
const problems = [];

names.forEach(function (name) {
  const key = name.replace(/^@hellopay\/cli-/, "");
  const binName = key.indexOf("win32") === 0 ? CLI + ".exe" : CLI;

  const args = ["pack", name + "@" + version, "--pack-destination", tmp, "--silent"];
  if (registry) args.push("--registry", registry);
  const packed = spawnSync("npm", args, { encoding: "utf8", shell: false, cwd: tmp });
  if (packed.status !== 0) {
    problems.push(name + ": could not download from the registry — " + String(packed.stderr).trim());
    return;
  }

  const tgz = fs
    .readdirSync(tmp)
    .filter(function (f) {
      return f.indexOf(key) !== -1 && f.endsWith(".tgz");
    })
    .pop();
  if (!tgz) {
    problems.push(name + ": npm pack produced no tarball");
    return;
  }

  const got = spawnSync("tar", ["-xzOf", path.join(tmp, tgz), "package/bin/" + binName], {
    shell: false,
    maxBuffer: 512 * 1024 * 1024,
  });
  if (got.status !== 0 || !got.stdout || got.stdout.length === 0) {
    problems.push(name + ": the published tarball has no bin/" + binName);
    return;
  }

  const actual = crypto.createHash("sha256").update(got.stdout).digest("hex");
  const expected = hashes[key];
  if (actual !== expected) {
    problems.push(
      name +
        ": the binary on the registry does not match the wrapper's table\n" +
        "    Expected: " +
        expected +
        "\n    Actual:   " +
        actual
    );
    return;
  }
  process.stdout.write("  " + name + "@" + version + "  " + actual.slice(0, 16) + "… ok\n");
});

fs.rmSync(tmp, { recursive: true, force: true });

if (problems.length > 0) {
  process.stderr.write("Error: do NOT publish the wrapper.\n");
  problems.forEach(function (p) {
    process.stderr.write("  " + p + "\n");
  });
  process.exit(1);
}

process.stdout.write("All 6 published binaries match the wrapper's checksum table.\n");
