// buildgate caps how many heavy builds (go build/test, node builds) run at once.
//
// It is installed as shims named go, npm, pnpm, yarn, npx, bun in a directory
// placed first on PATH. Build-like invocations wait for one of BUILDGATE_MAX
// (default 2) slots; everything else execs the real binary straight away.
// Slots are flock(2) locks, so a crashed or killed build frees its slot.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var (
	home, _  = os.UserHomeDir()
	baseDir  = filepath.Join(home, ".buildgate")
	lockDir  = filepath.Join(baseDir, "locks")
	shimList = []string{"go", "npm", "pnpm", "yarn", "npx", "bun"}
	cfg      = loadConfig()
)

// Config is edited by the BuildGate menu bar app (~/.buildgate/config.json).
type Config struct {
	Enabled     bool     `json:"enabled"`
	MaxBuilds   int      `json:"maxBuilds"`
	Tools       []string `json:"tools"`       // shims that are gated
	GoCommands  []string `json:"goCommands"`  // go subcommands, exact match
	NodeScripts []string `json:"nodeScripts"` // npm/pnpm/... args, prefix match
	WhenFull    string   `json:"whenFull"`    // "reject" (fail fast) or "wait"
	ExtraTools  []string `json:"extraTools"`  // always gated, e.g. golangci-lint
	Rules       []Rule   `json:"rules"`       // flutter, xcodebuild, gradle, cargo, ...
}

// Rule gates `Tool` when any argument starts with one of Commands (also the
// last part of a:b:task names). No Commands means every run except version/help.
type Rule struct {
	Tool     string   `json:"tool"`
	Commands []string `json:"commands"`
	Enabled  bool     `json:"enabled"`
}

var defaultRules = []Rule{
	{"flutter", []string{"build", "test", "analyze", "drive"}, true},
	{"dart", []string{"compile", "test", "analyze", "build_runner"}, true},
	{"xcodebuild", nil, true},
	{"swift", []string{"build", "test"}, true},
	{"pod", []string{"install", "update"}, true},
	{"gradle", []string{"assemble", "build", "bundle", "test", "check", "lint", "install"}, true},
	{"react-native", []string{"run-ios", "run-android", "build-ios", "build-android", "bundle"}, true},
	{"expo", []string{"export", "prebuild"}, true},
	{"tsc", nil, true},
	{"vite", []string{"build"}, true},
	{"next", []string{"build", "lint"}, true},
	{"turbo", []string{"build", "lint", "typecheck", "check"}, true},
	{"nx", []string{"build", "lint", "typecheck"}, true},
	{"cargo", []string{"build", "test", "check", "clippy", "install"}, true},
	{"mvn", []string{"package", "install", "compile", "test", "verify"}, true},
	{"bazel", []string{"build", "test"}, true},
	{"docker", []string{"build"}, true},
}

func loadConfig() Config {
	c := Config{
		Enabled:     true,
		MaxBuilds:   2,
		Tools:       shimList,
		GoCommands:  []string{"build", "test", "install", "vet"},
		NodeScripts: []string{"build", "typecheck", "tsc", "lint", "eslint"},
		WhenFull:    "reject",
		ExtraTools:  []string{"golangci-lint", "staticcheck", "eslint"},
		Rules:       defaultRules,
	}
	if b, err := os.ReadFile(filepath.Join(baseDir, "config.json")); err == nil {
		json.Unmarshal(b, &c)
	}
	if c.MaxBuilds < 1 {
		c.MaxBuilds = 1
	}
	return c
}

func wordsRe(words []string, exact bool) *regexp.Regexp {
	if len(words) == 0 {
		return regexp.MustCompile(`$^`)
	}
	q := make([]string, len(words))
	for i, w := range words {
		q[i] = regexp.QuoteMeta(strings.TrimSpace(w))
	}
	tail := ""
	if exact {
		tail = "$"
	}
	return regexp.MustCompile("^(" + strings.Join(q, "|") + ")" + tail)
}

func maxSlots() int { return cfg.MaxBuilds }

