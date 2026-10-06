# PersonalServerConfig

阿里云 ECS（Debian 12）动漫自动化全栈，Docker Compose 编排 9 容器：ani-rss（自动订阅下载）、qBittorrent（BT 下载）、v2rayA（代理）、File Browser（文件管理）、rclone-mount + rclone-webdav（OSS 媒体串流）、anime-migrate（本地→OSS 迁移）、bangumi-syncer（追番同步）、Glance（门户仪表盘）。

## 文件清单

| 文件 | 用途 |
|---|---|
| docker-compose.yml | 9 容器编排 |
| glance/glance.yml | Glance 门户主配置 |
| glance/assets/user.css | 门户样式（背景压暗 + 卡片毛玻璃） |
| glance/assets/icons/ | 门户图标与背景图 |
| migrate/ | 本地→OSS 迁移容器（Dockerfile + migrate.sh） |
| oss-mnt-share.service | WebDAV 共享目录挂载单元 |

> `.env` 与 `rclone/rclone.conf` 含真实密钥，**不入库**，模板见下方，按模板 nano 重建。

## 从零重建

1. 安装 Docker Compose 与 git
2. `git clone https://github.com/Katosred/PersonalServerConfig.git /opt/anime-server && cd /opt/anime-server`
3. `nano .env`，粘贴下方模板并填写真实值，然后 `chmod 600 .env`
4. `mkdir -p rclone && nano rclone/rclone.conf`，粘贴下方模板并填写 AccessKey，然后 `chmod 600 rclone/rclone.conf`
5. `docker compose up -d` 拉起全部容器
6. 安全组、crontab、RAM 策略等系统级配置参见部署教程

### .env 模板

```ini
# qBittorrent 登录API
QBT_API_KEY=
# ANI-RSS 登录API
ANIRSS_API_KEY=
# WebDAV 账号
WEBDAV_USER=
WEBDAV_PASS=
# OSS 远程：rclone 配置段名:Bucket名
OSS_REMOTE=
# 公网IP
PUBLIC_IP=
# BGM用户名
BANGUMI_USER=
```

### rclone/rclone.conf 模板

```ini
# 远程名（.env 里 OSS_REMOTE 冒号前就是它，两处必须一致）
[oss-media]
# 协议类型
type = s3
# 服务商
provider = Alibaba
# AccessKey ID（RAM 子账号的）
access_key_id = <AccessKey_ID>
# AccessKey Secret（只在创建时显示一次）
secret_access_key = <AccessKey_Secret>
# OSS 内网 endpoint（<你的地域ID> 如 cn-hangzhou）
endpoint = oss-<你的地域ID>-internal.aliyuncs.com
# 读写权限：私有
acl = private
```
