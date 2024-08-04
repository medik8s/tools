package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"github.com/medik8s/findIndexImage/backend"
)

//go:embed frontend/ui
var frontend embed.FS

var (
	// set by goreleaser with default settings
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func main() {

	args := os.Args
	if len(args) > 1 {
		cliOpt := "--cli"
		if len(args) != 2 || args[1] != cliOpt {
			log.Printf(fmt.Sprintf("Usage: %s [%s]", args[0], cliOpt))
			os.Exit(1)
		}
		// old command line behaviour, print all index images as json
		printAsJson()
		return
	}

	// use the new web ui
	serverAddress := "localhost:8080"
	stripRoot, _ := fs.Sub(frontend, "frontend/ui")
	go func() {
		if err := backend.Start(stripRoot, serverAddress, version); err != nil {
			log.Fatal(err)
		}
	}()

	if err := openURL(fmt.Sprintf("http://%s", serverAddress)); err != nil {
		log.Fatal(err)
	}

	select {}
}

func printAsJson() {
	results, err := backend.GetIndexImages(false)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	resultBytes, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	fmt.Println(string(resultBytes))
}

// https://gist.github.com/sevkin/9798d67b2cb9d07cb05f89f14ba682f8
// openURL opens the specified URL in the default browser of the user.
func openURL(url string) error {
	var cmd string
	var args []string

	switch runtime.GOOS {
	case "windows":
		cmd = "cmd"
		args = []string{"/c", "start"}
	case "darwin":
		cmd = "open"
		args = []string{url}
	default: // "linux", "freebsd", "openbsd", "netbsd"
		// Check if running under WSL
		if isWSL() {
			// Use 'cmd.exe /c start' to open the URL in the default Windows browser
			cmd = "cmd.exe"
			args = []string{"/c", "start", url}
		} else {
			// Use xdg-open on native Linux environments
			cmd = "xdg-open"
			args = []string{url}
		}
	}
	if len(args) > 1 {
		// args[0] is used for 'start' command argument, to prevent issues with URLs starting with a quote
		args = append(args[:1], append([]string{""}, args[1:]...)...)
	}
	return exec.Command(cmd, args...).Start()
}

// isWSL checks if the Go program is running inside Windows Subsystem for Linux
func isWSL() bool {
	releaseData, err := exec.Command("uname", "-r").Output()
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(releaseData)), "microsoft")
}