func main() {
	name := filepath.Base(os.Args[0])
	if name == "buildgate" {
		cli(os.Args[1:])
		return
	}
	real, err := realBin(name)
	if err != nil {
		fail("%s: not found on PATH (outside buildgate)", name)
	}
	args := os.Args[1:]
	if os.Getenv("BUILDGATE_HELD") != "" || !cfg.Enabled || !shouldGate(name, args) {
		syscall.Exec(real, append([]string{name}, args...), os.Environ())
		fail("exec %s failed", real)
	}
	os.Exit(gated(real, name, args))
}

func cli(args []string) {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Println(`buildgate - allow at most BUILDGATE_MAX (default 2) builds at once

  buildgate status          show running builds
  buildgate <cmd> [args]    run any command under the gate
  buildgate install         (re)create shims next to this binary
  buildgate agents          AI agents and shells, and whether they are limited
  buildgate setup [id|all]  set up shells and agents (claude, codex, gemini, ...)

Settings: BuildGate menu bar app (~/.buildgate/config.json)`)
		return
	}
	switch args[0] {
	case "status":
		status()
	case "install":
		install()
	case "claude-hook":
		claudeHook(true)
	case "hook": // any agent with Claude-style hooks (Codex), without rtk
		claudeHook(false)
	case "claude-post", "post":
		claudePost()
	case "agents":
		agentsCmd(args[1:])
	case "setup":
		setupCmd(args[1:])
	default:
		real, err := exec.LookPath(args[0])
		if err != nil {
			fail("%s: not found", args[0])
		}
		if os.Getenv("BUILDGATE_HELD") != "" {
			syscall.Exec(real, args, os.Environ())
		}
		os.Exit(gated(real, args[0], args[1:]))
	}
}

var quickArgs = map[string]bool{"version": true, "--version": true, "-v": true, "help": true, "--help": true, "-h": true,
	"--watch": true, "-w": true, "watch": true, "-version": true, "-help": true, "-usage": true, "-list": true,
	"-showsdks": true, "-showBuildSettings": true, "-showdestinations": true, "-showTestPlans": true}

func hasQuick(args []string) bool {
	for _, a := range args {
		if quickArgs[a] {
			return true
		}
	}
	return false
}

func matchesCommand(args, commands []string) bool {
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		last := a[strings.LastIndex(a, ":")+1:]
		for _, c := range commands {
			if c = strings.TrimSpace(c); c != "" && (strings.HasPrefix(a, c) || strings.HasPrefix(last, c)) {
				return true
			}
		}
	}
	return false
}

func ruleFor(name string) *Rule {
	for i, r := range cfg.Rules {
		if r.Enabled && r.Tool == name {
			return &cfg.Rules[i]
		}
	}
	return nil
}

func shouldGate(name string, args []string) bool {
	for _, t := range cfg.ExtraTools {
		if t == name {
			return !hasQuick(args)
		}
	}
	if r := ruleFor(name); r != nil {
		if len(r.Commands) == 0 {
			return !hasQuick(args)
		}
		return matchesCommand(args, r.Commands)
	}
	gated := false
	for _, t := range cfg.Tools {
		gated = gated || t == name
	}
	if !gated {
		return false
	}
	goRe, nodeRe := wordsRe(cfg.GoCommands, true), wordsRe(cfg.NodeScripts, false)
	if name == "go" {
		for _, a := range args {
			if !strings.HasPrefix(a, "-") {
				return goRe.MatchString(a)
			}
		}
		return false
	}
	for _, a := range args {
		if !strings.HasPrefix(a, "-") && nodeRe.MatchString(a) {
			return true
		}
	}
	return false
}

