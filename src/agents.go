package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Agent integrations. Every agent gets the shims through the shell startup
// files; agents with hooks (Claude Code, Codex) also get the PATH prefix per
// command and a plain explanation after a rejection or kill; agents that read
// a global instructions file get a short note on what exit 75 means.

type agent struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	How   string `json:"how"`
	Found bool   `json:"found"`
	Ready bool   `json:"ready"`
	setup func() error
}

const (
	envLine    = `[ -f "$HOME/.buildgate/env.sh" ] && . "$HOME/.buildgate/env.sh"  # buildgate`
	noteStart  = "<!-- buildgate:start -->"
	noteEnd    = "<!-- buildgate:end -->"
	agentsNote = noteStart + `
## BuildGate: build limit on this Mac

This machine runs BuildGate, which allows only a few builds at the same time
(go, npm/pnpm/yarn/bun scripts, flutter, dart, xcodebuild, swift, pod, gradle,
cargo, tsc, golangci-lint, ...).

- Exit code 75 with "buildgate: REJECTED ... TOO MANY BUILDS AT THE SAME TIME"
  means other builds are running. It is not a compile error, crash or memory
  problem. Wait (sleep 30-60), check ` + "`~/.buildgate/bin/buildgate status`" + `, then rerun the
  same command. Do not work around it (no BUILDGATE_HELD, no calling the real
  binary by path, no lowering concurrency flags).
- A build that dies with exit 143 / "Terminated" may have been stopped by the
  BuildGate watchdog for the same reason (see ~/.buildgate/killed.log).
` + noteEnd + "\n"
)

var envScript = `# BuildGate: keeps the build-limit shims first on PATH. Sourced from shell
# startup files (zshenv/zprofile/zshrc/bash) so every terminal, IDE and AI
# agent shell is limited, including login shells that reorder PATH.
case ":$PATH:" in
  ":$HOME/.buildgate/bin:"*) ;;
  *) PATH="$HOME/.buildgate/bin:${PATH//$HOME\/.buildgate\/bin:/}"; export PATH ;;
esac
`

func homePath(p ...string) string { return filepath.Join(append([]string{home}, p...)...) }

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func onPath(name string) bool { _, err := exec.LookPath(name); return err == nil }

func fileHas(p string, subs ...string) bool {
	b, err := os.ReadFile(p)
	if err != nil {
		return false
	}
	for _, s := range subs {
		if !strings.Contains(string(b), s) {
			return false
		}
	}
	return true
}

func gateBin() string { return homePath(".buildgate", "bin", "buildgate") }

func shellFiles() []string {
	files := []string{homePath(".zshenv"), homePath(".zprofile"), homePath(".zshrc")}
	for _, f := range []string{".bash_profile", ".bashrc"} {
		if exists(homePath(f)) {
			files = append(files, homePath(f))
		}
	}
	return files
}

func agents() []agent {
	hookCmd := `"` + gateBin() + `" hook`
	postCmd := `"` + gateBin() + `" post`
	list := []agent{
		{
			ID: "shell", Name: "All shells (terminals, IDEs, every agent)", How: "~/.zshenv, ~/.zprofile, ~/.zshrc, bash",
			Found: true,
			Ready: fileHas(homePath(".buildgate", "env.sh"), "buildgate/bin") && allHave(shellFiles(), "buildgate/env.sh"),
			setup: setupShell,
		},
		{
			ID: "claude", Name: "Claude Code", How: "hooks in ~/.claude/settings.json",
			Found: exists(homePath(".claude")) || onPath("claude"),
			Ready: fileHas(homePath(".claude", "settings.json"), "claude-hook", "claude-post"),
			setup: setupClaude,
		},
		{
			ID: "codex", Name: "Codex", How: "hooks in ~/.codex/hooks.json + ~/.codex/AGENTS.md",
			Found: exists(homePath(".codex")) || onPath("codex"),
			Ready: fileHas(homePath(".codex", "hooks.json"), `buildgate\" hook`, `buildgate\" post`) && fileHas(homePath(".codex", "AGENTS.md"), noteStart),
			setup: func() error {
				if err := mergeHook(homePath(".codex", "hooks.json"), "PreToolUse", hookCmd, nil); err != nil {
					return err
				}
				if err := mergeHook(homePath(".codex", "hooks.json"), "PostToolUse", postCmd, nil); err != nil {
					return err
				}
				codexWritableRoot()
				return writeNote(homePath(".codex", "AGENTS.md"))
			},
		},
	}
	notes := []struct{ id, name, bin, dir, file string }{
		{"gemini", "Gemini CLI", "gemini", ".gemini", "GEMINI.md"},
		{"opencode", "opencode", "opencode", ".config/opencode", "AGENTS.md"},
		{"amp", "Amp", "amp", ".config/amp", "AGENTS.md"},
		{"qwen", "Qwen Code", "qwen", ".qwen", "QWEN.md"},
		{"copilot", "GitHub Copilot CLI", "copilot", ".copilot", "copilot-instructions.md"},
		{"droid", "Factory Droid", "droid", ".factory", "AGENTS.md"},
	}
	for _, n := range notes {
		file := homePath(n.dir, n.file)
		list = append(list, agent{
			ID: n.id, Name: n.name, How: "note in ~/" + filepath.Join(n.dir, n.file),
			Found: exists(homePath(n.dir)) || onPath(n.bin),
			Ready: fileHas(file, noteStart),
			setup: func() error { return writeNote(file) },
		})
	}
	return list
}

