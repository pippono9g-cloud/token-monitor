# แนวทางดึง Claude Usage แบบเรียลไทม์ + Auto-renew Token

สรุปวิธีที่ Token Monitor ใช้อ่าน usage ของบัญชี Claude (subscription) แบบเรียลไทม์
ผ่าน OAuth token ของ Claude Code พร้อมต่ออายุ token เองอัตโนมัติ — เขียนไว้ให้คนนำไปพัฒนาต่อ

> ⚠️ Endpoint เหล่านี้เป็น **internal/undocumented** ของ Anthropic อาจเปลี่ยนได้ทุกเมื่อ
> ใช้เพื่อการส่วนตัว/เครื่องมือภายในเท่านั้น และควรมี fallback เสมอ

---

## 1. ภาพรวมสถาปัตยกรรม

```
┌─────────────┐   อ่าน token สด   ┌──────────────────────┐
│  keychain    │ ───────────────► │  แอปของเรา            │
│ "Claude Code-│                  │  freshOAuthToken()    │
│  credentials"│ ◄─────────────── │  - เช็ก expiresAt      │
└─────────────┘   เขียน token ใหม่ │  - refresh ถ้าใกล้หมด  │
       ▲                          └──────────┬───────────┘
       │ Claude Code ก็ใช้ token เดียวกัน        │ GET usage
       │ (sync กันผ่าน keychain)                ▼
       │                          ┌──────────────────────┐
       └──────────────────────────│ api.anthropic.com     │
                                  │ /api/oauth/usage       │
                                  └──────────────────────┘
```

หลักการ: **ยืม OAuth token ที่ Claude Code เก็บไว้ใน keychain** ไปเรียก usage endpoint
ถ้า token หมดอายุ ก็ refresh เอง แล้ว**เขียนกลับ keychain** เพื่อให้ Claude Code ใช้ token เดียวกันต่อ (ไม่หลุด login)

---

## 2. ที่มาของ Token

ต้องเป็น token จาก **`claude auth login`** (full browser OAuth) ไม่ใช่ `claude setup-token`

| วิธีได้ token | scope | ใช้กับ usage endpoint |
|---|---|---|
| `claude auth login` | `user:profile` + อื่นๆ ครบ | ✅ ได้ |
| `claude setup-token` | `user:inference` เท่านั้น | ❌ 403 (ขาด `user:profile`) |

### ที่เก็บใน macOS keychain
- **service:** `Claude Code-credentials`
- **account:** ชื่อ login user (`NSUserName()`)
- **ค่า (`-w`)** เป็น JSON:

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1781949578772,        // epoch ms
    "scopes": ["user:profile", "user:inference", ...],
    "subscriptionType": "pro"
  }
}
```

อ่านด้วย:
```bash
security find-generic-password -s "Claude Code-credentials" -w
```

---

## 3. เรียก Usage Endpoint

```
GET https://api.anthropic.com/api/oauth/usage
```

**Headers ที่จำเป็น:**
```
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/<version> (external, cli)   # สำคัญ! ไม่มี = โดน rate-limit หนัก
Content-Type: application/json
```

**Response (200):**
```json
{
  "five_hour":  { "utilization": 34.0, "resets_at": "2026-06-20T16:59:38.181360+00:00" },
  "seven_day":  { "utilization": 4.0,  "resets_at": "2026-06-25T18:00:00.951713+00:00" },
  "seven_day_opus":   null,
  "seven_day_sonnet": null
}
```

- `five_hour` = session window (5 ชม.)
- `seven_day` = weekly window (7 วัน)
- `utilization` = % ที่ใช้ไป (0–100), `resets_at` = เวลา reset (ISO8601)

**โพลได้ปลอดภัยที่ ~ทุก 3 นาทีขึ้นไป** (เราใช้ 5 นาที)

**รหัสตอบที่ต้องจัดการ:**
- `401/403` → token หมด/ถูก revoke → refresh แล้วลองใหม่ (ดูข้อ 4)
- `429` → rate-limited → ข้ามรอบนี้ รอรอบหน้า

---

## 4. Auto-renew Token (หัวใจของความ robust)

Claude Code ใช้ **refresh token rotation** — refresh ทีนึง refresh token เก่าใช้ไม่ได้ทันที
ดังนั้นถ้าเรา refresh เอง **ต้องเขียน token ใหม่กลับ keychain** ไม่งั้น Claude Code จะหลุด login

### Endpoint refresh
```
POST https://platform.claude.com/v1/oauth/token
Content-Type: application/json
User-Agent: claude-code/<version> (external, cli)

