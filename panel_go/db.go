package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	_ "github.com/glebarez/go-sqlite"
)

var db *sql.DB

const (
	dbPath    = "/etc/vpn-panel/panel.db"
	stateDir  = "/etc/vpn-setup-state"
	confPath  = "/etc/vpn-setup-state/vpn-users.conf"
	htmlDir   = "/var/www/html"
)

// Data Models
type Admin struct {
	ID           int       `json:"id"`
	Username     string    `json:"username"`
	PasswordHash string    `json:"-"`
	CreatedAt    string    `json:"created_at"`
}

type User struct {
	ID               int    `json:"id"`
	Username         string `json:"username"`
	Password         string `json:"password"`
	ExpireDate       string `json:"expire_date"`
	TrafficLimitGB   int64  `json:"traffic_limit_gb"`
	SpeedLimitMbps   int64  `json:"speed_limit_mbps"`
	Protocol         string `json:"protocol"`
	SubPath          string `json:"sub_path"`
	CreatedAt        string `json:"created_at"`
	IsActive         int    `json:"is_active"`
	UsedTrafficBytes int64  `json:"used_traffic_bytes"`
	RouteWarp        int    `json:"route_warp"`

	// Helper fields for template rendering
	Expired    bool   `json:"_expired"`
	ExpireFmt  string `json:"_expire_fmt"`
	TrafficFmt string `json:"_traffic_fmt"`
	SpeedFmt   string `json:"_speed_fmt"`
	H2Uri      string `json:"h2_uri"`
	MieruUri   string `json:"mieru_uri"`
	VlessUri   string `json:"vless_uri"`
	TrojanUri  string `json:"trojan_uri"`
	SsUri      string `json:"ss_uri"`
	Pct        int    `json:"pct"`
}

type TrafficHistory struct {
	ID        int    `json:"id"`
	Timestamp string `json:"timestamp"`
	RxBytes   int64  `json:"rx_bytes"`
	TxBytes   int64  `json:"tx_bytes"`
}

// Database Initialization
func initDB() {
	dir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		log.Printf("Warning: failed to create DB directory: %v", err)
	}

	var err error
	db, err = sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatalf("Failed to open SQLite database: %v", err)
	}

	db.SetMaxOpenConns(1) // Best for SQLite writes to avoid locked database errors
	db.SetConnMaxLifetime(time.Hour)

	_, err = db.Exec("PRAGMA journal_mode=WAL;")
	if err != nil {
		log.Printf("Warning: failed to set WAL mode: %v", err)
	}

	// Create tables
	queries := []string{
		`CREATE TABLE IF NOT EXISTS admin (
			id INTEGER PRIMARY KEY,
			username TEXT UNIQUE NOT NULL,
			password_hash TEXT NOT NULL,
			created_at TEXT DEFAULT (datetime('now'))
		);`,
		`CREATE TABLE IF NOT EXISTS users (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			username TEXT UNIQUE NOT NULL,
			password TEXT NOT NULL,
			expire_date TEXT DEFAULT 'never',
			traffic_limit_gb INTEGER DEFAULT 0,
			speed_limit_mbps INTEGER DEFAULT 0,
			protocol TEXT DEFAULT 'all',
			sub_path TEXT,
			created_at TEXT DEFAULT (datetime('now')),
			is_active INTEGER DEFAULT 1,
			used_traffic_bytes INTEGER DEFAULT 0
		);`,
		`CREATE TABLE IF NOT EXISTS traffic_history (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			timestamp TEXT NOT NULL DEFAULT (datetime('now')),
			rx_bytes INTEGER NOT NULL,
			tx_bytes INTEGER NOT NULL
		);`,
	}

	for _, q := range queries {
		if _, err := db.Exec(q); err != nil {
			log.Fatalf("Failed to execute SQL: %v\nQuery: %s", err, q)
		}
	}

	// Set permissions on database file
	if err := os.Chmod(dbPath, 0600); err != nil {
		log.Printf("Warning: failed to set DB file permissions: %v", err)
	}

	// Migrations: ensure columns exist
	migrateUsedTrafficBytes()
	migrateRouteWarp()
}

func migrateUsedTrafficBytes() {
	rows, err := db.Query("PRAGMA table_info(users)")
	if err != nil {
		log.Printf("Warning: failed to check table info: %v", err)
		return
	}
	defer rows.Close()

	hasColumn := false
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dfltValue interface{}
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dfltValue, &pk); err != nil {
			continue
		}
		if name == "used_traffic_bytes" {
			hasColumn = true
			break
		}
	}

	if !hasColumn {
		log.Println("Migrating database: adding used_traffic_bytes column to users table...")
		_, err = db.Exec("ALTER TABLE users ADD COLUMN used_traffic_bytes INTEGER DEFAULT 0")
		if err != nil {
			log.Printf("Warning: migration failed: %v", err)
		} else {
			log.Println("Migration successful.")
		}
	}
}