func allHave(files []string, sub string) bool {
	for _, f := range files {
		if !fileHas(f, sub) {
			return false
		}
	}
	return true
}

func setupShell() error {
	if err := os.WriteFile(homePath(".buildgate", "env.sh"), []byte(envScript), 0o644); err != nil {
		return err
	}
	old := `export PATH="$HOME/.buildgate/bin:$PATH"`
	for _, f := range shellFiles() {
		b, _ := os.ReadFile(f)
		s := string(b)
		if strings.Contains(s, "buildgate/env.sh") {
			continue
		}
		// The first version appended a plain export to ~/.zshrc; replace it.
		s = regexp.MustCompile(`(?m)^# buildgate: .*\n`+regexp.QuoteMeta(old)+`\n`).ReplaceAllString(s, "")
		s = strings.Replace(s, old+"\n", "", 1)
		if s != "" && !strings.HasSuffix(s, "\n") {
			s += "\n"
		}
		s += "\n# buildgate: limit concurrent builds (keep last, after brew/nvm PATH setup)\n" + envLine + "\n"
		if err := os.WriteFile(f, []byte(s), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func setupClaude() error {
	settings := homePath(".claude", "settings.json")
	hook := `"$HOME/.buildgate/bin/buildgate" claude-hook`
	post := `"$HOME/.buildgate/bin/buildgate" claude-post`
	// buildgate's hook chains rtk, so an existing `rtk hook claude` is replaced.
	if err := mergeHook(settings, "PreToolUse", hook, func(c string) bool { return c == "rtk hook claude" }); err != nil {
		return err
	}
	for _, ev := range []string{"PostToolUse", "PostToolUseFailure"} {
		if err := mergeHook(settings, ev, post, nil); err != nil {
			return err
		}
	}
	return nil
}

// mergeHook adds a Bash command hook to a Claude-style hooks file, replacing an
// entry for which replace returns true, and keeping everything else.
func mergeHook(path, event, command string, replace func(string) bool) error {
	root := map[string]any{}
	if b, err := os.ReadFile(path); err == nil && len(strings.TrimSpace(string(b))) > 0 {
		if err := json.Unmarshal(b, &root); err != nil {
			return fmt.Errorf("%s is not valid JSON: %v", path, err)
		}
	}
	hooks, _ := root["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	entries, _ := hooks[event].([]any)
	placed, changed := false, false
	for _, e := range entries {
		m, _ := e.(map[string]any)
		list, _ := m["hooks"].([]any)
		for _, h := range list {
			hm, _ := h.(map[string]any)
			c, _ := hm["command"].(string)
			if c == command {
				placed = true
			} else if replace != nil && replace(c) && !placed {
				hm["command"] = command
				placed, changed = true, true
			}
		}
	}
	if placed && !changed {
		return nil // already there; leave the file (and its key order) alone
	}
	if !placed {
		entries = append(entries, map[string]any{
			"matcher": "Bash",
			"hooks":   []any{map[string]any{"type": "command", "command": command}},
		})
	}
	hooks[event] = entries
	root["hooks"] = hooks
	os.MkdirAll(filepath.Dir(path), 0o755)
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(root); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(buf.String()), 0o644)
}

// writeNote adds (or refreshes) the BuildGate section in an instructions file.
func writeNote(path string) error {
	b, _ := os.ReadFile(path)
	s := string(b)
	if i := strings.Index(s, noteStart); i >= 0 {
		if j := strings.Index(s, noteEnd); j > i {
			s = s[:i] + strings.TrimLeft(s[j+len(noteEnd):], "\n")
		}
	}
	s = strings.TrimRight(s, "\n")
	if s != "" {
		s += "\n\n"
	}
	os.MkdirAll(filepath.Dir(path), 0o755)
	return os.WriteFile(path, []byte(s+agentsNote), 0o644)
}

// codexWritableRoot lets Codex's workspace-write sandbox take build slots
// (lock files live in ~/.buildgate). Only added when the section is absent.
func codexWritableRoot() {
	path := homePath(".codex", "config.toml")
	b, _ := os.ReadFile(path)
	if strings.Contains(string(b), "[sandbox_workspace_write]") {
		return
	}
	s := strings.TrimRight(string(b), "\n")
	s += fmt.Sprintf("\n\n# buildgate: build slots live here\n[sandbox_workspace_write]\nwritable_roots = [%q]\n", homePath(".buildgate"))
	os.WriteFile(path, []byte(s), 0o644)
}

func agentsCmd(args []string) {
	list := agents()
	if len(args) > 0 && args[0] == "--json" {
		json.NewEncoder(os.Stdout).Encode(list)
		return
	}
	for _, a := range list {
		state := "not installed"
		if a.Found {
			state = "NOT SET UP"
			if a.Ready {
				state = "ok"
			}
		}
		fmt.Printf("%-14s %-12s %s (%s)\n", a.ID, state, a.Name, a.How)
	}
}

func setupCmd(args []string) {
	want := "all"
	if len(args) > 0 {
		want = args[0]
	}
	failed := false
	for _, a := range agents() {
		if want != a.ID && !(want == "all" && a.Found) {
			continue
		}
		if err := a.setup(); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", a.ID, err)
			failed = true
			continue
		}
		fmt.Printf("%s: set up\n", a.ID)
	}
	if failed {
		os.Exit(1)
	}
}
