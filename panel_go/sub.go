package main

import (
	"crypto/md5"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/glebarez/go-sqlite"
)

const (
	dbPath   = "/etc/vpn-panel/panel.db"
	stateDir = "/etc/vpn-setup-state"
)

type SubInbound struct {
	Protocol string
	Remark   string
	Port     int
	Settings map[string]interface{}
}

func getUUID(input string) string {
	hasher := md5.New()
	hasher.Write([]byte(input))
	hash := hasher.Sum(nil)
	return fmt.Sprintf("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		hash[0], hash[1], hash[2], hash[3],
		hash[4], hash[5],
		hash[6], hash[7],
		hash[8], hash[9],
		hash[10], hash[11], hash[12], hash[13], hash[14], hash[15])
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
		var userID int
		err = db.QueryRow("SELECT id, username, password, protocol, is_active FROM users WHERE sub_path=? OR sub_path=?", token, "sub-"+token).
			Scan(&userID, &username, &password, &protocol, &isActive)

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

		// Read active inbounds from SQLite database
		ibRows, err := db.Query("SELECT i.protocol, i.remark, i.port, i.settings FROM inbounds i JOIN user_inbounds ui ON i.id = ui.inbound_id WHERE i.is_active=1 AND ui.user_id=?", userID)
		if err != nil {
			log.Printf("Inbounds query error: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		defer ibRows.Close()

		var activeInbounds []SubInbound
		for ibRows.Next() {
			var proto, remark, settingsJSON string
			var port int
			if err := ibRows.Scan(&proto, &remark, &port, &settingsJSON); err == nil {
				var settings map[string]interface{}
				_ = json.Unmarshal([]byte(settingsJSON), &settings)
				if settings == nil {
					settings = make(map[string]interface{})
				}
				activeInbounds = append(activeInbounds, SubInbound{
					Protocol: proto,
					Remark:   remark,
					Port:     port,
					Settings: settings,
				})
			}
		}

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
			fmt.Fprint(w, generateClashYAML(serverIP, username, password, protocol, activeInbounds))
		} else if isSingbox {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"singbox-%s.json\"", username))
			fmt.Fprint(w, generateSingboxJSON(serverIP, username, password, protocol, activeInbounds))
		} else {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			fmt.Fprint(w, generateBase64URIs(serverIP, username, password, protocol, activeInbounds))
		}
	})

	err := http.ListenAndServe(":8080", nil)
	if err != nil {
		log.Fatalf("Subscription server failed: %v", err)
	}
}

