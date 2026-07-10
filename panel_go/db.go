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

type Inbound struct {
	ID       int    `json:"id"`
	Remark   string `json:"remark"`
	Protocol string `json:"protocol"`
	Port     int    `json:"port"`
	Settings string `json:"settings"`
	IsActive int    `json:"is_active"`
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
		`CREATE TABLE IF NOT EXISTS user_inbounds (
			user_id INTEGER NOT NULL,
			inbound_id INTEGER NOT NULL,
			PRIMARY KEY (user_id, inbound_id)
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
	migrateInbounds()
	migrateUserInbounds()
}

func migrateUserInbounds() {
	// If the user_inbounds table was just created, it might be empty while users and inbounds exist.
	// To preserve existing access, we map all existing users to all existing inbounds if user_inbounds is totally empty
	// but users exist.
	var count int
	_ = db.QueryRow("SELECT COUNT(*) FROM user_inbounds").Scan(&count)
	if count == 0 {
		log.Println("Migrating database: populating user_inbounds for existing users...")
		_, err := db.Exec("INSERT INTO user_inbounds (user_id, inbound_id) SELECT u.id, i.id FROM users u CROSS JOIN inbounds i")
		if err != nil {
			log.Printf("Warning: user_inbounds migration failed: %v", err)
		} else {
			log.Println("user_inbounds migration successful.")
		}
	}
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
	var port int
	var settingsJSON string
	err := db.QueryRow("SELECT port, settings FROM inbounds WHERE protocol='mieru' AND is_active=1 LIMIT 1").Scan(&port, &settingsJSON)
	if err != nil {
		_ = exec.Command("systemctl", "stop", "mita").Run()
		return
	}

	udpPort := port

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
	configPath := "/etc/mita/config.json"
	configBytes, err := json.Marshal(config)
	if err != nil {
		log.Printf("Error marshalling Mieru config: %v", err)
		return
	}

	if err := os.WriteFile(configPath, configBytes, 0600); err != nil {
		log.Printf("Error writing Mieru config: %v", err)
		return
	}

	// Ensure correct ownership for systemd mita user
	_ = exec.Command("chown", "mita:mita", configPath).Run()

	// Restart Mieru (mita) systemd service
	_ = exec.Command("systemctl", "restart", "mita").Run()
}

func updateHysteriaUsers() {
	var port int
	var settingsJSON string
	err := db.QueryRow("SELECT port, settings FROM inbounds WHERE protocol='hysteria2' AND is_active=1 LIMIT 1").Scan(&port, &settingsJSON)
	if err != nil {
		_ = exec.Command("systemctl", "stop", "hysteria-server").Run()
		return
	}

	var settings map[string]interface{}
	_ = json.Unmarshal([]byte(settingsJSON), &settings)
	if settings == nil {
		settings = make(map[string]interface{})
	}

	rows, err := db.Query("SELECT username, password, route_warp FROM users WHERE is_active=1 AND (protocol='all' OR protocol='hysteria2')")
	if err != nil {
		log.Printf("Error fetching users for Hysteria2: %v", err)
		return
	}
	defer rows.Close()

	yamlBuilder := strings.Builder{}
	yamlBuilder.WriteString(fmt.Sprintf("listen: :%d\n", port))
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
		yamlBuilder.WriteString("    admin: dummy_pass\n")
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

	obfsPassword, _ := settings["obfs_password"].(string)
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
`, obfsPassword))

	configPath := "/etc/hysteria/config.yaml"
	_ = os.MkdirAll(filepath.Dir(configPath), 0755)
	if err := os.WriteFile(configPath, []byte(yamlBuilder.String()), 0600); err != nil {
		log.Printf("Error writing Hysteria2 config: %v", err)
		return
	}
	_ = exec.Command("chown", "hysteria:hysteria", configPath).Run()

	// Generate and write ACL file (Hysteria 2 uses direct(all) syntax)
	aclBuilder := strings.Builder{}
	aclBuilder.WriteString("direct(all)\n")

	aclPath := "/etc/hysteria/acl.txt"
	if err := os.WriteFile(aclPath, []byte(aclBuilder.String()), 0644); err != nil {
		log.Printf("Error writing Hysteria2 ACL: %v", err)
		return
	}
	_ = exec.Command("chown", "hysteria:hysteria", aclPath).Run()

	_ = exec.Command("systemctl", "restart", "hysteria-server").Run()
	updateXrayConfig()
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
	Method   string `json:"method,omitempty"`
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

type SBSniff struct {
	Enabled             bool `json:"enabled"`
	OverrideDestination bool `json:"override_destination"`
}

