package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "github.com/glebarez/go-sqlite"
)

const (
	dbPath   = "/etc/vpn-panel/panel.db"
	stateDir = "/etc/vpn-setup-state"
)

// Env Loader helper
func loadEnv(path string) map[string]string {
	data := make(map[string]string)
	content, err := os.ReadFile(path)
	if err != nil {
		return data
	}
	lines := strings.Split(string(content), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			val := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
			data[key] = val
		}
	}
	return data
}

func getMieruConfig() map[string]string {
	return loadEnv(filepath.Join(stateDir, "mieru.env"))
}

func getHysteria2Config() map[string]string {
	return loadEnv(filepath.Join(stateDir, "hysteria2.env"))
}

func getOldServerIP() string {
	urls := []string{"https://api.ipify.org", "https://ifconfig.me", "https://icanhazip.com"}
	for _, url := range urls {
		cmd := exec.Command("curl", "-s", "--max-time", "5", url)
		out, err := cmd.Output()
		if err == nil && len(strings.TrimSpace(string(out))) > 0 {
			return strings.TrimSpace(string(out))
		}
	}
	return "UNKNOWN"
}

var cachedServerIP = ""
var lastIPCheck = time.Time{}

func getServerIP() string {
	if cachedServerIP != "" && time.Since(lastIPCheck) < 10*time.Minute {
		return cachedServerIP
	}
	ip := getOldServerIP()
	if ip != "UNKNOWN" {
		cachedServerIP = ip
		lastIPCheck = time.Now()
	}
	return ip
}

func main() {
	log.Println("Starting dynamic subscription server on port :8080...")

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		token := strings.TrimPrefix(path, "/")
		token = strings.TrimPrefix(token, "sub/")
		token = strings.TrimSuffix(token, ".txt")
		token = strings.TrimSuffix(token, ".yaml")
		token = strings.TrimSuffix(token, ".json")

		if token == "" || token == "favicon.ico" {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}

		// Connect to SQLite database
		db, err := sql.Open("sqlite", dbPath)
		if err != nil {
			log.Printf("DB Open error: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		defer db.Close()

		var username, password, protocol string
		var isActive int
		err = db.QueryRow("SELECT username, password, protocol, is_active FROM users WHERE sub_path=? OR sub_path=?", token, "sub-"+token).
			Scan(&username, &password, &protocol, &isActive)

		if err != nil {
			if err == sql.ErrNoRows {
				// Fallback to static file serving from /var/www/html for installation defaults
				filePath := filepath.Join("/var/www/html", path)
				if info, err := os.Stat(filePath); err == nil && !info.IsDir() {
					http.ServeFile(w, r, filePath)
					return
				}
				log.Printf("Subscription token not found: %s", token)
				http.Error(w, "Profile Not Found", http.StatusNotFound)
			} else {
				log.Printf("DB query error: %v", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			}
			return
		}

		if isActive == 0 {
			http.Error(w, "Profile Disabled", http.StatusForbidden)
			return
		}

		// Read configuration environments
		h2 := getHysteria2Config()
		mieru := getMieruConfig()
		serverIP := getServerIP()

		// Detect target format: Clash, Sing-box or Base64
		userAgent := strings.ToLower(r.Header.Get("User-Agent"))
		flag := strings.ToLower(r.URL.Query().Get("flag"))
		targetType := strings.ToLower(r.URL.Query().Get("type"))

		isClash := strings.Contains(userAgent, "clash") || strings.Contains(userAgent, "mihomo") || flag == "clash" || targetType == "clash"
		isSingbox := strings.Contains(userAgent, "sing-box") || strings.Contains(userAgent, "karing") || flag == "sing-box" || flag == "singbox" || targetType == "singbox"

		if isClash {
			w.Header().Set("Content-Type", "text/yaml; charset=utf-8")
			w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"clash-%s.yaml\"", username))
			fmt.Fprint(w, generateClashYAML(serverIP, username, password, protocol, h2, mieru))
		} else if isSingbox {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"singbox-%s.json\"", username))
			fmt.Fprint(w, generateSingboxJSON(serverIP, username, password, protocol, h2, mieru))
		} else {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			fmt.Fprint(w, generateBase64URIs(serverIP, username, password, protocol, h2, mieru))
		}
	})

	err := http.ListenAndServe(":8080", nil)
	if err != nil {
		log.Fatalf("Subscription server failed: %v", err)
	}
}

