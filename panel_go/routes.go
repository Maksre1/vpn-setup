package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

var sessionKey []byte

type SessionData struct {
	AdminID   int    `json:"admin_id"`
	Username  string `json:"username"`
	CSRFToken string `json:"csrf_token"`
	ExpiresAt int64  `json:"expires_at"`
}

func initSessionKey() {
	secretPath := "/etc/vpn-panel/session.secret"
	if data, err := os.ReadFile(secretPath); err == nil && len(data) == 32 {
		sessionKey = data
		return
	}
	key := make([]byte, 32)
	_, _ = rand.Read(key)
	sessionKey = key
	_ = os.MkdirAll("/etc/vpn-panel", 0700)
	_ = os.WriteFile(secretPath, key, 0600)
}

func encryptSession(data SessionData) (string, error) {
	plaintext, err := json.Marshal(data)
	if err != nil {
		return "", err
	}

	block, err := aes.NewCipher(sessionKey)
	if err != nil {
		return "", err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}

	ciphertext := gcm.Seal(nonce, nonce, plaintext, nil)
	return base64.URLEncoding.EncodeToString(ciphertext), nil
}

func decryptSession(cookieVal string) (*SessionData, error) {
	ciphertext, err := base64.URLEncoding.DecodeString(cookieVal)
	if err != nil {
		return nil, err
	}

	block, err := aes.NewCipher(sessionKey)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short")
	}

	nonce, actualCiphertext := ciphertext[:nonceSize], ciphertext[nonceSize:]
	plaintext, err := gcm.Open(nil, nonce, actualCiphertext, nil)
	if err != nil {
		return nil, err
	}

	var data SessionData
	if err := json.Unmarshal(plaintext, &data); err != nil {
		return nil, err
	}
	return &data, nil
}

// Middleware for authentication and session restore
func restoreSession() gin.HandlerFunc {
	return func(c *gin.Context) {
		cookie, err := c.Cookie("session")
		if err == nil {
			session, err := decryptSession(cookie)
			if err == nil && session.ExpiresAt > time.Now().Unix() {
				c.Set("admin_id", session.AdminID)
				c.Set("admin_username", session.Username)
				c.Set("csrf_token", session.CSRFToken)
			}
		}
		c.Next()
	}
}

func authRequired() gin.HandlerFunc {
	return func(c *gin.Context) {
		if _, exists := c.Get("admin_id"); !exists {
			c.Redirect(http.StatusFound, "/login")
			c.Abort()
			return
		}
		c.Next()
	}
}

// CSRF validation middleware
func verifyCSRF() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.Method == "POST" {
			expectedToken, exists := c.Get("csrf_token")
			if !exists {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"ok": false, "msg": "CSRF token missing"})
				return
			}

			// Read token from header or form field
			receivedToken := c.GetHeader("X-CSRFToken")
			if receivedToken == "" {
				receivedToken = c.PostForm("csrf_token")
			}

			if receivedToken == "" || receivedToken != expectedToken.(string) {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"ok": false, "msg": "Invalid CSRF token"})
				return
			}
		}
		c.Next()
	}
}

// Struct to render templates dynamically depending on PJAX header
type PageData struct {
	Title         string
	ActiveTab     string
	AdminUsername string
	CSRFToken     string
	FlashMessage  string
	FlashCategory string
	Data          interface{}
}