type SBInbound struct {
	Type       string   `json:"type"`
	Tag        string   `json:"tag"`
	Listen     string   `json:"listen"`
	ListenPort int      `json:"listen_port"`
	Method     string   `json:"method,omitempty"`
	Users      []SBUser `json:"users,omitempty"`
	TLS        *SBTLS   `json:"tls,omitempty"`
	Sniff      *SBSniff `json:"sniff,omitempty"`
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

type XRLog struct {
	Loglevel string `json:"loglevel"`
}

type XRClient struct {
	ID       string `json:"id,omitempty"`
	Password string `json:"password,omitempty"`
	Method   string `json:"method,omitempty"`
	Email    string `json:"email"`
	Flow     string `json:"flow,omitempty"`
}

type XRInboundSettings struct {
	Decryption string     `json:"decryption,omitempty"`
	Clients    []XRClient `json:"clients,omitempty"`
	Method     string     `json:"method,omitempty"`
	Password   string     `json:"password,omitempty"`
	Network    string     `json:"network,omitempty"`
}

type XRRealitySettings struct {
	Show        bool     `json:"show"`
	Dest        string   `json:"dest"`
	Xver        int      `json:"xver"`
	ServerNames []string `json:"serverNames"`
	PrivateKey  string   `json:"privateKey"`
	ShortIds    []string `json:"shortIds"`
}

type XRTlsCert struct {
	CertificateFile string `json:"certificateFile"`
	KeyFile         string `json:"keyFile"`
}

type XRTlsSettings struct {
	ServerName   string      `json:"serverName,omitempty"`
	Certificates []XRTlsCert `json:"certificates,omitempty"`
}

type XRXhttpSettings struct {
	Mode string `json:"mode"`
	Path string `json:"path"`
}

type XRStreamSettings struct {
	Network         string             `json:"network,omitempty"`
	Security        string             `json:"security,omitempty"`
	RealitySettings *XRRealitySettings `json:"realitySettings,omitempty"`
	TlsSettings     *XRTlsSettings     `json:"tlsSettings,omitempty"`
	XhttpSettings   *XRXhttpSettings   `json:"xhttpSettings,omitempty"`
}

type XRSniffing struct {
	Enabled      bool     `json:"enabled"`
	DestOverride []string `json:"destOverride"`
}

type XRInbound struct {
	Port           int                `json:"port"`
	Listen         string             `json:"listen,omitempty"`
	Protocol       string             `json:"protocol"`
	Tag            string             `json:"tag"`
	Settings       *XRInboundSettings `json:"settings,omitempty"`
	StreamSettings *XRStreamSettings  `json:"streamSettings,omitempty"`
	Sniffing       *XRSniffing        `json:"sniffing,omitempty"`
}

type XROutbound struct {
	Protocol    string `json:"protocol"`
	Tag         string `json:"tag"`
	SendThrough string `json:"sendThrough,omitempty"`
}

type XRRoutingRule struct {
	Type        string   `json:"type"`
	OutboundTag string   `json:"outboundTag"`
	User        []string `json:"user,omitempty"`
}

type XRRouting struct {
	DomainStrategy string          `json:"domainStrategy"`
	Rules          []XRRoutingRule `json:"rules"`
}

type XRConfig struct {
	Log       XRLog        `json:"log"`
	Inbounds  []XRInbound  `json:"inbounds"`
	Outbounds []XROutbound `json:"outbounds"`
	Routing   *XRRouting   `json:"routing,omitempty"`
}

func updateXrayConfig() {
	rows, err := db.Query("SELECT id, username, password, protocol, route_warp FROM users WHERE is_active=1")
	if err != nil {
		log.Printf("Error querying users for Xray: %v", err)
		return
	}
	defer rows.Close()

	userByID := make(map[int]User)
	var warpUsernames []string
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Username, &u.Password, &u.Protocol, &u.RouteWarp); err == nil {
			userByID[u.ID] = u
			if u.RouteWarp == 1 {
				warpUsernames = append(warpUsernames, u.Username)
			}
		}
	}

	uiRows, err := db.Query("SELECT user_id, inbound_id FROM user_inbounds")
	if err != nil {
		log.Printf("Error querying user_inbounds: %v", err)
		return
	}
	defer uiRows.Close()

	inboundUsers := make(map[int][]int)
	for uiRows.Next() {
		var uid, iid int
		if err := uiRows.Scan(&uid, &iid); err == nil {
			inboundUsers[iid] = append(inboundUsers[iid], uid)
		}
	}

	ibRows, err := db.Query("SELECT id, remark, protocol, port, settings FROM inbounds WHERE is_active=1 AND protocol IN ('vless', 'trojan', 'shadowsocks')")
	if err != nil {
		log.Printf("Error querying active inbounds for Xray: %v", err)
		return
	}
	defer ibRows.Close()

	var inbounds []XRInbound

	for ibRows.Next() {
		var id int
		var remark, protocol, settingsJSON string
		var port int
		if err := ibRows.Scan(&id, &remark, &protocol, &port, &settingsJSON); err == nil {
			var settings map[string]interface{}
			_ = json.Unmarshal([]byte(settingsJSON), &settings)
			if settings == nil {
				settings = make(map[string]interface{})
			}

			var xrClients []XRClient
			for _, uid := range inboundUsers[id] {
				u, exists := userByID[uid]
				if !exists {
					continue
				}
				if protocol == "vless" {
					xrClients = append(xrClients, XRClient{Email: u.Username, ID: getUUID(u.Password)})
				} else if protocol == "shadowsocks" {
					cipher := "chacha20-poly1305"
					if c, ok := settings["cipher"].(string); ok && c != "" && c != "aes-256-gcm" {
						cipher = c
					}
					xrClients = append(xrClients, XRClient{Email: u.Username, Password: u.Password, Method: cipher})
				} else {
					xrClients = append(xrClients, XRClient{Email: u.Username, Password: u.Password})
				}
			}

			inb := XRInbound{
				Port:     port,
				Listen:   "::",
				Protocol: protocol,
				Tag:      fmt.Sprintf("%s-in-%d", protocol, id),
				Settings: &XRInboundSettings{},
			}

			if protocol == "vless" {
				inb.Settings.Decryption = "none"
				inb.Settings.Clients = xrClients

				transport := "xhttp"
				if t, ok := settings["transport"].(string); ok && t != "" {
					transport = t
				}
				inb.StreamSettings = &XRStreamSettings{
					Network: transport,
				}

				if transport == "xhttp" {
					inb.StreamSettings.XhttpSettings = &XRXhttpSettings{
						Mode: "auto",
						Path: "/xhttp",
					}
					if p, ok := settings["path"].(string); ok && p != "" {
						inb.StreamSettings.XhttpSettings.Path = p
					}
				}

				if settings["security"] == "reality" {
					inb.StreamSettings.Security = "reality"

					dest := "apps.apple.com:443"
					if d, ok := settings["reality_dest"].(string); ok && d != "" {
						dest = d
					}

					sni := "apps.apple.com"
					if s, ok := settings["sni"].(string); ok && s != "" {
						sni = s
					}

					inb.StreamSettings.RealitySettings = &XRRealitySettings{
						Show:        false,
						Dest:        dest,
						Xver:        0,
						ServerNames: []string{sni},
						PrivateKey:  fmt.Sprintf("%v", settings["private_key"]),
						ShortIds:    []string{fmt.Sprintf("%v", settings["short_id"])},
					}
				}
			} else if protocol == "trojan" {
				inb.Settings.Clients = xrClients

				certPath := "/etc/hysteria/certs/server.crt"
				keyPath := "/etc/hysteria/certs/server.key"
				if c, ok := settings["cert_path"].(string); ok && c != "" {
					certPath = c
				}
				if k, ok := settings["key_path"].(string); ok && k != "" {
					keyPath = k
				}

				inb.StreamSettings = &XRStreamSettings{
					Network:  "tcp",
					Security: "tls",
					TlsSettings: &XRTlsSettings{
						Certificates: []XRTlsCert{
							{
								CertificateFile: certPath,
								KeyFile:         keyPath,
							},
						},
					},
				}
			} else if protocol == "shadowsocks" {
				if len(xrClients) > 0 {
					inb.Settings.Method = xrClients[0].Method
					inb.Settings.Password = xrClients[0].Password
					inb.Settings.Network = "tcp,udp"
				}
			}

			if sniffEnabled, _ := settings["sniffing"].(bool); sniffEnabled {
				inb.Sniffing = &XRSniffing{
					Enabled:      true,
					DestOverride: []string{"http", "tls", "quic"},
				}
			}

			inbounds = append(inbounds, inb)
		}
	}

	outbounds := []XROutbound{
		{Protocol: "freedom", Tag: "direct-out"},
		{Protocol: "freedom", Tag: "warp-out", SendThrough: "172.16.0.2"},
	}

	var rules []XRRoutingRule
	if len(warpUsernames) > 0 {
		rules = append(rules, XRRoutingRule{
			Type:        "field",
			OutboundTag: "warp-out",
			User:        warpUsernames,
		})
	}

	var routing *XRRouting
	if len(rules) > 0 {
		routing = &XRRouting{
			DomainStrategy: "AsIs",
			Rules:          rules,
		}
	}

	cfg := XRConfig{
		Log: XRLog{
			Loglevel: "warning",
		},
		Inbounds:  inbounds,
		Outbounds: outbounds,
		Routing:   routing,
	}

	configPath := "/usr/local/etc/xray/config.json"
	
	bytes, err := json.MarshalIndent(cfg, "", "  ")
	if err == nil {
		_ = os.WriteFile(configPath, bytes, 0600)
	}

	_ = exec.Command("systemctl", "restart", "xray").Run()
}