func generateClashYAML(serverIP string, username string, password string, protocol string, h2 map[string]string, mieru map[string]string) string {
	var proxies []string
	var proxyNames []string

	if protocol == "all" || protocol == "hysteria2" {
		h2Port := h2["H2_PORT"]
		h2ObfsPass := h2["H2_OBFS_PASS"]
		h2CertCN := h2["H2_CERT_CN"]
		h2CertPinHex := h2["H2_CERT_PIN_HEX"]
		if h2Port != "" {
			proxies = append(proxies, fmt.Sprintf(`  - name: Hysteria2-Proxy
    type: hysteria2
    server: %s
    port: %s
    password: %s
    obfs: salamander
    obfs-password: %s
    sni: %s
    fingerprint: %s
    skip-cert-verify: false`, serverIP, h2Port, password, h2ObfsPass, h2CertCN, h2CertPinHex))
			proxyNames = append(proxyNames, "Hysteria2-Proxy")
		}
	}

	if protocol == "all" || protocol == "mieru" {
		mieruPort := mieru["MIERU_PORT"]
		if mieruPort != "" {
			proxies = append(proxies, fmt.Sprintf(`  - name: Mieru-Proxy
    type: mieru
    server: %s
    port: %s
    username: %s
    password: %s
    transport: UDP`, serverIP, mieruPort, username, password))
			proxyNames = append(proxyNames, "Mieru-Proxy")
		}
	}

	var namesYAML []string
	for _, n := range proxyNames {
		namesYAML = append(namesYAML, "      - "+n)
	}
	var namesAutoYAML []string
	for _, n := range proxyNames {
		namesAutoYAML = append(namesAutoYAML, "      - "+n)
	}

	template := `mixed-port: 7890
allow-lan: true
mode: rule
log-level: warning
ipv6: false

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "*.srv"
    - "*.msedge.net"
    - "stun.*.*"
    - "stun.*.*.*"
    - "+.stun.*.*"
    - "+.stun.*.*.*"
    - "+.stun.*.*.*.*"
    - "+.stun.*.*.*.*.*"
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip: true
    geoip-code: RU
    ipcidr:
      - 240.0.0.0/4

proxies:
%s

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Auto
%s
      - DIRECT

  - name: Auto
    type: url-test
    proxies:
%s
    url: http://cp.cloudflare.com/generate_204
    interval: 300
    tolerance: 50

rules:
  - GEOIP,private,DIRECT,no-resolve
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - DOMAIN-KEYWORD,localhost,DIRECT
  - GEOIP,RU,DIRECT
  - GEOIP,BY,DIRECT
  - GEOIP,KZ,DIRECT
  - DOMAIN-SUFFIX,yandex.ru,DIRECT
  - DOMAIN-SUFFIX,yandex.com,DIRECT
  - DOMAIN-SUFFIX,ya.ru,DIRECT
  - DOMAIN-SUFFIX,yandex.net,DIRECT
  - DOMAIN-SUFFIX,mail.ru,DIRECT
  - DOMAIN-SUFFIX,vk.com,DIRECT
  - DOMAIN-SUFFIX,ok.ru,DIRECT
  - DOMAIN-SUFFIX,gosuslugi.ru,DIRECT
  - DOMAIN-SUFFIX,tinkoff.ru,DIRECT
  - DOMAIN-SUFFIX,sberbank.ru,DIRECT
  - MATCH,Proxy
`
	return fmt.Sprintf(template, strings.Join(proxies, "\n"), strings.Join(namesYAML, "\n"), strings.Join(namesAutoYAML, "\n"))
}