func renderTemplate(c *gin.Context, pageTmpl string, title string, activeTab string, data interface{}) {
	adminUsername, _ := c.Get("admin_username")
	csrfToken, _ := c.Get("csrf_token")

	// Flush/Flash messages logic (using cookies or simple session values)
	flashMsg, _ := c.Cookie("flash_msg")
	flashCat, _ := c.Cookie("flash_cat")
	if flashMsg != "" {
		// Clear cookies
		c.SetCookie("flash_msg", "", -1, "/", "", false, true)
		c.SetCookie("flash_cat", "", -1, "/", "", false, true)
	}

	pageData := gin.H{
		"Title":         title,
		"ActiveTab":     activeTab,
		"AdminUsername": adminUsername,
		"CSRFToken":     csrfToken,
		"FlashMessage":  flashMsg,
		"FlashCategory": flashCat,
	}

	// Merge main data
	if m, ok := data.(gin.H); ok {
		for k, v := range m {
			pageData[k] = v
		}
	} else if data != nil {
		pageData["Data"] = data
	}

	tmpl, ok := templateCache[pageTmpl]
	if !ok {
		log.Printf("Template %s not found in cache", pageTmpl)
		c.String(http.StatusInternalServerError, "Internal Server Error")
		return
	}

	isPjax := c.GetHeader("X-PJAX") == "true"

	c.Header("Content-Type", "text/html; charset=utf-8")
	var err error
	if isPjax {
		err = tmpl.ExecuteTemplate(c.Writer, "pjax_base.html", pageData)
	} else {
		err = tmpl.ExecuteTemplate(c.Writer, "base_full.html", pageData)
	}

	if err != nil {
		log.Printf("Template execution error: %v", err)
		c.String(http.StatusInternalServerError, "Internal Server Error")
	}
}

func flash(c *gin.Context, msg, category string) {
	c.SetCookie("flash_msg", msg, 5, "/", "", false, true)
	c.SetCookie("flash_cat", category, 5, "/", "", false, true)
}

