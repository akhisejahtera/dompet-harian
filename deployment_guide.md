# Panduan Deploy DompetHarian ke aaPanel (ARM64 + Nginx)

Panduan ini menjelaskan langkah-langkah untuk melakukan deploy aplikasi Sinatra (Ruby) dan PostgreSQL ke server aaPanel kamu yang menggunakan arsitektur **ARM64** dan **Nginx**.

---

## Prasyarat Server (aaPanel)
1. OS Server: Ubuntu 20.04/22.04 LTS atau Debian 11/12 (Direkomendasikan untuk ARM64).
2. Nginx sudah terinstal melalui App Store aaPanel.
3. PostgreSQL sudah terinstal melalui App Store aaPanel.

---

## Langkah 1: Persiapan Database di aaPanel

1. Buka panel **aaPanel** kamu.
2. Masuk ke menu **Databases** -> tab **PostgreSQL** (jika menggunakan database manager aaPanel).
3. Buat database baru:
   - **Database Name**: `dompet_harian`
   - **Username**: (buat user baru, misal `db_harian`)
   - **Password**: (buat password yang aman)
4. Pastikan service PostgreSQL dalam keadaan berjalan (*Running*).

---

## Langkah 2: Install Ruby & Dependencies di Server (ARM64)

Karena arsitektur server adalah ARM64, kita akan menginstal Ruby dan compiler headers langsung dari sistem operasi agar proses kompilasi native extension `pg` berjalan lancar.

Buka terminal server aaPanel (bisa lewat menu **Terminal** di aaPanel atau SSH biasa), lalu jalankan perintah berikut:

```bash
# Update package list
sudo apt update

# Install Ruby dan compiler tools (wajib untuk kompilasi gem C-extension di ARM64)
sudo apt install -y ruby-full build-essential patch ruby-dev zlib1g-dev liblzma-dev libpq-dev git

# Install Bundler secara global
sudo gem install bundler
```

> [!IMPORTANT]
> Library `libpq-dev` wajib diinstal karena berisi headers PostgreSQL (`pg_config` & `libpq`) yang dibutuhkan untuk memproses instalasi gem `pg`.

---

## Langkah 3: Upload Kode Aplikasi

Kamu bisa meng-clone langsung dari GitHub ke folder web aaPanel:

```bash
# Masuk ke direktori web server
cd /www/wwwroot

# Clone repository
git clone https://github.com/akhisejahtera/dompet-harian.git

# Masuk ke folder aplikasi
cd dompet-harian
```

*Alternatif:* Kamu juga bisa mengunggah file ZIP project kamu lewat menu **Files** di aaPanel ke folder `/www/wwwroot/dompet-harian` lalu mengekstraknya di sana.

---

## Langkah 4: Install Dependencies & Konfigurasi Lingkungan

Di dalam direktori `/www/wwwroot/dompet-harian`, jalankan perintah berikut:

1. **Install Gems**:
   ```bash
   bundle install --path vendor/bundle
   ```
2. **Buat file `.env`**:
   Buat file bernama `.env` di root folder aplikasi untuk menyimpan kredensial database server:
   ```bash
   nano .env
   ```
   Isi file `.env` dengan kredensial PostgreSQL yang kamu buat di Langkah 1:
   ```env
   DB_USER=username_database_kamu
   DB_PASSWORD=password_database_kamu
   ```

---

## Langkah 5: Jalankan Aplikasi di Background (Systemd)

Untuk memastikan aplikasi terus berjalan di background dan otomatis aktif kembali jika server restart, kita akan membuat service systemd.

1. Buat file service baru:
   ```bash
   sudo nano /etc/systemd/system/dompetharian.service
   ```
2. Masukkan konfigurasi berikut (sesuaikan path ruby/bundle jika berbeda):
   ```ini
   [Unit]
   Description=DompetHarian Sinatra Expense Tracker
   After=network.target postgresql.service

   [Service]
   Type=simple
   User=www
   WorkingDirectory=/www/wwwroot/dompet-harian
   # Menggunakan Webrick bawaan pada port 4567 secara lokal
   ExecStart=/usr/bin/bundle exec rackup -p 4567 -o 127.0.0.1
   Restart=always
   Environment=RACK_ENV=production

   [Install]
   WantedBy=multi-user.target
   ```
3. Aktifkan dan jalankan service-nya:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable dompetharian
   sudo systemctl start dompetharian
   ```
4. Cek status aplikasi:
   ```bash
   sudo systemctl status dompetharian
   ```

---

## Langkah 6: Konfigurasi Nginx Reverse Proxy di aaPanel

Sekarang kita akan menghubungkan Nginx di aaPanel agar mengarahkan traffic domain ke aplikasi Sinatra lokal (port `4567`).

1. Di aaPanel, pergi ke menu **Website** -> Klik **Add Site**.
2. Masukkan **Domain** kamu (atau IP publik server jika belum ada domain).
3. Pada opsi **Database** pilih *No* (karena kita sudah buat manual di Langkah 1).
4. Klik **Submit**.
5. Setelah website terbuat, klik pada **Nama Website** tersebut untuk membuka setelan website.
6. Pergi ke menu **Reverse Proxy** (di kolom menu sebelah kiri setelan) -> Klik **Add reverse proxy**.
7. Konfigurasikan proxy:
   - **Proxy Name**: `dompet_harian_proxy`
   - **Target URL**: `http://127.0.0.1:4567`
   - **Sent Domain**: `$host`
8. Klik **Submit/Save**.

🎉 **Selesai!** Sekarang jika kamu mengakses domain atau IP website tersebut di browser, Nginx akan meneruskan request secara aman ke aplikasi Sinatra kamu.
