// hellopay là CLI giả, dùng để tập phát hành (Homebrew, Scoop, curl|bash, GitHub Releases).
// Nó cố ý bắt chước bề mặt của sepay-cli thật: có `version --json`, có subcommand,
// và nhận version/commit/date qua -ldflags lúc build.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"
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

const usage = `hellopay — a fake CLI for practising releases

Usage:
  hellopay <command> [arguments]

Commands:
  hello [name]    Print a greeting
  echo [args...]  Print each argument on its own line, verbatim
  listen          Run until interrupted (Ctrl-C), then shut down cleanly
  version         Show version information (add --json for machine output)
  help            Show this help

Examples:
  hellopay hello SePay
  hellopay version --json
  hellopay listen
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
		fmt.Printf("Hello, %s! (hellopay %s)\n", name, version)

	// echo và listen tồn tại để test kênh npm, không phải để dùng thật
	// (HUONG-DAN-PHAT-HANH-CLI.md §5.9.5).
	// echo   in từng đối số một dòng, nên so được chính xác cả khi đối số chứa dấu
	//        cách hay ký tự mà shell hay nuốt: & | ^ " '
	// listen chạy tới khi bị ngắt, nên bấm được Ctrl-C để thử việc chuyển tiếp tín
	//        hiệu dừng qua file trung gian của npm.
	case "echo":
		for _, a := range args[1:] {
			fmt.Println(a)
		}

	case "listen":
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
		fmt.Printf("hellopay %s: listening (pid %d). Press Ctrl-C to stop.\n", version, os.Getpid())
		select {
		case sig := <-stop:
			fmt.Printf("hellopay: received %v, shutting down cleanly.\n", sig)
		case <-time.After(10 * time.Minute):
			fmt.Fprintln(os.Stderr, "hellopay: nothing interrupted us in 10 minutes, giving up.")
			os.Exit(1)
		}

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
		fmt.Fprintf(os.Stderr, "hellopay: unknown command %q\n\n", args[0])
		fmt.Fprint(os.Stderr, usage)
		os.Exit(1)
	}
}
