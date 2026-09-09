#!/usr/bin/env node
"use strict";

// Dựng 7 gói npm từ dist/ của GoReleaser vào dist/npm/.
//
//   node npm/build-packages.js                       dựng trong lab
//   node npm/build-packages.js --require-signature   bắt buộc có chữ ký cosign (CI)
//
// Chuỗi tin cậy — HUONG-DAN-PHAT-HANH-CLI.md §5.9.6. Bảng mã băm nhúng vào gói bọc KHÔNG
// được tự chứng nhận cho mình; nó phải suy ra được từ một file đã có chữ ký:
//
//   1. kiểm chữ ký cosign của checksums.txt (có ghim danh tính, như install.sh:103-112)
//   2. so từng file nén với checksums.txt
//   3. giải nén, băm CHÍNH binary vừa giải ra từ file nén đã kiểm
//   4. nhúng mã băm đó vào gói bọc
//
// Bước 3 cố ý KHÔNG băm binary rời trong dist/: binary rời không nằm trong
// checksums.txt, nên băm nó là tự cắt đứt chuỗi ngay tại mắt xích cuối.

const { spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const REPO = "hoanghuydev/hellopay";
const SCOPE = "@hellopay";
const CLI = "hellopay";

const root = path.resolve(__dirname, "..");
const dist = path.join(root, "dist");
const out = path.join(dist, "npm");

// GoReleaser gọi CPU Intel 64-bit là amd64 và Windows là windows. Node không bao giờ
// dùng hai chữ đó. Bảng này là chỗ duy nhất được biết cả hai cách gọi.
const GOOS_TO_NODE = { darwin: "darwin", linux: "linux", windows: "win32" };
const GOARCH_TO_NODE = { amd64: "x64", arm64: "arm64" };

function die(message) {
  process.stderr.write("Error: " + message + "\n");
  process.exit(1);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    die("could not read " + path.relative(root, file) + ": " + e.message);
  }
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function run(cmd, args) {
  return spawnSync(cmd, args, { encoding: "utf8", shell: false });
}

// chữ ký cosign của checksums.txt

function verifySignature(requireIt) {
  const sums = path.join(dist, "checksums.txt");
  const sig = sums + ".sig";
  const pem = sums + ".pem";

  if (!fs.existsSync(sig) || !fs.existsSync(pem)) {
    if (requireIt) {
      die(
        "checksums.txt has no cosign signature.\n" +
          "  Expected: dist/checksums.txt.sig and dist/checksums.txt.pem\n" +
          "  A local `goreleaser --skip=publish` build does not sign. Do not publish from it."
      );
    }
    process.stdout.write(
      "Note: no cosign signature in dist/ — building unsigned (lab only).\n" +
        "  Run with --require-signature in CI so this becomes an error.\n"
    );
    return false;
  }

  if (run("cosign", ["version"]).status !== 0) {
    die(
      "a cosign signature is present but cosign is not installed.\n" +
        "  Install cosign, or the trust chain in G3 cannot be checked."
    );
  }

  const r = run("cosign", [
    "verify-blob",
    "--certificate",
    pem,
    "--signature",
    sig,
    "--certificate-identity-regexp",
    "^https://github\\.com/" + REPO + "/\\.github/workflows/",
    "--certificate-oidc-issuer",
    "https://token.actions.githubusercontent.com",
    sums,
  ]);
  if (r.status !== 0) {
    die(
      "cosign could not verify checksums.txt.\n" +
        "  checksums.txt was not signed by the release workflow of " +
        REPO +
        ".\n" +
        "  Do not publish. " +
        String(r.stderr || "").trim()
    );
  }
  process.stdout.write("Signature verified (cosign, identity pinned to " + REPO + ").\n");
  return true;
}

// file nén khớp checksums.txt

function loadChecksums() {
  const file = path.join(dist, "checksums.txt");
  const table = {};
  const text = fs.readFileSync(file, "utf8");
  text.split("\n").forEach(function (line) {
    const m = line.match(/^([a-f0-9]{64})\s+(.+)$/);
    if (m) table[m[2].trim()] = m[1];
  });
  if (Object.keys(table).length === 0) die("checksums.txt is empty or unreadable.");
  return table;
}

function verifyArchive(archivePath, checksums) {
  const name = path.basename(archivePath);
  const expected = checksums[name];
  if (!expected) die("no checksum entry for " + name + " in checksums.txt.");
  const actual = sha256(archivePath);
  if (actual !== expected) {
    die(
      "checksum verification failed for " +
        name +
        ".\n  Expected: " +
        expected +
        "\n  Actual:   " +
        actual
    );
  }
}

// giải nén và băm binary lấy ra từ file nén đã kiểm

function extractBinary(archivePath, binName, tmpDir) {
  const target = path.join(tmpDir, binName);
  let r;
  if (archivePath.endsWith(".zip")) {
    r = spawnSync("unzip", ["-p", archivePath, binName], {
      shell: false,
      maxBuffer: 512 * 1024 * 1024,
    });
  } else {
    r = spawnSync("tar", ["-xzOf", archivePath, binName], {
      shell: false,
      maxBuffer: 512 * 1024 * 1024,
    });
  }
  if (r.status !== 0 || !r.stdout || r.stdout.length === 0) {
    die("could not extract " + binName + " from " + path.basename(archivePath) + ".");
  }
  fs.writeFileSync(target, r.stdout, { mode: 0o755 });
  return target;
}

// dựng

function main() {
  const requireSignature = process.argv.indexOf("--require-signature") !== -1;

  const metadata = readJson(path.join(dist, "metadata.json"));
  const version = metadata.version;
  if (!version || /^v/.test(version)) {
    die("dist/metadata.json has no usable version (got: " + JSON.stringify(version) + ").");
  }

  verifySignature(requireSignature);
  const checksums = loadChecksums();

  const artifacts = readJson(path.join(dist, "artifacts.json"));
  const binaries = artifacts.filter(function (a) {
    return a.type === "Binary";
  });
  const archives = artifacts.filter(function (a) {
    return a.type === "Archive";
  });
  if (binaries.length !== 6) {
    die("expected 6 binaries in dist/artifacts.json, found " + binaries.length + ".");
  }

  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "hellopay-npm-"));

  const template = fs.readFileSync(
    path.join(__dirname, "platform-template", "package.json"),
    "utf8"
  );
  const hashes = {};
  const optional = {};
  const seen = {};

  binaries.forEach(function (bin) {
    const nodeOs = GOOS_TO_NODE[bin.goos];
    const nodeCpu = GOARCH_TO_NODE[bin.goarch];
    if (!nodeOs || !nodeCpu) die("no Node name for " + bin.goos + "/" + bin.goarch + ".");
    const key = nodeOs + "-" + nodeCpu;
    if (seen[key]) die("two binaries map to the same platform: " + key + ".");
    seen[key] = true;

    const archive = archives.filter(function (a) {
      return a.goos === bin.goos && a.goarch === bin.goarch;
    })[0];
    if (!archive) die("no archive for " + key + " in dist/artifacts.json.");

    const archivePath = path.join(root, archive.path);
    verifyArchive(archivePath, checksums);

    const binName = bin.goos === "windows" ? CLI + ".exe" : CLI;
    const extracted = extractBinary(archivePath, binName, tmpDir);
    const hash = sha256(extracted);

    // Binary rời trong dist/ phải khớp binary trong file nén. Lệch nghĩa là dist/ còn
    // sót đồ của lần build trước — đúng thứ một lần chạy lại thiếu --clean sẽ tạo ra.
    const loose = path.join(root, bin.path);
    if (fs.existsSync(loose) && sha256(loose) !== hash) {
      die(
        "dist/" +
          path.relative(dist, loose) +
          " does not match the binary inside " +
          path.basename(archivePath) +
          ".\n  dist/ is stale. Rebuild with `goreleaser release --clean`."
      );
    }

    const pkgName = SCOPE + "/cli-" + key;
    const pkgDir = path.join(out, "cli-" + key);
    fs.mkdirSync(path.join(pkgDir, "bin"), { recursive: true });
    fs.copyFileSync(extracted, path.join(pkgDir, "bin", binName));
    fs.chmodSync(path.join(pkgDir, "bin", binName), 0o755);

    const manifest = template
      .replace("@hellopay/cli-PLATFORM", pkgName)
      .replace('"version": "0.0.0"', '"version": "' + version + '"')
      .replace("OS/CPU", nodeOs + "/" + nodeCpu)
      .replace('"os": ["OS"]', '"os": ["' + nodeOs + '"]')
      .replace('"cpu": ["CPU"]', '"cpu": ["' + nodeCpu + '"]');
    JSON.parse(manifest); // hỏng khuôn thì phải chết ở đây, không phải lúc publish
    fs.writeFileSync(path.join(pkgDir, "package.json"), manifest);

    hashes[key] = hash;
    optional[pkgName] = version; // số phiên bản chính xác, trùng khít gói bọc
    process.stdout.write("  " + pkgName + "  " + hash.slice(0, 16) + "…\n");
  });

  if (Object.keys(hashes).length !== 6) die("expected 6 platform packages.");

  // Gói bọc dựng cuối, sau khi đã có đủ 6 mã băm.
  const wrapper = readJson(path.join(__dirname, "package.json"));
  wrapper.version = version;
  wrapper.optionalDependencies = optional;
  wrapper.hellopay = { binaryHashes: hashes };
  if (wrapper.scripts) die("the wrapper package must not declare any scripts.");

  const wrapperDir = path.join(out, CLI);
  fs.mkdirSync(path.join(wrapperDir, "bin"), { recursive: true });
  fs.writeFileSync(
    path.join(wrapperDir, "package.json"),
    JSON.stringify(wrapper, null, 2) + "\n"
  );
  fs.copyFileSync(path.join(__dirname, "bin", CLI + ".js"), path.join(wrapperDir, "bin", CLI + ".js"));
  fs.chmodSync(path.join(wrapperDir, "bin", CLI + ".js"), 0o755);
  fs.copyFileSync(path.join(__dirname, "README.md"), path.join(wrapperDir, "README.md"));
  fs.copyFileSync(path.join(root, "LICENSE"), path.join(wrapperDir, "LICENSE"));

  fs.rmSync(tmpDir, { recursive: true, force: true });
  process.stdout.write("  " + CLI + "  (wrapper, 6 hashes embedded)\n");
  process.stdout.write("Built 7 packages for " + version + " in dist/npm/.\n");
}

main()
