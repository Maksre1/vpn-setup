package main

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"log"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/skip2/go-qrcode"
)

// Random helpers
func genPassword(length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, length)
	for i := range b {
		num, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			log.Fatalf("Secure rand failed: %v", err)
		}
		b[i] = charset[num.Int64()]
	}
	return string(b)
}

func genRandomPath(prefix, ext string) string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	if ext == "" {
		return fmt.Sprintf("%s-%x", prefix, b)
	}
	return fmt.Sprintf("%s-%x.%s", prefix, b, ext)
}

// VPN connection URI generators
func getHysteria2Uri(config map[string]string, serverIP, username, password string) string {
	authPart := config["H2_PASS"]
	if username != "" && password != "" {
		authPart = fmt.Sprintf("%s:%s", username, password)
	} else if password != "" {
		authPart = password
	}

	if authPart == "" {
		return ""
	}

	port := config["H2_PORT"]
	if port == "" {
		port = "443"
	}

	return fmt.Sprintf("hysteria2://%s@%s:%s?obfs=salamander&obfs-password=%s&pinSHA256=%s&sni=%s",
		authPart, serverIP, port, config["H2_OBFS_PASS"], config["H2_CERT_PIN"], config["H2_CERT_CN"])
}

func getMieruUri(config map[string]string, serverIP, username, password string) string {
	user := username
	if user == "" {
		user = config["MIERU_USER"]
	}
	pwd := password
	if pwd == "" {
		pwd = config["MIERU_PASS"]
	}

	if pwd == "" {
		return ""
	}

	port := config["MIERU_PORT"]
	if port == "" {
		port = "443"
	}

	return fmt.Sprintf("mieru://%s:%s?username=%s&password=%s&network=udp#Mieru-Proxy",
		serverIP, port, user, pwd)
}

func genSubscriptionBase64(uris []string) string {
	var valid []string
	for _, u := range uris {
		if u != "" {
			valid = append(valid, u)
		}
	}
	content := strings.Join(valid, "\n")
	return base64.StdEncoding.EncodeToString([]byte(content))
}

// genQRSvg generates a scalable vector graphic QR code
func genQRSvg(text string) (string, error) {
	qr, err := qrcode.New(text, qrcode.Medium)
	if err != nil {
		return "", err
	}
	matrix := qr.Bitmap()
	size := len(matrix)

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="200" height="200" shape-rendering="crispEdges">`, size+4, size+4))
	sb.WriteString(`<rect width="100%" height="100%" fill="#ffffff"/>`)
	sb.WriteString(`<path fill="#000000" d="`)
	for y, row := range matrix {
		for x, val := range row {
			if val {
				sb.WriteString(fmt.Sprintf("M%d,%dh1v1h-1z ", x+2, y+2))
			}
		}
	}
	sb.WriteString(`"/>`)
	sb.WriteString(`</svg>`)
	return sb.String(), nil
}

// Certificate helpers
func getCertFingerprint(certPath string) string {
	cmd := exec.Command("openssl", "x509", "-in", certPath, "-noout", "-fingerprint", "-sha256")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	// Format: SHA256 Fingerprint=XX:XX:...
	parts := strings.SplitN(strings.TrimSpace(string(out)), "=", 2)
	if len(parts) < 2 {
		return ""
	}
	return strings.ToLower(strings.ReplaceAll(parts[1], ":", ""))
}

func genEcdsaCert(certDir, cn string) (string, string) {
	keyPath := filepath.Join(certDir, "server.key")
	crtPath := filepath.Join(certDir, "server.crt")
	if _, err := os.Stat(keyPath); err == nil {
		if _, err := os.Stat(crtPath); err == nil {
			return keyPath, crtPath
		}
	}

	_ = os.MkdirAll(certDir, 0755)
	_ = exec.Command("openssl", "ecparam", "-genkey", "-name", "prime256v1", "-out", keyPath).Run()
	_ = exec.Command("openssl", "req", "-new", "-x509",
		"-key", keyPath, "-out", crtPath,
		"-days", "3650", "-nodes",
		"-subj", fmt.Sprintf("/CN=%s/O=VPN-Panel/C=US", cn)).Run()

	_ = os.Chmod(keyPath, 0600)
	_ = os.Chmod(crtPath, 0644)
	return keyPath, crtPath
}