func migrateRouteWarp() {
	rows, err := db.Query("PRAGMA table_info(users)")
	if err != nil {
		log.Printf("Warning: failed to check table info: %v", err)
		return
	}
	defer rows.Close()

	hasColumn := false
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dfltValue interface{}
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dfltValue, &pk); err == nil {
			if name == "route_warp" {
				hasColumn = true
				break
			}
		}
	}

	if !hasColumn {
		log.Println("Migrating database: adding route_warp column to users table...")
		_, err = db.Exec("ALTER TABLE users ADD COLUMN route_warp INTEGER DEFAULT 0")
		if err != nil {
			log.Printf("Warning: migration failed: %v", err)
		} else {
			log.Println("Migration successful.")
		}
	}
}

// Configs and Env Parsers
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

func getSubscriptionPaths() map[string]string {
	return loadEnv(filepath.Join(stateDir, "subscription_path"))
}

// Server Specs and IP
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

// Cached server IP to avoid redundant outgoing calls
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

type ServerSpecs struct {
	RAM     int      `json:"ram_mb"`
	Load    []string `json:"load"`
	CPUCores int     `json:"cpu_cores"`
	Kernel  string   `json:"kernel"`
	Uptime  string   `json:"uptime"`
}

func getServerSpecs() ServerSpecs {
	specs := ServerSpecs{
		CPUCores: runtime.NumCPU(),
	}

	// RAM MB
	if content, err := os.ReadFile("/proc/meminfo"); err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			if strings.Contains(line, "MemTotal") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					if total, err := strconv.Atoi(fields[1]); err == nil {
						specs.RAM = total / 1024
					}
				}
				break
			}
		}
	} else if runtime.GOOS == "darwin" {
		// macOS fallback
		cmd := exec.Command("sysctl", "-n", "hw.memsize")
		if out, err := cmd.Output(); err == nil {
			if bytes, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64); err == nil {
				specs.RAM = int(bytes / (1024 * 1024))
			}
		}
	}

	// Load Avg
	if content, err := os.ReadFile("/proc/loadavg"); err == nil {
		fields := strings.Fields(string(content))
		if len(fields) >= 3 {
			specs.Load = fields[:3]
		}
	} else if runtime.GOOS == "darwin" {
		cmd := exec.Command("sysctl", "-n", "vm.loadavg")
		if out, err := cmd.Output(); err == nil {
			cleaned := strings.ReplaceAll(strings.ReplaceAll(string(out), "{", ""), "}", "")
			specs.Load = strings.Fields(cleaned)[:3]
		}
	}

	if len(specs.Load) == 0 {
		specs.Load = []string{"0.00", "0.00", "0.00"}
	}

	// Kernel
	specs.Kernel = "unknown"
	cmd := exec.Command("uname", "-r")
	if out, err := cmd.Output(); err == nil {
		specs.Kernel = strings.TrimSpace(string(out))
	}

	// Uptime
	specs.Uptime = "unknown"
	var uptimeSec float64 = 0
	if content, err := os.ReadFile("/proc/uptime"); err == nil {
		fields := strings.Fields(string(content))
		if len(fields) > 0 {
			if sec, err := strconv.ParseFloat(fields[0], 64); err == nil {
				uptimeSec = sec
			}
		}
	} else if runtime.GOOS == "darwin" {
		cmd := exec.Command("sysctl", "-n", "kern.boottime")
		if out, err := cmd.Output(); err == nil {
			re := regexp.MustCompile(`sec = (\d+)`)
			matches := re.FindStringSubmatch(string(out))
			if len(matches) > 1 {
				if sec, err := strconv.ParseInt(matches[1], 10, 64); err == nil {
					uptimeSec = float64(time.Now().Unix() - sec)
				}
			}
		}
	}

	if uptimeSec > 0 {
		days := int(uptimeSec / 86400)
		hours := int((int(uptimeSec) % 86400) / 3600)
		minutes := int((int(uptimeSec) % 3600) / 60)
		var parts []string
		if days > 0 {
			parts = append(parts, fmt.Sprintf("%d дн.", days))
		}
		if hours > 0 {
			parts = append(parts, fmt.Sprintf("%d ч.", hours))
		}
		if minutes > 0 || len(parts) == 0 {
			parts = append(parts, fmt.Sprintf("%d мин.", minutes))
		}
		specs.Uptime = strings.Join(parts, " ")
	}

	return specs
}

