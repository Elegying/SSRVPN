package route

import (
	"encoding/json"
	"testing"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

func TestProxyTrafficRequiresControllerAuthentication(t *testing.T) {
	handler := router(false, "traffic-test-secret", "", Cors{})
	for _, authenticated := range []bool{false, true} {
		request := httptest.NewRequest(http.MethodGet, "/ssrvpn/traffic", nil)
		if authenticated {
			request.Header.Set("Authorization", "Bearer traffic-test-secret")
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if !authenticated {
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("unauthenticated: %d", response.Code)
			}
			continue
		}
		if response.Code != http.StatusOK {
			t.Fatalf("authenticated: %d", response.Code)
		}
		var payload map[string]int64
		if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"sessionGeneration", "sampledAtMillis", "upload", "download"} {
			if value, ok := payload[key]; !ok || value < 0 {
				t.Fatalf("invalid field %s: %v", key, payload)
			}
		}
		if len(payload) != 4 {
			t.Fatalf("unexpected connection metadata: %v", payload)
		}
	}
}