func generateClashYAML(serverIP string, username string, password string, protocol string, inbounds []SubInbound) string {
	var proxies []string
	var proxyNames []string

	for _, ib := range inbounds {
		if protocol != "all" && protocol != ib.Protocol {
			continue
		}

		switch ib.Protocol {
		case "hysteria2":
			obfsPassword, _ := ib.Settings["obfs_password"].(string)
			certCN, _ := ib.Settings["cert_cn"].(string)
			certPinHex, _ := ib.Settings["cert_pin_hex"].(string)
			proxies = append(proxies, fmt.Sprintf(`  - name: %s
    type: hysteria2
    server: %s
    port: %d
    password: %s
    obfs: salamander
    obfs-password: %s
    sni: %s
    fingerprint: %s
    skip-cert-verify: false`, ib.Remark, serverIP, ib.Port, password, obfsPassword, certCN, certPinHex))
			proxyNames = append(proxyNames, ib.Remark)

		case "mieru":
			proxies = append(proxies, fmt.Sprintf(`  - name: %s
    type: mieru
    server: %s
    port: %d
    username: %s
    password: %s
    transport: UDP`, ib.Remark, serverIP, ib.Port, username, password))
			proxyNames = append(proxyNames, ib.Remark)

		case "vless":
			uuid := getUUID(password)
			pubKey, _ := ib.Settings["public_key"].(string)
			shortId, _ := ib.Settings["short_id"].(string)
			sni, _ := ib.Settings["sni"].(string)
			transport := "xhttp"
			if t, ok := ib.Settings["transport"].(string); ok && t != "" {
				transport = t
			}
			proxyYaml := fmt.Sprintf(`  - name: %s
    type: vless
    server: %s
    port: %d
    uuid: %s
    udp: true
    tls: true
    servername: %s
    network: %s
    reality-opts:
      public-key: %s
      short-id: %s
    client-fingerprint: firefox`, ib.Remark, serverIP, ib.Port, uuid, sni, transport, pubKey, shortId)

			if transport == "xhttp" {
				path := "/xhttp"
				if p, ok := ib.Settings["path"].(string); ok && p != "" {
					path = p
				}
				proxyYaml += fmt.Sprintf(`
    xhttp-opts:
      path: %s
      mode: auto`, path)
			}

			proxies = append(proxies, proxyYaml)
			proxyNames = append(proxyNames, ib.Remark)

		case "trojan":
			proxies = append(proxies, fmt.Sprintf(`  - name: %s
    type: trojan
    server: %s
    port: %d
    password: %s
    udp: true
    sni: %s
    skip-cert-verify: true`, ib.Remark, serverIP, ib.Port, password, serverIP))
			proxyNames = append(proxyNames, ib.Remark)

		case "shadowsocks":
			cipher := "aes-256-gcm"
			if cs, ok := ib.Settings["cipher"].(string); ok && cs != "" {
				cipher = cs
			}
			proxies = append(proxies, fmt.Sprintf(`  - name: %s
    type: ss
    server: %s
    port: %d
    cipher: %s
    password: %s
    udp: true`, ib.Remark, serverIP, ib.Port, cipher, password))
			proxyNames = append(proxyNames, ib.Remark)
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

func generateSingboxJSON(serverIP string, username string, password string, protocol string, inbounds []SubInbound) string {
	type ObfsConfig struct {
		Type     string `json:"type"`
		Password string `json:"password"`
	}

	type UTLSConfig struct {
		Enabled     bool   `json:"enabled"`
		Fingerprint string `json:"fingerprint"`
	}

	type RealityConfig struct {
		Enabled   bool   `json:"enabled"`
		PublicKey string `json:"public_key"`
		ShortId   string `json:"short_id"`
	}

	type TLSConfig struct {
		Enabled              bool           `json:"enabled"`
		ServerName           string         `json:"server_name"`
		Insecure             bool           `json:"insecure"`
		PinnedPeerCertSHA256 []string       `json:"pinned_peer_cert_sha256,omitempty"`
		UTLS                 *UTLSConfig    `json:"utls,omitempty"`
		Reality              *RealityConfig `json:"reality,omitempty"`
	}

	type Outbound struct {
		Type       string      `json:"type"`
		Tag        string      `json:"tag"`
		Outbounds  []string    `json:"outbounds,omitempty"`
		Server     string      `json:"server,omitempty"`
		ServerPort int         `json:"server_port,omitempty"`
		Password   string      `json:"password,omitempty"`
		Username   string      `json:"username,omitempty"`
		UUID       string      `json:"uuid,omitempty"`
		Method     string      `json:"method,omitempty"`
		Transport  interface{} `json:"transport,omitempty"`
		Obfs       *ObfsConfig `json:"obfs,omitempty"`
		TLS        *TLSConfig  `json:"tls,omitempty"`
	}

	type Config struct {
		Outbounds []Outbound `json:"outbounds"`
	}

	var outbounds []Outbound
	var selectorOutbounds []string

	for _, ib := range inbounds {
		if protocol != "all" && protocol != ib.Protocol {
			continue
		}

		switch ib.Protocol {
		case "hysteria2":
			obfsPassword, _ := ib.Settings["obfs_password"].(string)
			certCN, _ := ib.Settings["cert_cn"].(string)
			certPinHex, _ := ib.Settings["cert_pin_hex"].(string)
			out := Outbound{
				Type:       "hysteria2",
				Tag:        ib.Remark,
				Server:     serverIP,
				ServerPort: ib.Port,
				Password:   password,
				Obfs: &ObfsConfig{
					Type:     "salamander",
					Password: obfsPassword,
				},
				TLS: &TLSConfig{
					Enabled:    true,
					ServerName: certCN,
					Insecure:   false,
				},
			}
			if certPinHex != "" {
				out.TLS.PinnedPeerCertSHA256 = []string{certPinHex}
			}
			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, ib.Remark)

		case "mieru":
			out := Outbound{
				Type:       "mieru",
				Tag:        ib.Remark,
				Server:     serverIP,
				ServerPort: ib.Port,
				Username:   username,
				Password:   password,
				Transport:  "TCP",
			}
			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, ib.Remark)

		case "vless":
			pubKey, _ := ib.Settings["public_key"].(string)
			shortId, _ := ib.Settings["short_id"].(string)
			sni, _ := ib.Settings["sni"].(string)
			transport := "xhttp"
			if t, ok := ib.Settings["transport"].(string); ok && t != "" {
				transport = t
			}

			out := Outbound{
				Type:       "vless",
				Tag:        ib.Remark,
				Server:     serverIP,
				ServerPort: ib.Port,
				UUID:       getUUID(password),
				TLS: &TLSConfig{
					Enabled:    true,
					ServerName: sni,
					UTLS: &UTLSConfig{
						Enabled:     true,
						Fingerprint: "firefox",
					},
					Reality: &RealityConfig{
						Enabled:   true,
						PublicKey: pubKey,
						ShortId:   shortId,
					},
				},
			}

			if transport == "xhttp" {
				path := "/xhttp"
				if p, ok := ib.Settings["path"].(string); ok && p != "" {
					path = p
				}
				out.Transport = map[string]interface{}{
					"type": "xhttp",
					"path": path,
				}
			} else if transport != "tcp" && transport != "" {
				// Fallback/support for other transports like ws
				path := "/ws"
				if p, ok := ib.Settings["path"].(string); ok && p != "" {
					path = p
				}
				out.Transport = map[string]interface{}{
					"type": transport,
					"path": path,
				}
			}

			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, ib.Remark)

		case "trojan":
			out := Outbound{
				Type:       "trojan",
				Tag:        ib.Remark,
				Server:     serverIP,
				ServerPort: ib.Port,
				Password:   password,
				TLS: &TLSConfig{
					Enabled:    true,
					ServerName: serverIP,
					Insecure:   true,
				},
			}
			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, ib.Remark)

		case "shadowsocks":
			cipher := "aes-256-gcm"
			if cs, ok := ib.Settings["cipher"].(string); ok && cs != "" {
				cipher = cs
			}
			out := Outbound{
				Type:       "shadowsocks",
				Tag:        ib.Remark,
				Server:     serverIP,
				ServerPort: ib.Port,
				Method:     cipher,
				Password:   password,
			}
			outbounds = append(outbounds, out)
			selectorOutbounds = append(selectorOutbounds, ib.Remark)
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

func generateBase64URIs(serverIP string, username string, password string, protocol string, inbounds []SubInbound) string {
	var uris []string

	for _, ib := range inbounds {
		if protocol != "all" && protocol != ib.Protocol {
			continue
		}

		switch ib.Protocol {
		case "hysteria2":
			obfsPassword, _ := ib.Settings["obfs_password"].(string)
			certCN, _ := ib.Settings["cert_cn"].(string)
			certPinHex, _ := ib.Settings["cert_pin_hex"].(string)
			uri := fmt.Sprintf("hysteria2://%s@%s:%d?obfs=salamander&obfs-password=%s&sni=%s", password, serverIP, ib.Port, obfsPassword, certCN)
			if certPinHex != "" {
				uri += "&pinSHA256=" + certPinHex
			}
			uri += "#" + ib.Remark
			uris = append(uris, uri)

		case "mieru":
			uri := fmt.Sprintf("mieru://%s:%d?username=%s&password=%s&network=udp#%s", serverIP, ib.Port, username, password, ib.Remark)
			uris = append(uris, uri)

		case "vless":
			pubKey, _ := ib.Settings["public_key"].(string)
			shortId, _ := ib.Settings["short_id"].(string)
			sni, _ := ib.Settings["sni"].(string)
			uuid := getUUID(password)
			transport := "xhttp"
			if t, ok := ib.Settings["transport"].(string); ok && t != "" {
				transport = t
			}
			uri := fmt.Sprintf("vless://%s@%s:%d?security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&type=%s",
				uuid, serverIP, ib.Port, sni, pubKey, shortId, transport)
			if transport == "xhttp" {
				path := "/xhttp"
				if p, ok := ib.Settings["path"].(string); ok && p != "" {
					path = p
				}
				uri += "&path=" + url.QueryEscape(path)
			}
			uri += "#" + ib.Remark
			uris = append(uris, uri)

		case "trojan":
			uri := fmt.Sprintf("trojan://%s@%s:%d?security=tls&sni=%s&allowInsecure=1#%s",
				password, serverIP, ib.Port, serverIP, ib.Remark)
			uris = append(uris, uri)

		case "shadowsocks":
			cipher := "aes-256-gcm"
			if cs, ok := ib.Settings["cipher"].(string); ok && cs != "" {
				cipher = cs
			}
			auth := base64.StdEncoding.EncodeToString([]byte(cipher + ":" + password))
			uri := fmt.Sprintf("ss://%s@%s:%d#%s", auth, serverIP, ib.Port, ib.Remark)
			uris = append(uris, uri)
		}
	}

	content := strings.Join(uris, "\n")
	return base64.StdEncoding.EncodeToString([]byte(content))
}