func migrateInbounds() {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS inbounds (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		remark TEXT NOT NULL,
		protocol TEXT NOT NULL,
		port INTEGER NOT NULL,
		settings TEXT NOT NULL,
		is_active INTEGER DEFAULT 1
	)`)
	if err != nil {
		log.Printf("Warning: failed to create inbounds table: %v", err)
		return
	}

	// Check if inbounds table is empty
	var count int
	err = db.QueryRow("SELECT COUNT(*) FROM inbounds").Scan(&count)
	if err != nil {
		log.Printf("Warning: failed to check inbounds count: %v", err)
		return
	}

	if count == 0 {
		// Populate default inbounds from existing state
		sb := getSingboxConfig()
		h2 := getHysteria2Config()
		mieru := getMieruConfig()

		// 1. VLESS XHTTP Inbound
		vlessPortStr := sb["SB_VLESS_PORT"]
		if vlessPortStr != "" {
			vlessPort, _ := strconv.Atoi(vlessPortStr)
			if vlessPort > 0 {
				vlessSettings, _ := json.Marshal(map[string]interface{}{
					"security":     "reality",
					"utls":         "firefox",
					"sni":          sb["SB_REALITY_SNI"],
					"reality_dest": sb["SB_REALITY_SNI"] + ":443",
					"private_key":  sb["SB_REALITY_PRIV_KEY"],
					"public_key":   sb["SB_REALITY_PUB_KEY"],
					"short_id":     sb["SB_REALITY_SHORT_ID"],
					"transport":    "xhttp",
					"path":         "/xhttp",
					"sniffing":     true,
				})
				_, _ = db.Exec("INSERT INTO inbounds (remark, protocol, port, settings, is_active) VALUES (?, ?, ?, ?, 1)",
					"VLESS-XHTTP", "vless", vlessPort, string(vlessSettings))
			}
		}

		// 2. Trojan Inbound
		trojanPortStr := sb["SB_TROJAN_PORT"]
		if trojanPortStr != "" {
			trojanPort, _ := strconv.Atoi(trojanPortStr)
			if trojanPort > 0 {
				trojanSettings, _ := json.Marshal(map[string]interface{}{
					"security":   "tls",
					"cert_path":  "/etc/hysteria/certs/server.crt",
					"key_path":   "/etc/hysteria/certs/server.key",
					"transport":  "tcp",
					"sniffing":   true,
				})
				_, _ = db.Exec("INSERT INTO inbounds (remark, protocol, port, settings, is_active) VALUES (?, ?, ?, ?, 1)",
					"Trojan-Proxy", "trojan", trojanPort, string(trojanSettings))
			}
		}

		// 3. Shadowsocks Inbound
		ssPortStr := sb["SB_SS_PORT"]
		if ssPortStr != "" {
			ssPort, _ := strconv.Atoi(ssPortStr)
			if ssPort > 0 {
				ssSettings, _ := json.Marshal(map[string]interface{}{
					"cipher":    "aes-256-gcm",
					"transport": "tcp",
				})
				_, _ = db.Exec("INSERT INTO inbounds (remark, protocol, port, settings, is_active) VALUES (?, ?, ?, ?, 1)",
					"Shadowsocks-Proxy", "shadowsocks", ssPort, string(ssSettings))
			}
		}

		// 4. Hysteria2 Inbound
		h2PortStr := h2["H2_PORT"]
		if h2PortStr != "" {
			h2Port, _ := strconv.Atoi(h2PortStr)
			if h2Port > 0 {
				h2Settings, _ := json.Marshal(map[string]interface{}{
					"obfs_password": h2["H2_OBFS_PASS"],
					"cert_cn":       h2["H2_CERT_CN"],
					"cert_pin_hex":  h2["H2_CERT_PIN_HEX"],
					"cert_path":     "/etc/hysteria/certs/server.crt",
					"key_path":      "/etc/hysteria/certs/server.key",
				})
				_, _ = db.Exec("INSERT INTO inbounds (remark, protocol, port, settings, is_active) VALUES (?, ?, ?, ?, 1)",
					"Hysteria2-Proxy", "hysteria2", h2Port, string(h2Settings))
			}
		}

		// 5. Mieru Inbound
		mieruPortStr := mieru["MIERU_PORT"]
		if mieruPortStr != "" {
			mieruPort, _ := strconv.Atoi(mieruPortStr)
			if mieruPort > 0 {
				mieruSettings, _ := json.Marshal(map[string]interface{}{
					"transport": "udp",
				})
				_, _ = db.Exec("INSERT INTO inbounds (remark, protocol, port, settings, is_active) VALUES (?, ?, ?, ?, 1)",
					"Mieru-Proxy", "mieru", mieruPort, string(mieruSettings))
			}
		}
	}
}
