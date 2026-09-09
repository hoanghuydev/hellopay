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

  // --prefer-online: không có nó thì npm phục vụ được từ bộ nhớ đệm cục bộ, và bước
  // này sẽ đang so gói vừa đóng với chính nó thay vì với thứ kho gói trả về.
  const args = [
    "pack", name + "@" + version, "--pack-destination", tmp, "--silent", "--prefer-online",
  ];
  if (registry) args.push("--registry", registry);

  // Cửa sổ thử lại phải tính bằng PHÚT, không phải giây. Kho gói nhận gói xong (HTTP
  // 200 cho publish) nhưng trang mô tả gói mất một lúc mới đọc được ở mọi nơi; đo thật
  // hai lần trên registry.npmjs.org đều ra 3-5 phút, và không đều giữa các gói — một
  // lần chạy có 3/6 gói kịp còn 3 gói thì chưa.
  //
  // Thất bại giả ở đây là thất bại đắt nhất của pipeline: số phiên bản bị đốt và phải
  // tăng số cho cả 7 gói. Chờ thêm vài phút rẻ hơn nhiều. Ngược lại, KHÔNG được bỏ hẳn
  // việc kiểm để cho nhanh: đây là cửa duy nhất nhìn thấy thứ kho gói thật sự trả về.
  const MAX_WAIT_MS = 10 * 60 * 1000;
  const deadline = Date.now() + MAX_WAIT_MS;
  let packed;
  let waited = 0;
  for (let attempt = 1; ; attempt++) {
    packed = spawnSync("npm", args, { encoding: "utf8", shell: false, cwd: tmp });
    if (packed.status === 0) break;
    if (Date.now() >= deadline) break;
    const backoff = Math.min(15, attempt * 2);
    waited += backoff;
    if (attempt === 1 || attempt % 5 === 0) {
      process.stdout.write(
        "  " + name + ": chưa đọc được từ kho gói, đã chờ " + waited + "s (tối đa 600s)\n"
      );
    }
    spawnSync("sleep", [String(backoff)], { shell: false });
  }
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
