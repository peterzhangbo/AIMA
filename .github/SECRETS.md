# GitHub Secrets 配置说明

前往 `Settings → Secrets and variables → Actions` 添加以下 Secret：

## 必须配置的 Secrets

| Secret 名称 | 说明 | 如何获取 |
|---|---|---|
| `MACOS_CERTIFICATE` | Developer ID 证书（.p12）的 Base64 编码 | 见下方步骤 |
| `MACOS_CERTIFICATE_PWD` | 导出 .p12 时设置的密码 | 自己设置 |
| `SIGN_ID` | 签名身份字符串 | 见下方 |
| `APPLE_ID` | Apple ID 邮箱 | 你的 Apple 开发者账号邮箱 |
| `APPLE_TEAM_ID` | 开发者 Team ID | Apple Developer 后台查看 |
| `APPLE_APP_PASSWORD` | App 专用密码 | appleid.apple.com → 安全 → App 专用密码 |
| `RELEASE_PAT` | 有写权限的 PAT，用于推送到公开 releases 仓库 | 见下方 |

---

## 导出证书（MACOS_CERTIFICATE）

```bash
# 1. 打开「钥匙串访问」，找到你的 Developer ID Application 证书
# 2. 右键 → 导出 → 存为 certificate.p12，设置一个导出密码
# 3. Base64 编码后复制到剪贴板：
base64 -i certificate.p12 | pbcopy
# 将剪贴板内容粘贴到 MACOS_CERTIFICATE secret
```

## 获取 SIGN_ID

```bash
security find-identity -v -p codesigning | grep "Developer ID"
# 输出示例（填入完整字符串）：
# "Developer ID Application: Your Name (TEAMID)"
```

## 获取 APPLE_TEAM_ID

```bash
# 从 SIGN_ID 括号内取，或登录 developer.apple.com → Account 页面查看
```

---

## 创建 RELEASE_PAT

```
1. https://github.com/settings/tokens → Generate new token (classic)
2. 勾选 public_repo 权限
3. 将 token 填入私有仓库的 RELEASE_PAT secret
```

## 公开 releases 仓库设置

```
1. 新建公开仓库 https://github.com/new → 名称：AIMA-releases → Public
2. 仓库里只放 README.md（说明这是 AIMA 的下载页）
3. 不放任何源码
```

用户从 `https://github.com/peterzhangbo/AIMA-releases/releases/latest` 下载，
无需登录 GitHub，只看到一个 zip 文件，没有源码。

---

## 发布流程

配置好 Secrets 后，每次发布只需：

```bash
git tag v0.1.x
git push origin v0.1.x
```

GitHub Actions 会自动：
1. 构建 release 二进制
2. 导入证书并签名
3. 提交 Apple 公证（1–3 分钟）
4. Staple 装订票据
5. 打包 zip 并创建 GitHub Release
