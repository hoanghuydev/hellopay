#!/usr/bin/env node
"use strict";

// Người gác cổng của kênh npm.
//
// Ba việc, đúng thứ tự: tìm gói nền tảng khớp máy → so mã băm của binary với bảng
// nhúng trong package.json của chính gói này → mới chạy binary.
//
// CỐ TÌNH khác esbuild ở hai chỗ. Đừng "sửa cho giống bản gốc":
//
//   1. esbuild so mã băm trong install.js — một script tự chạy lúc cài. Gói này KHÔNG
//      có script nào chạy lúc cài, nên việc so mã băm dời sang lúc chạy, tức là ở đây.
//      Lý do: khách cài bằng --ignore-scripts thì cờ đó phải THẬT SỰ bảo vệ họ.
//
//   2. esbuild có biến ESBUILD_BINARY_PATH để trỏ sang binary khác. Ở đây KHÔNG có, và
//      không được thêm: một biến như vậy vô hiệu hoá toàn bộ chuỗi mã băm bằng đúng một
//      dòng. Cùng lý do install.sh từ chối biến BASE_URL
//      (HUONG-DAN-PHAT-HANH-CLI.md §5.3.2).
//
// Không dùng thư viện ngoài nào. Mỗi thư viện thêm vào là một mục phải theo dõi lỗ hổng
// (PCI-DSS 6.3.2) và một đường tấn công nữa.

const { spawn } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const pkg = require("../package.json");

const SUPPORTED = [
  "darwin-x64",
  "darwin-arm64",
  "linux-x64",
  "linux-arm64",
  "win32-x64",
  "win32-arm64",
];

const HOMEPAGE = "https://github.com/hoanghuydev/hellopay";

