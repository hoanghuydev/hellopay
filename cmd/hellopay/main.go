// hellopay là CLI giả, dùng để tập phát hành (Homebrew, Scoop, curl|bash, GitHub Releases).
// Nó cố ý bắt chước bề mặt của sepay-cli thật: có `version --json`, có subcommand,
// và nhận version/commit/date qua -ldflags lúc build.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
)

// Ba biến này để trống trong source và được nhồi vào lúc build bằng:
//
//	go build -ldflags "-X main.version=v0.1.0 -X main.commit=abc123 -X main.date=..."
//
// Nếu build tay mà không truyền gì thì nó hiện "dev" — đó là cách nhanh nhất để
// biết một binary đến từ bản phát hành chính thức hay từ máy ai đó.
var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

const usage = `hellopay — CLI giả để tập phát hành

Cách dùng:
  hellopay <lệnh> [tham số]

Lệnh:
  hello [tên]     In lời chào
  version         In thông tin phiên bản (thêm --json để máy đọc)
  help            In trợ giúp này

Ví dụ:
  hellopay hello SePay
  hellopay version --json
`

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Print(usage)
		return
	}

	switch args[0] {
	case "hello":
		name := "world"
		if len(args) > 1 {
			name = strings.Join(args[1:], " ")
		}
		fmt.Printf("Xin chào, %s! (hellopay %s)\n", name, version)

	case "version", "--version", "-v":
		if len(args) > 1 && args[1] == "--json" {
			out, _ := json.MarshalIndent(map[string]string{
				"version":  version,
				"commit":   commit,
				"date":     date,
				"go":       runtime.Version(),
				"platform": runtime.GOOS + "/" + runtime.GOARCH,
			}, "", "  ")
			fmt.Println(string(out))
			return
		}
		fmt.Printf("hellopay %s (%s, %s) %s/%s\n",
			version, commit, date, runtime.GOOS, runtime.GOARCH)

	case "help", "--help", "-h":
		fmt.Print(usage)

	default:
		fmt.Fprintf(os.Stderr, "hellopay: không biết lệnh %q\n\n", args[0])
		fmt.Fprint(os.Stderr, usage)
		os.Exit(1)
	}
}
