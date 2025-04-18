#!/bin/bash

# تأكد من تنفيذ السكربت كـ root
if [ "$EUID" -ne 0 ]; then
    echo "يجب تنفيذ السكربت كـ root!"
    exit 1
fi

# أخذ المدخلات من المستخدم
DOMAIN=$1
USER=$2

# إعداد المتغيرات
APP_NAME="odoo_${DOMAIN//./_}"
ODDO_DIR="/home/$USER/web/$DOMAIN"
DB_NAME="${USER}_${DOMAIN//./_}"
DB_USER="${USER}_odoo"
DB_PASSWORD=$(openssl rand -base64 12)
PORT=$(shuf -i 8000-9000 -n 1)
SSL_EMAIL="admin@$DOMAIN"

# إنشاء المجلد الرئيسي والتأكد من صلاحيات المستخدم
mkdir -p $ODDO_DIR/{public_html,addons,config}
chown -R $USER:$USER $ODDO_DIR

# 1. تثبيت Docker و Docker Compose إذا لزم الأمر
if ! command -v docker &> /dev/null; then
    echo "جارٍ تثبيت Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
fi

if ! command -v docker-compose &> /dev/null; then
    echo "جارٍ تثبيت Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# 2. إنشاء قاعدة بيانات عبر HestiaCP
if ! /usr/local/hestia/bin/v-add-database "$USER" "$DB_NAME" "$DB_USER" "$DB_PASSWORD"; then
    echo "فشل إنشاء قاعدة البيانات. يتم التراجع..."
    exit 1
fi

# 3. إنشاء ملف docker-compose.yml
cat > $ODDO_DIR/docker-compose.yml <<EOL
version: '3'
services:
  odoo:
    image: odoo:latest
    container_name: $APP_NAME
    restart: unless-stopped
    ports:
      - "$PORT:8069"
    volumes:
      - $ODDO_DIR/addons:/mnt/extra-addons
      - $ODDO_DIR/config:/etc/odoo
    environment:
      - HOST=postgres
      - USER=$DB_USER
      - PASSWORD=$DB_PASSWORD
      - DB_NAME=$DB_NAME
    depends_on:
      - postgres

  postgres:
    image: postgres:13
    container_name: ${APP_NAME}_db
    restart: unless-stopped
    environment:
      - POSTGRES_USER=$DB_USER
      - POSTGRES_PASSWORD=$DB_PASSWORD
      - POSTGRES_DB=$DB_NAME
    volumes:
      - $ODDO_DIR/postgres:/var/lib/postgresql/data
EOL

# 4. تشغيل الحاويات
sudo -u $USER docker-compose -f $ODDO_DIR/docker-compose.yml up -d || {
    echo "فشل تشغيل الحاويات. يتم التراجع..."
    /usr/local/hestia/bin/v-delete-database "$USER" "$DB_NAME"
    exit 1
}

# 5. إعداد Nginx مع SSL
cat > /etc/nginx/sites-available/$DOMAIN <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    
    # إعادة التوجيه إلى HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://localhost:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # تحسينات الأمان
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options "SAMEORIGIN";
}
EOL

# 6. تفعيل الموقع وإصدار شهادة SSL
ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
systemctl reload nginx

if ! certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $SSL_EMAIL; then
    echo "فشل إصدار شهادة SSL. يتم الاستمرار بدون SSL..."
    rm /etc/nginx/sites-enabled/$DOMAIN
    cp $ODDO_DIR/nginx-backup.conf /etc/nginx/sites-available/$DOMAIN
    ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    systemctl reload nginx
fi

# 7. إعداد النسخ الاحتياطي التلقائي
cat > /usr/local/bin/backup-$APP_NAME <<EOL
#!/bin/bash
tar -czf $ODDO_DIR/backup-\$(date +%F).tar.gz $ODDO_DIR/postgres $ODDO_DIR/addons
docker exec ${APP_NAME}_db pg_dump -U $DB_USER $DB_NAME > $ODDO_DIR/db-backup-\$(date +%F).sql
EOL

chmod +x /usr/local/bin/backup-$APP_NAME
echo "0 3 * * * root /usr/local/bin/backup-$APP_NAME" | sudo tee -a /etc/crontab

# 8. إعداد Fail2Ban
cat > /etc/fail2ban/jail.d/$APP_NAME.conf <<EOL
[$APP_NAME]
enabled = true
port = $PORT
filter = odoo
logpath = $ODDO_DIR/config/odoo-server.log
maxretry = 3
bantime = 1h
EOL

systemctl restart fail2ban

# 9. إرسال تفاصيل التثبيت للمستخدم
cat > $ODDO_DIR/installation-info.txt <<EOL
تم تثبيت Odoo بنجاح!

تفاصيل الوصول:
- العنوان: https://$DOMAIN
- اسم المستخدم (افتراضي): admin
- كلمة المرور (افتراضي): admin
- منفذ الحاوية: $PORT
- بيانات قاعدة البيانات:
  - المضيف: localhost
  - الاسم: $DB_NAME
  - المستخدم: $DB_USER
  - كلمة المرور: $DB_PASSWORD

نسخة احتياطية تلقائية يومية الساعة 3 صباحًا.
EOL

chown $USER:$USER $ODDO_DIR/installation-info.txt

echo "تم الانتهاء من التثبيت! تفاصيل التثبيت في: $ODDO_DIR/installation-info.txt"