// Phong cách thông báo: HUONG-DAN-PHAT-HANH-CLI.md §5.3.2. Tiếng Anh, không màu, chữ ngay sau "Error:"
// viết thường, dòng chi tiết thụt 2 dấu cách, tất cả ra luồng lỗi.
function fail(message) {
  const details = Array.prototype.slice.call(arguments, 1);
  process.stderr.write("Error: " + message + "\n");
  for (let i = 0; i < details.length; i++) {
    process.stderr.write("  " + details[i] + "\n");
  }
  process.exit(1);
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

// bộ nhớ đệm kết quả so mã băm
// Binary 1,9 MB của lab chỉ tốn ~20 ms, nhưng sepay-cli thật sẽ là 30-50 MB (~400 ms)
// và một CLI hay bị gọi trong vòng lặp shell. Dựng ở đây để lab kiểm được đúng cơ chế
// bản thật sẽ dùng.
//
// KHÔNG dùng os.tmpdir(): trên máy nhiều người dùng thư mục đó ai cũng ghi được, nên
// một file đệm dựng sẵn biến "đã kiểm" thành thứ kẻ tấn công tự khai. Đệm nằm trong
// thư mục riêng của người dùng, VÀ chỉ dùng khi binary cũng thuộc về chính người dùng
// đó — cài toàn cục (binary của root) thì luôn băm lại, vì khi ấy đệm nằm ở phía yếu
// hơn binary. Windows không có khái niệm uid dùng được ở đây nên bỏ đệm luôn.

function cacheFile() {
  const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
  return path.join(base, "hellopay", "verified.json");
}

function cacheKey(st, expected) {
  // ctime là trường bắt buộc, không phải trường thừa: không có lời gọi hệ thống nào
  // đặt được ctime, nên mọi lần ghi vào file đều đẩy nó lên — kể cả khi binary bị ghi
  // đè tại chỗ với đúng kích thước rồi `touch -r` trả mtime về như cũ. Bỏ ctime ra là
  // mở đúng đường đó, và đệm sẽ khẳng định một binary đã bị tráo là đã kiểm.
  return [st.dev, st.ino, st.size, Math.floor(st.mtimeMs), Math.floor(st.ctimeMs), expected].join(":");
}

function ownedByUs(st) {
  return typeof process.getuid === "function" && st.uid === process.getuid();
}

function alreadyVerified(binPath, expected) {
  if (process.platform === "win32") return false;
  try {
    const st = fs.statSync(binPath);
    if (!ownedByUs(st)) return false;
    const file = cacheFile();
    const meta = fs.lstatSync(file);
    if (!meta.isFile() || !ownedByUs(meta)) return false;
    const data = JSON.parse(fs.readFileSync(file, "utf8"));
    return data[binPath] === cacheKey(st, expected);
  } catch (e) {
    return false;
  }
}

// `st` PHẢI là trạng thái file đọc TRƯỚC khi băm, không phải đọc lại ở đây. Đọc lại
// sau khi băm là ghi cặp (trạng thái MỚI, mã băm CŨ): ai tráo file trong khoảng giữa
// hai thao tác đó sẽ được đệm cấp cho một giấy chứng nhận vĩnh viễn, và mọi lần chạy
// sau đều bỏ qua việc băm. Một cuộc đua chớp nhoáng biến thành một lỗ hổng thường trực.
function rememberVerified(binPath, expected, st) {
  if (process.platform === "win32") return;
  try {
    if (!ownedByUs(st)) return;
    const file = cacheFile();
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    let data = {};
    try {
      const meta = fs.lstatSync(file);
      if (meta.isFile() && ownedByUs(meta)) {
        data = JSON.parse(fs.readFileSync(file, "utf8"));
      }
    } catch (e) {
      data = {};
    }
    data[binPath] = cacheKey(st, expected);
    // Ghi ra file tạm rồi đổi tên. Ghi thẳng thì `writeFileSync` đi theo liên kết mềm,
    // nên một liên kết mềm đặt sẵn ở chỗ file đệm sẽ bị ghi đè mất nội dung; và `mode`
    // chỉ có tác dụng lúc TẠO file, nên một file cũ ai cũng đọc được sẽ giữ nguyên
    // quyền cũ. Đổi tên thì thay hẳn inode, cả hai vấn đề biến mất.
    const temp = file + "." + process.pid + ".tmp";
    fs.writeFileSync(temp, JSON.stringify(data), { mode: 0o600 });
    fs.renameSync(temp, file);
  } catch (e) {
    // Đệm hỏng chỉ làm lệnh chậm hơn. Không bao giờ được làm lệnh thất bại.
  }
}

// chạy

function main() {
  const key = process.platform + "-" + process.arch;

  if (SUPPORTED.indexOf(key) === -1) {
    fail(
      "unsupported platform: " + process.platform + " " + process.arch + ".",
      "Supported: darwin/x64, darwin/arm64, linux/x64, linux/arm64, win32/x64, win32/arm64.",
      "Install with the shell script instead: " + HOMEPAGE
    );
  }

  const platformPkg = "@hellopay/cli-" + key;
  const binName = process.platform === "win32" ? "hellopay.exe" : "hellopay";

  let pkgDir;
  try {
    pkgDir = path.dirname(require.resolve(platformPkg + "/package.json"));
  } catch (e) {
    // Hai nguyên nhân, không phải một. Thông báo chỉ nêu nguyên nhân thứ nhất sẽ đẩy
    // người dùng đi cài lại mãi không xong khi thật ra gói không có trên kho gói —
    // đúng chuyện đã xảy ra với chính bản 0.1.3 của lab.
    fail(
      "the hellopay binary for " + process.platform + "/" + process.arch + " is not installed.",
      "Expected package: " + platformPkg + "@" + pkg.version,
      "Usually optional dependencies were skipped (npm install --no-optional or",
      "--omit=optional). Reinstall with them enabled.",
      "If they were not skipped, that package is not on the registry. Check with:",
      "  npm view " + platformPkg + "@" + pkg.version
    );
  }

  // Giải hết liên kết mềm TRƯỚC, rồi mới kiểm đường dẫn có nằm đúng trong gói không.
  // Kiểm trước khi giải là kiểm vô nghĩa: một liên kết mềm tên bin/hellopay trỏ ra
  // /tmp/evil vẫn "nằm trong gói" nếu chỉ so chuỗi.
  let realDir;
  let binPath;
  const expectedPath = function () {
    return path.join(realDir, "bin", binName);
  };
  try {
    realDir = fs.realpathSync(pkgDir);
    binPath = fs.realpathSync(expectedPath());
  } catch (e) {
    fail(
      "the hellopay binary is missing from " + platformPkg + ".",
      "Expected file: bin/" + binName,
      "Reinstall the package."
    );
  }
  if (binPath !== expectedPath()) {
    fail(
      "the hellopay binary resolves outside its package.",
      "Expected: " + expectedPath(),
      "Actual:   " + binPath,
      "Do not run it. Reinstall the package."
    );
  }

  // Gói nền tảng còn sót lại từ bản trước là chuyện cài đặt bình thường, không phải
  // dấu hiệu bị tấn công. Không bắt ở đây thì nó rơi xuống bước so mã băm và người
  // dùng nhận đúng câu "do not run the binary" — đọc như một sự cố an ninh.
  try {
    const platformVersion = require(path.join(realDir, "package.json")).version;
    if (platformVersion !== pkg.version) {
      fail(
        "the installed " + platformPkg + " is version " + platformVersion + ", not " + pkg.version + ".",
        "This happens when a previous version is left behind by an upgrade.",
        "Remove node_modules and the lockfile entry, then reinstall."
      );
    }
  } catch (e) {
    // đọc không được thì để bước so mã băm bên dưới xử lý
  }

  // Không có bảng mã băm thì DỪNG, không phải chạy tạm. Một gói bọc dựng thiếu bảng
  // này là một gói bọc không kiểm được gì — nó phải hỏng to, không được hỏng lặng.
  const table = (pkg.hellopay && pkg.hellopay.binaryHashes) || {};
  const expected = table[key];
  if (typeof expected !== "string" || !/^[a-f0-9]{64}$/.test(expected)) {
    fail(
      "no checksum is recorded for " + key + " in this package.",
      "This package was not built by the release pipeline.",
      "Do not run the binary. Reinstall from a published version."
    );
  }

  if (!alreadyVerified(binPath, expected)) {
    let stBefore = null;
    try {
      stBefore = fs.statSync(binPath);
    } catch (e) {
      stBefore = null; // không đọc được thì thôi, chỉ mất phần đệm
    }
    const actual = sha256(binPath);
    if (actual !== expected) {
      fail(
        "checksum verification failed for the hellopay binary.",
        "Expected: " + expected,
        "Actual:   " + actual,
        "Reinstall the package. If this persists, do not run the binary."
      );
    }
    if (stBefore) rememberVerified(binPath, expected, stBefore);
  }

  const env = Object.assign({}, process.env);
  delete env.NODE_OPTIONS; // NODE_OPTIONS=--require=/tmp/evil.js nhét được mã lạ vào
  delete env.NODE_PATH; // tiến trình con nếu nó cũng là Node.

  const child = spawn(binPath, process.argv.slice(2), {
    stdio: "inherit", // dùng chung màn hình + bàn phím với người dùng
    shell: false, // tường minh: bật shell thì --ref "a & calc" thành hai câu lệnh
    env: env,
    windowsHide: true,
  });

  // Trên Windows, `child.kill(sig)` là TerminateProcess chứ không phải một tín hiệu:
  // binary không chạy được phần dọn dẹp của nó. Bấm Ctrl-C thật trong console thì
  // Windows gửi thẳng tới cả nhóm tiến trình nên vẫn dọn sạch — chỉ có đường gọi
  // child.kill/taskkill từ chương trình khác là không. Ca 10 (§5.9.5) đo đúng đường
  // Ctrl-C thật; đường kia chưa có ai đo.
  const forward = function (sig) {
    return function () {
      try {
        child.kill(sig);
      } catch (e) {
        // con đã chết rồi
      }
    };
  };
  process.on("SIGINT", forward("SIGINT"));
  process.on("SIGTERM", forward("SIGTERM"));

  child.on("error", function (err) {
    fail(
      "could not start the hellopay binary.",
      err.code === "EACCES"
        ? "The file is not executable. Reinstall the package."
        : String(err.message),
      "Path: " + binPath
    );
  });

  // Trả đúng mã thoát. Không làm đúng chỗ này nghĩa là CI của khách hàng báo thành
  // công trong khi lệnh thất bại — với CLI thanh toán thì đây là loại lỗi tệ nhất.
  child.on("exit", function (code, signal) {
    if (signal) {
      const num = os.constants.signals[signal];
      process.exit(num ? 128 + num : 1);
    }
    process.exit(code === null ? 1 : code);
  });
}

// Không để Node in nguyên đoạn lỗi kỹ thuật ra mặt khách hàng
// (HUONG-DAN-PHAT-HANH-CLI.md §5.3.2).
try {
  main();
} catch (e) {
  fail("hellopay could not start.", String((e && e.message) || e), "Reinstall the package.");
}