// realBin finds the next `name` on PATH that is not this shim.
func realBin(name string) (string, error) {
	self, _ := os.Executable()
	selfInfo, _ := os.Stat(self)
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			continue
		}
		p := filepath.Join(dir, name)
		fi, err := os.Stat(p)
		if err != nil || fi.IsDir() || fi.Mode()&0o111 == 0 {
			continue
		}
		if selfInfo != nil && os.SameFile(fi, selfInfo) {
			continue
		}
		return p, nil
	}
	// Project-local tools (eslint, tsc, ...) live in node_modules/.bin.
	if dir, err := os.Getwd(); err == nil {
		for {
			p := filepath.Join(dir, "node_modules", ".bin", name)
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
				return p, nil
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return "", exec.ErrNotFound
}

var logDir = filepath.Join(baseDir, "logs")

// openLog starts ~/.buildgate/logs/<time>-<pid>.log with a small header the
// menu bar app parses (# command / # cwd / # started), pruning old logs.
func openLog(label string) *os.File {
	if os.MkdirAll(logDir, 0o755) != nil {
		return nil
	}
	if old, _ := filepath.Glob(filepath.Join(logDir, "*.log")); len(old) > 200 {
		for _, p := range old[:len(old)-150] { // names sort by time
			os.Remove(p)
		}
	}
	name := fmt.Sprintf("%s-%d.log", time.Now().Format("20060102-150405"), os.Getpid())
	f, err := os.OpenFile(filepath.Join(logDir, name), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil
	}
	cwd, _ := os.Getwd()
	fmt.Fprintf(f, "# command: %s\n# cwd: %s\n# pid: %d\n# started: %s\n\n", label, cwd, os.Getpid(), time.Now().Format(time.RFC3339))
	return f
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

func gated(real, name string, args []string) int {
	label := strings.TrimSpace(name + " " + strings.Join(args, " "))
	slot := acquire(label)
	defer func() { slot.Truncate(0); slot.Close() }()

	cmd := exec.Command(real, args...)
	cmd.Args[0] = name
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "BUILDGATE_HELD=1")
	// Copy output to a log for the app. Terminal output is left alone so
	// colors/progress bars keep working; agents write to pipes and get logged.
	logf := openLog(label)
	started := time.Now()
	if logf != nil {
		defer logf.Close()
		if !isTerminal(os.Stdout) {
			cmd.Stdout = io.MultiWriter(os.Stdout, logf)
		}
		if !isTerminal(os.Stderr) {
			cmd.Stderr = io.MultiWriter(os.Stderr, logf)
		}
		if isTerminal(os.Stdout) && isTerminal(os.Stderr) {
			fmt.Fprintln(logf, "(output went to a terminal and was not captured)")
		}
	}
	code := run(cmd)
	if logf != nil {
		fmt.Fprintf(logf, "\n# exit: %d (%s)\n", code, time.Since(started).Round(time.Second))
	}
	return code
}

func run(cmd *exec.Cmd) int {
	// Ctrl-C reaches the child via the process group; just outlive it.
	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	if err := cmd.Start(); err != nil {
		fail("%v", err)
	}
	go func() {
		for s := range sigs {
			if s != syscall.SIGINT && s != syscall.SIGQUIT {
				cmd.Process.Signal(s)
			}
		}
	}()
	err := cmd.Wait()
	if ee, ok := err.(*exec.ExitError); ok {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	} else if err != nil {
		fail("%v", err)
	}
	return 0
}

func acquire(label string) *os.File {
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		fail("%v", err)
	}
	n := maxSlots()
	start := time.Now()
	announced := false
	cwd, _ := os.Getwd()
	waitFile := filepath.Join(lockDir, fmt.Sprintf("wait.%d", os.Getpid()))
	defer os.Remove(waitFile)
	for {
		if announced {
			n = loadConfig().MaxBuilds
		}
		for i := 0; i < n; i++ {
			f, writable, err := openSlot(i)
			if err != nil {
				// A sandbox (e.g. Codex read-only) that hides the slots entirely:
				// better to build unlimited than to fail every build.
				fmt.Fprintf(os.Stderr, "buildgate: cannot use build slots here (%v); running without the limit\n", err)
				return nil
			}
			if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) == nil {
				os.Remove(waitFile)
				if writable {
					f.Truncate(0)
					fmt.Fprintf(f, "pid=%d since=%s cwd=%s\n%s\n", os.Getpid(), time.Now().Format("15:04:05"), cwd, label)
				}
				if announced {
					fmt.Fprintf(os.Stderr, "buildgate: got slot after %s\n", time.Since(start).Round(time.Second))
				}
				return f
			}
			f.Close()
		}
		if cfg.WhenFull != "wait" && time.Since(start) > time.Second {
			logEvent("rejected", label, cwd, runningList())
			if lf := openLog(label); lf != nil {
				fmt.Fprintf(lf, "REJECTED: too many builds running (%d/%d)\n%s\n\n# exit: 75 (rejected)\n", n, n, running())
				lf.Close()
			}
			fmt.Fprintf(os.Stderr, "buildgate: REJECTED %q - TOO MANY BUILDS AT THE SAME TIME (%d/%d running).\n%s\nWait for a running build to finish, then retry.\n", label, n, n, running())
			os.Exit(75)
		}
		if cfg.WhenFull == "wait" && !announced {
			os.WriteFile(waitFile, []byte(fmt.Sprintf("pid=%d since=%s cwd=%s\n%s\n", os.Getpid(), time.Now().Format("15:04:05"), cwd, label)), 0o644)
			fmt.Fprintf(os.Stderr, "buildgate: %d builds already running, waiting for a slot (buildgate status)\n", n)
			announced = true
		}
		if cfg.WhenFull != "wait" {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// openSlot opens a slot lock file. Sandboxes that make ~/.buildgate read-only
// (Codex workspace-write without writable_roots) still allow flock on a
// read-only descriptor, so the limit holds there too, just without owner info.
func openSlot(i int) (*os.File, bool, error) {
	f, err := os.OpenFile(slotPath(i), os.O_CREATE|os.O_RDWR, 0o644)
	if err == nil {
		return f, true, nil
	}
	if ro, rerr := os.Open(slotPath(i)); rerr == nil {
		return ro, false, nil
	}
	return nil, false, err
}

// Event is one rejection or watchdog kill, read back by the PostToolUse hook
// so agents learn why their command failed even when rtk hides stderr.
type Event struct {
	Time    string   `json:"time"`
	Tool    string   `json:"tool,omitempty"` // Claude tool_use_id (BUILDGATE_TOOL_ID)
	Kind    string   `json:"kind"`           // rejected | killed
	Command string   `json:"command"`
	Cwd     string   `json:"cwd"`
	Running []string `json:"running"`
	Max     int      `json:"max"`
}

var eventsPath = filepath.Join(baseDir, "events.jsonl")

func logEvent(kind, command, cwd string, running []string) {
	e := Event{time.Now().Format(time.RFC3339), os.Getenv("BUILDGATE_TOOL_ID"), kind, command, cwd, running, cfg.MaxBuilds}
	b, _ := json.Marshal(e)
	f, err := os.OpenFile(eventsPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	f.Write(append(b, '\n'))
	f.Close()
}

func runningList() []string {
	var out []string
	for i := 0; i < maxSlots(); i++ {
		b, _ := os.ReadFile(slotPath(i))
		if ownerAlive(b) {
			lines := strings.SplitN(strings.TrimSpace(string(b)), "\n", 2)
			cmd := lines[len(lines)-1]
			cwd := ""
			if j := strings.Index(lines[0], "cwd="); j >= 0 {
				cwd = lines[0][j+4:]
			}
			out = append(out, cmd+"  (in "+cwd+")")
		}
	}
	return out
}

// running lists the builds holding slots, for the reject message.
func running() string {
	var out []string
	for i := 0; i < maxSlots(); i++ {
		b, _ := os.ReadFile(slotPath(i))
		if ownerAlive(b) {
			out = append(out, "  running: "+strings.ReplaceAll(strings.TrimSpace(string(b)), "\n", " | "))
		}
	}
	return strings.Join(out, "\n")
}

func ownerAlive(b []byte) bool {
	var pid int
	if _, err := fmt.Sscanf(string(b), "pid=%d", &pid); err != nil || pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) != syscall.ESRCH
}

func slotPath(i int) string { return filepath.Join(lockDir, fmt.Sprintf("slot.%d", i)) }

func status() {
	n := maxSlots()
	busy := 0
	for i := 0; i < n; i++ {
		b, _ := os.ReadFile(slotPath(i))
		if !ownerAlive(b) {
			fmt.Printf("slot %d: free\n", i)
			continue
		}
		busy++
		fmt.Printf("slot %d: %s\n", i, strings.ReplaceAll(strings.TrimSpace(string(b)), "\n", "\n        "))
	}
	fmt.Printf("%d/%d busy\n", busy, n)
}

func install() {
	self, err := os.Executable()
	if err != nil {
		fail("%v", err)
	}
	dir := filepath.Dir(self)
	// Pre-create the slots so sandboxed agents can lock them read-only.
	os.MkdirAll(lockDir, 0o755)
	for i := 0; i < 16; i++ {
		if f, err := os.OpenFile(slotPath(i), os.O_CREATE|os.O_RDONLY, 0o644); err == nil {
			f.Close()
		}
	}
	names := append(append([]string{}, shimList...), cfg.ExtraTools...)
	// Rule tools get a shim only when installed, so `command -v cargo` stays honest.
	var skipped []string
	for _, r := range cfg.Rules {
		if !r.Enabled || contains(names, r.Tool) {
			continue
		}
		if _, err := realBin(r.Tool); err == nil {
			names = append(names, r.Tool)
		} else {
			skipped = append(skipped, r.Tool)
		}
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		if t, err := os.Readlink(p); err == nil && t == "buildgate" && !contains(names, e.Name()) {
			os.Remove(p)
		}
	}
	for _, s := range names {
		p := filepath.Join(dir, s)
		os.Remove(p)
		if err := os.Symlink("buildgate", p); err != nil {
			fail("%v", err)
		}
	}
	fmt.Printf("shims in %s: %s\n", dir, strings.Join(names, " "))
	if len(skipped) > 0 {
		fmt.Printf("not installed (no shim): %s\n", strings.Join(skipped, " "))
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// toolWord matches commands that may (directly or via make) run a gated tool.
func toolWord() *regexp.Regexp {
	words := []string{"go", "npm", "pnpm", "yarn", "npx", "bun", "tsc", "vite", "next", "turbo", "make", "rtk", "fastlane", "gradlew"}
	for _, t := range cfg.ExtraTools {
		words = append(words, regexp.QuoteMeta(t))
	}
	for _, r := range cfg.Rules {
		words = append(words, regexp.QuoteMeta(r.Tool))
	}
	return regexp.MustCompile(`(^|[\s;&|(/])(` + strings.Join(words, "|") + `)(\s|$)`)
}

// claudeHook is a Claude Code PreToolUse hook for Bash. It chains the rtk hook
// (when installed), then puts the buildgate shims first on PATH so agent
// shells that predate ~/.zshrc changes are still gated.
func claudeHook(withRTK bool) {
	in, _ := io.ReadAll(os.Stdin)
	var ev struct {
		ToolInput      map[string]any `json:"tool_input"`
		ToolUseID      string         `json:"tool_use_id"`
		PermissionMode string         `json:"permission_mode"`
	}
	if json.Unmarshal(in, &ev) != nil || ev.ToolInput == nil {
		return
	}
	markToolStart(ev.ToolUseID)
	// Codex applies updatedInput only together with permissionDecision "allow",
	// which also skips its approval prompt. Do that only when approvals are off
	// already; otherwise the shell startup files put the shims on PATH.
	if !withRTK && ev.PermissionMode != "bypassPermissions" {
		return
	}
	out := map[string]any{"hookEventName": "PreToolUse"}
	original, _ := ev.ToolInput["command"].(string)
	input := ev.ToolInput
	if rtk, err := exec.LookPath("rtk"); err == nil && withRTK {
		cmd := exec.Command(rtk, "hook", "claude")
		cmd.Stdin = bytes.NewReader(in)
		if b, err := cmd.Output(); err == nil && len(bytes.TrimSpace(b)) > 0 {
			var r struct {
				Hook map[string]any `json:"hookSpecificOutput"`
			}
			if json.Unmarshal(b, &r) == nil && r.Hook != nil {
				out = r.Hook
				if u, ok := r.Hook["updatedInput"].(map[string]any); ok {
					input = u
				}
			}
		}
	}
	command, _ := input["command"].(string)
	// Check the original too: rtk may rename the tool (eslint -> rtk lint).
	if cfg.Enabled && (toolWord().MatchString(command) || toolWord().MatchString(original)) && !strings.Contains(command, ".buildgate/bin") {
		prefix := `export PATH="$HOME/.buildgate/bin:$PATH"; `
		if id := regexp.MustCompile(`^[A-Za-z0-9_-]+$`).FindString(ev.ToolUseID); id != "" {
			prefix = "export BUILDGATE_TOOL_ID=" + id + "; " + prefix
		}
		input["command"] = prefix + command
	}
	if _, changed := out["updatedInput"]; !changed && input["command"] == original {
		return // nothing to rewrite
	}
	out["hookEventName"] = "PreToolUse"
	out["updatedInput"] = input
	if !withRTK {
		out["permissionDecision"] = "allow"
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.Encode(map[string]any{"hookSpecificOutput": out})
}

// claudePost is a PostToolUse(+Failure) hook for Bash: if BuildGate rejected or
// killed something during this tool call, tell the agent plainly.
func claudePost() {
	in, _ := io.ReadAll(os.Stdin)
	var ev struct {
		ToolUseID string `json:"tool_use_id"`
		HookEvent string `json:"hook_event_name"`
		Cwd       string `json:"cwd"`
	}
	if json.Unmarshal(in, &ev) != nil || ev.ToolUseID == "" {
		return
	}
	started := toolStart(ev.ToolUseID)
	data, err := os.ReadFile(eventsPath)
	if err != nil {
		return
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) > 2000 { // keep the file small
		lines = lines[len(lines)-1000:]
		os.WriteFile(eventsPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
	}
	var msgs []string
	for _, l := range lines {
		var e Event
		if json.Unmarshal([]byte(l), &e) != nil {
			continue
		}
		// Without a tool id (the command was not rewritten), take untagged
		// events since this tool call started, in or under the agent's cwd.
		recent := false
		if t, err := time.Parse(time.RFC3339, e.Time); err == nil && !started.IsZero() {
			recent = !t.Before(started.Truncate(time.Second))
		}
		untagged := e.Tool == "" && recent && ev.Cwd != "" && strings.HasPrefix(e.Cwd, ev.Cwd)
		if e.Tool != ev.ToolUseID && !untagged {
			continue
		}
		verb := "REJECTED (it never started)"
		if e.Kind == "killed" {
			verb = "KILLED by the BuildGate watchdog"
		}
		m := fmt.Sprintf("BuildGate %s `%s` in %s because %d builds were already running (limit %d):", verb, e.Command, e.Cwd, len(e.Running), e.Max)
		for _, r := range e.Running {
			if len(r) > 160 {
				r = r[:157] + "..."
			}
			m += "\n  - " + r
		}
		msgs = append(msgs, m)
	}
	if len(msgs) == 0 {
		return
	}
	ctx := strings.Join(msgs, "\n") + "\nThis was NOT a crash, compile error or out-of-memory: BuildGate limits concurrent builds on this machine. " +
		"Any 'killed', 'terminated abnormally' or exit 75/143/254 output from this command is caused by that. " +
		"Do not lower GOMAXPROCS/concurrency or change flags to work around it. Wait for the running builds to finish (e.g. sleep 30-60s), then rerun the same command."
	event := ev.HookEvent
	if event == "" {
		event = "PostToolUse"
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.Encode(map[string]any{
		"systemMessage":      fmt.Sprintf("BuildGate stopped %d command(s) here: too many builds running", len(msgs)),
		"hookSpecificOutput": map[string]any{"hookEventName": event, "additionalContext": ctx},
	})
}

var toolIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// markToolStart records when an agent's Bash call began (PreToolUse), so the
// PostToolUse hook can attribute untagged rejections to it.
func markToolStart(id string) {
	if !toolIDRe.MatchString(id) {
		return
	}
	dir := filepath.Join(baseDir, "tools")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, id), []byte(time.Now().Format(time.RFC3339)), 0o644)
	if entries, err := os.ReadDir(dir); err == nil && len(entries) > 200 {
		for _, e := range entries {
			if fi, err := e.Info(); err == nil && time.Since(fi.ModTime()) > 24*time.Hour {
				os.Remove(filepath.Join(dir, e.Name()))
			}
		}
	}
}

func toolStart(id string) time.Time {
	if !toolIDRe.MatchString(id) {
		return time.Time{}
	}
	p := filepath.Join(baseDir, "tools", id)
	b, _ := os.ReadFile(p)
	os.Remove(p)
	t, _ := time.Parse(time.RFC3339, strings.TrimSpace(string(b)))
	return t
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "buildgate: "+format+"\n", a...)
	os.Exit(127)
}