func generateSingboxJSON(serverIP string, username string, password string, protocol string, h2 map[string]string, mieru map[string]string) string {
	type ObfsConfig struct {
		Type     string `json:"type"`
		Password string `json:"password"`
	}

	type TLSConfig struct {
		Enabled              bool     `json:"enabled"`
		ServerName           string   `json:"server_name"`
		Insecure             bool     `json:"insecure"`
		PinnedPeerCertSHA256 []string `json:"pinned_peer_cert_sha256,omitempty"`
	}

	type Outbound struct {
		Type       string      `json:"type"`
		Tag        string      `json:"tag"`
		Outbounds  []string    `json:"outbounds,omitempty"`
		Server     string      `json:"server,omitempty"`
		ServerPort int         `json:"server_port,omitempty"`
		Password   string      `json:"password,omitempty"`
		Username   string      `json:"username,omitempty"`
		Transport  string      `json:"transport,omitempty"`
		Obfs       *ObfsConfig `json:"obfs,omitempty"`
		TLS        *TLSConfig  `json:"tls,omitempty"`
	}

	type Config struct {
		Outbounds []Outbound `json:"outbounds"`
	}

	var outbounds []Outbound
	var selectorOutbounds []string

	if protocol == "all" || protocol == "hysteria2" {
		h2PortStr := h2["H2_PORT"]
		h2Port, _ := strconv.Atoi(h2PortStr)
		h2ObfsPass := h2["H2_OBFS_PASS"]
		h2CertCN := h2["H2_CERT_CN"]
		h2CertPinHex := h2["H2_CERT_PIN_HEX"]

		if h2Port > 0 {
			out := Outbound{
				Type:       "hysteria2",
				Tag:        "Hysteria2-Proxy",
				Server:     serverIP,
				ServerPort: h2Port,
				Password:   password,
				Obfs: &ObfsConfig{
					Type:     "salamander",
					Password: h2ObfsPass,
				},
				TLS: &TLSConfig{
					Enabled:    true,
					ServerName: h2CertCN,
					Insecure:   false,
				},
			}
			if h2CertPinHex != "" {
				out.TLS.PinnedPeerCertSHA256 = []string{h2CertPinHex}
			}
			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, "Hysteria2-Proxy")
		}
	}

	if protocol == "all" || protocol == "mieru" {
		mieruPortStr := mieru["MIERU_PORT"]
		mieruPort, _ := strconv.Atoi(mieruPortStr)

		if mieruPort > 0 {
			out := Outbound{
				Type:       "mieru",
				Tag:        "Mieru-Proxy",
				Server:     serverIP,
				ServerPort: mieruPort,
				Username:   username,
				Password:   password,
				Transport:  "TCP",
			}
			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, "Mieru-Proxy")
		}
	}

	selectorOutbounds = append(selectorOutbounds, "direct")

	selector := Outbound{
		Type:      "selector",
		Tag:       "PROXY",
		Outbounds: selectorOutbounds,
	}

	finalOutbounds := []Outbound{selector}
	finalOutbounds = append(finalOutbounds, outbounds...)
	finalOutbounds = append(finalOutbounds, Outbound{Type: "direct", Tag: "direct"})

	cfg := Config{Outbounds: finalOutbounds}
	bytes, _ := json.MarshalIndent(cfg, "", "  ")
	return string(bytes)
}

func generateBase64URIs(serverIP string, username string, password string, protocol string, h2 map[string]string, mieru map[string]string) string {
	var uris []string

	if protocol == "all" || protocol == "hysteria2" {
		h2Port := h2["H2_PORT"]
		h2ObfsPass := h2["H2_OBFS_PASS"]
		h2CertCN := h2["H2_CERT_CN"]
		h2CertPinHex := h2["H2_CERT_PIN_HEX"]
		if h2Port != "" {
			uri := fmt.Sprintf("hysteria2://%s@%s:%s?obfs=salamander&obfs-password=%s&sni=%s", password, serverIP, h2Port, h2ObfsPass, h2CertCN)
			if h2CertPinHex != "" {
				uri += "&pinSHA256=" + h2CertPinHex
			}
			uri += "#Hysteria2-Proxy"
			uris = append(uris, uri)
		}
	}

	if protocol == "all" || protocol == "mieru" {
		mieruPort := mieru["MIERU_PORT"]
		if mieruPort != "" {
			uri := fmt.Sprintf("mieru://%s:%s?username=%s&password=%s&network=udp#Mieru-Proxy", serverIP, mieruPort, username, password)
			uris = append(uris, uri)
		}
	}

	content := strings.Join(uris, "\n")
	return base64.StdEncoding.EncodeToString([]byte(content))
}