// User Sync logic
func syncUserToConf(u User) {
	// Read existing conf
	var lines []string
	if content, err := os.ReadFile(confPath); err == nil {
		for _, line := range strings.Split(string(content), "\n") {
			if strings.TrimSpace(line) != "" {
				lines = append(lines, strings.TrimSpace(line))
			}
		}
	}

	prefix := ""
	if u.IsActive != 1 {
		prefix = "DISABLED_"
	}

	newLine := fmt.Sprintf("%s%s|%s|%s|%d|%d|%s|%d",
		prefix, u.Username, u.Password, u.ExpireDate, u.TrafficLimitGB, u.SpeedLimitMbps, u.Protocol, u.RouteWarp)

	updated := false
	for i, line := range lines {
		if strings.HasPrefix(line, u.Username+"|") || strings.HasPrefix(line, "DISABLED_"+u.Username+"|") {
			lines[i] = newLine
			updated = true
			break
		}
	}
	if !updated {
		lines = append(lines, newLine)
	}

	if err := os.MkdirAll(stateDir, 0700); err == nil {
		err = os.WriteFile(confPath, []byte(strings.Join(lines, "\n")+"\n"), 0600)
		if err != nil {
			log.Printf("Error writing conf: %v", err)
		}
	}

}

func removeUserFromConf(username string, subPath string) {
	var lines []string
	if content, err := os.ReadFile(confPath); err == nil {
		for _, line := range strings.Split(string(content), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, username+"|") && !strings.HasPrefix(line, "DISABLED_"+username+"|") {
				lines = append(lines, line)
			}
		}
	}

	if len(lines) > 0 {
		_ = os.WriteFile(confPath, []byte(strings.Join(lines, "\n")+"\n"), 0600)
	} else {
		_ = os.WriteFile(confPath, []byte(""), 0600)
	}
}

func updateMieruUsers() {
	mieru := getMieruConfig()
	portStr := mieru["MIERU_PORT"]
	if portStr == "" {
		return
	}

	port, _ := strconv.Atoi(portStr)
	udpPort, _ := strconv.Atoi(mieru["MIERU_UDP_PORT"])
	if udpPort == 0 {
		udpPort = port
	}

	rows, err := db.Query("SELECT username, password FROM users WHERE is_active=1 AND (protocol='all' OR protocol='mieru')")
	if err != nil {
		log.Printf("Error fetching users for Mieru: %v", err)
		return
	}
	defer rows.Close()

	type MieruUserJSON struct {
		Name     string `json:"name"`
		Password string `json:"password"`
	}
	usersJSON := []MieruUserJSON{}
	for rows.Next() {
		var name, pass string
		if err := rows.Scan(&name, &pass); err == nil {
			usersJSON = append(usersJSON, MieruUserJSON{Name: name, Password: pass})
		}
	}

	// Mieru JSON Config Structure
	type PortBinding struct {
		Port     int    `json:"port"`
		Protocol string `json:"protocol"`
	}
	type MieruConfig struct {
		PortBindings []PortBinding    `json:"portBindings"`
		Users        []MieruUserJSON  `json:"users"`
		LoggingLevel string           `json:"loggingLevel"`
		MTU          int              `json:"mtu"`
	}

	config := MieruConfig{
		PortBindings: []PortBinding{
			{Port: port, Protocol: "TCP"},
			{Port: udpPort, Protocol: "UDP"},
		},
		Users:        usersJSON,
		LoggingLevel: "WARN",
		MTU:          1400,
	}

	// Marshal config
	configPath := "/tmp/mita_panel_config.json"
	configBytes, err := json.Marshal(config)
	if err != nil {
		log.Printf("Error marshalling Mieru config: %v", err)
		return
	}

	if err := os.WriteFile(configPath, configBytes, 0600); err != nil {
		log.Printf("Error writing temporary Mieru config: %v", err)
		return
	}

	// Apply configuration using Mieru CLI
	_ = exec.Command("mita", "apply", "config", configPath).Run()
	_ = os.Remove(configPath)

	// Restart Mieru (mita) systemd service
	_ = exec.Command("systemctl", "restart", "mita").Run()
}