// Time & format helpers
func isExpired(expireDate string) bool {
	if expireDate == "" || expireDate == "never" || expireDate == "None" {
		return false
	}
	t, err := time.Parse("2006-01-02", expireDate)
	if err != nil {
		return false
	}
	// Check if expiry date is before today
	today := time.Now().Truncate(24 * time.Hour)
	return t.Before(today)
}

func formatExpire(expireDate string) string {
	if expireDate == "" || expireDate == "never" || expireDate == "None" {
		return "бессрочно"
	}
	if isExpired(expireDate) {
		return fmt.Sprintf("истёк (%s)", expireDate)
	}
	return expireDate
}

func formatTraffic(bytes int64) string {
	if bytes == 0 {
		return "0 Б"
	}
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d Б", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	units := []string{"КБ", "МБ", "ГБ", "ТБ"}
	return fmt.Sprintf("%.2f %s", float64(bytes)/float64(div), units[exp])
}

func formatTrafficLimit(gb int64) string {
	if gb == 0 {
		return "безлимит"
	}
	return fmt.Sprintf("%d ГБ", gb)
}

func formatSpeed(mbps int64) string {
	if mbps == 0 {
		return "безлимит"
	}
	return fmt.Sprintf("%d Мбит/с", mbps)
}

// Get network traffic
func getNetworkTraffic() (int64, int64) {
	var rx, tx int64 = 0, 0
	content, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		// Fallback for local testing (simulated counter)
		t := time.Now().Unix()
		rx = (t % 86400) * 15000 + 5000000000
		tx = (t % 86400) * 10000 + 2000000000
		return rx, tx
	}

	lines := strings.Split(string(content), "\n")
	for i, line := range lines {
		if i < 2 {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 10 {
			iface := strings.TrimSuffix(fields[0], ":")
			if iface == "lo" || strings.HasPrefix(iface, "wg") || strings.HasPrefix(iface, "tun") {
				continue
			}
			if r, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
				rx += r
			}
			if t, err := strconv.ParseInt(fields[9], 10, 64); err == nil {
				tx += t
			}
		}
	}
	return rx, tx
}

// Record traffic snapshot
func recordTrafficSnapshot() {
	rx, tx := getNetworkTraffic()
	
	// Check the last entry
	var lastID int
	var lastTimestamp string
	var lastRx, lastTx int64
	err := db.QueryRow("SELECT id, timestamp, rx_bytes, tx_bytes FROM traffic_history ORDER BY id DESC LIMIT 1").Scan(&lastID, &lastTimestamp, &lastRx, &lastTx)
	
	shouldInsert := false
	if err != nil {
		// No entries
		shouldInsert = true
	} else {
		if t, err := time.Parse("2006-01-02 15:04:05", lastTimestamp); err == nil {
			if time.Since(t).Seconds() >= 300 {
				shouldInsert = true
			}
		} else {
			shouldInsert = true
		}
	}

	if shouldInsert {
		_, _ = db.Exec("DELETE FROM traffic_history WHERE datetime(timestamp) < datetime('now', '-1 day')")
		_, err = db.Exec("INSERT INTO traffic_history (rx_bytes, tx_bytes) VALUES (?, ?)", rx, tx)
		if err != nil {
			log.Printf("Error inserting traffic history: %v", err)
		}
	}
}

