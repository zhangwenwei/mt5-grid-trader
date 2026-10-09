# Gmail 批量打标签脚本

按会话（thread）给 Gmail 收件箱里还没有用户标签的邮件，按发件人或主题规则加上**现有**标签。
脚本只会**添加**标签，不会删除标签、移出收件箱或标记已读。

## 一、设置 Gmail API（只需做一次）

### 1. 新建 Google Cloud 项目
1. 打开 https://console.cloud.google.com/ ，用你的 Gmail 账号登录（第一次进入要同意服务条款）。
2. 点顶部左侧的**项目选择器** → **新建项目**，项目名称填 `gmail-labeler`（随意），组织选「无组织」→ **创建**。
3. 创建好后，确认顶部的项目选择器里当前选中的是这个新项目。

### 2. 启用 Gmail API
1. 左侧菜单 → **API 和服务** → **库**（或直接打开 https://console.cloud.google.com/apis/library/gmail.googleapis.com ）。
2. 搜索 **Gmail API** → 进入 → 点 **启用**。

### 3. 配置 OAuth 同意屏幕
1. 左侧菜单 → **API 和服务** → **OAuth 同意屏幕**（新版界面叫 **Google Auth Platform**，会自动跳转过去）→ **开始**。
2. **应用信息**：应用名称填 `Gmail Labeler`，用户支持邮箱选你自己的邮箱 → 下一步。
3. **受众群体**：选 **外部（External）** → 下一步。
4. **联系信息**：填你的邮箱 → 下一步 → 勾选同意政策 → **创建**。
5. 左侧进入 **受众群体（Audience）** → **测试用户** → **添加用户** → 填上你自己的 Gmail 地址 → 保存。
   （不加的话登录时会提示「访问被阻止」。）

### 4. 创建 OAuth 桌面应用凭证并下载 credentials.json
1. 左侧进入 **客户端（Clients）**（旧版界面：API 和服务 → 凭据 → 创建凭据 → OAuth 客户端 ID）→ **创建客户端**。
2. **应用类型**选 **桌面应用（Desktop app）**，名称随意 → **创建**。
3. 在弹窗里点 **下载 JSON**（如果弹窗关了：在客户端列表点进这个客户端，右侧有下载按钮）。
4. 把下载的文件（名字类似 `client_secret_xxxx.json`）**重命名为 `credentials.json`**，放到本脚本所在的同一个文件夹。

> ⚠️ `credentials.json` 和之后生成的 `token.json` 相当于你邮箱的钥匙，不要发给别人或上传到网上（已在 `.gitignore` 中排除）。

### 5. 安装 Python 依赖（Python 3.9+）
```
pip install -r requirements.txt
```

### 6. 第一次登录
运行任意命令（例如下面的 dry-run）时会自动打开浏览器：
1. 选你的 Gmail 账号。
2. 出现「Google 尚未验证此应用」→ 点 **继续**（这是你自己的应用，所以可以放心）。
3. 勾选「查看和修改您的电子邮件」权限（gmail.modify）→ 继续。
4. 浏览器显示认证完成即可关闭，授权信息保存在 `token.json`，下次不用再登录。

> 说明：应用处于「测试」状态时，Google 会让 token **7 天后过期**。过期后脚本会自动重新打开浏览器让你登录，属正常现象。

## 二、使用流程

### 第 1 步：dry-run（只读，不改任何邮件）
```
python gmail_labeler.py dry-run
# 想先小规模试：python gmail_labeler.py dry-run --limit 50
```
输出：
- `plan.csv`：每个会话一行：threadId、日期、发件人、主题、**计划标签**、命中规则、邮件数、Gmail 链接。
- 终端打印每个标签分到多少个会话。
- `others_by_sender.csv` + 终端列表：被分到「其他通知」的邮件按发件人汇总（数量、地址、域名、主题样例）。

### 第 2 步：审核、补充规则
- 看 `others_by_sender.csv`，需要补规则就改 `gmail_labeler.py` 顶部的 `RULES`，然后**重新 dry-run**
  （有本地缓存 `cache_threads.jsonl`，第二次 dry-run 不用重新读邮件，很快）。
- 个别会话也可以直接在 `plan.csv` 里改 `labels` 列（多个标签用 `;` 分隔，只能用那 10 个现有标签）。

### 第 3 步：正式执行
```
python gmail_labeler.py apply
```
- 读取的是你审核过的 `plan.csv`，所见即所得；执行前会让你输入 `yes` 确认。
- 只调用 `threads.modify` 的 `addLabelIds`。
- 限速 8 次请求/秒；遇到 429/5xx/限流类 403/网络错误会自动指数退避重试。
- 每成功一个会话就记入 `applied.log`；中途断了直接重跑 `apply`，已完成的会跳过，失败的（`failed.log`）会再试。

## 三、规则说明
- 规则从上到下，命中第一条即停止。只看会话里第一封「不是你自己发出」的邮件的发件人和主题。
- 域名匹配包含子域名：`smbc.co.jp` 也会匹配 `xxx.smbc.co.jp`；带 `@` 的条目按完整地址匹配。
- 关键词匹配不区分大小写。
- 需要你在 dry-run 后重点确认的几处推断：
  - **tesla.com 营销邮件**：主题不包含 `TESLA_TRANSACTIONAL_SUBJECT`（注文/納車/予約/service/receipt…）的才算广告；其余落到后面的规则。
  - **amazon.co.jp 订单/发货**：主题包含 `AMAZON_ORDER_SUBJECT`（注文/発送/お届け/order/shipped…）才算网购。
  - **医疗预约「发件人是诊所」**：发件人显示名/地址包含 `CLINIC_SENDER_HINTS`（クリニック/病院/歯科/clinic…），或在 `CLINIC_SENDERS` 里列出。
  - **主题含「認証コード/Security alert…」归安全**：放在第 3 条，所以孩子教育、PMI 的邮件仍归它们自己；想让安全优先就把这个条件移到 `RULES` 最前面。