func updateHysteriaUsers() {
	h2 := getHysteria2Config()
	portStr := h2["H2_PORT"]
	if portStr == "" {
		return
	}

	rows, err := db.Query("SELECT username, password, route_warp FROM users WHERE is_active=1 AND (protocol='all' OR protocol='hysteria2')")
	if err != nil {
		log.Printf("Error fetching users for Hysteria2: %v", err)
		return
	}
	defer rows.Close()

	yamlBuilder := strings.Builder{}
	yamlBuilder.WriteString(fmt.Sprintf("listen: :%s\n", portStr))
	yamlBuilder.WriteString("tls:\n  cert: /etc/hysteria/certs/server.crt\n  key:  /etc/hysteria/certs/server.key\n")
	yamlBuilder.WriteString("auth:\n  type: userpass\n  userpass:\n")

	var warpUsers []string
	hasUsers := false
	for rows.Next() {
		var name, pass string
		var warp int
		if err := rows.Scan(&name, &pass, &warp); err == nil {
			yamlBuilder.WriteString(fmt.Sprintf("    %s: %s\n", name, pass))
			hasUsers = true
			if warp == 1 {
				warpUsers = append(warpUsers, name)
			}
		}
	}

	if !hasUsers {
		yamlBuilder.WriteString(fmt.Sprintf("    admin: %s\n", getOptString(h2, "H2_PASS", "dummy_pass")))
	}

	// Add outbounds config
	yamlBuilder.WriteString(`outbounds:
  - name: direct
    type: direct
  - name: warp
    type: direct
    bind: 172.16.0.2

acl:
  file: /etc/hysteria/acl.txt
`)

	yamlBuilder.WriteString(fmt.Sprintf(`obfs:
  type: salamander
  salamander:
    password: %s
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
stats:
  bind: 127.0.0.1:25413
  secret: hysteria_stats_secret
`, getOptString(h2, "H2_OBFS_PASS", "")))

	configPath := "/etc/hysteria/config.yaml"
	_ = os.MkdirAll(filepath.Dir(configPath), 0755)
	if err := os.WriteFile(configPath, []byte(yamlBuilder.String()), 0600); err != nil {
		log.Printf("Error writing Hysteria2 config: %v", err)
		return
	}
	_ = exec.Command("chown", "hysteria:hysteria", configPath).Run()

	// Generate and write ACL file
	aclBuilder := strings.Builder{}
	if len(warpUsers) > 0 {
		var quoted []string
		for _, u := range warpUsers {
			quoted = append(quoted, fmt.Sprintf(`"%s"`, u))
		}
		aclBuilder.WriteString(fmt.Sprintf("warp auth(%s)\n", strings.Join(quoted, ", ")))
	}
	aclBuilder.WriteString("direct all\n")

	aclPath := "/etc/hysteria/acl.txt"
	if err := os.WriteFile(aclPath, []byte(aclBuilder.String()), 0644); err != nil {
		log.Printf("Error writing Hysteria2 ACL: %v", err)
		return
	}
	_ = exec.Command("chown", "hysteria:hysteria", aclPath).Run()

	_ = exec.Command("systemctl", "restart", "hysteria-server").Run()
	updateSingboxUsers()
}

