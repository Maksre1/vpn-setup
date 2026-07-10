package main

import (
	"embed"
	"html/template"
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

//go:embed templates/* static/*
var resources embed.FS

var templateCache = make(map[string]*template.Template)

func main() {
	// 1. Check CLI arguments for admin creation and user management
	if len(os.Args) > 1 {
		cmd := os.Args[1]
		if cmd == "--create-admin" && len(os.Args) >= 4 {
			createAdmin(os.Args[2], os.Args[3])
			return
		}
		if cmd == "add" && len(os.Args) >= 3 {
			cliAddUser(os.Args[2:])
			return
		}
		if cmd == "remove" && len(os.Args) >= 3 {
			cliRemoveUser(os.Args[2])
			return
		}
		if cmd == "list" {
			cliListUsers()
			return
		}
		if cmd == "cleanup" {
			cliCleanupUsers()
			return
		}
	}

	// 2. Initialize App Components
	initSessionKey()
	initDB()
	
	// Seed admin if table is empty
	var adminCount int
	_ = db.QueryRow("SELECT COUNT(*) FROM admin").Scan(&adminCount)
	if adminCount == 0 {
		defaultPass := "admin"
		if data, err := os.ReadFile("/etc/vpn-panel/admin_password.txt"); err == nil {
			content := strings.TrimSpace(string(data))
			if strings.Contains(content, ":") {
				parts := strings.SplitN(content, ":", 2)
				defaultPass = parts[1]
			}
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(defaultPass), bcrypt.DefaultCost)
		if err == nil {
			_, _ = db.Exec("INSERT INTO admin (username, password_hash) VALUES (?, ?)", "admin", string(hash))
			log.Printf("Seeded admin user using password from admin_password.txt")
		}
	}
	// Sync database users to configuration files and generate HTML subscriptions at startup
	syncAllUsersToConfigs()
	defer db.Close()

	// 3. Initialize isolated template cache for each page to prevent block namespace pollution
	initTemplateCache()

	// 4. Setup Gin Engine
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())
	r.Use(restoreSession())

	// Serve static files from embedded FS
	r.GET("/static/*filepath", func(c *gin.Context) {
		// Embed paths are relative to root of FS (i.e., contain static/ prefix)
		path := c.Request.URL.Path
		if strings.HasPrefix(path, "/") {
			path = path[1:]
		}
		c.FileFromFS(path, http.FS(resources))
	})

	// Setup routes
	setupRoutes(r)

	// 4. Start background traffic accounting
	startTrafficDaemon()

	// 5. Setup TLS Certificates and listen
	port := getPanelPort()
	h2 := getHysteria2Config()
	certDir := "/etc/hysteria/certs"

	keyPath, crtPath := genEcdsaCert(certDir, getOptString(h2, "H2_CERT_CN", "vpn-panel"))

	log.Printf("VPN Panel starting on port %s...", port)
	err := r.RunTLS(":"+port, crtPath, keyPath)
	if err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

func getPanelPort() string {
	if port := os.Getenv("PANEL_PORT"); port != "" {
		return port
	}
	env := loadEnv("/etc/vpn-setup-state/panel.env")
	if port, ok := env["PANEL_PORT"]; ok && port != "" {
		return port
	}
	envH2 := loadEnv("/etc/vpn-setup-state/hysteria2.env")
	if port, ok := envH2["PANEL_PORT"]; ok && port != "" {
		return port
	}
	return "8443"
}

func createAdmin(username, password string) {
	initDB()
	defer db.Close()

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		log.Fatalf("Failed to hash password: %v", err)
	}

	var count int
	_ = db.QueryRow("SELECT COUNT(*) FROM admin WHERE username=?", username).Scan(&count)
	if count > 0 {
		_, err = db.Exec("UPDATE admin SET password_hash=? WHERE username=?", string(hash), username)
	} else {
		_, err = db.Exec("INSERT INTO admin (username, password_hash) VALUES (?, ?)", username, string(hash))
	}

	if err != nil {
		log.Fatalf("Failed to write admin to DB: %v", err)
	}
	log.Printf("Admin user '%s' created/updated successfully.", username)
}

func initTemplateCache() {
	pages := []string{"dashboard.html", "users.html", "inbounds.html", "logs.html", "settings.html", "login.html"}
	for _, page := range pages {
		t := template.New(page).Funcs(template.FuncMap{
			"format_traffic": formatTraffic,
			"format_speed":   formatSpeed,
			"format_expire":  formatExpire,
			"slice": func(s string, start, end int) string {
				if len(s) > end {
					return s[start:end]
				}
				return s
			},
			"multiply": func(a, b int64) int64 {
				return a * b
			},
		})

		// For login, it's standalone, no base layout needed.
		// For others, parse base layouts + the specific page
		var err error
		if page == "login.html" {
			_, err = t.ParseFS(resources, "templates/"+page)
		} else {
			_, err = t.ParseFS(resources, "templates/base_full.html", "templates/pjax_base.html", "templates/"+page)
		}

		if err != nil {
			log.Fatalf("Failed to parse template set for %s: %v", page, err)
		}
		templateCache[page] = t
	}
}