func getTrafficHistory() []map[string]interface{} {
	rows, err := db.Query("SELECT * FROM traffic_history ORDER BY id")
	if err != nil {
		return []map[string]interface{}{}
	}
	defer rows.Close()

	type THRow struct {
		ID        int
		Timestamp string
		RxBytes   int64
		TxBytes   int64
	}

	var historyRows []THRow
	for rows.Next() {
		var r THRow
		if err := rows.Scan(&r.ID, &r.Timestamp, &r.RxBytes, &r.TxBytes); err == nil {
			historyRows = append(historyRows, r)
		}
	}

	// Pre-populate mock historical data if too few points exist
	if len(historyRows) < 12 {
		_, _ = db.Exec("DELETE FROM traffic_history")
		baseRx, baseTx := getNetworkTraffic()
		now := time.Now()
		for i := 24; i > 0; i-- {
			ts := now.Add(time.Duration(-i*5) * time.Minute).Format("2006-01-02 15:04:05")
			// Generate some randomized bytes offset
			rxVal := baseRx - int64(i * (15 * 1024 * 1024))
			txVal := baseTx - int64(i * (8 * 1024 * 1024))
			_, _ = db.Exec("INSERT INTO traffic_history (timestamp, rx_bytes, tx_bytes) VALUES (?, ?, ?)", ts, rxVal, txVal)
		}

		// Re-fetch
		return getTrafficHistory()
	}

	var history []map[string]interface{}
	for i := 1; i < len(historyRows); i++ {
		prev := historyRows[i-1]
		curr := historyRows[i]

		rxDiff := curr.RxBytes - prev.RxBytes
		txDiff := curr.TxBytes - prev.TxBytes
		if rxDiff < 0 {
			rxDiff = 0
		}
		if txDiff < 0 {
			txDiff = 0
		}

		rxMB := roundFloat(float64(rxDiff)/(1024*1024), 2)
		txMB := roundFloat(float64(txDiff)/(1024*1024), 2)

		label := curr.Timestamp
		if t, err := time.Parse("2006-01-02 15:04:05", curr.Timestamp); err == nil {
			label = t.Format("15:04")
		}

		history = append(history, map[string]interface{}{
			"Label": label,
			"Rx":    rxMB,
			"Tx":    txMB,
		})
	}
	return history
}

func roundFloat(val float64, precision uint) float64 {
	ratio := mathPow(10, float64(precision))
	return float64(int(val*ratio+0.5)) / ratio
}

func mathPow(base, exp float64) float64 {
	// Simple power function to avoid importing math package
	res := 1.0
	for i := 0; i < int(exp); i++ {
		res *= base
	}
	return res
}

func checkServiceStatus(unit string) bool {
	cmd := exec.Command("systemctl", "is-active", unit)
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "active"
}

func getAllServiceStatuses() map[string]bool {
	services := map[string]string{
		"Mieru (mita)": "mita",
		"Hysteria2":    "hysteria-server",
		"Cloudflare WARP": "wg-quick@wgcf-warp",
		"fail2ban":     "fail2ban",
		"VPN Panel":    "vpn-panel",
	}
	result := make(map[string]bool)
	for dName, unit := range services {
		result[dName] = checkServiceStatus(unit)
	}
	return result
}

func restartSystemdService(name string) bool {
	unitMap := map[string]string{
		"Mieru (mita)": "mita",
		"Mieru":        "mita",
		"mieru":        "mita",
		"mita":         "mita",
		"Hysteria2":    "hysteria-server",
		"hysteria":     "hysteria-server",
		"hysteria-server": "hysteria-server",
		"Cloudflare WARP": "wg-quick@wgcf-warp",
		"warp":         "wg-quick@wgcf-warp",
		"wg-quick@wgcf-warp": "wg-quick@wgcf-warp",
		"fail2ban":     "fail2ban",
		"VPN Panel":    "vpn-panel",
		"panel":        "vpn-panel",
		"vpn-panel":    "vpn-panel",
	}

	unit, ok := unitMap[name]
	if !ok {
		unit = name
	}

	cmd := exec.Command("systemctl", "restart", unit)
	err := cmd.Run()
	return err == nil
}

func getLogsText(service string, lines int) string {
	unitMap := map[string]string{
		"mieru":    "mita",
		"hysteria": "hysteria-server",
		"warp":     "wg-quick@wgcf-warp",
		"fail2ban": "fail2ban",
		"panel":    "vpn-panel",
	}
	unit, ok := unitMap[service]
	if !ok {
		unit = service
	}

	cmd := exec.Command("journalctl", "-u", unit, "--no-pager", "-n", fmt.Sprintf("%d", lines), "--output=short-iso")
	out, err := cmd.Output()
	if err != nil {
		return fmt.Sprintf("Error retrieving logs: %v", err)
	}
	return string(out)
}

type DiskUsage struct {
	Total int64 `json:"total"`
	Free  int64 `json:"free"`
	Used  int64 `json:"used"`
	Pct   int   `json:"pct"`
}

