# OpenUsage fork — 打包补丁

存放**故意不提交进 git** 的打包改动。功能代码（pi provider 卡片）在 fork 仓库的
`feat/pi-card` 分支上，这里只放签名/公证相关的本地改动。

- 仓库：`~/workspace/github/openusage`（fork: https://github.com/luoph/openusage）
- 分支：`feat/pi-card`
- patch 基线：`a08b86e7`（feat: pi 卡的模型明细标注所属 provider）

## release-fork.patch

改两个文件，让上游的 `script/release.sh` 能在 fork 下打出可公证的包：

- `script/release.sh`
  - `ICLOUD_PROVISIONING_PROFILE` 与 `SPARKLE_PUBLIC_KEY` 从必需改为可选
  - 不给 `SPARKLE_PUBLIC_KEY` 时不写 `SUFeedURL`/`SUPublicEDKey`——**这条别删**，否则包会指向上游
    appcast，官方一发版 Sparkle 就把 fork 自动更新覆盖掉
  - 新增两种公证凭据来源：`NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`（App Store Connect API key，
    本机走这条）和 `NOTARY_KEYCHAIN_PROFILE`（钥匙串里的 app 专用密码）
- `script/OpenUsage.release.entitlements.plist` — 去掉 iCloud 能力。Apple 只为签名 Team 自己的容器
  签发 profile，fork 无法声明上游的 `iCloud.com.robinebers.openusage`

## 用法

```bash
cd ~/workspace/github/openusage

# 应用
git apply ~/workspace/luoph/openusage-pi/release-fork.patch

# 撤销
git apply --reverse ~/workspace/luoph/openusage-pi/release-fork.patch

# 改动后重新导出
git diff -- script/release.sh script/OpenUsage.release.entitlements.plist \
  > ~/workspace/luoph/openusage-pi/release-fork.patch
```

rebase 到新的上游基线后，`git apply` 可能因上游改了同一段而冲突。用
`git apply --3way` 走三方合并，解完再按上面导出一次、更新本文件的基线 commit。

## 打包命令

```bash
cd ~/workspace/github/openusage
git apply ~/workspace/luoph/openusage-pi/release-fork.patch

# 正式公证版。凭据复用 linear-pake 的本机约定：Developer ID 身份 + App Store Connect API key
# (~/Documents/圆红点/cert/AuthKey_*.p8)，key id / issuer id 从 RoundRedDot/ideashell-frontend
# 的 GitHub 仓库变量读取，需要 gh 已登录。
source ~/workspace/luoph/linear-pake/scripts/apple-credentials.sh
NOTARY_KEY="$APPLE_NOTARY_KEY_PATH" \
NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID" \
NOTARY_ISSUER="$APPLE_NOTARY_ISSUER_ID" \
CODESIGN_IDENTITY="$APPLE_SIGN_IDENTITY" \
OPENUSAGE_VERSION=0.7.11-pi.1 \
PATH="$(dirname $(xcrun --find swift)):$PATH" \
script/release.sh

# 不公证的试跑：去掉 NOTARY_* 三个变量，改成 ALLOW_UNNOTARIZED=1
```

公证会提交两次（.app 和 .dmg 各一次），每次几分钟。成品自带 stapler 票据，离线也能验证。
验证：`spctl -a -vv <app>` 应为 `accepted / source=Notarized Developer ID`。

产物是 `dist/OpenUsage-<版本>.dmg`（universal，Developer ID 签名 + hardened runtime）。

日常本机自用不必走这套，用开发签名重建更快：

```bash
BUNDLE_ID=com.robinebers.openusage PATH="$(dirname $(xcrun --find swift)):$PATH" \
  script/build_and_run.sh build
pkill -x OpenUsage; /bin/rm -rf /Applications/OpenUsage.app
ditto dist/OpenUsage.app /Applications/OpenUsage.app && open /Applications/OpenUsage.app
```

官方 0.7.11 原版备份在 `~/Applications-Backup/OpenUsage-0.7.11-official.app`。
