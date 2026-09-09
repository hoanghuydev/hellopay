#!/usr/bin/env node
"use strict";

// Tự kiểm dist/npm/ trước khi đóng gói hay publish. Tương đương `goreleaser check`
// cho kênh npm: chạy được ở lab, ở CI, và ở bước 1 của trình tự phát hành (mục 8).
//
//   node npm/verify.js
//
// Nguyên tắc: mọi thứ ở đây phải hỏng TO. Một gói bọc thiếu mã băm, thiếu một nền tảng,
// hay lệch số phiên bản với binary là thứ chỉ lộ ra ở máy khách hàng nếu không chặn ở đây.

const { spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const CLI = "hellopay";
const SCOPE = "@hellopay";
const EXPECTED = [
  "darwin-arm64",
  "darwin-x64",
  "linux-arm64",
  "linux-x64",
  "win32-arm64",
  "win32-x64",
];

const root = path.resolve(__dirname, "..");
const out = path.join(root, "dist", "npm");

const problems = [];
function check(ok, message) {
  if (!ok) problems.push(message);
  return ok;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

if (!fs.existsSync(out)) {
  process.stderr.write("Error: dist/npm/ does not exist.\n  Run: node npm/build-packages.js\n");
  process.exit(1);
}

const wrapperDir = path.join(out, CLI);
const wrapper = readJson(path.join(wrapperDir, "package.json"));
const version = wrapper.version;

check(!!version && version !== "0.0.0", "wrapper version is still 0.0.0 — build did not stamp it");
check(!wrapper.scripts, "wrapper declares scripts — no script may run at install time");
check(!!wrapper.repository && !!wrapper.repository.url, "wrapper has no repository (needed for provenance)");
check(
  Array.isArray(wrapper.files) && wrapper.files.length === 1 && wrapper.files[0] === "bin",
  "wrapper files must be exactly [\"bin\"]"
);

const hashes = (wrapper.hellopay && wrapper.hellopay.binaryHashes) || {};
const optional = wrapper.optionalDependencies || {};

// Đủ 6 tổ hợp, không thiếu, không thừa, không trùng.
EXPECTED.forEach(function (key) {
  const pkgName = SCOPE + "/cli-" + key;
  const dir = path.join(out, "cli-" + key);

  if (!check(fs.existsSync(dir), "missing platform package: " + pkgName)) return;

  const manifest = readJson(path.join(dir, "package.json"));
  const parts = key.split("-");
  const binName = parts[0] === "win32" ? CLI + ".exe" : CLI;
  const binPath = path.join(dir, "bin", binName);

  check(manifest.name === pkgName, pkgName + ": name is " + manifest.name);
  check(manifest.version === version, pkgName + ": version " + manifest.version + " != wrapper " + version);
  check(!manifest.scripts, pkgName + ": declares scripts");
  check(!manifest.bin, pkgName + ": declares bin — only the wrapper may");
  check(String(manifest.os) === parts[0], pkgName + ": os is " + JSON.stringify(manifest.os));
  check(String(manifest.cpu) === parts[1], pkgName + ": cpu is " + JSON.stringify(manifest.cpu));
  check(optional[pkgName] === version, pkgName + ": not pinned to " + version + " in optionalDependencies");

  if (!check(fs.existsSync(binPath), pkgName + ": missing bin/" + binName)) return;

  const stat = fs.statSync(binPath);
  check(stat.size > 0, pkgName + ": binary is empty");
  if (parts[0] !== "win32") {
    check((stat.mode & 0o111) !== 0, pkgName + ": binary is not executable");
  }
  check(
    /^[a-f0-9]{64}$/.test(hashes[key] || ""),
    pkgName + ": no checksum recorded in the wrapper"
  );
  check(
    hashes[key] === sha256(binPath),
    pkgName + ": recorded checksum does not match the shipped binary"
  );
});

Object.keys(hashes).forEach(function (key) {
  check(EXPECTED.indexOf(key) !== -1, "unexpected checksum entry: " + key);
});
Object.keys(optional).forEach(function (name) {
  check(
    EXPECTED.indexOf(name.replace(SCOPE + "/cli-", "")) !== -1,
    "unexpected optional dependency: " + name
  );
});

// Kiểm chéo bắt buộc (mục 5): số phiên bản của gói npm phải khớp số phiên bản NHỒI
// TRONG binary. Đây là bước duy nhất chứng minh được cả hai chiều — gói đúng bản, và
// binary trong gói đúng là binary của bản đó, không phải bản cũ còn sót trong dist/.
const nativeKey = process.platform + "-" + process.arch;
if (EXPECTED.indexOf(nativeKey) !== -1) {
  const nativeBin = path.join(out, "cli-" + nativeKey, "bin", CLI);
  if (fs.existsSync(nativeBin)) {
    const r = spawnSync(nativeBin, ["version", "--json"], { encoding: "utf8", shell: false });
    if (r.status !== 0) {
      problems.push("could not run the " + nativeKey + " binary: " + String(r.stderr).trim());
    } else {
      let reported;
      try {
        reported = JSON.parse(r.stdout).version;
      } catch (e) {
        problems.push("`" + CLI + " version --json` did not return JSON");
      }
      check(
        reported === version,
        "binary reports version " + reported + " but the package says " + version
      );
    }
  }
} else {
  process.stdout.write("Note: " + nativeKey + " is not a target — skipping the run-the-binary check.\n");
}

if (problems.length > 0) {
  process.stderr.write("Error: dist/npm/ is not fit to publish.\n");
  problems.forEach(function (p) {
    process.stderr.write("  " + p + "\n");
  });
  process.exit(1);
}

process.stdout.write("verify: 7 packages, 6 platforms, all checksums match, version " + version + ".\n");