// Router registration
func setupRoutes(r *gin.Engine) {
	r.GET("/login", func(c *gin.Context) {
		// If already logged in, redirect to index
		if _, exists := c.Get("admin_id"); exists {
			c.Redirect(http.StatusFound, "/")
			return
		}
		tmpl := templateCache["login.html"]
		c.Header("Content-Type", "text/html; charset=utf-8")
		_ = tmpl.Execute(c.Writer, gin.H{})
	})

	r.POST("/login", func(c *gin.Context) {
		username := c.PostForm("username")
		password := c.PostForm("password")

		var adminID int
		var passHash string
		err := db.QueryRow("SELECT id, password_hash FROM admin WHERE username=?", username).Scan(&adminID, &passHash)
		if err != nil {
			tmpl := templateCache["login.html"]
			c.Header("Content-Type", "text/html; charset=utf-8")
			_ = tmpl.Execute(c.Writer, gin.H{"Error": "Неверный логин или пароль"})
			return
		}

		err = bcrypt.CompareHashAndPassword([]byte(passHash), []byte(password))
		if err != nil {
			tmpl := templateCache["login.html"]
			c.Header("Content-Type", "text/html; charset=utf-8")
			_ = tmpl.Execute(c.Writer, gin.H{"Error": "Неверный логин или пароль"})
			return
		}

		// Generate random CSRF token
		b := make([]byte, 16)
		_, _ = rand.Read(b)
		csrfToken := hex.EncodeToString(b)

		// Create session
		session := SessionData{
			AdminID:   adminID,
			Username:  username,
			CSRFToken: csrfToken,
			ExpiresAt: time.Now().Add(2 * time.Hour).Unix(),
		}

		cookieVal, err := encryptSession(session)
		if err != nil {
			tmpl := templateCache["login.html"]
			c.Header("Content-Type", "text/html; charset=utf-8")
			_ = tmpl.Execute(c.Writer, gin.H{"Error": "Ошибка создания сессии"})
			return
		}

		c.SetCookie("session", cookieVal, 7200, "/", "", false, true)
		c.Redirect(http.StatusFound, "/")
	})

	r.GET("/logout", func(c *gin.Context) {
		c.SetCookie("session", "", -1, "/", "", false, true)
		c.Redirect(http.StatusFound, "/login")
	})

	// Authenticated routes
	auth := r.Group("/")
	auth.Use(authRequired())
	auth.Use(verifyCSRF())

	// Inbounds HTML Page view
	auth.GET("/inbounds", func(c *gin.Context) {
		rows, err := db.Query("SELECT id, remark, protocol, port, settings, is_active FROM inbounds")
		if err != nil {
			c.String(http.StatusInternalServerError, "Ошибка БД: %v", err)
			return
		}
		defer rows.Close()

		var inbounds []Inbound
		for rows.Next() {
			var ib Inbound
			if err := rows.Scan(&ib.ID, &ib.Remark, &ib.Protocol, &ib.Port, &ib.Settings, &ib.IsActive); err == nil {
				inbounds = append(inbounds, ib)
			}
		}

		renderTemplate(c, "inbounds.html", "Подключения", "inbounds", gin.H{
			"Inbounds": inbounds,
		})
	})

	// Add/Edit Inbound APIs
	auth.POST("/api/inbounds/save", func(c *gin.Context) {
		idStr := c.PostForm("id")
		remark := c.PostForm("remark")
		protocol := c.PostForm("protocol")
		port, _ := strconv.Atoi(c.PostForm("port"))
		isActive := 0
		if c.PostForm("is_active") == "1" || c.PostForm("is_active") == "on" {
			isActive = 1
		}

		// Settings JSON parsing/building
		settings := make(map[string]interface{})
		settings["sniffing"] = c.PostForm("sniffing") == "1" || c.PostForm("sniffing") == "on"
		settings["transport"] = c.PostForm("transport")

		switch protocol {
		case "vless":
			settings["security"] = c.PostForm("security")
			settings["utls"] = c.PostForm("utls")
			settings["sni"] = c.PostForm("sni")
			settings["reality_dest"] = c.PostForm("reality_dest")
			settings["private_key"] = c.PostForm("private_key")
			settings["public_key"] = c.PostForm("public_key")
			settings["short_id"] = c.PostForm("short_id")
		case "trojan":
			settings["security"] = c.PostForm("security")
			settings["cert_path"] = c.PostForm("cert_path")
			settings["key_path"] = c.PostForm("key_path")
		case "shadowsocks":
			settings["cipher"] = c.PostForm("cipher")
		case "hysteria2":
			settings["obfs_password"] = c.PostForm("obfs_password")
			settings["cert_cn"] = c.PostForm("cert_cn")
			settings["cert_pin_hex"] = c.PostForm("cert_pin_hex")
			settings["cert_path"] = c.PostForm("cert_path")
			settings["key_path"] = c.PostForm("key_path")
		case "mieru":
			settings["transport"] = c.PostForm("transport")
		}

		settingsBytes, _ := json.Marshal(settings)
		settingsJSON := string(settingsBytes)

		var dbErr error
		if idStr == "" {
			// Insert new inbound
			_, dbErr = db.Exec("INSERT INTO inbounds (remark, protocol, port, settings, is_active) VALUES (?, ?, ?, ?, ?)",
				remark, protocol, port, settingsJSON, isActive)
		} else {
			// Update inbound
			id, _ := strconv.Atoi(idStr)
			_, dbErr = db.Exec("UPDATE inbounds SET remark=?, protocol=?, port=?, settings=?, is_active=? WHERE id=?",
				remark, protocol, port, settingsJSON, isActive, id)
		}

		if dbErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": dbErr.Error()})
			return
		}

		// Trigger service updates
		if protocol == "mieru" {
			updateMieruUsers()
		} else if protocol == "hysteria2" {
			updateHysteriaUsers()
		} else {
			updateSingboxUsers()
		}

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "Подключение успешно сохранено"})
	})

	auth.POST("/api/inbounds/:id/toggle", func(c *gin.Context) {
		id, _ := strconv.Atoi(c.Param("id"))
		var protocol string
		var isActive int
		err := db.QueryRow("SELECT protocol, is_active FROM inbounds WHERE id=?", id).Scan(&protocol, &isActive)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"ok": false, "msg": "Подключение не найдено"})
			return
		}

		newActive := 1 - isActive
		_, err = db.Exec("UPDATE inbounds SET is_active=? WHERE id=?", newActive, id)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": err.Error()})
			return
		}

		if protocol == "mieru" {
			updateMieruUsers()
		} else if protocol == "hysteria2" {
			updateHysteriaUsers()
		} else {
			updateSingboxUsers()
		}

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "Статус изменен", "is_active": newActive})
	})

	auth.POST("/api/inbounds/:id/delete", func(c *gin.Context) {
		id, _ := strconv.Atoi(c.Param("id"))
		var protocol string
		err := db.QueryRow("SELECT protocol FROM inbounds WHERE id=?", id).Scan(&protocol)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"ok": false, "msg": "Подключение не найдено"})
			return
		}

		_, err = db.Exec("DELETE FROM inbounds WHERE id=?", id)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": err.Error()})
			return
		}

		if protocol == "mieru" {
			updateMieruUsers()
		} else if protocol == "hysteria2" {
			updateHysteriaUsers()
		} else {
			updateSingboxUsers()
		}

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "Подключение удалено"})
	})

	// Add an endpoint to generate Reality X25519 Keys on backend
	auth.POST("/api/reality/generate-keys", func(c *gin.Context) {
		priv, pub, err := generateRealityKeyPair()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": "Не удалось запустить sing-box для генерации ключей: " + err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"ok": true, "private_key": priv, "public_key": pub})
	})

	// Fetch dynamic URIs for user info modal
	auth.GET("/api/users/:username/uris", func(c *gin.Context) {
		username := c.Param("username")
		var password, protocol string
		err := db.QueryRow("SELECT password, protocol FROM users WHERE username=?", username).Scan(&password, &protocol)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"ok": false, "msg": "Пользователь не найден"})
			return
		}

		serverIP := getServerIP()

		// Fetch active inbounds
		rows, err := db.Query("SELECT protocol, remark, port, settings FROM inbounds WHERE is_active=1")
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": err.Error()})
			return
		}
		defer rows.Close()

		type Connection struct {
			Remark   string `json:"remark"`
			Protocol string `json:"protocol"`
			Uri      string `json:"uri"`
		}
		var connections []Connection

		for rows.Next() {
			var proto, remark, settingsJSON string
			var port int
			if err := rows.Scan(&proto, &remark, &port, &settingsJSON); err == nil {
				// Filter by user protocol choice
				if protocol != "all" && protocol != proto {
					continue
				}

				var settings map[string]interface{}
				_ = json.Unmarshal([]byte(settingsJSON), &settings)
				if settings == nil {
					settings = make(map[string]interface{})
				}

				uri := ""
				switch proto {
				case "hysteria2":
					obfsPassword, _ := settings["obfs_password"].(string)
					certCN, _ := settings["cert_cn"].(string)
					certPinHex, _ := settings["cert_pin_hex"].(string)
					uri = fmt.Sprintf("hysteria2://%s@%s:%d?obfs=salamander&obfs-password=%s&sni=%s",
						password, serverIP, port, obfsPassword, certCN)
					if certPinHex != "" {
						uri += "&pinSHA256=" + certPinHex
					}
					uri += "#" + remark

				case "mieru":
					uri = fmt.Sprintf("mieru://%s:%d?username=%s&password=%s&network=udp#%s",
						serverIP, port, username, password, remark)

				case "vless":
					uuid := getUUID(password)
					pubKey, _ := settings["public_key"].(string)
					shortId, _ := settings["short_id"].(string)
					sni, _ := settings["sni"].(string)
					uri = fmt.Sprintf("vless://%s@%s:%d?security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&type=tcp#%s",
						uuid, serverIP, port, sni, pubKey, shortId, remark)

				case "trojan":
					uri = fmt.Sprintf("trojan://%s@%s:%d?security=tls&sni=%s&allowInsecure=1#%s",
						password, serverIP, port, serverIP, remark)

				case "shadowsocks":
					cipher := "aes-256-gcm"
					if cs, ok := settings["cipher"].(string); ok && cs != "" {
						cipher = cs
					}
					auth := base64.StdEncoding.EncodeToString([]byte(cipher + ":" + password))
					uri = fmt.Sprintf("ss://%s@%s:%d#%s", auth, serverIP, port, remark)
				}

				if uri != "" {
					connections = append(connections, Connection{
						Remark:   remark,
						Protocol: proto,
						Uri:      uri,
					})
				}
			}
		}

		c.JSON(http.StatusOK, gin.H{
			"ok":          true,
			"connections": connections,
		})
	})

	auth.GET("/", func(c *gin.Context) {
		var active, expired, total int
		_ = db.QueryRow("SELECT COUNT(*) FROM users WHERE is_active=1").Scan(&active)
		
		// Fetch all to check expiry
		rows, err := db.Query("SELECT expire_date, is_active FROM users")
		if err == nil {
			defer rows.Close()
			for rows.Next() {
				var exp string
				var activeInt int
				if err := rows.Scan(&exp, &activeInt); err == nil {
					total++
					if isExpired(exp) {
						expired++
					}
				}
			}
		}

		statuses := getAllServiceStatuses()
		specs := getServerSpecs()
		serverIP := getServerIP()

		h2Config := getHysteria2Config()
		mieruConfig := getMieruConfig()
		subPaths := getSubscriptionPaths()

		// Periodic traffic snapshot logging
		recordTrafficSnapshot()

		renderTemplate(c, "dashboard.html", "Обзор", "dashboard", gin.H{
			"Active":         active,
			"Expired":        expired,
			"Total":          total,
			"Statuses":       statuses,
			"Specs":          specs,
			"ServerIP":       serverIP,
			"ClashPath":      getOptString(subPaths, "CLASH_PATH", "clash.yaml"),
			"SubPath":        getOptString(subPaths, "SUB_PATH", "sub.txt"),
			"LoadAvgFmt":     strings.Join(specs.Load, " / "),
			"TrafficHistory": getTrafficHistory(),
			"H2Port":         getOptString(h2Config, "H2_PORT", "443"),
			"MieruPort":      getOptString(mieruConfig, "MIERU_PORT", "443"),
		})
	})

	auth.GET("/users", func(c *gin.Context) {
		rows, err := db.Query("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users ORDER BY id")
		if err != nil {
			c.String(http.StatusInternalServerError, "DB error")
			return
		}
		defer rows.Close()

		var users []User
		serverIP := getServerIP()
		h2 := getHysteria2Config()
		mieru := getMieruConfig()
		sb := getSingboxConfig()

		for rows.Next() {
			var u User
			err := rows.Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
				&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
			if err == nil {
				u.Expired = isExpired(u.ExpireDate)
				u.ExpireFmt = formatExpire(u.ExpireDate)
				u.TrafficFmt = formatTrafficLimit(u.TrafficLimitGB)
				u.SpeedFmt = formatSpeed(u.SpeedLimitMbps)

				if u.Protocol == "all" || u.Protocol == "hysteria2" {
					u.H2Uri = getHysteria2Uri(h2, serverIP, u.Username, u.Password)
				}
				if u.Protocol == "all" || u.Protocol == "mieru" {
					u.MieruUri = getMieruUri(mieru, serverIP, u.Username, u.Password)
				}
				if u.Protocol == "all" || u.Protocol == "vless" {
					u.VlessUri = getVlessUri(sb, serverIP, u.Password)
				}
				if u.Protocol == "all" || u.Protocol == "trojan" {
					u.TrojanUri = getTrojanUri(sb, serverIP, u.Password)
				}
				if u.Protocol == "all" || u.Protocol == "shadowsocks" {
					u.SsUri = getShadowsocksUri(sb, serverIP, u.Password)
				}

				// Calculate progress bar percentage
				if u.TrafficLimitGB > 0 {
					limitBytes := u.TrafficLimitGB * 1024 * 1024 * 1024
					u.Pct = int((u.UsedTrafficBytes * 100) / limitBytes)
					if u.Pct > 100 {
						u.Pct = 100
					}
				} else {
					u.Pct = 0
				}

				users = append(users, u)
			}
		}

		renderTemplate(c, "users.html", "Пользователи", "users", gin.H{
			"Users":    users,
			"ServerIP": serverIP,
		})
	})

	auth.POST("/users/add", func(c *gin.Context) {
		username := strings.TrimSpace(c.PostForm("username"))
		if matched, _ := regexp.MatchString("^[a-zA-Z0-9_-]{3,32}$", username); !matched {
			c.JSON(http.StatusBadRequest, gin.H{"ok": false, "msg": "Имя пользователя должно содержать только латинские буквы, цифры, дефис и подчеркивание (3-32 символов)."})
			return
		}

		password := genPassword(24)
		expireDays := c.PostForm("expire_preset")
		var expire string
		switch expireDays {
		case "7":
			expire = time.Now().AddDate(0, 0, 7).Format("2006-01-02")
		case "30":
			expire = time.Now().AddDate(0, 0, 30).Format("2006-01-02")
		case "90":
			expire = time.Now().AddDate(0, 0, 90).Format("2006-01-02")
		case "365":
			expire = time.Now().AddDate(0, 0, 365).Format("2006-01-02")
		case "custom":
			expire = c.PostForm("expire_custom")
		default:
			expire = "never"
		}

		traffic, _ := strconv.ParseInt(c.PostForm("traffic_limit"), 10, 64)
		speed, _ := strconv.ParseInt(c.PostForm("speed_limit"), 10, 64)
		protocol := c.PostForm("protocol")
		if protocol == "" {
			protocol = "all"
		}

		routeWarp := 0
		if c.PostForm("route_warp") == "on" || c.PostForm("route_warp") == "1" {
			routeWarp = 1
		}

		subPath := genRandomPath("sub", "")

		_, err := db.Exec(`INSERT INTO users (username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, route_warp)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, username, password, expire, traffic, speed, protocol, subPath, routeWarp)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": fmt.Sprintf("Ошибка сохранения в БД: %v", err)})
			return
		}

		// Sync configs
		var u User
		_ = db.QueryRow("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users WHERE username=?", username).Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		syncUserToConf(u)
		updateMieruUsers()
		updateHysteriaUsers()

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": fmt.Sprintf("Пользователь '%s' создан. Подписка: %s", username, subPath)})
	})

	auth.POST("/users/quick", func(c *gin.Context) {
		// Generate random username: user_ + 6 characters
		randSuffix := genPassword(6)
		username := "user_" + randSuffix
		password := genPassword(24)
		expire := "never"
		var traffic int64 = 0 // unlimited
		var speed int64 = 0   // unlimited
		protocol := "all"
		routeWarp := 1 // Route through WARP by default for quick users
		subPath := genRandomPath("sub", "")

		_, err := db.Exec(`INSERT INTO users (username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, route_warp)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, username, password, expire, traffic, speed, protocol, subPath, routeWarp)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": fmt.Sprintf("Ошибка быстрого создания: %v", err)})
			return
		}

		// Sync configs
		var u User
		_ = db.QueryRow("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users WHERE username=?", username).Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		syncUserToConf(u)
		updateMieruUsers()
		updateHysteriaUsers()

		h2 := getHysteria2Config()
		mieru := getMieruConfig()
		sb := getSingboxConfig()
		serverIP := getServerIP()
		h2Uri := getHysteria2Uri(h2, serverIP, username, password)
		mieruUri := getMieruUri(mieru, serverIP, username, password)
		vlessUri := getVlessUri(sb, serverIP, password)
		trojanUri := getTrojanUri(sb, serverIP, password)
		ssUri := getShadowsocksUri(sb, serverIP, password)

		c.JSON(http.StatusOK, gin.H{
			"ok":         true,
			"msg":        fmt.Sprintf("Быстрое создание успешно. Пользователь: %s", username),
			"username":   username,
			"sub_path":   subPath,
			"h2_uri":     h2Uri,
			"mieru_uri":  mieruUri,
			"vless_uri":  vlessUri,
			"trojan_uri": trojanUri,
			"ss_uri":     ssUri,
		})
	})

	auth.POST("/users/:id/edit", func(c *gin.Context) {
		id, _ := strconv.Atoi(c.Param("id"))
		var u User
		err := db.QueryRow("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users WHERE id=?", id).Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"ok": false, "msg": "Пользователь не найден"})
			return
		}

		expireDays := c.PostForm("expire_preset")
		var expire string
		switch expireDays {
		case "7":
			expire = time.Now().AddDate(0, 0, 7).Format("2006-01-02")
		case "30":
			expire = time.Now().AddDate(0, 0, 30).Format("2006-01-02")
		case "90":
			expire = time.Now().AddDate(0, 0, 90).Format("2006-01-02")
		case "365":
			expire = time.Now().AddDate(0, 0, 365).Format("2006-01-02")
		case "custom":
			expire = c.PostForm("expire_custom")
		default:
			expire = "never"
		}

		traffic, _ := strconv.ParseInt(c.PostForm("traffic_limit"), 10, 64)
		speed, _ := strconv.ParseInt(c.PostForm("speed_limit"), 10, 64)
		protocol := c.PostForm("protocol")
		isActive := 0
		if c.PostForm("is_active") == "on" {
			isActive = 1
		}
		routeWarp := 0
		if c.PostForm("route_warp") == "on" || c.PostForm("route_warp") == "1" {
			routeWarp = 1
		}
		resetTraffic := c.PostForm("reset_traffic") == "on"

		if resetTraffic {
			_, err = db.Exec("UPDATE users SET expire_date=?, traffic_limit_gb=?, speed_limit_mbps=?, protocol=?, is_active=?, route_warp=?, used_traffic_bytes=0 WHERE id=?",
				expire, traffic, speed, protocol, isActive, routeWarp, id)
		} else {
			_, err = db.Exec("UPDATE users SET expire_date=?, traffic_limit_gb=?, speed_limit_mbps=?, protocol=?, is_active=?, route_warp=? WHERE id=?",
				expire, traffic, speed, protocol, isActive, routeWarp, id)
		}

		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": "Ошибка обновления БД"})
			return
		}

		// Re-fetch and sync configs
		_ = db.QueryRow("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users WHERE id=?", id).Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		syncUserToConf(u)
		updateMieruUsers()
		updateHysteriaUsers()

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": fmt.Sprintf("Пользователь '%s' обновлен", u.Username)})
	})

	auth.POST("/users/:id/delete", func(c *gin.Context) {
		id, _ := strconv.Atoi(c.Param("id"))
		var username, subPath string
		err := db.QueryRow("SELECT username, sub_path FROM users WHERE id=?", id).Scan(&username, &subPath)
		if err == nil {
			_, _ = db.Exec("DELETE FROM users WHERE id=?", id)
			removeUserFromConf(username, subPath)
			updateMieruUsers()
			updateHysteriaUsers()
			c.JSON(http.StatusOK, gin.H{"ok": true, "msg": fmt.Sprintf("Пользователь '%s' удален", username)})
			return
		}
		c.JSON(http.StatusNotFound, gin.H{"ok": false, "msg": "Пользователь не найден"})
	})

	auth.POST("/users/:id/reset-password", func(c *gin.Context) {
		id, _ := strconv.Atoi(c.Param("id"))
		var username string
		err := db.QueryRow("SELECT username FROM users WHERE id=?", id).Scan(&username)
		if err == nil {
			newPass := genPassword(24)
			_, _ = db.Exec("UPDATE users SET password=? WHERE id=?", newPass, id)

			var u User
			_ = db.QueryRow("SELECT * FROM users WHERE id=?", id).Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
				&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes)
			syncUserToConf(u)
			updateMieruUsers()
			updateHysteriaUsers()

			c.JSON(http.StatusOK, gin.H{"ok": true, "msg": fmt.Sprintf("Пароль пользователя '%s' сброшен: %s", username, newPass)})
			return
		}
		c.JSON(http.StatusNotFound, gin.H{"ok": false, "msg": "Пользователь не найден"})
	})

	auth.GET("/logs", func(c *gin.Context) {
		selected := c.DefaultQuery("service", "mieru")
		linesStr := c.DefaultQuery("lines", "50")
		lines, _ := strconv.Atoi(linesStr)
		if lines == 0 {
			lines = 50
		}

		type LogService struct {
			Svc  string
			Name string
		}
		logServices := []LogService{
			{"mieru", "Mieru"},
			{"hysteria", "Hysteria2"},
			{"warp", "WARP"},
			{"fail2ban", "fail2ban"},
			{"panel", "Panel"},
		}

		renderTemplate(c, "logs.html", "Логи", "logs", gin.H{
			"Services": logServices,
			"Selected": selected,
			"Lines":    lines,
			"LogText":  getLogsText(selected, lines),
		})
	})

	auth.GET("/api/logs/:service", func(c *gin.Context) {
		service := c.Param("service")
		linesStr := c.DefaultQuery("lines", "50")
		lines, _ := strconv.Atoi(linesStr)
		if lines == 0 {
			lines = 50
		}
		c.JSON(http.StatusOK, gin.H{"logs": getLogsText(service, lines)})
	})

	auth.GET("/settings", func(c *gin.Context) {
		type ServiceUnit struct {
			Name string
			Unit string
		}
		services := []ServiceUnit{
			{"Mieru (mita)", "mita"},
			{"Hysteria2", "hysteria-server"},
			{"Cloudflare WARP", "wg-quick@wgcf-warp"},
			{"fail2ban", "fail2ban"},
		}

		h2 := getHysteria2Config()
		panelPort := getOptString(h2, "PANEL_PORT", "8443")

		renderTemplate(c, "settings.html", "Настройки", "settings", gin.H{
			"Services":  services,
			"PanelPort": panelPort,
		})
	})

	auth.POST("/api/restart", func(c *gin.Context) {
		type RestartReq struct {
			Service string `json:"service"`
		}
		var req RestartReq
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"ok": false, "msg": "Invalid JSON"})
			return
		}

		ok := restartSystemdService(req.Service)
		c.JSON(http.StatusOK, gin.H{"ok": ok, "msg": "Сервис перезапущен"})
	})

	auth.GET("/api/qr", func(c *gin.Context) {
		text := c.Query("text")
		if text == "" {
			c.String(http.StatusBadRequest, "Missing text")
			return
		}
		svg, err := genQRSvg(text)
		if err != nil {
			c.String(http.StatusInternalServerError, "QR error")
			return
		}
		c.Header("Content-Type", "image/svg+xml")
		c.String(http.StatusOK, svg)
	})

	auth.GET("/api/status", func(c *gin.Context) {
		c.JSON(http.StatusOK, getAllServiceStatuses())
	})

	auth.GET("/api/live-stats", func(c *gin.Context) {
		rx, tx := getNetworkTraffic()
		specs := getServerSpecs()
		c.JSON(http.StatusOK, gin.H{
			"cpu_pct":  getCPULoadPct(),
			"ram":      getRAMUsage(),
			"disk":     getDiskUsage(),
			"statuses": getAllServiceStatuses(),
			"uptime":   specs.Uptime,
			"rx_bytes": rx,
			"tx_bytes": tx,
		})
	})

	auth.POST("/settings/change-password", func(c *gin.Context) {
		oldPass := c.PostForm("old_password")
		newPass := c.PostForm("new_password")
		adminUsername, _ := c.Get("admin_username")

		var passHash string
		err := db.QueryRow("SELECT password_hash FROM admin WHERE username=?", adminUsername).Scan(&passHash)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": "Ошибка базы данных"})
			return
		}

		err = bcrypt.CompareHashAndPassword([]byte(passHash), []byte(oldPass))
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"ok": false, "msg": "Старый пароль неверный"})
			return
		}

		newHash, err := bcrypt.GenerateFromPassword([]byte(newPass), bcrypt.DefaultCost)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": "Ошибка хэширования пароля"})
			return
		}

		_, err = db.Exec("UPDATE admin SET password_hash=? WHERE username=?", string(newHash), adminUsername)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": "Ошибка сохранения нового пароля"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "Пароль администратора успешно изменен"})
	})

	auth.GET("/settings/backup", func(c *gin.Context) {
		c.Header("Content-Description", "File Transfer")
		c.Header("Content-Disposition", "attachment; filename=panel_backup.db")
		c.Header("Content-Type", "application/octet-stream")
		c.File(dbPath)
	})

	auth.POST("/settings/restore", func(c *gin.Context) {
		file, err := c.FormFile("backup_file")
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"ok": false, "msg": "Файл бэкапа не загружен"})
			return
		}

		db.Close()

		err = c.SaveUploadedFile(file, dbPath)
		if err != nil {
			initDB()
			c.JSON(http.StatusInternalServerError, gin.H{"ok": false, "msg": "Не удалось восстановить базу данных"})
			return
		}

		initDB()
		syncAllUsersToConfigs()

		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "База данных успешно восстановлена. Все службы синхронизированы."})
	})

	auth.POST("/api/reboot", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "Сервер перезагружается..."})
		go func() {
			time.Sleep(1 * time.Second)
			_ = exec.Command("reboot").Run()
		}()
	})
}
