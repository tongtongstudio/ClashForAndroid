//go:build premium

package config

import (
	"encoding/json"
	"strings"

	"github.com/Dreamacro/clash/config"
)

type overrideExtras struct {
	Experimental struct {
		SniffTLSSNI *bool `json:"sniff-tls-sni"`
	} `json:"experimental"`
}

// applyExtraOverride 把 UI 的 experimental.sniff-tls-sni 映射到 Clash.Meta 的
// sniffer.enable + sniffer.sniffing，保证 premium 的 sniff 开关生效。
func applyExtraOverride(cfg *config.RawConfig, content string) {
	var extra overrideExtras
	if err := json.Unmarshal([]byte(content), &extra); err != nil {
		return
	}

	enabled := extra.Experimental.SniffTLSSNI
	if enabled == nil {
		return
	}

	cfg.Sniffer.Enable = *enabled
	if !*enabled {
		return
	}

	for _, s := range cfg.Sniffer.Sniffing {
		if strings.EqualFold(s, "tls") {
			return
		}
	}

	cfg.Sniffer.Sniffing = append(cfg.Sniffer.Sniffing, "tls")
}