func getDiskUsage() DiskUsage {
	var stat syscall.Statfs_t
	err := syscall.Statfs("/", &stat)
	if err != nil {
		return DiskUsage{}
	}

	total := int64(stat.Blocks) * int64(stat.Bsize)
	free := int64(stat.Bavail) * int64(stat.Bsize)
	used := total - free

	pct := 0
	if total > 0 {
		pct = int((used * 100) / total)
	}

	return DiskUsage{
		Total: total,
		Free:  free,
		Used:  used,
		Pct:   pct,
	}
}

type RAMUsage struct {
	Total int64 `json:"total"` // MB
	Used  int64 `json:"used"`  // MB
	Pct   int   `json:"pct"`
}

func getRAMUsage() RAMUsage {
	var total, available int64 = 0, 0
	content, err := os.ReadFile("/proc/meminfo")
	if err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			if strings.Contains(line, "MemTotal") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					t, _ := strconv.ParseInt(fields[1], 10, 64)
					total = t / 1024
				}
			} else if strings.Contains(line, "MemAvailable") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					a, _ := strconv.ParseInt(fields[1], 10, 64)
					available = a / 1024
				}
			}
		}
	} else {
		// MacOS fallback
		total = 8192
		available = 5120
	}

	if total == 0 {
		return RAMUsage{Total: 1024, Used: 256, Pct: 25}
	}

	used := total - available
	pct := int((used * 100) / total)
	if pct < 0 {
		pct = 0
	}
	return RAMUsage{
		Total: total,
		Used:  used,
		Pct:   pct,
	}
}

func getCPULoadPct() int {
	specs := getServerSpecs()
	if len(specs.Load) > 0 && specs.CPUCores > 0 {
		load1, err := strconv.ParseFloat(specs.Load[0], 64)
		if err == nil {
			pct := int((load1 * 100) / float64(specs.CPUCores))
			if pct > 100 {
				pct = 100
			}
			return pct
		}
	}
	return 5
}

func getSingboxConfig() map[string]string {
	return loadEnv("/etc/vpn-setup-state/singbox.env")
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

func getVlessUri(config map[string]string, serverIP, password string) string {
	port := config["SB_VLESS_PORT"]
	pubKey := config["SB_REALITY_PUB_KEY"]
	shortId := config["SB_REALITY_SHORT_ID"]
	sni := config["SB_REALITY_SNI"]
	if port == "" || pubKey == "" {
		return ""
	}
	uuid := getUUID(password)
	return fmt.Sprintf("vless://%s@%s:%s?security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&type=tcp#VLESS-Reality",
		uuid, serverIP, port, sni, pubKey, shortId)
}

func getTrojanUri(config map[string]string, serverIP, password string) string {
	port := config["SB_TROJAN_PORT"]
	if port == "" {
		return ""
	}
	return fmt.Sprintf("trojan://%s@%s:%s?security=tls&sni=%s&allowInsecure=1#Trojan-Proxy",
		password, serverIP, port, serverIP)
}

func getShadowsocksUri(config map[string]string, serverIP, password string) string {
	port := config["SB_SS_PORT"]
	if port == "" {
		return ""
	}
	auth := base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:" + password))
	return fmt.Sprintf("ss://%s@%s:%s#Shadowsocks-Proxy", auth, serverIP, port)
}

func generateRealityKeyPair() (string, string, error) {
	// Try xray first
	cmd := exec.Command("/usr/local/bin/xray", "x25519")
	out, err := cmd.Output()
	if err == nil {
		lines := strings.Split(string(out), "\n")
		var priv, pub string
		for _, l := range lines {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "Private key:") {
				priv = strings.TrimSpace(strings.TrimPrefix(l, "Private key:"))
			}
			if strings.HasPrefix(l, "Public key:") {
				pub = strings.TrimSpace(strings.TrimPrefix(l, "Public key:"))
			}
		}
		if priv != "" && pub != "" {
			return priv, pub, nil
		}
	}

	// Fallback to sing-box
	cmd = exec.Command("/usr/local/bin/sing-box", "generate", "reality-keypair")
	out, err = cmd.Output()
	if err != nil {
		return "", "", err
	}
	lines := strings.Split(string(out), "\n")
	var priv, pub string
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "PrivateKey:") {
			priv = strings.TrimSpace(strings.TrimPrefix(l, "PrivateKey:"))
		}
		if strings.HasPrefix(l, "PublicKey:") {
			pub = strings.TrimSpace(strings.TrimPrefix(l, "PublicKey:"))
		}
	}
	return priv, pub, nil
}
