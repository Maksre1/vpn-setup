package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os/exec"
	"time"
)

type MieruUserMetrics struct {
	DownloadBytes int64 `json:"DownloadBytes"`
	UploadBytes   int64 `json:"UploadBytes"`
}

type MieruMetrics struct {
	Users map[string]MieruUserMetrics `json:"users"`
}

type H2UserMetrics struct {
	Tx int64 `json:"tx"`
	Rx int64 `json:"rx"`
}

type H2Metrics map[string]H2UserMetrics

func getH2Traffic() H2Metrics {
	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", "http://127.0.0.1:25413/traffic", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "hysteria_stats_secret")

	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}

	var metrics H2Metrics
	if err := json.Unmarshal(body, &metrics); err != nil {
		return nil
	}
	return metrics
}

func getMieruTraffic() map[string]MieruUserMetrics {
	cmd := exec.Command("mita", "get", "metrics")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var metrics MieruMetrics
	if err := json.Unmarshal(out, &metrics); err != nil {
		return nil
	}
	return metrics.Users
}

func runTrafficAccounting() {
	lastMieruTraffic := make(map[string]int64)
	lastH2Traffic := make(map[string]int64)

	log.Println("[Traffic Daemon] Запуск фонового потока учёта трафика...")

	for {
		time.Sleep(30 * time.Second)

		h2Stats := getH2Traffic()
		mieruStats := getMieruTraffic()

		rows, err := db.Query("SELECT id, username, traffic_limit_gb, used_traffic_bytes, is_active FROM users")
		if err != nil {
			log.Printf("[Traffic Daemon] Ошибка чтения пользователей: %v", err)
			continue
		}

		type UserAccounting struct {
			ID               int
			Username         string
			TrafficLimitGB   int64
			UsedTrafficBytes int64
			IsActive         int
		}

		var users []UserAccounting
		for rows.Next() {
			var u UserAccounting
			if err := rows.Scan(&u.ID, &u.Username, &u.TrafficLimitGB, &u.UsedTrafficBytes, &u.IsActive); err == nil {
				users = append(users, u)
			}
		}
		rows.Close()

		deactivateNeeded := false

		// Begin transaction for traffic updates
		tx, err := db.Begin()
		if err != nil {
			log.Printf("[Traffic Daemon] Ошибка начала транзакции: %v", err)
			continue
		}

		for _, user := range users {
			uname := user.Username

			// 1. Calculate Mieru Delta
			var mTotal int64 = 0
			if metrics, ok := mieruStats[uname]; ok {
				mTotal = metrics.DownloadBytes + metrics.UploadBytes
			}

			var mDelta int64 = 0
			if lastTotal, exists := lastMieruTraffic[uname]; exists {
				if mTotal >= lastTotal {
					mDelta = mTotal - lastTotal
				} else {
					mDelta = mTotal // Service restart reset counters
				}
			} else if mTotal > 0 {
				lastMieruTraffic[uname] = mTotal
			}

			if mTotal > 0 {
				lastMieruTraffic[uname] = mTotal
			}

			// 2. Calculate Hysteria2 Delta
			var h2Total int64 = 0
			if metrics, ok := h2Stats[uname]; ok {
				h2Total = metrics.Tx + metrics.Rx
			}

			var h2Delta int64 = 0
			if lastTotal, exists := lastH2Traffic[uname]; exists {
				if h2Total >= lastTotal {
					h2Delta = h2Total - lastTotal
				} else {
					h2Delta = h2Total // Service restart reset counters
				}
			} else if h2Total > 0 {
				lastH2Traffic[uname] = h2Total
			}

			if h2Total > 0 {
				lastH2Traffic[uname] = h2Total
			}

			// 3. Accumulate traffic and check limit
			totalDelta := mDelta + h2Delta
			if totalDelta > 0 {
				newUsed := user.UsedTrafficBytes + totalDelta
				_, err := tx.Exec("UPDATE users SET used_traffic_bytes=? WHERE id=?", newUsed, user.ID)
				if err != nil {
					log.Printf("[Traffic Daemon] Ошибка обновления трафика для %s: %v", uname, err)
				}

				// Check traffic limit
				if user.TrafficLimitGB > 0 {
					limitBytes := user.TrafficLimitGB * 1024 * 1024 * 1024
					if newUsed >= limitBytes && user.IsActive == 1 {
						_, err := tx.Exec("UPDATE users SET is_active=0 WHERE id=?", user.ID)
						if err != nil {
							log.Printf("[Traffic Daemon] Ошибка деактивации пользователя %s: %v", uname, err)
						} else {
							deactivateNeeded = true
							log.Printf("[Traffic Daemon] Пользователь '%s' заблокирован (превышен лимит %d ГБ)", uname, user.TrafficLimitGB)
						}
					}
				}
			}
		}

		if err := tx.Commit(); err != nil {
			log.Printf("[Traffic Daemon] Ошибка фиксации транзакции трафика: %v", err)
			continue
		}

		if deactivateNeeded {
			syncAllUsersToConfigs()
		}
	}
}

func startTrafficDaemon() {
	go runTrafficAccounting()
}