{
  "grant_type": "refresh_token",
  "refresh_token": "<refreshToken>",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}
```
> `client_id` เป็นค่าคงที่ของ Claude Code (public client) — ดึงได้จาก binary ของ `claude`

**Response (200):**
```json
{
  "access_token": "sk-ant-oat01-...(ใหม่)",
  "refresh_token": "sk-ant-ort01-...(ใหม่ - หมุนแล้ว)",
  "expires_in": 28800
}
```

### ขั้นตอน (เขียนกลับ keychain)
```python
# 1. อ่าน blob เดิมทั้งก้อน (เก็บ field อื่นไว้ครบ)
blob = json.loads(security_read())
oauth = blob["claudeAiOauth"]

# 2. POST refresh ด้วย oauth["refreshToken"]
data = refresh(oauth["refreshToken"])   # ได้ access_token, refresh_token, expires_in

# 3. อัปเดต field
oauth["accessToken"]  = data["access_token"]
oauth["refreshToken"] = data["refresh_token"]              # ต้องเก็บตัวใหม่!
oauth["expiresAt"]    = int((time.time() + data["expires_in"]) * 1000)
blob["claudeAiOauth"] = oauth

# 4. เขียนกลับ keychain (-U = update ถ้ามีอยู่แล้ว)
security add-generic-password -U -s "Claude Code-credentials" -a <user> -w '<blob json>'
```

### เมื่อไหร่ถึง refresh
1. **เชิงรุก (proactive):** ก่อนยิงทุกครั้ง ถ้า `expiresAt - now < 5 นาที` → refresh ก่อน
2. **เชิงรับ (reactive):** ถ้า usage endpoint ตอบ 401 → refresh แล้วยิงซ้ำ 1 ครั้ง

> ⚠️ ถ้าทั้ง Claude Code และแอปเรา refresh พร้อมกัน อาจชนกัน 1 ฝั่ง — แต่เพราะอ่าน
> keychain สดทุกครั้ง ระบบจะ self-heal รอบถัดไป (กรณีหายากมาก)

---

## 5. Fallback (เผื่อ token ใช้ไม่ได้จริง)

ถ้าไม่มี token / refresh ไม่ผ่าน → ถอยไปวิธี **scrape หน้าเว็บ** `https://claude.ai/settings/usage`
ผ่าน WKWebView (ต้อง login claude.ai ในหน้าต่างแอป) แล้ว regex หา "% used" + "Resets in ..."

แบ่งสถานะให้ผู้ใช้เห็น: 🟢 = API เชื่อมต่อ, 🔴 = โหมดเว็บ

---

## 6. ข้อควรระวัง / Threading

- การยิง refresh + อ่าน/เขียน keychain ทั้งหมด **ต้องทำบน background thread** (มี blocking I/O)
  ห้ามทำบน main thread เพราะ UI จะค้าง
- การอ่าน keychain ของแอปอื่น (ที่ Claude Code สร้าง) ครั้งแรก macOS จะเด้ง prompt ขออนุญาต
  ผู้ใช้ต้องกด **Always Allow** ครั้งเดียว
- ใส่ `User-Agent: claude-code/...` ทุก request เสมอ ไม่งั้นโดน rate-limit bucket ที่โหดมาก

---

## 7. ค่าคงที่อ้างอิง

| ชื่อ | ค่า |
|---|---|
| usage endpoint | `https://api.anthropic.com/api/oauth/usage` |
| token endpoint | `https://platform.claude.com/v1/oauth/token` |
| client_id | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| anthropic-beta | `oauth-2025-04-20` |
| keychain service | `Claude Code-credentials` |
| scope ที่ต้องมี | `user:profile` |

---

โค้ดจริงดูได้ที่ [`mac/TokenMonitorApp/main.m`](../mac/TokenMonitorApp/main.m):
`keychainBlob`, `claudeCredentials`, `refreshAccessTokenWritingBack`,
`freshOAuthToken`, `fetchUsageWithToken:allowRefresh:`
