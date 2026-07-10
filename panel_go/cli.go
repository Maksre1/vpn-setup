package main

import (
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func cliAddUser(args []string) {
	username := strings.TrimSpace(args[0])
	if matched, _ := regexp.MatchString("^[a-zA-Z0-9_-]{3,32}$", username); !matched {
		log.Fatalf("Ошибка: Недопустимое имя пользователя '%s'. Разрешены только буквы, цифры, дефис и подчеркивание (3-32 символов).", username)
	}

	initDB()
	defer db.Close()

	var existing int
	_ = db.QueryRow("SELECT COUNT(*) FROM users WHERE username=?", username).Scan(&existing)
	if existing > 0 {
		log.Fatalf("Ошибка: Пользователь '%s' уже существует.", username)
	}

	// Defaults
	expire := "never"
	var traffic int64 = 0
	var speed int64 = 0
	protocol := "all"
	routeWarp := 0

	// Parse arguments manually
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--expire":
			if i+1 < len(args) {
				expire = args[i+1]
				i++
			}
		case "--traffic":
			if i+1 < len(args) {
				traffic, _ = strconv.ParseInt(args[i+1], 10, 64)
				i++
			}
		case "--speed":
			if i+1 < len(args) {
				speed, _ = strconv.ParseInt(args[i+1], 10, 64)
				i++
			}
		case "--protocol":
			if i+1 < len(args) {
				protocol = args[i+1]
				i++
			}
		case "--route-warp":
			if i+1 < len(args) {
				if args[i+1] == "1" || args[i+1] == "on" || args[i+1] == "true" {
					routeWarp = 1
				} else {
					routeWarp = 0
				}
				i++
			}
		}
	}

	if expire != "never" {
		if _, err := time.Parse("2006-01-02", expire); err != nil {
			log.Fatalf("Ошибка: Неверный формат даты истечения. Используйте YYYY-MM-DD или 'never'.")
		}
	}
	if traffic < 0 {
		log.Fatalf("Ошибка: Лимит трафика не может быть отрицательным.")
	}
	if speed < 0 {
		log.Fatalf("Ошибка: Лимит скорости не может быть отрицательным.")
	}
	if protocol != "all" && protocol != "mieru" && protocol != "hysteria2" && protocol != "vless" && protocol != "trojan" && protocol != "shadowsocks" {
		log.Fatalf("Ошибка: Недопустимый протокол. Допустимые: all, mieru, hysteria2, vless, trojan, shadowsocks.")
	}

	password := genPassword(24)
	subPath := genRandomPath("sub", "")

	_, err := db.Exec(`INSERT INTO users (username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, is_active, route_warp)
		VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)`, username, password, expire, traffic, speed, protocol, subPath, routeWarp)
	if err != nil {
		log.Fatalf("Ошибка при создании пользователя в БД: %v", err)
	}

	var u User
	_ = db.QueryRow("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users WHERE username=?", username).Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
		&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
	syncUserToConf(u)
	updateMieruUsers()
	updateHysteriaUsers()

	fmt.Printf("Пользователь '%s' успешно создан.\n", username)
	fmt.Printf("Пароль: %s\n", password)
	fmt.Printf("Подписка: %s\n", subPath)
}

func cliRemoveUser(username string) {
	username = strings.TrimSpace(username)
	initDB()
	defer db.Close()

	var u User
	err := db.QueryRow("SELECT id, username, sub_path FROM users WHERE username=?", username).Scan(&u.ID, &u.Username, &u.SubPath)
	if err != nil {
		log.Fatalf("Ошибка: Пользователь '%s' не найден.", username)
	}

	_, _ = db.Exec("DELETE FROM users WHERE username=?", username)
	removeUserFromConf(username, u.SubPath)
	updateMieruUsers()
	updateHysteriaUsers()

	fmt.Printf("Пользователь '%s' успешно удален.\n", username)
}

func cliListUsers() {
	initDB()
	defer db.Close()

	rows, err := db.Query("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users ORDER BY id")
	if err != nil {
		log.Fatalf("Ошибка чтения БД: %v", err)
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		var u User
		err := rows.Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		if err == nil {
			users = append(users, u)
		}
	}

	if len(users) == 0 {
		fmt.Println("Нет пользователей.")
		return
	}

	fmt.Printf("%-4s | %-15s | %-12s | %-12s | %-12s | %-8s | %-9s | %-8s\n",
		"ID", "Имя", "Пароль", "Истекает", "Трафик (ГБ)", "Скорость", "Протокол", "Статус")
	fmt.Println(strings.Repeat("-", 95))
	for _, u := range users {
		status := "активен"
		if u.IsActive == 0 {
			status = "выкл"
		}
		if isExpired(u.ExpireDate) {
			status = "истёк"
		}
		pw := u.Password
		if len(pw) > 6 {
			pw = pw[:6] + "..."
		}
		fmt.Printf("%-4d | %-15s | %-12s | %-12s | %-12d | %-8d | %-9s | %-8s\n",
			u.ID, u.Username, pw, u.ExpireDate, u.TrafficLimitGB, u.SpeedLimitMbps, u.Protocol, status)
	}
}

func cliCleanupUsers() {
	initDB()
	defer db.Close()

	rows, err := db.Query("SELECT id, username, password, expire_date, traffic_limit_gb, speed_limit_mbps, protocol, sub_path, created_at, is_active, used_traffic_bytes, route_warp FROM users WHERE is_active=1")
	if err != nil {
		log.Fatalf("Ошибка чтения БД: %v", err)
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		var u User
		err := rows.Scan(&u.ID, &u.Username, &u.Password, &u.ExpireDate, &u.TrafficLimitGB, &u.SpeedLimitMbps,
			&u.Protocol, &u.SubPath, &u.CreatedAt, &u.IsActive, &u.UsedTrafficBytes, &u.RouteWarp)
		if err == nil {
			users = append(users, u)
		}
	}

	changes := 0
	for _, u := range users {
		if u.ExpireDate != "never" && u.ExpireDate != "" {
			if isExpired(u.ExpireDate) {
				fmt.Printf("Деактивация пользователя: %s (истёк: %s)\n", u.Username, u.ExpireDate)
				_, err = db.Exec("UPDATE users SET is_active=0 WHERE id=?", u.ID)
				if err == nil {
					u.IsActive = 0
					syncUserToConf(u)
					changes++
				}
			}
		}
	}

	if changes > 0 {
		updateMieruUsers()
		updateHysteriaUsers()
		fmt.Printf("Деактивировано пользователей: %d. Обновление конфигурации...\n", changes)
	} else {
		fmt.Println("Нет истекших активных пользователей.")
	}
}