func syncAllUsersToConfigs() {
	rows, err := db.Query("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users")
	if err != nil {
		log.Printf("Error fetching all users: %v", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var u User
		err := rows.Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		if err == nil {
			syncUserToConf(u)
		}
	}

	updateMieruUsers()
	updateHysteriaUsers()
}

// Helpers
func getOptString(m map[string]string, key, dflt string) string {
	if val, ok := m[key]; ok {
		return val
	}
	return dflt
}

type SBUser struct {
	Name     string `json:"name,omitempty"`
	UUID     string `json:"uuid,omitempty"`
	Password string `json:"password,omitempty"`
}

type SBRealityHandshake struct {
	Server     string `json:"server"`
	ServerPort int    `json:"server_port"`
}

type SBReality struct {
	Enabled    bool               `json:"enabled"`
	Handshake  SBRealityHandshake `json:"handshake"`
	PrivateKey string             `json:"private_key"`
	ShortId    []string           `json:"short_id"`
}

type SBTLS struct {
	Enabled    bool       `json:"enabled"`
	ServerName string     `json:"server_name,omitempty"`
	Reality    *SBReality `json:"reality,omitempty"`
	CertPath   string     `json:"cert_path,omitempty"`
	KeyPath    string     `json:"key_path,omitempty"`
}

type SBInbound struct {
	Type       string   `json:"type"`
	Tag        string   `json:"tag"`
	Listen     string   `json:"listen"`
	ListenPort int      `json:"listen_port"`
	Method     string   `json:"method,omitempty"`
	Users      []SBUser `json:"users,omitempty"`
	TLS        *SBTLS   `json:"tls,omitempty"`
}

type SBOutbound struct {
	Type         string `json:"type"`
	Tag          string `json:"tag"`
	LocalAddress string `json:"local_address,omitempty"`
}

type SBRule struct {
	User     []string `json:"user,omitempty"`
	Outbound string   `json:"outbound"`
}

type SBRoute struct {
	Rules []SBRule `json:"rules"`
	Final string   `json:"final"`
}

type SBConfig struct {
	Inbounds  []SBInbound  `json:"inbounds"`
	Outbounds []SBOutbound `json:"outbounds"`
	Route     SBRoute      `json:"route"`
}

func updateSingboxUsers() {
	sb := getSingboxConfig()
	vlessPortStr := sb["SB_VLESS_PORT"]
	if vlessPortStr == "" {
		return
	}
	vlessPort, _ := strconv.Atoi(vlessPortStr)
	trojanPort, _ := strconv.Atoi(sb["SB_TROJAN_PORT"])
	ssPort, _ := strconv.Atoi(sb["SB_SS_PORT"])

	rows, err := db.Query("SELECT username, password, protocol, route_warp FROM users WHERE is_active=1")
	if err != nil {
		log.Printf("Error querying users for Sing-box: %v", err)
		return
	}
	defer rows.Close()

	var vlessUsers []SBUser
	var trojanUsers []SBUser
	var ssUsers []SBUser
	var warpUsernames []string

	for rows.Next() {
		var name, pass, proto string
		var warp int
		if err := rows.Scan(&name, &pass, &proto, &warp); err == nil {
			if warp == 1 {
				warpUsernames = append(warpUsernames, name)
			}
			if proto == "all" || proto == "vless" {
				vlessUsers = append(vlessUsers, SBUser{Name: name, UUID: getUUID(pass)})
			}
			if proto == "all" || proto == "trojan" {
				trojanUsers = append(trojanUsers, SBUser{Name: name, Password: pass})
			}
			if proto == "all" || proto == "shadowsocks" {
				ssUsers = append(ssUsers, SBUser{Name: name, Password: pass})
			}
		}
	}

	var inbounds []SBInbound

	// VLESS Reality Inbound
	if vlessPort > 0 {
		inbounds = append(inbounds, SBInbound{
			Type:       "vless",
			Tag:        "vless-in",
			Listen:     "::",
			ListenPort: vlessPort,
			Users:      vlessUsers,
			TLS: &SBTLS{
				Enabled:    true,
				ServerName: sb["SB_REALITY_SNI"],
				Reality: &SBReality{
					Enabled: true,
					Handshake: SBRealityHandshake{
						Server:     sb["SB_REALITY_SNI"],
						ServerPort: 443,
					},
					PrivateKey: sb["SB_REALITY_PRIV_KEY"],
					ShortId:    []string{sb["SB_REALITY_SHORT_ID"]},
				},
			},
		})
	}

	// Trojan Inbound (uses self-signed cert from hysteria)
	if trojanPort > 0 {
		inbounds = append(inbounds, SBInbound{
			Type:       "trojan",
			Tag:        "trojan-in",
			Listen:     "::",
			ListenPort: trojanPort,
			Users:      trojanUsers,
			TLS: &SBTLS{
				Enabled:  true,
				CertPath: "/etc/hysteria/certs/server.crt",
				KeyPath:  "/etc/hysteria/certs/server.key",
			},
		})
	}

	// Shadowsocks Inbound
	if ssPort > 0 {
		inbounds = append(inbounds, SBInbound{
			Type:       "shadowsocks",
			Tag:        "shadowsocks-in",
			Listen:     "::",
			ListenPort: ssPort,
			Method:     "aes-256-gcm",
			Users:      ssUsers,
		})
	}

	outbounds := []SBOutbound{
		{Type: "direct", Tag: "direct-out"},
		{Type: "direct", Tag: "warp-out", LocalAddress: "172.16.0.2"},
	}

	var rules []SBRule
	if len(warpUsernames) > 0 {
		rules = append(rules, SBRule{
			User:     warpUsernames,
			Outbound: "warp-out",
		})
	}

	cfg := SBConfig{
		Inbounds:  inbounds,
		Outbounds: outbounds,
		Route: SBRoute{
			Rules: rules,
			Final: "direct-out",
		},
	}

	configPath := "/etc/sing-box/config.json"
	_ = os.MkdirAll(filepath.Dir(configPath), 0755)
	
	bytes, err := json.MarshalIndent(cfg, "", "  ")
	if err == nil {
		_ = os.WriteFile(configPath, bytes, 0600)
	}

	_ = exec.Command("systemctl", "restart", "sing-box").Run()
}
