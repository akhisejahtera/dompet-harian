require 'sinatra/base'
require 'pg'
require 'dotenv'
require 'json'
require 'date'
require 'openssl'
require 'securerandom'

Dotenv.load

# Password Hashing utility using standard OpenSSL PBKDF2 (safe on macOS system Ruby)
class PasswordHasher
  def self.hash_password(password)
    salt = SecureRandom.hex(16)
    iterations = 20000
    hash = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, 32, 'sha256')
    "pbkdf2$#{iterations}$#{salt}$#{hash.unpack1('H*')}"
  end

  def self.verify_password(password, digest)
    return false if digest.nil?
    parts = digest.split('$')
    return false unless parts.size == 4 && parts[0] == 'pbkdf2'
    
    iterations = parts[1].to_i
    salt = parts[2]
    stored_hash = parts[3]
    
    hash = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, 32, 'sha256')
    secure_compare(hash.unpack1('H*'), stored_hash)
  end

  private

  def self.secure_compare(a, b)
    return false unless a.bytesize == b.bytesize
    l = a.unpack("C*")
    r = b.unpack("C*")
    res = 0
    l.zip(r).each { |x, y| res |= x ^ y }
    res == 0
  end
end

class DompetHarian < Sinatra::Base
  def self.db_config(dbname)
    config = {
      dbname: dbname,
      user: ENV['DB_USER'] || ENV['USER'] || 'yaakhi',
      host: ENV['DB_HOST'] || '127.0.0.1',
      port: (ENV['DB_PORT'] || 5432).to_i
    }
    config[:password] = ENV['DB_PASSWORD'] if ENV['DB_PASSWORD'] && !ENV['DB_PASSWORD'].strip.empty?
    config
  end

  def self.setup_database
    user = ENV['DB_USER'] || ENV['USER'] || 'yaakhi'
    puts "Initializing database using configuration..."
    
    # 1. Connect to default postgres DB to ensure dompet_harian database exists
    begin
      conn = PG.connect(db_config('postgres'))
      db_exists = conn.exec("SELECT 1 FROM pg_database WHERE datname = 'dompet_harian'").any?
      unless db_exists
        conn.exec("CREATE DATABASE dompet_harian")
        puts "Database 'dompet_harian' created successfully."
      end
    rescue => e
      puts "Notice during DB check/creation: #{e.message}"
    ensure
      conn.close if conn
    end

    # 2. Connect to dompet_harian database and create/migrate schema
    begin
      conn = PG.connect(db_config('dompet_harian'))
      
      # Create users table
      conn.exec <<-SQL
        CREATE TABLE IF NOT EXISTS users (
          id SERIAL PRIMARY KEY,
          username VARCHAR(50) NOT NULL UNIQUE,
          email VARCHAR(100) NOT NULL UNIQUE,
          password_digest VARCHAR(255) NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      SQL
      puts "Table 'users' checked/created successfully."

      # Check if legacy expenses table exists
      expenses_exist = conn.exec("SELECT 1 FROM pg_tables WHERE tablename = 'expenses'").any?
      # Check if transactions table exists
      transactions_exist = conn.exec("SELECT 1 FROM pg_tables WHERE tablename = 'transactions'").any?

      if expenses_exist && !transactions_exist
        puts "Migrating table 'expenses' to 'transactions'..."
        conn.exec("ALTER TABLE expenses RENAME TO transactions")
        transactions_exist = true
      end

      if transactions_exist
        # Ensure type column exists on transactions
        conn.exec("ALTER TABLE transactions ADD COLUMN IF NOT EXISTS type VARCHAR(10) NOT NULL DEFAULT 'expense'")
        # Ensure user_id column exists
        conn.exec("ALTER TABLE transactions ADD COLUMN IF NOT EXISTS user_id INTEGER REFERENCES users(id) ON DELETE CASCADE")
        puts "Table 'transactions' verified/updated successfully."
      else
        # Create transactions table from scratch
        conn.exec <<-SQL
          CREATE TABLE IF NOT EXISTS transactions (
            id SERIAL PRIMARY KEY,
            title VARCHAR(100) NOT NULL,
            amount NUMERIC(15, 2) NOT NULL,
            type VARCHAR(10) NOT NULL DEFAULT 'expense',
            category VARCHAR(50) NOT NULL,
            date DATE NOT NULL,
            notes TEXT,
            user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          );
        SQL
        puts "Table 'transactions' created successfully."
      end

      # Data migration for existing orphaned transactions (user_id IS NULL)
      orphaned_exists = conn.exec("SELECT 1 FROM transactions WHERE user_id IS NULL LIMIT 1").any?
      if orphaned_exists
        puts "Found orphaned transactions. Migrating to default user 'yaakhi'..."
        # Check if default user exists
        default_user_res = conn.exec_params("SELECT id FROM users WHERE username = $1", ['yaakhi'])
        if default_user_res.any?
          yaakhi_id = default_user_res[0]['id'].to_i
        else
          # Create user 'yaakhi'
          default_digest = PasswordHasher.hash_password('password123')
          insert_res = conn.exec_params(
            "INSERT INTO users (username, email, password_digest) VALUES ($1, $2, $3) RETURNING id",
            ['yaakhi', 'yaakhi@dompetharian.com', default_digest]
          )
          yaakhi_id = insert_res[0]['id'].to_i
          puts "Default user 'yaakhi' created successfully."
        end
        
        # Associate orphaned transactions to yaakhi
        conn.exec_params("UPDATE transactions SET user_id = $1 WHERE user_id IS NULL", [yaakhi_id])
        puts "Successfully linked existing transactions to user 'yaakhi' (id: #{yaakhi_id})."
      end

    rescue => e
      puts "Database initialization failed: #{e.message}"
      raise e
    ensure
      conn.close if conn
    end
  end

  # Configure Sinatra
  configure do
    set :public_folder, File.dirname(__FILE__) + '/public'
    set :views, File.dirname(__FILE__) + '/views'
    enable :sessions
    set :session_secret, 'supersecretkey_dompetharian'

    # Auto-initialize database on startup
    setup_database
  end

  # DB Connection helper for request lifetime
  helpers do
    def db
      @db ||= PG.connect(DompetHarian.db_config('dompet_harian'))
    end

    def current_user
      return nil unless session[:user_id]
      @current_user ||= db.exec_params("SELECT id, username, email FROM users WHERE id = $1", [session[:user_id]]).first
    end

    def user_initials(username)
      return '?' if username.nil? || username.strip.empty?
      parts = username.strip.split(/\s+/)
      if parts.size >= 2
        (parts[0][0] + parts[1][0]).upcase
      else
        username[0..1].upcase
      end
    end

    def format_idr(number)
      # Format: Rp 150.000
      parts = number.to_f.round.to_s.split('.')
      integer_part = parts[0].gsub(/(\d)(?=(\d\d\d)+(?!\d))/, '\\1.')
      "Rp #{integer_part}"
    end

    def format_date(date_str)
      # Format YYYY-MM-DD to readable Indonesian format: e.g. 24 Jun 2026
      date = Date.parse(date_str)
      months = %w[Jan Feb Mar Apr Mei Jun Jul Agu Sep Okt Nov Des]
      "#{date.day} #{months[date.month - 1]} #{date.year}"
    end

    def category_icon(category)
      case category
      when 'Makanan & Minuman' then 'utensils'
      when 'Transportasi' then 'car'
      when 'Tagihan & Utilitas' then 'receipt'
      when 'Hiburan & Rekreasi' then 'gamepad-2'
      when 'Belanja' then 'shopping-bag'
      when 'Kesehatan' then 'heart-pulse'
      when 'Gaji' then 'briefcase'
      when 'Investasi' then 'trending-up'
      when 'Wirausaha' then 'store'
      else 'credit-card'
      end
    end

    def category_color_class(category)
      case category
      when 'Makanan & Minuman' then 'cat-food'
      when 'Transportasi' then 'cat-transport'
      when 'Tagihan & Utilitas' then 'cat-bills'
      when 'Hiburan & Rekreasi' then 'cat-entertainment'
      when 'Belanja' then 'cat-shopping'
      when 'Kesehatan' then 'cat-health'
      when 'Gaji' then 'cat-salary'
      when 'Investasi' then 'cat-investment'
      when 'Wirausaha' then 'cat-business'
      else 'cat-others'
      end
    end
  end

  after do
    @db.close if @db
  end

  # Predefined categories for UI forms
  EXPENSE_CATEGORIES = [
    'Makanan & Minuman',
    'Transportasi',
    'Tagihan & Utilitas',
    'Hiburan & Rekreasi',
    'Belanja',
    'Kesehatan',
    'Lainnya'
  ].freeze

  INCOME_CATEGORIES = [
    'Gaji',
    'Investasi',
    'Wirausaha',
    'Lainnya'
  ].freeze

  # --- AUTH MIDDLEWARE ---
  before do
    # Whitelisted routes (public pages & assets)
    public_routes = ['/login', '/register']
    path = request.path_info
    
    pass if public_routes.include?(path) || path.start_with?('/css') || path.start_with?('/js')
    
    unless session[:user_id]
      if request.xhr?
        content_type :json
        halt 401, { success: false, error: 'Silakan login terlebih dahulu!' }.to_json
      else
        session[:error] = 'Silakan login terlebih dahulu!'
        redirect '/login'
      end
    end
  end

  # --- ROUTES ---

  # 1. Login Views & Logic
  get '/login' do
    redirect '/' if session[:user_id]
    erb :login, layout: false
  end

  post '/login' do
    username = params[:username]
    password = params[:password]

    if username.nil? || username.strip.empty? || password.nil? || password.empty?
      session[:error] = 'Username dan password wajib diisi!'
      redirect '/login'
    end

    user_res = db.exec_params(
      "SELECT * FROM users WHERE username = $1 OR email = $1",
      [username.strip]
    ).first

    if user_res && PasswordHasher.verify_password(password, user_res['password_digest'])
      session[:user_id] = user_res['id'].to_i
      session[:success] = "Selamat datang kembali, #{user_res['username']}!"
      redirect '/'
    else
      session[:error] = 'Username/Email atau password salah!'
      redirect '/login'
    end
  end

  # 2. Register Views & Logic
  get '/register' do
    redirect '/' if session[:user_id]
    erb :register, layout: false
  end

  post '/register' do
    username = params[:username]
    email = params[:email]
    password = params[:password]
    confirm_password = params[:confirm_password]

    if username.nil? || username.strip.empty? || email.nil? || email.strip.empty? || password.nil? || password.empty?
      session[:error] = 'Semua field wajib diisi!'
      redirect '/register'
    end

    if password != confirm_password
      session[:error] = 'Konfirmasi password tidak cocok!'
      redirect '/register'
    end

    # Check for existing username or email
    existing_user = db.exec_params(
      "SELECT 1 FROM users WHERE username = $1 OR email = $2",
      [username.strip, email.strip]
    ).any?

    if existing_user
      session[:error] = 'Username atau Email sudah terdaftar!'
      redirect '/register'
    end

    begin
      digest = PasswordHasher.hash_password(password)
      res = db.exec_params(
        "INSERT INTO users (username, email, password_digest) VALUES ($1, $2, $3) RETURNING id",
        [username.strip, email.strip, digest]
      )
      session[:user_id] = res[0]['id'].to_i
      session[:success] = 'Akun berhasil dibuat! Selamat datang di DompetHarian.'
      redirect '/'
    rescue => e
      session[:error] = "Gagal mendaftarkan akun: #{e.message}"
      redirect '/register'
    end
  end

  # 3. Logout Logic
  post '/logout' do
    session.clear
    session[:success] = 'Anda telah berhasil logout.'
    redirect '/login'
  end

  # 4. Dashboard View
  get '/' do
    user_id = session[:user_id]
    today = Date.today.to_s
    first_of_month = Date.new(Date.today.year, Date.today.month, 1).to_s
    
    # Total Today (Expenses)
    res_today = db.exec_params("SELECT SUM(amount) FROM transactions WHERE date = $1 AND type = 'expense' AND user_id = $2", [today, user_id])
    @total_today = res_today[0]['sum'] ? res_today[0]['sum'].to_f : 0.0

    # Total Expenses This Month
    res_month = db.exec_params("SELECT SUM(amount) FROM transactions WHERE date >= $1 AND date <= CURRENT_DATE AND type = 'expense' AND user_id = $2", [first_of_month, user_id])
    @total_month = res_month[0]['sum'] ? res_month[0]['sum'].to_f : 0.0

    # Total Income This Month
    res_income = db.exec_params("SELECT SUM(amount) FROM transactions WHERE date >= $1 AND date <= CURRENT_DATE AND type = 'income' AND user_id = $2", [first_of_month, user_id])
    @total_income = res_income[0]['sum'] ? res_income[0]['sum'].to_f : 0.0

    # Net Balance (all time)
    res_bal_income = db.exec_params("SELECT SUM(amount) FROM transactions WHERE type = 'income' AND user_id = $1", [user_id])
    res_bal_expense = db.exec_params("SELECT SUM(amount) FROM transactions WHERE type = 'expense' AND user_id = $1", [user_id])
    total_income_all = res_bal_income[0]['sum'] ? res_bal_income[0]['sum'].to_f : 0.0
    total_expense_all = res_bal_expense[0]['sum'] ? res_bal_expense[0]['sum'].to_f : 0.0
    @balance = total_income_all - total_expense_all

    # Average Daily Expense This Month
    day_count = Date.today.day
    @avg_daily = day_count > 0 ? (@total_month / day_count) : 0.0

    # Recent 5 transactions
    @recent_transactions = db.exec_params("SELECT * FROM transactions WHERE user_id = $1 ORDER BY date DESC, id DESC LIMIT 5", [user_id]).to_a
    @recent_expenses = @recent_transactions # fallback for view compatibility

    # Category breakdown for charts (Expenses this month)
    @category_stats = db.exec_params(
      "SELECT category, SUM(amount) as total FROM transactions WHERE date >= $1 AND type = 'expense' AND user_id = $2 GROUP BY category ORDER BY total DESC",
      [first_of_month, user_id]
    ).to_a

    @expense_categories = EXPENSE_CATEGORIES
    @income_categories = INCOME_CATEGORIES
    @categories = EXPENSE_CATEGORIES + INCOME_CATEGORIES
    erb :dashboard
  end

  # 5. History & Filters View
  get '/expenses' do
    user_id = session[:user_id]
    
    # Read filter query params
    @search_query = params[:search]
    @category_filter = params[:category]
    @type_filter = params[:type]
    @start_date = params[:start_date]
    @end_date = params[:end_date]

    sql_parts = ["SELECT * FROM transactions WHERE user_id = $1"]
    params_list = [user_id]
    param_idx = 2

    if @search_query && !@search_query.strip.empty?
      sql_parts << "AND title ILIKE $#{param_idx}"
      params_list << "%#{@search_query}%"
      param_idx += 1
    end

    if @category_filter && !@category_filter.empty?
      sql_parts << "AND category = $#{param_idx}"
      params_list << @category_filter
      param_idx += 1
    end

    if @type_filter && !@type_filter.empty?
      sql_parts << "AND type = $#{param_idx}"
      params_list << @type_filter
      param_idx += 1
    end

    if @start_date && !@start_date.empty?
      sql_parts << "AND date >= $#{param_idx}"
      params_list << @start_date
      param_idx += 1
    end

    if @end_date && !@end_date.empty?
      sql_parts << "AND date <= $#{param_idx}"
      params_list << @end_date
      param_idx += 1
    end

    sql_parts << "ORDER BY date DESC, id DESC"
    full_sql = sql_parts.join(" ")

    @transactions = db.exec_params(full_sql, params_list).to_a
    @expenses = @transactions
    
    @expense_categories = EXPENSE_CATEGORIES
    @income_categories = INCOME_CATEGORIES
    @categories = EXPENSE_CATEGORIES + INCOME_CATEGORIES
    
    erb :expenses
  end

  # 6. Add Transaction (Supports normal form POST and AJAX)
  post '/expenses' do
    user_id = session[:user_id]
    title = params[:title]
    amount = params[:amount].to_f
    type = params[:type] || 'expense'
    category = params[:category]
    date = params[:date]
    notes = params[:notes]

    # Validate inputs
    if title.nil? || title.strip.empty? || amount <= 0 || category.nil? || date.nil? || date.empty? || !['expense', 'income'].include?(type)
      status 400
      if request.xhr?
        content_type :json
        return { success: false, error: 'Silakan isi semua field dengan benar!' }.to_json
      else
        session[:error] = 'Silakan isi semua field dengan benar!'
        redirect back
      end
    end

    # Insert into database
    begin
      db.exec_params(
        "INSERT INTO transactions (title, amount, type, category, date, notes, user_id) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        [title, amount, type, category, date, notes, user_id]
      )

      if request.xhr?
        content_type :json
        status 200
        { success: true, message: 'Catatan transaksi berhasil disimpan!' }.to_json
      else
        session[:success] = 'Catatan transaksi berhasil disimpan!'
        redirect '/'
      end
    rescue => e
      status 500
      if request.xhr?
        content_type :json
        { success: false, error: "Gagal menyimpan ke database: #{e.message}" }.to_json
      else
        session[:error] = "Gagal menyimpan ke database: #{e.message}"
        redirect back
      end
    end
  end

  # 7. Delete Transaction
  post '/expenses/:id/delete' do
    user_id = session[:user_id]
    id = params[:id].to_i
    
    begin
      result = db.exec_params("DELETE FROM transactions WHERE id = $1 AND user_id = $2", [id, user_id])
      
      if request.xhr?
        content_type :json
        status 200
        { success: true, message: 'Catatan berhasil dihapus!' }.to_json
      else
        session[:success] = 'Catatan berhasil dihapus!'
        redirect back
      end
    rescue => e
      status 500
      if request.xhr?
        content_type :json
        { success: false, error: "Gagal menghapus catatan: #{e.message}" }.to_json
      else
        session[:error] = "Gagal menghapus catatan: #{e.message}"
        redirect back
      end
    end
  end

  # 8. Reports & Charts View (and data API)
  get '/reports' do
    user_id = session[:user_id]
    first_of_month = Date.new(Date.today.year, Date.today.month, 1).to_s
    
    # 1. Doughnut chart data (Category totals)
    expense_data = db.exec_params(
      "SELECT category, SUM(amount) as total FROM transactions WHERE date >= $1 AND type = 'expense' AND user_id = $2 GROUP BY category",
      [first_of_month, user_id]
    )
    @category_chart = expense_data.map { |row| { category: row['category'], total: row['total'].to_f } }

    income_data = db.exec_params(
      "SELECT category, SUM(amount) as total FROM transactions WHERE date >= $1 AND type = 'income' AND user_id = $2 GROUP BY category",
      [first_of_month, user_id]
    )
    @income_category_chart = income_data.map { |row| { category: row['category'], total: row['total'].to_f } }

    # 2. Line chart data (Daily spending & income trend last 30 days)
    thirty_days_ago = (Date.today - 30).to_s
    
    daily_expense_data = db.exec_params(
      "SELECT date, SUM(amount) as total FROM transactions WHERE date >= $1 AND type = 'expense' AND user_id = $2 GROUP BY date ORDER BY date ASC",
      [thirty_days_ago, user_id]
    )

    daily_income_data = db.exec_params(
      "SELECT date, SUM(amount) as total FROM transactions WHERE date >= $1 AND type = 'income' AND user_id = $2 GROUP BY date ORDER BY date ASC",
      [thirty_days_ago, user_id]
    )
    
    # Build complete list of last 30 days to fill in gaps with 0
    expense_date_map = {}
    daily_expense_data.each { |row| expense_date_map[row['date']] = row['total'].to_f }

    income_date_map = {}
    daily_income_data.each { |row| income_date_map[row['date']] = row['total'].to_f }
    
    @daily_trend = []
    (30).downto(0) do |i|
      d = (Date.today - i).to_s
      @daily_trend << { 
        date: d, 
        formatted_date: Date.parse(d).strftime('%d %b'), 
        total: expense_date_map[d] || 0.0,
        income_total: income_date_map[d] || 0.0
      }
    end

    if request.xhr?
      content_type :json
      { categories: @category_chart, income_categories: @income_category_chart, daily: @daily_trend }.to_json
    else
      erb :reports
    end
  end
end
