// meetrec-gateway — OpenAI-совместимый шлюз к `claude -p` (подписка Claude Code) на сервере.
//
//	GET  /v1/models            — список моделей
//	POST /v1/chat/completions  — ответ модели (без стриминга)
//	GET  /healthz              — жив ли шлюз (без авторизации)
//
// Слушает только localhost: снаружи доступен через SSH-туннель (его поднимает meetrec на маке).
// Авторизация — Bearer-токен из ~/.config/meetrec/gateway-token (создаётся при первом запуске).
// В лог пишутся только метаданные (модель, время, токены, статус) — не содержимое запросов.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var models = []string{"claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"}

const defaultModel = "claude-opus-5-5"

type server struct {
	token   string
	claude  string
	workdir string
	sem     chan struct{}
	timeout time.Duration
}

func main() {
	addr := flag.String("listen", "127.0.0.1:8787", "адрес (держи на localhost — доступ через SSH-туннель)")
	claude := flag.String("claude", "", "путь к claude (по умолчанию ~/.local/bin/claude или из PATH)")
	parallel := flag.Int("parallel", 4, "одновременных вызовов claude")
	timeout := flag.Duration("timeout", 10*time.Minute, "таймаут одного ответа")
	flag.Parse()

	home, _ := os.UserHomeDir()
	token, err := loadToken(filepath.Join(home, ".config/meetrec/gateway-token"))
	if err != nil {
		log.Fatalf("токен: %v", err)
	}
	bin := *claude
	if bin == "" {
		bin = filepath.Join(home, ".local/bin/claude")
		if _, err := os.Stat(bin); err != nil {
			if p, err := exec.LookPath("claude"); err == nil {
				bin = p
			}
		}
	}
	// Пустая рабочая папка: claude не подтянет чужие CLAUDE.md / память проекта.
	workdir := filepath.Join(home, ".cache/meetrec-gateway/empty")
	if err := os.MkdirAll(workdir, 0o700); err != nil {
		log.Fatal(err)
	}
	s := &server{token: token, claude: bin, workdir: workdir, sem: make(chan struct{}, *parallel), timeout: *timeout}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /v1/models", s.auth(s.listModels))
	mux.HandleFunc("POST /v1/chat/completions", s.auth(s.chat))
	log.Printf("meetrec-gateway на %s, claude=%s", *addr, bin)
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func loadToken(path string) (string, error) {
	if b, err := os.ReadFile(path); err == nil && len(bytes.TrimSpace(b)) > 0 {
		return string(bytes.TrimSpace(b)), nil
	}
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	t := hex.EncodeToString(buf)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(t+"\n"), 0o600); err != nil {
		return "", err
	}
	log.Printf("создан новый токен: %s", path)
	return t, nil
}

func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) != 1 {
			apiError(w, http.StatusUnauthorized, "invalid_api_key", "неверный токен шлюза")
			return
		}
		next(w, r)
	}
}

func (s *server) listModels(w http.ResponseWriter, _ *http.Request) {
	type model struct {
		ID      string `json:"id"`
		Object  string `json:"object"`
		OwnedBy string `json:"owned_by"`
	}
	data := make([]model, 0, len(models))
	for _, m := range models {
		data = append(data, model{m, "model", "anthropic"})
	}
	writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

type chatRequest struct {
	Model    string `json:"model"`
	Messages []struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
}

// text — content бывает строкой или массивом частей [{type: "text", text: "..."}].
func text(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		var b strings.Builder
		for _, p := range parts {
			if p.Type == "text" {
				b.WriteString(p.Text)
			}
		}
		return b.String()
	}
	return ""
}

func (s *server) chat(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	var req chatRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 20<<20)).Decode(&req); err != nil {
		apiError(w, http.StatusBadRequest, "invalid_request_error", "не JSON: "+err.Error())
		return
	}
	model := req.Model
	if model == "" || model == "default" {
		model = defaultModel
	}
	// system → промпт claude -p; остальные сообщения → stdin (одно — как есть, несколько — с ролями).
	var system []string
	var convo []string
	nonSystem := 0
	for _, m := range req.Messages {
		if m.Role != "system" {
			nonSystem++
		}
	}
	for _, m := range req.Messages {
		t := text(m.Content)
		switch {
		case m.Role == "system":
			system = append(system, t)
		case nonSystem == 1:
			convo = append(convo, t)
		default:
			convo = append(convo, fmt.Sprintf("[%s]\n%s", m.Role, t))
		}
	}
	prompt := strings.Join(system, "\n\n")
	if strings.TrimSpace(prompt) == "" {
		prompt = "Respond to the input."
	}

	select {
	case s.sem <- struct{}{}:
		defer func() { <-s.sem }()
	case <-r.Context().Done():
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.timeout)
	defer cancel()
	// "--" — промпт, начинающийся с «-» (списки), не должен разбираться как флаг claude.
	cmd := exec.CommandContext(ctx, s.claude, "-p", "--model", model,
		"--output-format", "json", "--no-session-persistence", "--", prompt)
	cmd.Dir = s.workdir
	cmd.WaitDelay = 5 * time.Second // таймаут срабатывает, даже если дочерние процессы claude держат вывод
	cmd.Stdin = strings.NewReader(strings.Join(convo, "\n\n"))
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	runErr := cmd.Run()

	var res struct {
		Result  string `json:"result"`
		IsError bool   `json:"is_error"`
		Usage   struct {
			InputTokens              int `json:"input_tokens"`
			OutputTokens             int `json:"output_tokens"`
			CacheReadInputTokens     int `json:"cache_read_input_tokens"`
			CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	}
	parseErr := json.Unmarshal(stdout.Bytes(), &res)
	status := http.StatusOK
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		status = http.StatusGatewayTimeout
		apiError(w, status, "timeout", fmt.Sprintf("claude не ответил за %s", s.timeout))
	case parseErr != nil || runErr != nil || res.IsError:
		status = http.StatusBadGateway
		msg := strings.TrimSpace(res.Result)
		if msg == "" {
			msg = strings.TrimSpace(firstN(stdout.String()+" "+stderr.String(), 400))
		}
		apiError(w, status, "upstream_error", "claude: "+msg)
	default:
		prompt := res.Usage.InputTokens + res.Usage.CacheReadInputTokens + res.Usage.CacheCreationInputTokens
		writeJSON(w, status, map[string]any{
			"id": fmt.Sprintf("chatcmpl-%d", time.Now().UnixNano()), "object": "chat.completion",
			"created": time.Now().Unix(), "model": model,
			"choices": []map[string]any{{"index": 0, "finish_reason": "stop",
				"message": map[string]string{"role": "assistant", "content": res.Result}}},
			"usage": map[string]int{"prompt_tokens": prompt, "completion_tokens": res.Usage.OutputTokens,
				"total_tokens": prompt + res.Usage.OutputTokens},
		})
	}
	log.Printf("chat model=%s status=%d took=%s out_tokens=%d", model, status,
		time.Since(started).Round(time.Millisecond), res.Usage.OutputTokens)
}

func firstN(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func apiError(w http.ResponseWriter, status int, typ, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"type": typ, "message": msg}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
