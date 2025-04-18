### التحسينات الرئيسية:

1. **إدارة المنافذ الديناميكية**:
```bash
PORT=$(shuf -i 8000-9000 -n 1)
```
- يختار منفذًا عشوائيًا بين 8000-9000 لكل تثبيت جديد.

2. **التكامل مع HestiaCP**:
```bash
/usr/local/hestia/bin/v-add-database "$USER" "$DB_NAME" "$DB_USER" "$DB_PASSWORD"
```
- يستخدم الأوامر الرسمية لـ HestiaCP لإدارة قواعد البيانات.

3. **Docker Compose**:
```yaml
version: '3'
services:
  odoo:
    # ...
  postgres:
    # ...
```
- يفصل بين حاويات Odoo وPostgreSQL لكل نسخة.

4. **SSL التلقائي مع التراجع الآمن**:
```bash
if ! certbot --nginx ...; then
    echo "فشل SSL. الاستمرار بدون..."
    # استعادة إعدادات Nginx الأصلية
fi
```

5. **نظام النسخ الاحتياطي**:
```bash
echo "0 3 * * * root /usr/local/bin/backup-$APP_NAME" | sudo tee -a /etc/crontab
```
- ينشئ نسخًا احتياطية يومية للبيانات وقاعدة البيانات.

6. **أمان متقدم**:
```bash
# إعدادات Nginx الأمنية
add_header Strict-Transport-Security...;

# قواعد Fail2Ban المخصصة
[$APP_NAME]
enabled = true
port = $PORT
```

### كيفية الاستخدام:
1. أضف السكربت إلى `/usr/local/hestia/data/templates/web/quick_apps/odoo.sh`
2. اجعله قابل للتنفيذ:
```bash
chmod +x /usr/local/hestia/data/templates/web/quick_apps/odoo.sh
```
3. أضفه إلى قائمة التطبيقات السريعة في `available_apps`:
```
odoo|Odoo (Advanced)|odoo.sh
```

### المميزات الجديدة:
- عزل كامل لكل نسخة عبر Docker Compose
- إدارة SSL تلقائية مع تراجع آمن
- مراقبة الحماية عبر Fail2Ban
- نسخ احتياطي يومي تلقائي
- تكامل كامل مع نظام HestiaCP
- تقرير تثبيت تلقائي للمستخدم

ملاحظة: تأكد من تثبيت الحزم المطلوبة مسبقًا (`fail2ban`, `certbot`) على الخادم قبل التنفيذ.
