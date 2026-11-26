//go:build premium

package config

import "github.com/Dreamacro/clash/config"

func patchTun(cfg *config.RawConfig, _ string) error {
	// Clash.Meta 不再从顶层 tun 字段启动 TUN（该配置已由 listeners/sing-tun 接管），
	// ClashForAndroid 自身使用 VpnService + tun2socket，因此这里无需关闭内核 TUN。
	return nil
}
